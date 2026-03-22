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
//  BlackbirdRow.swift
//  Created by Marco Arment on 2/27/23.
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

// MARK: - Standard row

public extension Ironbird {
	/// A dictionary of a single table row's values, keyed by their column names.
	typealias Row = Dictionary<String, Ironbird.Value>
}

public extension Ironbird.Row {
	subscript<T: IronbirdModel, V: IronbirdColumnWrappable>(_ keyPath: KeyPath<T, IronbirdColumn<Optional<V>>>) -> V? {
		let table = SchemaGenerator.shared.table(for: T.self)
		let columnName = table.keyPathToColumnName(keyPath: keyPath)

		guard let value = self[columnName], value != .null else { return nil }
		guard let typedValue = V.fromValue(value) else { fatalError("\(String(describing: T.self)).\(columnName) value in Ironbird.Row dictionary not convertible to \(String(describing: V.self))") }
		return typedValue
	}

	subscript<T: IronbirdModel, V: IronbirdColumnWrappable>(_ keyPath: KeyPath<T, IronbirdColumn<V>>) -> V {
		let table = SchemaGenerator.shared.table(for: T.self)
		let columnName = table.keyPathToColumnName(keyPath: keyPath)

		guard let value = self[columnName] else { fatalError("\(String(describing: T.self)).\(columnName) value not present in Ironbird.Row dictionary") }
		guard let typedValue = V.fromValue(value) else { fatalError("\(String(describing: T.self)).\(columnName) value in Ironbird.Row dictionary not convertible to \(String(describing: V.self))") }
		return typedValue
	}
}

// MARK: - Model-specific row

// This allows typed key-pair lookups without specifying the type name at the call site, e.g.:
//
//   row[\.$title]
//
//     instead of
//
//   row[\MyModelName.$title]
//
public extension Ironbird {
	/// A specialized version of ``Row`` associated with its source ``IronbirdModel`` type for convenient access to its values with column key-paths.
	struct ModelRow<T: IronbirdModel>: Collection, Equatable, Sendable {
		private let table: Ironbird.Table

		init(_ row: Ironbird.Row, table: Ironbird.Table) {
			self.table = table
			self.dictionary = row
		}

		public var row: Ironbird.Row { self.dictionary }

		public subscript<V: IronbirdColumnWrappable>(_ keyPath: KeyPath<T, IronbirdColumn<Optional<V>>>) -> V? {
			let columnName = self.table.keyPathToColumnName(keyPath: keyPath)

			guard let value = dictionary[columnName], value != .null else { return nil }
			guard let typedValue = V.fromValue(value) else { fatalError("\(String(describing: T.self)).\(columnName) value in Ironbird.Row dictionary not convertible to \(String(describing: V.self))") }
			return typedValue
		}

		public subscript<V: IronbirdColumnWrappable>(_ keyPath: KeyPath<T, IronbirdColumn<V>>) -> V {
			let columnName = self.table.keyPathToColumnName(keyPath: keyPath)

			guard let value = dictionary[columnName] else { fatalError("\(String(describing: T.self)).\(columnName) value not present in Ironbird.Row dictionary") }
			guard let typedValue = V.fromValue(value) else { fatalError("\(String(describing: T.self)).\(columnName) value in Ironbird.Row dictionary not convertible to \(String(describing: V.self))") }
			return typedValue
		}

		public func value(keyPath: PartialKeyPath<T>) -> Ironbird.Value? {
			let columnName = self.table.keyPathToColumnName(keyPath: keyPath)
			guard let value = dictionary[columnName] else { fatalError("\(String(describing: T.self)).\(columnName) value not present in Ironbird.Row dictionary") }
			return value
		}

		// Collection conformance
		public typealias DictionaryType = Dictionary<String, Ironbird.Value>
		public typealias Index = DictionaryType.Index
		private var dictionary: DictionaryType = [:]
		public var keys: Dictionary<String, Ironbird.Value>.Keys { self.dictionary.keys }
		public typealias Indices = DictionaryType.Indices
		public typealias Iterator = DictionaryType.Iterator
		public typealias SubSequence = DictionaryType.SubSequence
		public var startIndex: Index { self.dictionary.startIndex }
		public var endIndex: DictionaryType.Index { self.dictionary.endIndex }
		public subscript(position: Index) -> Iterator.Element { self.dictionary[position] }
		public subscript(bounds: Range<Index>) -> SubSequence { self.dictionary[bounds] }
		public var indices: Indices { self.dictionary.indices }
		public subscript(key: String) -> Ironbird.Value? {
			get { self.dictionary[key] }
			set { self.dictionary[key] = newValue }
		}

		public func index(after i: Index) -> Index { self.dictionary.index(after: i) }
		public func makeIterator() -> DictionaryIterator<String, Ironbird.Value> { self.dictionary.makeIterator() }
	}
}
