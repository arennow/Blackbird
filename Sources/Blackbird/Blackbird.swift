//
//           /\
//          |  |                       Blackbird
//          |  |
//         .|  |.       https://github.com/marcoarment/Blackbird
//         $    $
//        /$    $\          Copyright 2022–2023 Marco Arment
//       / $|  |$ \          Released under the MIT License
//      .__$|  |$__.
//           \/
//
//  Blackbird.swift
//  Created by Marco Arment on 11/6/22.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation
import SQLite3
import Synchronization
import Semaphore

/// A small, fast, lightweight SQLite database wrapper and model layer.
public class Blackbird {
    /// A dictionary of argument values for a database query, keyed by column names.
    public typealias Arguments = Dictionary<String, Blackbird.Value>
    
    /// A set of primary-key values, where each is an array of values (to support multi-column primary keys).
    public typealias PrimaryKeyValues = Set<[Blackbird.Value]>

    /// A set of column names.
    public typealias ColumnNames = Set<String>

    /// Basic info for a ``BlackbirdColumn`` as returned by ``BlackbirdModel/columnInfoFromKeyPaths(_:)``.
    public struct ColumnInfo {
        /// The column's name.
        public let name: String
        
        /// The column's type.
        public let type: any BlackbirdColumnWrappable.Type
    }

    public enum Error: Swift.Error {
        /// Throw this within a `cancellableTransaction` block to cancel and roll back the transaction. It will not propagate further up the call stack.
        case cancelTransaction
    }

    /// A wrapper for SQLite's column data types.
    public enum Value: Sendable, ExpressibleByStringLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, Hashable, Comparable {
        public static func < (lhs: Blackbird.Value, rhs: Blackbird.Value) -> Bool {
            switch lhs {
                case .null:           return false
                case let .integer(i): return i < rhs.int64Value ?? 0
                case let .double(d):  return d < rhs.doubleValue ?? 0
                case let .text(s):    return s < rhs.stringValue ?? ""
                case let .data(b):    return b.count < rhs.dataValue?.count ?? 0
            }
        }
        
        case null
        case integer(Int64)
        case double(Double)
        case text(String)
        case data(Data)

        public enum Error: Swift.Error {
            case cannotConvertToValue
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(sqliteLiteral())
        }
        
        public static func fromAny(_ value: Any?) throws -> Value {
            guard var value else { return .null }
            
            if let optional = value as? any OptionalProtocol {
                if let wrapped = optional.wrappedOptionalValue {
                    value = wrapped
                } else {
                    return .null
                }
            }
            
            switch value {
                case _ as NSNull: return .null
                case let v as Value: return v
                case let v as any StringProtocol: return .text(String(v))
                case let v as any BlackbirdStorableAsInteger: return .integer(v.unifiedRepresentation())
                case let v as any BlackbirdStorableAsDouble: return .double(v.unifiedRepresentation())
                case let v as any BlackbirdStorableAsText: return .text(v.unifiedRepresentation())
                case let v as any BlackbirdStorableAsData: return .data(v.unifiedRepresentation())
                case let v as any BlackbirdIntegerEnum: return .integer(v.rawValue.unifiedRepresentation())
                case let v as any BlackbirdStringEnum: return .text(v.rawValue.unifiedRepresentation())
                default: throw Error.cannotConvertToValue
            }
        }

        public init(stringLiteral value: String) { self = .text(value) }
        public init(floatLiteral value: Double)  { self = .double(value) }
        public init(integerLiteral value: Int64) { self = .integer(value) }
        public init(booleanLiteral value: Bool)  { self = .integer(value ? 1 : 0) }
        
        public func sqliteLiteral() -> String {
            switch self {
                case let .integer(i): return String(i)
                case let .double(d):  return String(d)
                case let .text(s):    return "'\(s.replacingOccurrences(of: "'", with: "''"))'"
                case let .data(b):    return "X'\(b.map { String(format: "%02hhX", $0) }.joined())'"
                case .null:           return "NULL"
            }
        }
        
        public static func fromSQLiteLiteral(_ literalString: String) -> Self? {
            if literalString == "NULL" { return .null }
            
            if literalString.hasPrefix("'"), literalString.hasSuffix("'") {
                let start = literalString.index(literalString.startIndex, offsetBy: 1)
                let end = literalString.index(literalString.endIndex, offsetBy: -1)
                return .text(literalString[start..<end].replacingOccurrences(of: "''", with: "'"))
            }

            if literalString.hasPrefix("X'"), literalString.hasSuffix("'") {
                let start = literalString.index(literalString.startIndex, offsetBy: 2)
                let end = literalString.index(literalString.endIndex, offsetBy: -1)
                let hex = literalString[start..<end].replacingOccurrences(of: "''", with: "'")
                
                let hexChars = hex.map { $0 }
                let hexPairs = stride(from: 0, to: hexChars.count, by: 2).map { String(hexChars[$0]) + String(hexChars[$0 + 1]) }
                let bytes = hexPairs.compactMap { UInt8($0, radix: 16) }
                return .data(Data(bytes))
            }
            
            if let i = Int64(literalString) { return .integer(i) }
            if let d = Double(literalString) { return .double(d) }
            return nil
        }

        public var boolValue: Bool? {
            switch self {
                case .null:           return nil
                case let .integer(i): return i > 0
                case let .double(d):  return d > 0
                case let .text(s):    return (Int(s) ?? 0) != 0
                case let .data(b):    if let str = String(data: b, encoding: .utf8), let i = Int(str) { return i != 0 } else { return nil }
            }
        }

        public var dataValue: Data? {
            switch self {
                case .null:           return nil
                case let .data(b):    return b
                case let .integer(i): return String(i).data(using: .utf8)
                case let .double(d):  return String(d).data(using: .utf8)
                case let .text(s):    return s.data(using: .utf8)
            }
        }

        public var doubleValue: Double? {
            switch self {
                case .null:           return nil
                case let .double(d):  return d
                case let .integer(i): return Double(i)
                case let .text(s):    return Double(s)
                case let .data(b):    if let str = String(data: b, encoding: .utf8) { return Double(str) } else { return nil }
            }
        }

        public var intValue: Int? {
            switch self {
                case .null:           return nil
                case let .integer(i): return Int(i)
                case let .double(d):  return Int(d)
                case let .text(s):    return Int(s)
                case let .data(b):    if let str = String(data: b, encoding: .utf8) { return Int(str) } else { return nil }
            }
        }

        public var int64Value: Int64? {
            switch self {
                case .null:           return nil
                case let .integer(i): return Int64(i)
                case let .double(d):  return Int64(d)
                case let .text(s):    return Int64(s)
                case let .data(b):    if let str = String(data: b, encoding: .utf8) { return Int64(str) } else { return nil }
            }
        }

        public var stringValue: String? {
            switch self {
                case .null:           return nil
                case let .text(s):    return s
                case let .integer(i): return String(i)
                case let .double(d):  return String(d)
                case let .data(b):    return String(data: b, encoding: .utf8)
            }
        }

        internal func objcValue() -> NSObject {
            switch self {
                case .null:           return NSNull()
                case let .integer(i): return NSNumber(value: i)
                case let .double(d):  return NSNumber(value: d)
                case let .text(s):    return NSString(string: s)
                case let .data(d):    return NSData(data: d)
            }
        }

        private static let copyValue = unsafeBitCast(-1, to: sqlite3_destructor_type.self) // a.k.a. SQLITE_TRANSIENT
        
        internal func bind(database: isolated Blackbird.Database.Core, statement: OpaquePointer, index: Int32, for query: String) throws {
            var result: Int32
            switch self {
                case     .null:       result = sqlite3_bind_null(statement, index)
                case let .integer(i): result = sqlite3_bind_int64(statement, index, i)
                case let .double(d):  result = sqlite3_bind_double(statement, index, d)
                case let .text(s):    result = sqlite3_bind_text(statement, index, s, -1, Blackbird.Value.copyValue)
                case let .data(d):    result = d.withUnsafeBytes { bytes in sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Blackbird.Value.copyValue) }
            }
            if result != SQLITE_OK { throw Blackbird.Database.Error.queryArgumentValueError(query: query, description: database.errorDesc(database.dbHandle)) }
        }
        
        internal func bind(database: isolated Blackbird.Database.Core, statement: OpaquePointer, name: String, for query: String) throws {
            let idx = sqlite3_bind_parameter_index(statement, name)
            if idx == 0 { throw Blackbird.Database.Error.queryArgumentNameError(query: query, name: name) }
            return try bind(database: database, statement: statement, index: idx, for: query)
        }
    }
}

// MARK: - Utilities

extension Blackbird {
    internal final class FileChangeMonitor: Sendable {
        private struct State {
            var sources: [DispatchSourceFileSystemObject] = []
            var changeHandler: (@Sendable () -> Void)? = nil
            var isClosed = false
            var currentExpectedChanges = Set<Int64>()
        }

        private let state = Mutex(State())

        public func addFile(filePath: String) {
            let fsPath = (filePath as NSString).fileSystemRepresentation
            let fd = open(fsPath, O_EVTONLY)
            guard fd >= 0 else { return }

            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: nil)
            source.setCancelHandler { Darwin.close(fd) }

            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.state.withLock { s in
                    if s.currentExpectedChanges.isEmpty, !s.isClosed { s.changeHandler?() }
                }
            }

            source.activate()
            state.withLock { $0.sources.append(source) }
        }

        deinit {
            cancel()
        }

        public func onChange(_ handler: @escaping @Sendable () -> Void) {
            state.withLock { $0.changeHandler = handler }
        }

        public func cancel() {
            state.withLock { s in
                s.isClosed = true
                for source in s.sources { source.cancel() }
            }
        }

        public func beginExpectedChange(_ changeID: Int64) {
            state.withLock { _ = $0.currentExpectedChanges.insert(changeID) }
        }

        public func endExpectedChange(_ changeID: Int64) {
            state.withLock { _ = $0.currentExpectedChanges.remove(changeID) }
        }
    }
}
