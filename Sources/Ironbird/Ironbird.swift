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
#if canImport(SQLite3)
	import SQLite3
#elseif canImport(CSQLite3)
	import CSQLite3
#endif
import Synchronization

/// A small, fast, lightweight SQLite database wrapper and model layer.
public enum Ironbird {
	/// A dictionary of argument values for a database query, keyed by column names.
	public typealias Arguments = Dictionary<String, Ironbird.Value>

	/// A set of primary-key values, where each is an array of values (to support multi-column primary keys).
	public typealias PrimaryKeyValues = Set<[Ironbird.Value]>

	/// A set of column names.
	public typealias ColumnNames = Set<String>

	/// Basic info for a ``IronbirdColumn`` as returned by ``IronbirdModel/columnInfoFromKeyPaths(_:)``.
	public struct ColumnInfo {
		/// The column's name.
		public let name: String

		/// The column's type.
		public let type: any IronbirdColumnWrappable.Type
	}

	public enum Error: Swift.Error {
		/// Throw this within a `cancellableTransaction` block to cancel and roll back the transaction. It will not propagate further up the call stack.
		case cancelTransaction
	}

	/// A wrapper for SQLite's column data types.
	public enum Value: Sendable, ExpressibleByStringLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, Hashable, Comparable {
		public static func < (lhs: Ironbird.Value, rhs: Ironbird.Value) -> Bool {
			switch lhs {
				case .null: return false
				case .integer(let i): return i < rhs.int64Value ?? 0
				case .double(let d): return d < rhs.doubleValue ?? 0
				case .text(let s): return s < rhs.stringValue ?? ""
				case .data(let b): return b.count < rhs.dataValue?.count ?? 0
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
			hasher.combine(self.sqliteLiteral())
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
				case let v as any IronbirdStorableAsInteger: return .integer(v.unifiedRepresentation())
				case let v as any IronbirdStorableAsDouble: return .double(v.unifiedRepresentation())
				case let v as any IronbirdStorableAsText: return .text(v.unifiedRepresentation())
				case let v as any IronbirdStorableAsData: return .data(v.unifiedRepresentation())
				case let v as any IronbirdIntegerEnum: return .integer(v.rawValue.unifiedRepresentation())
				case let v as any IronbirdStringEnum: return .text(v.rawValue.unifiedRepresentation())
				default: throw Error.cannotConvertToValue
			}
		}

		public init(stringLiteral value: String) { self = .text(value) }
		public init(floatLiteral value: Double) { self = .double(value) }
		public init(integerLiteral value: Int64) { self = .integer(value) }
		public init(booleanLiteral value: Bool) { self = .integer(value ? 1 : 0) }

		public func sqliteLiteral() -> String {
			switch self {
				case .integer(let i): return String(i)
				case .double(let d): return String(d)
				case .text(let s): return "'\(s.replacingOccurrences(of: "'", with: "''"))'"
				case .data(let b): return "X'\(b.map { String(format: "%02hhX", $0) }.joined())'"
				case .null: return "NULL"
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

				let hexChars = hex.map(\.self)
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
				case .null: return nil
				case .integer(let i): return i > 0
				case .double(let d): return d > 0
				case .text(let s): return (Int(s) ?? 0) != 0
				case .data(let b): if let str = String(data: b, encoding: .utf8), let i = Int(str) { return i != 0 } else { return nil }
			}
		}

		public var dataValue: Data? {
			switch self {
				case .null: return nil
				case .data(let b): return b
				case .integer(let i): return String(i).data(using: .utf8)
				case .double(let d): return String(d).data(using: .utf8)
				case .text(let s): return s.data(using: .utf8)
			}
		}

		public var doubleValue: Double? {
			switch self {
				case .null: return nil
				case .double(let d): return d
				case .integer(let i): return Double(i)
				case .text(let s): return Double(s)
				case .data(let b): if let str = String(data: b, encoding: .utf8) { return Double(str) } else { return nil }
			}
		}

		public var intValue: Int? {
			switch self {
				case .null: return nil
				case .integer(let i): return Int(i)
				case .double(let d): return Int(d)
				case .text(let s): return Int(s)
				case .data(let b): if let str = String(data: b, encoding: .utf8) { return Int(str) } else { return nil }
			}
		}

		public var int64Value: Int64? {
			switch self {
				case .null: return nil
				case .integer(let i): return Int64(i)
				case .double(let d): return Int64(d)
				case .text(let s): return Int64(s)
				case .data(let b): if let str = String(data: b, encoding: .utf8) { return Int64(str) } else { return nil }
			}
		}

		public var stringValue: String? {
			switch self {
				case .null: return nil
				case .text(let s): return s
				case .integer(let i): return String(i)
				case .double(let d): return String(d)
				case .data(let b): return String(data: b, encoding: .utf8)
			}
		}

		func objcValue() -> NSObject {
			switch self {
				case .null: return NSNull()
				case .integer(let i): return NSNumber(value: i)
				case .double(let d): return NSNumber(value: d)
				case .text(let s): return NSString(string: s)
				case .data(let d): return NSData(data: d)
			}
		}

		private static let copyValue = unsafeBitCast(-1, to: sqlite3_destructor_type.self) // a.k.a. SQLITE_TRANSIENT

		func bind(database: isolated Ironbird.Database.Core, statement: OpaquePointer, index: Int32, for query: String) throws {
			var result: Int32
			switch self {
				case .null: result = sqlite3_bind_null(statement, index)
				case .integer(let i): result = sqlite3_bind_int64(statement, index, i)
				case .double(let d): result = sqlite3_bind_double(statement, index, d)
				case .text(let s): result = sqlite3_bind_text(statement, index, s, -1, Ironbird.Value.copyValue)
				case .data(let d): result = d.withUnsafeBytes { bytes in sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Ironbird.Value.copyValue) }
			}
			if result != SQLITE_OK { throw Ironbird.Database.Error.queryArgumentValueError(query: query, description: database.errorDesc(database.dbHandle)) }
		}

		func bind(database: isolated Ironbird.Database.Core, statement: OpaquePointer, name: String, for query: String) throws {
			let idx = sqlite3_bind_parameter_index(statement, name)
			if idx == 0 { throw Ironbird.Database.Error.queryArgumentNameError(query: query, name: name) }
			return try self.bind(database: database, statement: statement, index: idx, for: query)
		}
	}
}

// MARK: - Utilities

extension Ironbird {
	#if canImport(Darwin)
		final class FileChangeMonitor: Sendable {
			private struct State {
				var sources: [DispatchSourceFileSystemObject] = []
				var changeHandler: (@Sendable () -> Void)?
				var isClosed = false
				var currentExpectedChanges = Set<Int64>()
			}

			private let state = Mutex(State())

			func addFile(filePath: String) {
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
				self.state.withLock { $0.sources.append(source) }
			}

			deinit {
				cancel()
			}

			func onChange(_ handler: @escaping @Sendable () -> Void) {
				self.state.withLock { $0.changeHandler = handler }
			}

			func cancel() {
				self.state.withLock { s in
					s.isClosed = true
					for source in s.sources {
						source.cancel()
					}
				}
			}

			func beginExpectedChange(_ changeID: Int64) {
				self.state.withLock { _ = $0.currentExpectedChanges.insert(changeID) }
			}

			func endExpectedChange(_ changeID: Int64) {
				self.state.withLock { _ = $0.currentExpectedChanges.remove(changeID) }
			}
		}
	#else
		// No-op implementation for platforms without Darwin dispatch sources (e.g. Linux).
		// File change monitoring requires Darwin-specific APIs (DispatchSourceFileSystemObject, O_EVTONLY).
		final class FileChangeMonitor: Sendable {
			func addFile(filePath: String) {}
			func onChange(_ handler: @escaping @Sendable () -> Void) {}
			func cancel() {}
			func beginExpectedChange(_ changeID: Int64) {}
			func endExpectedChange(_ changeID: Int64) {}
		}
	#endif
}
