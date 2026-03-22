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
//  BlackbirdColumnTypes.swift
//  Created by Marco Arment on 1/14/23.
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

/// A wrapped data type supported by ``IronbirdColumn``.
public protocol IronbirdColumnWrappable: Hashable, Codable, Sendable {
	static func fromValue(_ value: Ironbird.Value) -> Self?
}

// MARK: - Column storage-type protocols

/// Internally represents data types compatible with SQLite's `INTEGER` type.
///
/// `UInt` and `UInt64` are intentionally omitted since SQLite integers max out at 64-bit signed.
public protocol IronbirdStorableAsInteger: Codable {
	func unifiedRepresentation() -> Int64
	static func from(unifiedRepresentation: Int64) -> Self
}

/// Internally represents data types compatible with SQLite's `DOUBLE` type.
public protocol IronbirdStorableAsDouble: Codable {
	func unifiedRepresentation() -> Double
	static func from(unifiedRepresentation: Double) -> Self
}

/// Internally represents data types compatible with SQLite's `TEXT` type.
public protocol IronbirdStorableAsText: Codable {
	func unifiedRepresentation() -> String
	static func from(unifiedRepresentation: String) -> Self
}

/// Internally represents data types compatible with SQLite's `BLOB` type.
public protocol IronbirdStorableAsData: Codable {
	func unifiedRepresentation() -> Data
	static func from(unifiedRepresentation: Data) -> Self
}

extension Double: IronbirdColumnWrappable, IronbirdStorableAsDouble {
	public func unifiedRepresentation() -> Double { self }
	public static func from(unifiedRepresentation: Double) -> Self { unifiedRepresentation }
	public static func fromValue(_ value: Ironbird.Value) -> Self? { value.doubleValue }
}

extension Float: IronbirdColumnWrappable, IronbirdStorableAsDouble {
	public func unifiedRepresentation() -> Double { Double(self) }
	public static func from(unifiedRepresentation: Double) -> Self { Float(unifiedRepresentation) }
	public static func fromValue(_ value: Ironbird.Value) -> Self? { if let d = value.doubleValue { return Float(d) } else { return nil } }
}

extension Date: IronbirdColumnWrappable, IronbirdStorableAsDouble {
	public func unifiedRepresentation() -> Double { self.timeIntervalSince1970 }
	public static func from(unifiedRepresentation: Double) -> Self { Date(timeIntervalSince1970: unifiedRepresentation) }
	public static func fromValue(_ value: Ironbird.Value) -> Self? { if let d = value.doubleValue { return Date(timeIntervalSince1970: d) } else { return nil } }
}

extension Data: IronbirdColumnWrappable, IronbirdStorableAsData {
	public func unifiedRepresentation() -> Data { self }
	public static func from(unifiedRepresentation: Data) -> Self { unifiedRepresentation }
	public static func fromValue(_ value: Ironbird.Value) -> Self? { value.dataValue }
}

extension String: IronbirdColumnWrappable, IronbirdStorableAsText {
	public func unifiedRepresentation() -> String { self }
	public static func from(unifiedRepresentation: String) -> Self { unifiedRepresentation }
	public static func fromValue(_ value: Ironbird.Value) -> Self? { value.stringValue }
}

extension URL: IronbirdColumnWrappable, IronbirdStorableAsText {
	public func unifiedRepresentation() -> String { self.absoluteString }
	public static func from(unifiedRepresentation: String) -> Self { URL(string: unifiedRepresentation)! }
	public static func fromValue(_ value: Ironbird.Value) -> Self? { if let s = value.stringValue { return URL(string: s) } else { return nil } }
}

extension Bool: IronbirdColumnWrappable, IronbirdStorableAsInteger {
	public func unifiedRepresentation() -> Int64 { Int64(self ? 1 : 0) }
	public static func from(unifiedRepresentation: Int64) -> Self { unifiedRepresentation == 0 ? false : true }
	public static func fromValue(_ value: Ironbird.Value) -> Self? { value.boolValue }
}

extension Int: IronbirdColumnWrappable, IronbirdStorableAsInteger {
	public func unifiedRepresentation() -> Int64 { Int64(self) }
	public static func from(unifiedRepresentation: Int64) -> Self { Int(unifiedRepresentation) }
	public static func fromValue(_ value: Ironbird.Value) -> Self? { value.intValue }
}

extension Int8: IronbirdColumnWrappable, IronbirdStorableAsInteger {
	public func unifiedRepresentation() -> Int64 { Int64(self) }
	public static func from(unifiedRepresentation: Int64) -> Self { Int8(unifiedRepresentation) }
	public static func fromValue(_ value: Ironbird.Value) -> Self? { if let i = value.intValue { return Int8(i) } else { return nil } }
}

extension Int16: IronbirdColumnWrappable, IronbirdStorableAsInteger {
	public func unifiedRepresentation() -> Int64 { Int64(self) }
	public static func from(unifiedRepresentation: Int64) -> Self { Int16(unifiedRepresentation) }
	public static func fromValue(_ value: Ironbird.Value) -> Self? { if let i = value.intValue { return Int16(i) } else { return nil } }
}

extension Int32: IronbirdColumnWrappable, IronbirdStorableAsInteger {
	public func unifiedRepresentation() -> Int64 { Int64(self) }
	public static func from(unifiedRepresentation: Int64) -> Self { Int32(unifiedRepresentation) }
	public static func fromValue(_ value: Ironbird.Value) -> Self? { if let i = value.intValue { return Int32(i) } else { return nil } }
}

extension Int64: IronbirdColumnWrappable, IronbirdStorableAsInteger {
	public func unifiedRepresentation() -> Int64 { self }
	public static func from(unifiedRepresentation: Int64) -> Self { unifiedRepresentation }
	public static func fromValue(_ value: Ironbird.Value) -> Self? { if let i = value.int64Value { return Int64(i) } else { return nil } }
}

extension UInt8: IronbirdColumnWrappable, IronbirdStorableAsInteger {
	public func unifiedRepresentation() -> Int64 { Int64(self) }
	public static func from(unifiedRepresentation: Int64) -> Self { UInt8(unifiedRepresentation) }
	public static func fromValue(_ value: Ironbird.Value) -> Self? { if let i = value.intValue { return UInt8(i) } else { return nil } }
}

extension UInt16: IronbirdColumnWrappable, IronbirdStorableAsInteger {
	public func unifiedRepresentation() -> Int64 { Int64(self) }
	public static func from(unifiedRepresentation: Int64) -> Self { UInt16(unifiedRepresentation) }
	public static func fromValue(_ value: Ironbird.Value) -> Self? { if let i = value.intValue { return UInt16(i) } else { return nil } }
}

extension UInt32: IronbirdColumnWrappable, IronbirdStorableAsInteger {
	public func unifiedRepresentation() -> Int64 { Int64(self) }
	public static func from(unifiedRepresentation: Int64) -> Self { UInt32(unifiedRepresentation) }
	public static func fromValue(_ value: Ironbird.Value) -> Self? { if let i = value.int64Value { return UInt32(i) } else { return nil } }
}

// MARK: - Enums, hacks for optionals

/// Declares an enum as compatible with Ironbird column storage, with a raw type of `String` or `URL`.
public protocol IronbirdStringEnum: RawRepresentable, CaseIterable, IronbirdColumnWrappable where RawValue: IronbirdStorableAsText {
	associatedtype RawValue
}

/// Declares an enum as compatible with Ironbird column storage, with a Ironbird-compatible raw integer type such as `Int`.
public protocol IronbirdIntegerEnum: RawRepresentable, CaseIterable, IronbirdColumnWrappable where RawValue: IronbirdStorableAsInteger {
	associatedtype RawValue
	static func unifiedRawValue(from unifiedRepresentation: Int64) -> RawValue
}

extension IronbirdStringEnum {
	public static func fromValue(_ value: Ironbird.Value) -> Self? { if let s = value.stringValue { return Self(rawValue: RawValue.from(unifiedRepresentation: s)) } else { return nil } }

	static func defaultPlaceholderValue() -> Self { allCases.first! }
}

public extension IronbirdIntegerEnum {
	static func unifiedRawValue(from unifiedRepresentation: Int64) -> RawValue { RawValue.from(unifiedRepresentation: unifiedRepresentation) }
	static func fromValue(_ value: Ironbird.Value) -> Self? { if let i = value.int64Value { return Self(rawValue: Self.unifiedRawValue(from: i)) } else { return nil } }
	internal static func defaultPlaceholderValue() -> Self { allCases.first! }
}

extension Optional: IronbirdColumnWrappable where Wrapped: IronbirdColumnWrappable {
	public static func fromValue(_ value: Ironbird.Value) -> Self? { Wrapped.fromValue(value) }
}

// Bad hack to make Optional<IronbirdIntegerEnum> conform to IronbirdStorableAsInteger
extension Optional: @retroactive RawRepresentable where Wrapped: RawRepresentable {
	public typealias RawValue = Wrapped.RawValue
	public init?(rawValue: Wrapped.RawValue) {
		if let w = Wrapped(rawValue: rawValue) { self = .some(w) } else { self = .none }
	}

	public var rawValue: Wrapped.RawValue { fatalError() }
}

extension Optional: @retroactive CaseIterable where Wrapped: CaseIterable {
	public static var allCases: [Optional<Wrapped>] { Wrapped.allCases.map { Optional<Wrapped>($0) } }
}

protocol IronbirdIntegerOptionalEnum {
	static func nilInstance() -> Self
}

extension Optional: IronbirdIntegerEnum, IronbirdIntegerOptionalEnum where Wrapped: IronbirdIntegerEnum {
	static func nilInstance() -> Self { .none }
}

protocol IronbirdStringOptionalEnum {
	static func nilInstance() -> Self
}

extension Optional: IronbirdStringEnum, IronbirdStringOptionalEnum where Wrapped: IronbirdStringEnum {
	static func nilInstance() -> Self { .none }
}
