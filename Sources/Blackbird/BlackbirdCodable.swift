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
//  BlackbirdCodable.swift
//  Created by Marco Arment on 11/7/22.
//
//  With significant thanks to (and borrowing from):
//   https://shareup.app/blog/encoding-and-decoding-sqlite-in-swift/
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

class BlackbirdSQLiteDecoder: Decoder {
	enum Error: Swift.Error {
		case invalidValue(String, value: String)
		case missingValue(String)
	}

	var codingPath: [CodingKey] = []
	var userInfo: [CodingUserInfoKey: Any] = [:]

	let database: Blackbird.Database
	let row: Blackbird.Row
	init(database: Blackbird.Database, row: Blackbird.Row, codingPath: [CodingKey] = []) {
		self.database = database
		self.row = row
		self.codingPath = codingPath
	}

	func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
		if let iterableKey = Key.self as? any BlackbirdCodingKey.Type {
			// Custom CodingKeys are in use, so remap the row to use the expected keys instead of raw column names
			var newRow = Blackbird.Row()
			for (columnName, customFieldName) in iterableKey.allLabeledCases {
				if let rowValue = row[columnName] {
					newRow[customFieldName] = rowValue
				}
			}
			return KeyedDecodingContainer(BlackbirdSQLiteKeyedDecodingContainer<Key>(codingPath: self.codingPath, database: self.database, row: newRow))
		}

		// Use default names without custom CodingKeys
		return KeyedDecodingContainer(BlackbirdSQLiteKeyedDecodingContainer<Key>(codingPath: self.codingPath, database: self.database, row: self.row))
	}

	func unkeyedContainer() throws -> UnkeyedDecodingContainer { fatalError("unsupported") }
	func singleValueContainer() throws -> SingleValueDecodingContainer { BlackbirdSQLiteSingleValueDecodingContainer(codingPath: self.codingPath, database: self.database, row: self.row) }
}

fileprivate struct BlackbirdSQLiteSingleValueDecodingContainer: SingleValueDecodingContainer {
	enum Error: Swift.Error {
		case invalidEnumValue(typeDescription: String, value: Sendable)
	}

	var codingPath: [CodingKey] = []
	let database: Blackbird.Database
	var row: Blackbird.Row

	init(codingPath: [CodingKey], database: Blackbird.Database, row: Blackbird.Row) {
		self.codingPath = codingPath
		self.database = database
		self.row = row
	}

	private func value() throws -> Blackbird.Value {
		guard let key = codingPath.first?.stringValue, let v = row[key] else {
			throw BlackbirdSQLiteDecoder.Error.missingValue(self.codingPath.first?.stringValue ?? "(unknown key)")
		}
		return v
	}

	func decodeNil() -> Bool { true }
	func decode(_ type: Bool.Type) throws -> Bool { (try self.value()).boolValue ?? false }
	func decode(_ type: String.Type) throws -> String { (try self.value()).stringValue ?? "" }
	func decode(_ type: Double.Type) throws -> Double { (try self.value()).doubleValue ?? 0 }
	func decode(_ type: Float.Type) throws -> Float { Float((try self.value()).doubleValue ?? 0) }
	func decode(_ type: Int.Type) throws -> Int { (try self.value()).intValue ?? 0 }
	func decode(_ type: Int8.Type) throws -> Int8 { Int8((try self.value()).intValue ?? 0) }
	func decode(_ type: Int16.Type) throws -> Int16 { Int16((try self.value()).intValue ?? 0) }
	func decode(_ type: Int32.Type) throws -> Int32 { Int32((try self.value()).intValue ?? 0) }
	func decode(_ type: Int64.Type) throws -> Int64 { (try self.value()).int64Value ?? 0 }
	func decode(_ type: UInt.Type) throws -> UInt { UInt((try self.value()).int64Value ?? 0) }
	func decode(_ type: UInt8.Type) throws -> UInt8 { UInt8((try self.value()).intValue ?? 0) }
	func decode(_ type: UInt16.Type) throws -> UInt16 { UInt16((try self.value()).intValue ?? 0) }
	func decode(_ type: UInt32.Type) throws -> UInt32 { UInt32((try self.value()).int64Value ?? 0) }
	func decode(_ type: UInt64.Type) throws -> UInt64 { UInt64((try self.value()).int64Value ?? 0) }

	func decode<T: Decodable>(_ type: T.Type) throws -> T {
		let value = try value()
		if T.self == Data.self { return (value.dataValue ?? Data()) as! T }
		if T.self == URL.self, let urlStr = value.stringValue, let url = URL(string: urlStr) { return url as! T }
		if T.self == Date.self { return Date(timeIntervalSince1970: value.doubleValue ?? 0) as! T }

		if let eT = T.self as? any BlackbirdIntegerOptionalEnum.Type, value.int64Value == nil {
			return (try self.decodeNilRepresentable(eT) as? T)!
		}

		if let eT = T.self as? any BlackbirdStringOptionalEnum.Type, value.stringValue == nil {
			return (try self.decodeNilRepresentable(eT) as? T)!
		}

		if let eT = T.self as? any BlackbirdIntegerEnum.Type {
			let rawValue = value.int64Value ?? 0
			guard let integerEnum = try decodeRepresentable(eT, unifiedRawValue: rawValue), let converted = integerEnum as? T else {
				throw Error.invalidEnumValue(typeDescription: String(describing: eT), value: rawValue)
			}
			return converted
		}

		if let eT = T.self as? any BlackbirdStringEnum.Type {
			let rawValue = value.stringValue ?? ""
			guard let stringEnum = try decodeRepresentable(eT, unifiedRawValue: rawValue), let converted = stringEnum as? T else {
				throw Error.invalidEnumValue(typeDescription: String(describing: eT), value: rawValue)
			}
			return converted
		}

		if let eT = T.self as? any OptionalCreatable.Type, let wrappedType = eT.creatableWrappedType() as? any Decodable.Type {
			if value == .null {
				return eT.createFromNilValue() as! T
			} else {
				let wrappedValue = try decode(wrappedType)
				return eT.createFromValue(wrappedValue) as! T
			}
		}

		if let eT = T.self as? any BlackbirdStorableAsData.Type, let data = value.dataValue {
			return try JSONDecoder().decode(eT, from: data) as! T
		}

		return try T(from: BlackbirdSQLiteDecoder(database: self.database, row: self.row, codingPath: self.codingPath))
	}

	func decodeRepresentable<T: BlackbirdIntegerEnum>(_ type: T.Type, unifiedRawValue: Int64) throws -> T? {
		T(rawValue: T.RawValue.from(unifiedRepresentation: unifiedRawValue))
	}

	func decodeRepresentable<T: BlackbirdStringEnum>(_ type: T.Type, unifiedRawValue: String) throws -> T? {
		T(rawValue: T.RawValue.from(unifiedRepresentation: unifiedRawValue))
	}

	func decodeNilRepresentable<T: BlackbirdIntegerOptionalEnum>(_ type: T.Type) throws -> T {
		T.nilInstance()
	}

	func decodeNilRepresentable<T: BlackbirdStringOptionalEnum>(_ type: T.Type) throws -> T {
		T.nilInstance()
	}
}

fileprivate class BlackbirdSQLiteKeyedDecodingContainer<K: CodingKey>: KeyedDecodingContainerProtocol {
	typealias Key = K
	let codingPath: [CodingKey]
	let database: Blackbird.Database
	var row: Blackbird.Row

	init(codingPath: [CodingKey] = [], database: Blackbird.Database, row: Blackbird.Row) {
		self.database = database
		self.row = row
		self.codingPath = codingPath
	}

	var allKeys: [K] { self.row.keys.compactMap { K(stringValue: $0) } }
	func contains(_ key: K) -> Bool { self.row[key.stringValue] != nil }

	func decodeNil(forKey key: K) throws -> Bool {
		if let value = row[key.stringValue] { return value == .null }
		return true
	}

	func decode(_ type: Bool.Type, forKey key: K) throws -> Bool { self.row[key.stringValue]?.boolValue ?? false }
	func decode(_ type: String.Type, forKey key: K) throws -> String { self.row[key.stringValue]?.stringValue ?? "" }
	func decode(_ type: Double.Type, forKey key: K) throws -> Double { self.row[key.stringValue]?.doubleValue ?? 0 }
	func decode(_ type: Float.Type, forKey key: K) throws -> Float { Float(self.row[key.stringValue]?.doubleValue ?? 0) }
	func decode(_ type: Int.Type, forKey key: K) throws -> Int { self.row[key.stringValue]?.intValue ?? 0 }
	func decode(_ type: Int8.Type, forKey key: K) throws -> Int8 { Int8(self.row[key.stringValue]?.intValue ?? 0) }
	func decode(_ type: Int16.Type, forKey key: K) throws -> Int16 { Int16(self.row[key.stringValue]?.intValue ?? 0) }
	func decode(_ type: Int32.Type, forKey key: K) throws -> Int32 { Int32(self.row[key.stringValue]?.intValue ?? 0) }
	func decode(_ type: Int64.Type, forKey key: K) throws -> Int64 { self.row[key.stringValue]?.int64Value ?? 0 }
	func decode(_ type: UInt.Type, forKey key: K) throws -> UInt { UInt(self.row[key.stringValue]?.int64Value ?? 0) }
	func decode(_ type: UInt8.Type, forKey key: K) throws -> UInt8 { UInt8(self.row[key.stringValue]?.intValue ?? 0) }
	func decode(_ type: UInt16.Type, forKey key: K) throws -> UInt16 { UInt16(self.row[key.stringValue]?.intValue ?? 0) }
	func decode(_ type: UInt32.Type, forKey key: K) throws -> UInt32 { UInt32(self.row[key.stringValue]?.int64Value ?? 0) }
	func decode(_ type: UInt64.Type, forKey key: K) throws -> UInt64 { UInt64(self.row[key.stringValue]?.int64Value ?? 0) }
	func decode(_: Data.Type, forKey key: K) throws -> Data { self.row[key.stringValue]?.dataValue ?? Data() }

	func decode(_: Date.Type, forKey key: K) throws -> Date {
		let timeInterval = try decode(Double.self, forKey: key)
		return Date(timeIntervalSince1970: timeInterval)
	}

	func decode(_: URL.Type, forKey key: K) throws -> URL {
		let string = try decode(String.self, forKey: key)
		guard let url = URL(string: string) else { throw BlackbirdSQLiteDecoder.Error.invalidValue(key.stringValue, value: string) }
		return url
	}

	func decode<T: Decodable>(_ type: T.Type, forKey key: K) throws -> T {
		if Data.self == T.self { return try self.decode(Data.self, forKey: key) as! T }
		if Date.self == T.self { return try self.decode(Date.self, forKey: key) as! T }
		if URL.self == T.self { return try self.decode(URL.self, forKey: key) as! T }

		var newPath = self.codingPath
		newPath.append(key)
		return try T(from: BlackbirdSQLiteDecoder(database: self.database, row: self.row, codingPath: newPath))
	}

	func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: K) throws -> KeyedDecodingContainer<NestedKey> { fatalError("unsupported") }
	func nestedUnkeyedContainer(forKey key: K) throws -> UnkeyedDecodingContainer { fatalError("unsupported") }
	func superDecoder() throws -> Decoder { fatalError("unsupported") }
	func superDecoder(forKey key: K) throws -> Decoder { fatalError("unsupported") }
}
