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
//  BlackbirdSchema.swift
//  Created by Marco Arment on 11/18/22.
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
import Synchronization

// MARK: - Schema

public struct IronbirdModelSchemaResolution: OptionSet, Sendable {
	public let rawValue: Int
	public init(rawValue: Int) { self.rawValue = rawValue }

	public static let createdTable = IronbirdModelSchemaResolution(rawValue: 1 << 0)
	public static let migratedTable = IronbirdModelSchemaResolution(rawValue: 1 << 1)
	public static let migratedFullTextIndex = IronbirdModelSchemaResolution(rawValue: 1 << 2)
}

extension Ironbird {
	enum ColumnType {
		case integer
		case double
		case text
		case data

		static func parseType(_ str: String) -> ColumnType? {
			if str.hasPrefix("TEXT") { return .text }
			if str.hasPrefix("INT") || str.hasPrefix("BOOL") { return .integer }
			if str.hasPrefix("FLOAT") || str.hasPrefix("DOUBLE") || str.hasPrefix("REAL") || str.hasPrefix("NUMERIC") { return .double }
			if str.hasPrefix("BLOB") { return .data }
			return nil
		}

		func definition() -> String {
			switch self {
				case .integer: return "INTEGER"
				case .double: return "DOUBLE"
				case .text: return "TEXT"
				case .data: return "BLOB"
			}
		}

		func defaultValue() -> Value {
			switch self {
				case .integer: return .integer(0)
				case .double: return .double(0)
				case .text: return .text("")
				case .data: return .data(Data())
			}
		}
	}

	struct Column: Equatable, Hashable {
		enum Error: Swift.Error {
			case cannotParseColumnDefinition(table: String, description: String)
		}

		// intentionally ignoring primaryKeyIndex since it's only used for internal sorting
		static func == (lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name && lhs.columnType == rhs.columnType && lhs.mayBeNull == rhs.mayBeNull }
		func hash(into hasher: inout Hasher) {
			hasher.combine(self.name)
			hasher.combine(self.columnType)
			hasher.combine(self.mayBeNull)
		}

		let name: String
		let columnType: ColumnType
		let valueType: Any.Type?
		let mayBeNull: Bool

		let primaryKeyIndex: Int // Only used for sorting, not considered for equality

		func definition() -> String {
			"`\(self.name)` \(self.columnType.definition()) \(self.mayBeNull ? "NULL" : "NOT NULL") DEFAULT \((self.mayBeNull ? .null : self.columnType.defaultValue()).sqliteLiteral())"
		}

		init(name: String, columnType: ColumnType, valueType: Any.Type, mayBeNull: Bool = false) {
			if name == "_rowid_" { fatalError("A @IronbirdColumn cannot be named \"_rowid_\"") }
			self.name = name
			self.columnType = columnType
			self.valueType = valueType
			self.mayBeNull = mayBeNull
			self.primaryKeyIndex = 0
		}

		init(row: Row, tableName: String) throws {
			guard
				let name = row["name"]?.stringValue,
				let typeStr = row["type"]?.stringValue,
				let notNull = row["notnull"]?.boolValue,
				let primaryKeyIndex = row["pk"]?.intValue
			else { throw Error.cannotParseColumnDefinition(table: tableName, description: "Unexpected format from PRAGMA table_info") }

			guard name != "_rowid_" else { throw Error.cannotParseColumnDefinition(table: tableName, description: "Columns named \"_rowid_\" are not supported in IronbirdModel tables") }

			guard let columnType = ColumnType.parseType(typeStr) else { throw Error.cannotParseColumnDefinition(table: tableName, description: "Column \"\(name)\" has unsupported type: \"\(typeStr)\"") }
			self.name = name
			self.columnType = columnType
			self.valueType = nil
			self.mayBeNull = !notNull
			self.primaryKeyIndex = primaryKeyIndex
		}
	}

	struct Index: Equatable, Hashable {
		enum Error: Swift.Error {
			case cannotParseIndexDefinition(definition: String, description: String)
		}

		func hash(into hasher: inout Hasher) {
			hasher.combine(self.name)
			hasher.combine(self.unique)
			hasher.combine(self.columnNames)
		}

		private static let parserIgnoredCharacters: CharacterSet = .whitespacesAndNewlines.union(CharacterSet(charactersIn: "`'\""))

		let name: String
		let unique: Bool
		let columnNames: [String]

		func definition(tableName: String) -> String {
			if self.columnNames.isEmpty { fatalError("Indexes require at least one column") }
			return "CREATE \(self.unique ? "UNIQUE " : "")INDEX `\(tableName)+index+\(self.name)` ON \(tableName) (\(self.columnNames.joined(separator: ",")))"
		}

		init(columnNames: [String], unique: Bool = false) {
			guard !columnNames.isEmpty else { fatalError("No columns specified") }
			self.columnNames = columnNames
			self.unique = unique
			self.name = columnNames.joined(separator: "+")
		}

		init(definition: String) throws {
			let scanner = Scanner(string: definition)
			scanner.charactersToBeSkipped = Self.parserIgnoredCharacters
			scanner.caseSensitive = false
			guard scanner.scanString("CREATE") != nil else { throw Error.cannotParseIndexDefinition(definition: definition, description: "Expected 'CREATE'") }
			self.unique = scanner.scanString("UNIQUE") != nil
			guard scanner.scanString("INDEX") != nil else { throw Error.cannotParseIndexDefinition(definition: definition, description: "Expected 'INDEX'") }

			guard let indexName = scanner.scanUpToString(" ON")?.trimmingCharacters(in: Self.parserIgnoredCharacters), !indexName.isEmpty else {
				throw Error.cannotParseIndexDefinition(definition: definition, description: "Expected index name")
			}

			let nameScanner = Scanner(string: indexName)
			_ = nameScanner.scanUpToString("+index+")
			if nameScanner.scanString("+index+") == "+index+" {
				self.name = String(indexName.suffix(from: nameScanner.currentIndex))
			} else {
				throw Error.cannotParseIndexDefinition(definition: definition, description: "Index name does not match expected format")
			}

			guard scanner.scanString("ON") != nil else { throw Error.cannotParseIndexDefinition(definition: definition, description: "Expected 'ON'") }

			guard let tableName = scanner.scanUpToString("(")?.trimmingCharacters(in: Self.parserIgnoredCharacters), !tableName.isEmpty else {
				throw Error.cannotParseIndexDefinition(definition: definition, description: "Expected table name")
			}
			guard scanner.scanString("(") != nil, let columnList = scanner.scanUpToString(")"), scanner.scanString(")") != nil, !columnList.isEmpty else {
				throw Error.cannotParseIndexDefinition(definition: definition, description: "Expected column list")
			}

			self.columnNames = columnList.components(separatedBy: ",").map { $0.trimmingCharacters(in: Self.parserIgnoredCharacters) }.filter { !$0.isEmpty }
			guard !self.columnNames.isEmpty else { throw Error.cannotParseIndexDefinition(definition: definition, description: "No columns specified") }
		}
	}

	struct Table: Hashable {
		static func == (lhs: Ironbird.Table, rhs: Ironbird.Table) -> Bool {
			lhs.name == rhs.name && lhs.columns == rhs.columns && lhs.indexes == rhs.indexes && lhs.primaryKeys == rhs.primaryKeys && lhs.withoutRowID == rhs.withoutRowID
		}

		func hash(into hasher: inout Hasher) {
			hasher.combine(self.name)
			hasher.combine(self.columns)
			hasher.combine(self.indexes)
			hasher.combine(self.primaryKeys)
			hasher.combine(self.withoutRowID)
		}

		let name: String
		let columns: [Column]
		let columnNames: ColumnNames
		let primaryKeys: [Column]
		let indexes: [Index]
		let fullTextIndex: FullTextIndexSchema?
		let upsertClause: String
		let withoutRowID: Bool

		let emptyInstance: (any IronbirdModel)?

		private static let resolvedTablesWithDatabases = Mutex([Table: Set<Database.InstanceID>]())
		private static let resolvedTableNamesInDatabases = Mutex([Database.InstanceID: Set<String>]())

		static func resetResolvedTables(for databaseID: Database.InstanceID) {
			Self.resolvedTablesWithDatabases.withLock { dict in
				for key in dict.keys {
					dict[key]?.remove(databaseID)
				}
			}
			Self.resolvedTableNamesInDatabases.withLock { $0[databaseID] = nil }
		}

		init(name: String, columns: [Column], primaryKeyColumnNames: [String] = ["id"], indexes: [Index] = [], fullTextSearchableColumns: [String: IronbirdModelFullTextSearchableColumn], withoutRowID: Bool = false, emptyInstance: any IronbirdModel) {
			if columns.isEmpty { fatalError("No columns specified") }
			let orderedColumnNames = columns.map(\.name)
			self.emptyInstance = emptyInstance
			self.name = name
			self.columns = columns
			self.indexes = indexes
			self.fullTextIndex = fullTextSearchableColumns.isEmpty ? nil : FullTextIndexSchema(contentTableName: name, fields: fullTextSearchableColumns)
			self.columnNames = Set(orderedColumnNames)
			self.primaryKeys = primaryKeyColumnNames.map { name in
				guard let pkColumn = columns.first(where: { $0.name == name }) else { fatalError("Primary-key column \"\(name)\" not found") }
				return pkColumn
			}
			self.withoutRowID = withoutRowID
			self.upsertClause = Self.generateUpsertClause(columnNames: orderedColumnNames, primaryKeyColumnNames: primaryKeyColumnNames)
		}

		// Enable "upsert" (REPLACE INTO) behavior ONLY for primary-key conflicts, not any other UNIQUE constraints
		private static func generateUpsertClause(columnNames: [String], primaryKeyColumnNames: [String]) -> String {
			let upsertReplacements = columnNames.filter { !primaryKeyColumnNames.contains($0) }.map { "`\($0)` = excluded.`\($0)`" }
			return upsertReplacements.isEmpty ? "" : "ON CONFLICT (`\(primaryKeyColumnNames.joined(separator: "`,`"))`) DO UPDATE SET \(upsertReplacements.joined(separator: ","))"
		}

		init?(isolatedCore core: isolated Database.Core, tableName: String, type: any IronbirdModel.Type) throws {
			if tableName.isEmpty { fatalError("Table name cannot be empty") }

			var columns: [Column] = []
			var primaryKeyColumns: [Column] = []
			let query = "PRAGMA table_info('\(tableName)')"
			for row in try core.query(query) {
				let column = try Column(row: row, tableName: tableName)
				columns.append(column)
				if column.primaryKeyIndex > 0 { primaryKeyColumns.append(column) }
			}
			if columns.isEmpty { return nil }
			primaryKeyColumns.sort { $0.primaryKeyIndex < $1.primaryKeyIndex }
			let orderedColumnNames = columns.map(\.name)

			self.emptyInstance = nil
			self.name = tableName
			self.columns = columns
			self.primaryKeys = primaryKeyColumns
			self.columnNames = Set(orderedColumnNames)
			self.fullTextIndex = nil
			self.indexes = try core.query("SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = ?", tableName).compactMap { row in
				guard let sql = row["sql"]?.stringValue else { return nil }
				return try Index(definition: sql)
			}

			let createSQL = try core.query("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", tableName).first?["sql"]?.stringValue ?? ""
			self.withoutRowID = createSQL.range(of: "WITHOUT ROWID", options: .caseInsensitive) != nil
			self.upsertClause = Self.generateUpsertClause(columnNames: orderedColumnNames, primaryKeyColumnNames: primaryKeyColumns.map(\.name))
		}

		func keyPathToColumnInfo(keyPath: AnyKeyPath) -> Ironbird.ColumnInfo {
			guard let emptyInstance else { fatalError("Cannot call keyPathToColumnName on a Ironbird.Table initialized directly from a database") }
			guard let column = emptyInstance[keyPath: keyPath] as? any ColumnWrapper else { fatalError("Key path is not a @IronbirdColumn on \(name)") }
			guard let name = column.internalNameInSchemaGenerator.value.withLock({ $0 }) else { fatalError("Failed to look up key-path name on \(self.name)") }
			return Ironbird.ColumnInfo(name: name, type: column.valueType.self)
		}

		func keyPathToColumnName(keyPath: AnyKeyPath) -> String {
			guard let emptyInstance else { fatalError("Cannot call keyPathToColumnName on a Ironbird.Table initialized directly from a database") }
			guard let column = emptyInstance[keyPath: keyPath] as? any ColumnWrapper else { fatalError("Key path is not a @IronbirdColumn on \(name). Make sure to use the $-prefixed wrapper, e.g. \\.$id.") }
			guard let name = column.internalNameInSchemaGenerator.value.withLock({ $0 }) else { fatalError("Failed to look up key-path name on \(self.name)") }
			return name
		}

		func keyPathToFTSColumnName(keyPath: AnyKeyPath) -> String {
			let keyPathName = self.keyPathToColumnName(keyPath: keyPath)
			guard self.fullTextIndex?.fields[keyPathName] != nil else { fatalError("Column \\.$\(keyPathName) is not included in `\(self.name).fullTextSearchableColumns`.") }
			return keyPathName
		}

		func createTableStatement(type: (some IronbirdModel).Type, overrideTableName: String? = nil) -> String {
			let columnDefs = self.columns.map { $0.definition() }.joined(separator: ",")
			let pkDef = self.primaryKeys.isEmpty ? "" : ",PRIMARY KEY (`\(self.primaryKeys.map(\.name).joined(separator: "`,`"))`)"
			let withoutRowIDClause = self.withoutRowID ? " WITHOUT ROWID" : ""
			return "CREATE TABLE `\(overrideTableName ?? self.name)` (\(columnDefs)\(pkDef))\(withoutRowIDClause)"
		}

		func createIndexStatements(type: (some IronbirdModel).Type) -> [String] { self.indexes.map { $0.definition(tableName: self.name) } }

		@discardableResult
		func resolveWithDatabase(type: (some IronbirdModel).Type, database: Database, core: Database.Core, isExplicitResolve: Bool = false, validator: (@Sendable (_ database: Database, _ core: isolated Database.Core) throws -> Void)?) async throws -> IronbirdModelSchemaResolution {
			if self._isAlreadyResolved(type: type, in: database) { return [] }

			if !isExplicitResolve, database.options.contains(.requireModelSchemaValidationBeforeUse) {
				fatalError("IronbirdModel \(String(describing: type)) is being queried before calling resolveSchema(in:) in a database with the .requireModelSchemaValidationBeforeUse option enabled")
			}

			return try await core.transaction {
				try self._resolveWithDatabaseIsolated(type: type, database: database, core: $0, validator: validator)
			}
		}

		@discardableResult
		func resolveWithDatabaseIsolated(type: (some IronbirdModel).Type, database: Database, core: isolated Database.Core, isExplicitResolve: Bool = false, validator: (@Sendable (_ database: Database, _ core: isolated Database.Core) throws -> Void)?) throws -> IronbirdModelSchemaResolution {
			if self._isAlreadyResolved(type: type, in: database) { return [] }

			if !isExplicitResolve, database.options.contains(.requireModelSchemaValidationBeforeUse) {
				fatalError("IronbirdModel \(String(describing: type)) is being queried before calling resolveSchema(in:) in a database with the .requireModelSchemaValidationBeforeUse option enabled")
			}

			return try self._resolveWithDatabaseIsolated(type: type, database: database, core: core, validator: validator)
		}

		func _isAlreadyResolved(type: (some Any).Type, in database: Database) -> Bool {
			let alreadyResolved = Self.resolvedTablesWithDatabases.withLock { $0[self]?.contains(database.id) ?? false }
			if !alreadyResolved, Self.resolvedTableNamesInDatabases.withLock({ $0[database.id]?.contains(name) ?? false }) {
				fatalError("Multiple IronbirdModel types cannot use the same table name (\"\(self.name)\") in one Database")
			}
			return alreadyResolved
		}

		private func _resolveWithDatabaseIsolated(type: (some IronbirdModel).Type, database: Database, core: isolated Database.Core, validator: (@Sendable (_ database: Database, _ core: isolated Database.Core) throws -> Void)?) throws -> IronbirdModelSchemaResolution {
			var resolution: IronbirdModelSchemaResolution = []

			// Table not created yet
			let schemaInDB: Table
			do {
				let existingSchemaInDB = try Table(isolatedCore: core, tableName: name, type: type)
				if let existingSchemaInDB {
					schemaInDB = existingSchemaInDB
				} else {
					try core.execute(self.createTableStatement(type: type))
					for createIndexStatement in self.createIndexStatements(type: type) {
						try core.execute(createIndexStatement)
					}
					schemaInDB = try Table(isolatedCore: core, tableName: self.name, type: type)!
					resolution.insert(.createdTable)
				}
			}

			let primaryKeysChanged = (primaryKeys != schemaInDB.primaryKeys)
			let withoutRowIDChanged = self.withoutRowID != schemaInDB.withoutRowID

			// comparing as Sets to ignore differences in column/index order
			let currentColumns = Set(schemaInDB.columns)
			let targetColumns = Set(columns)
			let currentIndexes = Set(schemaInDB.indexes)
			let targetIndexes = Set(indexes)

			let needsSchemaChanges = withoutRowIDChanged || primaryKeysChanged || currentColumns != targetColumns || currentIndexes != targetIndexes
			let needsFTSRebuild = try fullTextIndex?.needsRebuild(core: core) ?? false
			let needsFTSDelete = try fullTextIndex == nil && FullTextIndexSchema.ftsTableExists(core: core, contentTableName: self.name)

			if needsSchemaChanges || needsFTSRebuild || needsFTSDelete {
				try core.transaction { core in
					// drop indexes and columns
					var schemaInDB = schemaInDB
					for indexToDrop in currentIndexes.subtracting(targetIndexes) {
						try core.execute("DROP INDEX `\(self.name)+index+\(indexToDrop.name)`")
					}
					for columnNameToDrop in schemaInDB.columnNames.subtracting(self.columnNames) {
						try core.execute("ALTER TABLE `\(self.name)` DROP COLUMN `\(columnNameToDrop)`")
					}
					schemaInDB = try Table(isolatedCore: core, tableName: self.name, type: type)!

					if withoutRowIDChanged || primaryKeysChanged || !Set(schemaInDB.columns).subtracting(self.columns).isEmpty {
						// At least one column has changed type -- do a full rebuild
						let tempTableName = "_\(name)+temp+\(Int32.random(in: 0..<Int32.max))"
						try core.execute(self.createTableStatement(type: type, overrideTableName: tempTableName))

						let commonColumnNames = Set(schemaInDB.columnNames).intersection(self.columnNames)
						let commonColumnsOrderedNameList = schemaInDB.columns.filter { commonColumnNames.contains($0.name) }.map(\.name)
						if !commonColumnsOrderedNameList.isEmpty {
							let fieldList = "`\(commonColumnsOrderedNameList.joined(separator: "`,`"))`"
							try core.execute("INSERT INTO `\(tempTableName)` (\(fieldList)) SELECT \(fieldList) FROM `\(self.name)`")
						}
						try core.execute("DROP TABLE `\(self.name)`")
						try core.execute("ALTER TABLE `\(tempTableName)` RENAME TO `\(self.name)`")
						schemaInDB = try Table(isolatedCore: core, tableName: self.name, type: type)!
					}

					// add columns and indexes
					for columnToAdd in Set(self.columns).subtracting(schemaInDB.columns) {
						if !columnToAdd.mayBeNull, let valueType = columnToAdd.valueType, valueType is URL.Type {
							throw IronbirdTableError.impossibleMigration(type: type,
																		 description: "Cannot add non-NULL URL column `\(columnToAdd.name)` since default values for existing rows cannot be specified")
						}

						try core.execute("ALTER TABLE `\(self.name)` ADD COLUMN \(columnToAdd.definition())")
					}

					for indexToAdd in Set(self.indexes).subtracting(schemaInDB.indexes) {
						try core.execute(indexToAdd.definition(tableName: self.name))
					}

					if needsFTSRebuild { try self.fullTextIndex?.rebuild(core: core) }

					if needsFTSDelete {
						try core.query("DROP TRIGGER IF EXISTS `\(FullTextIndexSchema.insertTriggerName(self.name))`")
						try core.query("DROP TRIGGER IF EXISTS `\(FullTextIndexSchema.updateTriggerName(self.name))`")
						try core.query("DROP TRIGGER IF EXISTS `\(FullTextIndexSchema.deleteTriggerName(self.name))`")
						try core.query("DROP TABLE IF EXISTS `\(FullTextIndexSchema.ftsTableName(self.name))`")
					}
				}

				if needsSchemaChanges { resolution.insert(.migratedTable) }

				if needsFTSRebuild || needsFTSDelete { resolution.insert(.migratedFullTextIndex) }
			}

			// allow calling model to verify before committing
			if let validator { try validator(database, core) }

			Self.resolvedTablesWithDatabases.withLock {
				if $0[self] == nil { $0[self] = Set<Database.InstanceID>() }
				$0[self]!.insert(database.id)
			}

			Self.resolvedTableNamesInDatabases.withLock {
				if $0[database.id] == nil { $0[database.id] = Set<String>() }
				$0[database.id]!.insert(self.name)
			}

			return resolution
		}
	}
}

extension String {
	func removingLeadingUnderscore() -> String {
		guard self.hasPrefix("_"), self.count > 1, let firstCharIndex = self.indices.first else { return self }
		return String(self.suffix(from: self.index(after: firstCharIndex)))
	}
}

final class SchemaGenerator: Sendable {
	static let shared = SchemaGenerator()

	let tableCache = Mutex<[ObjectIdentifier: Ironbird.Table]>([:])

	func table(for type: (some IronbirdModel).Type) -> Ironbird.Table {
		self.tableCache.withLock { cache in
			let identifier = ObjectIdentifier(type)
			if let cached = cache[identifier] { return cached }

			let table = Self.generateTableDefinition(type)
			cache[identifier] = table
			return table
		}
	}

	static func instanceFromDefaults<T: IronbirdModel>(_ type: T.Type) -> T {
		do {
			return try T(from: IronbirdDefaultsDecoder())
		} catch {
			fatalError("\(String(describing: T.self)) instances cannot be generated by Ironbird's automatic decoding:\n\n" +
				"    \(error)\n\n" +
				"    If \(String(describing: T.self)) implements init(from decoder: Decoder), it must\n" +
				"    return a valid instance when supplied with a IronbirdDefaultsDecoder.\n\n" +
				"    See the IronbirdDefaultsDecoder documentation.\n")
		}
	}

	private static func generateTableDefinition<T: IronbirdModel>(_ type: T.Type) -> Ironbird.Table {
		let emptyInstance = self.instanceFromDefaults(type)

		let mirror = Mirror(reflecting: emptyInstance)
		var columns: [Ironbird.Column] = []
		var nullableColumnNames = Set<String>()
		var hasColumNamedID = false
		for child in mirror.children {
			guard var label = child.label else { continue }

			if let column = child.value as? any ColumnWrapper {
				label = label.removingLeadingUnderscore()
				column.internalNameInSchemaGenerator.value.withLock { $0 = label }
				if label == "id" { hasColumNamedID = true }

				var isOptional = false
				var unwrappedType = Swift.type(of: column.value) as Any.Type
				while let wrappedType = unwrappedType as? WrappedType.Type {
					if unwrappedType is OptionalProtocol.Type {
						isOptional = true
						nullableColumnNames.insert(label)
					}
					unwrappedType = wrappedType.schemaGeneratorWrappedType()
				}

				var columnType: Ironbird.ColumnType
				switch unwrappedType {
					case is IronbirdStorableAsInteger.Type: columnType = .integer
					case is IronbirdStorableAsDouble.Type: columnType = .double
					case is IronbirdStorableAsText.Type: columnType = .text
					case is IronbirdStorableAsData.Type: columnType = .data
					case is any IronbirdIntegerEnum.Type: columnType = .integer
					case is any IronbirdStringEnum.Type: columnType = .text
					default:
						fatalError("\(String(describing: T.self)).\(label) is not a supported type for a database column (\(String(describing: unwrappedType)))")
				}

				columns.append(Ironbird.Column(name: label, columnType: columnType, valueType: unwrappedType, mayBeNull: isOptional))
			}
		}

		let keyPathToColumnName = { (keyPath: AnyKeyPath, messageLabel: String) in
			guard let column = emptyInstance[keyPath: keyPath] as? any ColumnWrapper else {
				fatalError("\(String(describing: T.self)): \(messageLabel) includes a key path that is not a @IronbirdColumn. (Use the \"$\" wrapper for a column.)")
			}

			guard let name = column.internalNameInSchemaGenerator.value.withLock({ $0 }) else { fatalError("\(String(describing: T.self)): Failed to look up \(messageLabel) key-path name") }
			return name
		}

		var primaryKeyNames = T.primaryKey.map { keyPathToColumnName($0, "primary key") }
		if primaryKeyNames.count == 0 {
			if hasColumNamedID { primaryKeyNames = ["id"] }
			else { fatalError("\(String(describing: T.self)): Must specify a primary key or have a property named \"id\" to automatically use as primary key") }
		}

		var indexes = T.indexes.map { keyPaths in Ironbird.Index(columnNames: keyPaths.map { keyPathToColumnName($0, "index") }, unique: false) }
		indexes.append(contentsOf: T.uniqueIndexes.map { keyPaths in
			Ironbird.Index(columnNames: keyPaths.map {
				let name = keyPathToColumnName($0, "unique index")
				if nullableColumnNames.contains(name), keyPaths.count > 1 {
					/*
					    I've decided not to support multi-column UNIQUE indexes containing NULLable columns because
					    they behave in a way that most people wouldn't expect: a NULL value anywhere in a multi-column
					    index makes it pass any UNIQUE checks, even if the other column values would otherwise be
					    non-unique.

					    E.g. CREATE TABLE t (a NOT NULL, b NULL) with UNIQUE (a, b) would allow these rows to coexist:

					       (a=1, b=NULL)
					       (a=1, b=NULL)

					    ...even though they would not be considered unique values by Swift or most people's assumptions.

					    Since Ironbird tries to abstract away most really weird SQL behaviors that would differ
					    significantly from what Swift programmers expect, this is intentionally not permitted.
					 */
					fatalError("\(String(describing: T.self)): Ironbird does not support multi-column UNIQUE indexes containing NULL columns. " +
						"Change column \"\(name)\" to non-optional, or create a separate UNIQUE index for it.")
				}
				return name
			}, unique: true)
		})

		var indexedColumnSets = Set<[String]>()
		for index in indexes {
			let (inserted, _) = indexedColumnSets.insert(index.columnNames)
			if !inserted { fatalError("\(String(describing: T.self)): Duplicate index definitions for [\(index.columnNames.joined(separator: ","))]") }
		}

		var ftsColumns: [String: IronbirdModelFullTextSearchableColumn] = [:]
		for (key, value) in T.fullTextSearchableColumns {
			ftsColumns[keyPathToColumnName(key, "fullTextSearchableColumns")] = value
		}

		return Ironbird.Table(name: T.tableName, columns: columns, primaryKeyColumnNames: primaryKeyNames, indexes: indexes, fullTextSearchableColumns: ftsColumns, withoutRowID: T.withoutRowID, emptyInstance: emptyInstance)
	}
}

// MARK: - Empty initialization of Codable types

//
// HUGE credit to https://github.com/jjrscott/EmptyInitializer for this decoder trick!
// The following is a condensed version of that code with minor tweaks, mostly to work
// with IronbirdColumn wrappers and support URL as a property type.

/// A special `Decoder`, used internally by ``IronbirdModel``, that returns placeholder values for all keys.
///
/// Used primarily by ``IronbirdModel/instanceFromDefaults()`` and schema generation.
///
/// For any key, `IronbirdDefaultsDecoder` returns a default value for the requested type:
///
/// Type | Value Returned
/// --- | ---
/// Any numeric type | `0`
/// `Bool` | `false`
/// `String` | `""` (empty string)
/// `URL` |  `https://apple.com/`
/// `Date` | `Date.distantPast`
/// `Data` | `Data()` (empty data)
/// Any `CaseIterable` enum | The enum's first value
///
/// If a ``IronbirdModel`` does not implement custom decoding, this works automatically.
///
/// If you implement custom decoding in a ``IronbirdModel`` using `init(from:)`, ensure that a valid instance
/// is always returned when the supplied `Decoder` argument is a `IronbirdDefaultsDecoder`.
///
/// ## Example
///
/// ```swift
/// struct MyCustomDecodedModel: IronbirdModel {
///     @IronbirdColumn var id: Int
///     @IronbirdColumn var name: String
///     @IronbirdColumn var url: URL
///
///     enum CodingKeys: String, IronbirdCodingKey {
///         case id = "idStr"
///         case name
///         case url
///     }
///
///     init(from decoder: Decoder) throws {
///         let container = try decoder.container(keyedBy: CodingKeys.self)
///
///         // We expect the key "idStr" to contain a String representation
///         // of an Int for our `id` property.
///         //
///         // Since IronbirdDefaultsDecoder returns "" for String, which
///         // would fail the Int conversion, we supply a placeholder value
///         // when used with IronbirdDefaultsDecoder.
///
///         if decoder is IronbirdDefaultsDecoder {
///             self.id = 0
///         } else {
///             let idStr = try container.decode(String.self, forKey: .id)
///             guard let id = Int(idStr) else {
///                 throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Expected numeric string")
///             }
///             self.id = id
///         }
///
///         // Straightforward decoding works for most fields:
///         self.name = try container.decode(String.self, forKey: .name)
///         self.url = try container.decode(URL.self, forKey: .url)
///     }
/// }
///
/// ```
public struct IronbirdDefaultsDecoder: Decoder {
	public var codingPath: [CodingKey] = []
	public var userInfo: [CodingUserInfoKey: Any] = [:]
	public func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> { KeyedDecodingContainer(EmptyKeyedDecodingContainer<Key>()) }
	public func unkeyedContainer() throws -> UnkeyedDecodingContainer { EmptyUnkeyedDecodingContainer() }
	public func singleValueContainer() throws -> SingleValueDecodingContainer { EmptySingleValueDecodingContainer() }
}

fileprivate struct EmptyKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
	var codingPath: [CodingKey] = []
	var allKeys: [Key] = []
	func contains(_ key: Key) -> Bool { true }
	func decodeNil(forKey key: Key) throws -> Bool { true }
	func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { false }
	func decode(_ type: String.Type, forKey key: Key) throws -> String { "" }
	func decode(_ type: Double.Type, forKey key: Key) throws -> Double { 0 }
	func decode(_ type: Float.Type, forKey key: Key) throws -> Float { 0 }
	func decode(_ type: Int.Type, forKey key: Key) throws -> Int { 0 }
	func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { 0 }
	func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { 0 }
	func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { 0 }
	func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { 0 }
	func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { 0 }
	func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { 0 }
	func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { 0 }
	func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { 0 }
	func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { 0 }
	func decode<T>(_ type: IronbirdColumn<T>.Type, forKey key: Key) throws -> IronbirdColumn<T> { IronbirdColumn<T>(wrappedValue: try T(from: IronbirdDefaultsDecoder())) }
	func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
		if T.self == URL.self { return URL(string: "https://apple.com/") as! T }
		if T.self == Data.self { return Data() as! T }
		if T.self == Date.self { return Date.distantPast as! T }
		if let iterableT = T.self as? any CaseIterable.Type, let first = (iterableT.allCases as any Collection).first { return first as! T }
		return try T(from: IronbirdDefaultsDecoder())
	}

	func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer { EmptyUnkeyedDecodingContainer() }
	func superDecoder() throws -> Decoder { IronbirdDefaultsDecoder() }
	func superDecoder(forKey key: Key) throws -> Decoder { IronbirdDefaultsDecoder() }
	func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
		KeyedDecodingContainer(EmptyKeyedDecodingContainer<NestedKey>())
	}
}

fileprivate struct EmptySingleValueDecodingContainer: SingleValueDecodingContainer {
	var codingPath: [CodingKey] = []
	func decodeNil() -> Bool { true }
	func decode(_ type: Bool.Type) throws -> Bool { false }
	func decode(_ type: String.Type) throws -> String { "" }
	func decode(_ type: Double.Type) throws -> Double { 0 }
	func decode(_ type: Float.Type) throws -> Float { 0 }
	func decode(_ type: Int.Type) throws -> Int { 0 }
	func decode(_ type: Int8.Type) throws -> Int8 { 0 }
	func decode(_ type: Int16.Type) throws -> Int16 { 0 }
	func decode(_ type: Int32.Type) throws -> Int32 { 0 }
	func decode(_ type: Int64.Type) throws -> Int64 { 0 }
	func decode(_ type: UInt.Type) throws -> UInt { 0 }
	func decode(_ type: UInt8.Type) throws -> UInt8 { 0 }
	func decode(_ type: UInt16.Type) throws -> UInt16 { 0 }
	func decode(_ type: UInt32.Type) throws -> UInt32 { 0 }
	func decode(_ type: UInt64.Type) throws -> UInt64 { 0 }
	func decode<T>(_ type: IronbirdColumn<T>.Type) throws -> IronbirdColumn<T> { IronbirdColumn<T>(wrappedValue: try T(from: IronbirdDefaultsDecoder())) }
	func decode<T: Decodable>(_ type: T.Type) throws -> T {
		if T.self == URL.self { return URL(string: "https://apple.com/") as! T }
		if T.self == Data.self { return Data() as! T }
		if let iterableT = T.self as? any CaseIterable.Type, let first = (iterableT.allCases as any Collection).first { return first as! T }
		return try T(from: IronbirdDefaultsDecoder())
	}
}

fileprivate struct EmptyUnkeyedDecodingContainer: UnkeyedDecodingContainer {
	var codingPath: [CodingKey] = []
	var count: Int?
	var isAtEnd: Bool = true
	var currentIndex: Int = 0
	mutating func decodeNil() throws -> Bool { true }
	mutating func decode(_ type: Bool.Type) throws -> Bool { false }
	mutating func decode(_ type: String.Type) throws -> String { "" }
	mutating func decode(_ type: Double.Type) throws -> Double { 0 }
	mutating func decode(_ type: Float.Type) throws -> Float { 0 }
	mutating func decode(_ type: Int.Type) throws -> Int { 0 }
	mutating func decode(_ type: Int8.Type) throws -> Int8 { 0 }
	mutating func decode(_ type: Int16.Type) throws -> Int16 { 0 }
	mutating func decode(_ type: Int32.Type) throws -> Int32 { 0 }
	mutating func decode(_ type: Int64.Type) throws -> Int64 { 0 }
	mutating func decode(_ type: UInt.Type) throws -> UInt { 0 }
	mutating func decode(_ type: UInt8.Type) throws -> UInt8 { 0 }
	mutating func decode(_ type: UInt16.Type) throws -> UInt16 { 0 }
	mutating func decode(_ type: UInt32.Type) throws -> UInt32 { 0 }
	mutating func decode(_ type: UInt64.Type) throws -> UInt64 { 0 }
	mutating func decode<T>(_ type: IronbirdColumn<T>.Type) throws -> IronbirdColumn<T> { IronbirdColumn<T>(wrappedValue: try T(from: IronbirdDefaultsDecoder())) }
	mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
		if T.self == URL.self { return URL(string: "file:///") as! T }
		if T.self == Data.self { return Data() as! T }
		if let iterableT = T.self as? any CaseIterable.Type, let first = (iterableT.allCases as any Collection).first { return first as! T }
		return try T(from: IronbirdDefaultsDecoder())
	}

	mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer { EmptyUnkeyedDecodingContainer() }
	mutating func superDecoder() throws -> Decoder { IronbirdDefaultsDecoder() }
	mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
		KeyedDecodingContainer(EmptyKeyedDecodingContainer<NestedKey>())
	}
}
