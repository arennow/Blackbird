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
//  BlackbirdTestModels.swift
//  Created by Marco Arment on 11/20/22.
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
@testable import Ironbird

struct TestModel: IronbirdModel {
	static let indexes: [[IronbirdColumnKeyPath]] = [
		[\.$title],
	]

	@TaskLocal static var cacheLimit: Int = 0

	@IronbirdColumn var id: Int64
	@IronbirdColumn var title: String
	@IronbirdColumn var url: URL

	var nonColumn: String = ""
}

struct TestModelWithoutIDColumn: IronbirdModel {
	static let primaryKey: [IronbirdColumnKeyPath] = [\.$pk]

	@IronbirdColumn var pk: Int
	@IronbirdColumn var title: String
}

struct TestModelWithDescription: IronbirdModel {
	@TaskLocal static var cacheLimit: Int = 0

	static let indexes: [[IronbirdColumnKeyPath]] = [
		[\.$title],
		[\.$url],
	]

	@IronbirdColumn var id: Int
	@IronbirdColumn var url: URL?
	@IronbirdColumn var title: String
	@IronbirdColumn var description: String
}

struct TestCodingKeys: IronbirdModel {
	enum CodingKeys: String, IronbirdCodingKey {
		case id
		case title = "customTitle"
		case description = "d"
	}

	@IronbirdColumn var id: Int64
	@IronbirdColumn var title: String
	@IronbirdColumn var description: String
}

struct TestCustomDecoder: IronbirdModel {
	@IronbirdColumn var id: Int
	@IronbirdColumn var name: String
	@IronbirdColumn var thumbnail: URL

	enum CodingKeys: String, IronbirdCodingKey {
		case id = "idStr"
		case name = "nameStr"
		case thumbnail = "thumbStr"
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)

		// Special-case handling for IronbirdDefaultsDecoder:
		//  supplies a valid numeric string instead of failing on
		//  the empty string ("") returned by IronbirdDefaultsDecoder

		if decoder is IronbirdDefaultsDecoder {
			self.id = 0
		} else {
			let idStr = try container.decode(String.self, forKey: .id)
			guard let id = Int(idStr) else {
				throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Expected numeric string")
			}
			self.id = id
		}

		self.name = try container.decode(String.self, forKey: .name)
		self.thumbnail = try container.decode(URL.self, forKey: .thumbnail)
	}
}

struct TypeTest: IronbirdModel {
	@IronbirdColumn var id: Int64

	@IronbirdColumn var typeIntNull: Int64?
	@IronbirdColumn var typeIntNotNull: Int64

	@IronbirdColumn var typeTextNull: String?
	@IronbirdColumn var typeTextNotNull: String

	@IronbirdColumn var typeDoubleNull: Double?
	@IronbirdColumn var typeDoubleNotNull: Double

	@IronbirdColumn var typeDataNull: Data?
	@IronbirdColumn var typeDataNotNull: Data

	enum RepresentableIntEnum: Int, IronbirdIntegerEnum {
		typealias RawValue = Int

		case zero = 0
		case one = 1
		case two = 2
	}

	@IronbirdColumn var typeIntEnum: RepresentableIntEnum
	@IronbirdColumn var typeIntEnumNull: RepresentableIntEnum?
	@IronbirdColumn var typeIntEnumNullWithValue: RepresentableIntEnum?

	enum RepresentableStringEnum: String, IronbirdStringEnum {
		typealias RawValue = String

		case empty = ""
		case zero
		case one
		case two
	}

	@IronbirdColumn var typeStringEnum: RepresentableStringEnum
	@IronbirdColumn var typeStringEnumNull: RepresentableStringEnum?
	@IronbirdColumn var typeStringEnumNullWithValue: RepresentableStringEnum?

	enum RepresentableIntNonZero: Int, IronbirdIntegerEnum {
		typealias RawValue = Int

		case one = 1
		case two = 2
	}

	@IronbirdColumn var typeIntNonZeroEnum: RepresentableIntNonZero
	@IronbirdColumn var typeIntNonZeroEnumWithDefault: RepresentableIntNonZero = .one
	@IronbirdColumn var typeIntNonZeroEnumNull: RepresentableIntNonZero?
	@IronbirdColumn var typeIntNonZeroEnumNullWithValue: RepresentableIntNonZero?

	enum RepresentableStringNonEmpty: String, IronbirdStringEnum {
		typealias RawValue = String

		case one
		case two
	}

	@IronbirdColumn var typeStringNonEmptyEnum: RepresentableStringNonEmpty
	@IronbirdColumn var typeStringNonEmptyEnumWithDefault: RepresentableStringNonEmpty = .two
	@IronbirdColumn var typeStringNonEmptyEnumNull: RepresentableStringNonEmpty?
	@IronbirdColumn var typeStringNonEmptyEnumNullWithValue: RepresentableStringNonEmpty?

	@IronbirdColumn var typeURLNull: URL?
	@IronbirdColumn var typeURLNotNull: URL

	@IronbirdColumn var typeDateNull: Date?
	@IronbirdColumn var typeDateNotNull: Date
}

struct MulticolumnPrimaryKeyTest: IronbirdModel {
	static let primaryKey: [IronbirdColumnKeyPath] = [\.$userID, \.$feedID, \.$episodeID]

	@IronbirdColumn var userID: Int64
	@IronbirdColumn var feedID: Int64
	@IronbirdColumn var episodeID: Int64
}

struct WithoutRowIDTestModel: IronbirdModel {
	static let primaryKey: [IronbirdColumnKeyPath] = [\.$postID, \.$tagID]
	static let withoutRowID: Bool = true
	static let indexes: [[IronbirdColumnKeyPath]] = [[\.$tagID]]

	@IronbirdColumn var postID: Int64
	@IronbirdColumn var tagID: Int64
}

// Used by the requiresPrimaryKey exit test in WithoutRowIDTests: no explicit primaryKey and no
// column named "id" causes a fatalError during schema generation when withoutRowID is true.
struct WithoutRowIDNoPrimaryKeyModel: IronbirdModel {
	static let withoutRowID: Bool = true
	@IronbirdColumn var name: String
}

// Shared row type used by the migration test in WithoutRowIDTests
struct WithoutRowIDMigrationRow: Hashable {
	var postID: Int64
	var tagID: Int64
}

struct WithoutRowIDMigrationWithRowID: IronbirdModel {
	static let tableName = "WithoutRowIDMigration"
	static let primaryKey: [IronbirdColumnKeyPath] = [\.$postID, \.$tagID]
	static let withoutRowID: Bool = false

	@IronbirdColumn var postID: Int64
	@IronbirdColumn var tagID: Int64
}

struct WithoutRowIDMigrationWithoutRowID: IronbirdModel {
	static let tableName = "WithoutRowIDMigration"
	static let primaryKey: [IronbirdColumnKeyPath] = [\.$postID, \.$tagID]
	static let withoutRowID: Bool = true

	@IronbirdColumn var postID: Int64
	@IronbirdColumn var tagID: Int64
}

public struct TestModelWithOptionalColumns: IronbirdModel {
	@IronbirdColumn public var id: Int64
	@IronbirdColumn public var date: Date
	@IronbirdColumn public var name: String
	@IronbirdColumn public var value: String?
	@IronbirdColumn public var otherValue: Int?
	@IronbirdColumn public var optionalDate: Date?
	@IronbirdColumn public var optionalURL: URL?
	@IronbirdColumn public var optionalData: Data?
}

public struct TestModelWithUniqueIndex: IronbirdModel {
	public static let uniqueIndexes: [[IronbirdColumnKeyPath]] = [
		[\.$a, \.$b, \.$c],
	]

	@IronbirdColumn public var id: Int64
	@IronbirdColumn public var a: String
	@IronbirdColumn public var b: Int
	@IronbirdColumn public var c: Date
}

public struct TestModelForUpdateExpressions: IronbirdModel {
	@IronbirdColumn public var id: Int64
	@IronbirdColumn public var i: Int
	@IronbirdColumn public var d: Double
}

// MARK: - Schema change: Add primary-key column

struct SchemaChangeAddPrimaryKeyColumnInitial: IronbirdModel {
	static let tableName = "SchemaChangeAddPrimaryKeyColumn"
	static let primaryKey: [IronbirdColumnKeyPath] = [\.$userID, \.$feedID]

	@IronbirdColumn var userID: Int64
	@IronbirdColumn var feedID: Int64
	@IronbirdColumn var subscribed: Bool
}

struct SchemaChangeAddPrimaryKeyColumnChanged: IronbirdModel {
	static let tableName = "SchemaChangeAddPrimaryKeyColumn"
	static let primaryKey: [IronbirdColumnKeyPath] = [\.$userID, \.$feedID, \.$episodeID]

	@IronbirdColumn var userID: Int64
	@IronbirdColumn var feedID: Int64
	@IronbirdColumn var episodeID: Int64
	@IronbirdColumn var subscribed: Bool
}

// MARK: - Schema change: Add columns

struct SchemaChangeAddColumnsInitial: IronbirdModel {
	static let tableName = "SchemaChangeAddColumns"

	@IronbirdColumn var id: Int64
	@IronbirdColumn var title: String
}

struct SchemaChangeAddColumnsChanged: IronbirdModel {
	static let tableName = "SchemaChangeAddColumns"

	@IronbirdColumn var id: Int64
	@IronbirdColumn var title: String
	@IronbirdColumn var description: String
	@IronbirdColumn var url: URL?
	@IronbirdColumn var art: Data
}

// MARK: - Schema change: Drop columns

struct SchemaChangeRebuildTableInitial: IronbirdModel {
	static let tableName = "SchemaChangeRebuild"
	static let primaryKey: [IronbirdColumnKeyPath] = [\.$id, \.$title]

	@IronbirdColumn var id: Int64
	@IronbirdColumn var title: String
	@IronbirdColumn var flags: Int
}

struct SchemaChangeRebuildTableChanged: IronbirdModel {
	static let tableName = "SchemaChangeRebuild"

	@IronbirdColumn var id: Int64
	@IronbirdColumn var title: String
	@IronbirdColumn var flags: String
	@IronbirdColumn var description: String
}

// MARK: - Schema change: Add index

struct SchemaChangeAddIndexInitial: IronbirdModel {
	static let tableName = "SchemaChangeAddIndex"

	@IronbirdColumn var id: Int64
	@IronbirdColumn var title: String
}

struct SchemaChangeAddIndexChanged: IronbirdModel {
	static let tableName = "SchemaChangeAddIndex"
	static let indexes: [[IronbirdColumnKeyPath]] = [
		[\.$title],
	]

	@IronbirdColumn var id: Int64
	@IronbirdColumn var title: String
}

// MARK: - Invalid index definition

struct DuplicateIndexesModel: IronbirdModel {
	static let indexes: [[IronbirdColumnKeyPath]] = [
		[\.$title],
	]

	static let uniqueIndexes: [[IronbirdColumnKeyPath]] = [
		[\.$title],
	]

	@IronbirdColumn var id: Int64
	@IronbirdColumn var title: String
}

// MARK: - Full-text search

struct FTSModel: IronbirdModel {
	static let fullTextSearchableColumns: FullTextIndex = [
		\.$title: .text(weight: 3.0),
		\.$description: .text,
		\.$category: .filterOnly,
	]

	@IronbirdColumn var id: Int
	@IronbirdColumn var title: String
	@IronbirdColumn var url: URL
	@IronbirdColumn var description: String
	@IronbirdColumn var keywords: String
	@IronbirdColumn var category: Int
}

struct FTSModelAfterMigration: IronbirdModel {
	static let tableName = "FTSModel"

	static let fullTextSearchableColumns: FullTextIndex = [
		\.$title: .text(weight: 3.0),
		\.$description: .text,
		\.$category: .filterOnly,
		\.$keywords: .text(weight: 0.5),
	]

	@IronbirdColumn var id: Int
	@IronbirdColumn var title: String
	@IronbirdColumn var url: URL
	@IronbirdColumn var description: String
	@IronbirdColumn var keywords: String
	@IronbirdColumn var category: Int
}

struct FTSModelAfterDeletion: IronbirdModel {
	static let tableName = "FTSModel"

	@IronbirdColumn var id: Int
	@IronbirdColumn var title: String
	@IronbirdColumn var url: URL
	@IronbirdColumn var description: String
	@IronbirdColumn var keywords: String
	@IronbirdColumn var category: Int
}
