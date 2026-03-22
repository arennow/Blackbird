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
//  BlackbirdModelStructuredQuerying.swift
//  Created by Marco Arment on 3/11/23.
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

import Loggable
import Logging

extension PartialKeyPath: @retroactive @unchecked Sendable {}

public extension String.StringInterpolation {
	mutating func appendInterpolation<T: IronbirdModel>(_ keyPath: T.IronbirdColumnKeyPath) {
		let table = SchemaGenerator.shared.table(for: T.self)
		appendLiteral(table.keyPathToColumnName(keyPath: keyPath))
	}
}

/// A column key-paths and direction to be used in SQL queries as `ORDER BY` clauses.
///
/// Specify as either:
/// - `.ascending(keyPath)`: equivalent to `ORDER BY keyPath` in SQL
/// - `.descending(keyPath)`: equivalent to `ORDER BY keyPath DESC` in SQL
///
/// Used as a `orderBy:` expression in ``IronbirdModel`` functions such as:
/// - ``IronbirdModel/query(in:columns:matching:orderBy:limit:)``
/// - ``IronbirdModel/read(from:matching:orderBy:limit:)``
public struct IronbirdModelOrderClause<T: IronbirdModel>: Sendable, CustomDebugStringConvertible {
	public enum Direction: Sendable {
		case ascending
		case descending
	}

	let column: T.IronbirdColumnKeyPath
	let direction: Direction

	public static func ascending(_ column: T.IronbirdColumnKeyPath) -> IronbirdModelOrderClause { IronbirdModelOrderClause(column, direction: .ascending) }
	public static func descending(_ column: T.IronbirdColumnKeyPath) -> IronbirdModelOrderClause { IronbirdModelOrderClause(column, direction: .descending) }

	init(_ column: T.IronbirdColumnKeyPath, direction: Direction) {
		self.column = column
		self.direction = direction
	}

	func orderByClause(table: Ironbird.Table) -> String {
		let columnName = table.keyPathToColumnName(keyPath: self.column)
		return "`\(columnName)`\(self.direction == .descending ? " DESC" : "")"
	}

	public var debugDescription: String { self.orderByClause(table: T.table) }
}

struct DecodedStructuredQuery {
	let query: String
	let arguments: [Sendable]
	let whereClause: String? // already included in query
	let whereArguments: [Sendable]? // already included in arguments
	let changedColumns: Ironbird.ColumnNames
	let tableName: String
	let cacheKey: [Ironbird.Value]?

	init<T: IronbirdModel>(operation: String = "SELECT * FROM", selectColumnSubset: [PartialKeyPath<T>]? = nil, forMulticolumnPrimaryKey: [Any]? = nil, matching: IronbirdModelColumnExpression<T>? = nil, updating: [PartialKeyPath<T>: Sendable] = [:], orderBy: [IronbirdModelOrderClause<T>] = [], limit: Int? = nil, offset: Int? = nil, updateWhereAutoOptimization: Bool = true) {
		let table = SchemaGenerator.shared.table(for: T.self)
		var clauses: [String] = []
		var arguments: [Ironbird.Value] = []
		var operation = operation
		var matching = matching

		let isSelectStatement: Bool
		if let selectColumnSubset {
			let columnList = selectColumnSubset.map { table.keyPathToColumnName(keyPath: $0) }.joined(separator: "`,`")
			operation = "SELECT `\(columnList)` FROM"
			isSelectStatement = true
		} else {
			isSelectStatement = operation.uppercased().hasPrefix("SELECT ")
		}

		var setClauses: [String] = []
		var changedColumns = Ironbird.ColumnNames()
		var updateWhereNotMatchingExpr: IronbirdModelColumnExpression<T>? = nil
		for (keyPath, value) in updating {
			let columnName = table.keyPathToColumnName(keyPath: keyPath)
			changedColumns.insert(columnName)

			let constantValue: Ironbird.Value?
			if let valueExpression = value as? IronbirdColumnExpression<T> {
				constantValue = valueExpression.constantValue
				let (placeholder, values) = valueExpression.expressionInUpdateQuery(table: table)
				setClauses.append("`\(columnName)` = \(placeholder)")
				arguments.append(contentsOf: values)
			} else {
				let valueWrapped = try! Ironbird.Value.fromAny(value)
				setClauses.append("`\(columnName)` = ?")
				arguments.append(valueWrapped)
				constantValue = valueWrapped
			}

			if updateWhereAutoOptimization, let constantValue {
				// In an UPDATE query, SQLite will call the update hook and report a change on EVERY row
				// that matches the WHERE clause (or every row in the table without a WHERE) and report it
				// as changed, even if no rows matched and therefore no data was changed. E.g.:
				//
				//   UPDATE t SET a = NULL, b = 2; -- in a table with X rows, this reports X rows changed
				//   UPDATE t SET a = NULL, b = 2; -- ALSO reports X rows changed, even though none actually were
				//
				// So we add automatic WHERE clauses corresponding to each SET value to make it like this:
				//
				//   UPDATE t SET a = NULL, b = 2 WHERE a IS NOT NULL OR b != 2;
				//
				// ...which makes SQLite properly report only the actually-changed rows.
				//
				if updateWhereNotMatchingExpr != nil {
					updateWhereNotMatchingExpr = updateWhereNotMatchingExpr! || keyPath != constantValue
				} else {
					updateWhereNotMatchingExpr = keyPath != constantValue
				}
			}
		}
		if !setClauses.isEmpty {
			clauses.append("SET \(setClauses.joined(separator: ","))")

			if let updateWhereNotMatchingExpr {
				if matching != nil {
					matching = matching! && updateWhereNotMatchingExpr
				} else {
					matching = updateWhereNotMatchingExpr
				}
			}
		}

		if let matching {
			if forMulticolumnPrimaryKey != nil { fatalError("Cannot combine forMulticolumnPrimaryKey with matching") }

			let (whereClause, whereArguments) = matching.compile(table: table, queryingFullTextIndex: false)
			self.whereClause = whereClause
			self.whereArguments = whereArguments
			if let whereClause { clauses.append("WHERE \(whereClause)") }
			arguments.append(contentsOf: whereArguments)
		} else if let forMulticolumnPrimaryKey {
			let whereArguments = forMulticolumnPrimaryKey.map { try! Ironbird.Value.fromAny($0) }
			self.whereClause = table.primaryKeys.map { "`\($0.name)` = ?" }.joined(separator: " AND ")
			self.whereArguments = whereArguments
			clauses.append("WHERE \(self.whereClause!)")
			arguments.append(contentsOf: whereArguments)
		} else {
			self.whereClause = nil
			self.whereArguments = nil
		}

		if !orderBy.isEmpty {
			let orderByClause = orderBy.map { $0.orderByClause(table: table) }.joined(separator: ",")
			clauses.append("ORDER BY \(orderByClause)")
		}

		if let limit {
			clauses.append("LIMIT \(limit)")

			if let offset {
				clauses.append("OFFSET \(offset)")
			}
		}

		self.tableName = table.name
		self.query = "\(operation) `\(self.tableName)`\(clauses.isEmpty ? "" : " \(clauses.joined(separator: " "))")"
		self.arguments = arguments
		self.changedColumns = changedColumns

		if isSelectStatement {
			var cacheKey = [Ironbird.Value.text(self.query)]
			cacheKey.append(contentsOf: arguments)
			self.cacheKey = cacheKey
		} else {
			self.cacheKey = nil
		}
	}
}

fileprivate let sharedModelCacheLogger = Logger.with(subsystem: Ironbird.loggingSubsystem, category: "ModelCache")

public extension IronbirdModel {
	fileprivate static func _cacheableStructuredResult<T: Sendable>(database: Ironbird.Database, decoded: DecodedStructuredQuery, resultFetcher: ((Ironbird.Database) async throws -> T)) async throws -> T {
		let cacheLimit = Self.cacheLimit
		guard cacheLimit > 0, let cacheKey = decoded.cacheKey else { return try await resultFetcher(database) }

		let logActivity = database.options.contains(.debugPrintCacheActivity)

		if let cachedResult = database.cache.readQueryResult(tableName: decoded.tableName, cacheKey: cacheKey) as? T {
			if logActivity { sharedModelCacheLogger.debug("[IronbirdModel] ++ Cache hit: \(cacheKey)") }
			return cachedResult
		}

		let result = try await resultFetcher(database)
		if logActivity { sharedModelCacheLogger.debug("[IronbirdModel] -- Cache write: \(cacheKey)") }
		database.cache.writeQueryResult(tableName: decoded.tableName, cacheKey: cacheKey, result: result, entryLimit: cacheLimit)
		return result
	}

	fileprivate static func _cacheableStructuredResultIsolated<T: Sendable>(database: Ironbird.Database, core: isolated Ironbird.Database.Core, decoded: DecodedStructuredQuery, resultFetcher: ((Ironbird.Database, isolated Ironbird.Database.Core) throws -> T)) throws -> T {
		let cacheLimit = Self.cacheLimit
		guard cacheLimit > 0, let cacheKey = decoded.cacheKey else { return try resultFetcher(database, core) }

		if let cachedResult = database.cache.readQueryResult(tableName: decoded.tableName, cacheKey: cacheKey) as? T { return cachedResult }

		let result = try resultFetcher(database, core)
		database.cache.writeQueryResult(tableName: decoded.tableName, cacheKey: cacheKey, result: result, entryLimit: cacheLimit)
		return result
	}

	/// Get the number of rows in this IronbirdModel's table.
	///
	/// - Parameters:
	///   - database: The ``Ironbird/Database`` instance to read from.
	///   - matching: An optional filtering expression using column key-paths, e.g. `\.$id > 100`, to be used in the resulting SQL query as a `WHERE` clause. See ``IronbirdModelColumnExpression``.
	///
	///     If not specified, all rows in the table will be counted.
	/// - Returns: The number of matching rows.
	///
	/// ## Example
	/// ```swift
	/// let c = try await Post.count(in: db, matching: \.$id > 100)
	/// // Equivalent to:
	/// // "SELECT COUNT(*) FROM Post WHERE id > 100"
	/// ```
	static func count(in database: Ironbird.Database, matching: IronbirdModelColumnExpression<Self>? = nil) async throws -> Int {
		let decoded = DecodedStructuredQuery(operation: "SELECT COUNT(*) FROM", matching: matching)
		return try await self._cacheableStructuredResult(database: database, decoded: decoded) {
			try await _queryInternal(in: $0, decoded.query, arguments: decoded.arguments).first!["COUNT(*)"]!.intValue!
		}
	}

	/// Synchronous version of ``count(in:matching:)``  for use when the database actor is isolated within calls to ``Ironbird/Database/transaction(_:)`` or ``Ironbird/Database/cancellableTransaction(_:)``.
	static func countIsolated(in database: Ironbird.Database, core: isolated Ironbird.Database.Core, matching: IronbirdModelColumnExpression<Self>? = nil) throws -> Int {
		let decoded = DecodedStructuredQuery(operation: "SELECT COUNT(*) FROM", matching: matching)
		return try self._cacheableStructuredResultIsolated(database: database, core: core, decoded: decoded) {
			try _queryInternalIsolated(in: $0, core: $1, decoded.query, arguments: decoded.arguments).first!["COUNT(*)"]!.intValue!
		}
	}

	/// Reads instances from a database using key-path equality tests.
	///
	/// - Parameters:
	///   - database: The ``Ironbird/Database`` instance to read from.
	///   - matching: An optional filtering expression using column key-paths, e.g. `\.$id == 1`, to be used in the resulting SQL query as a `WHERE` clause. See ``IronbirdModelColumnExpression``.
	///   - orderBy: An optional series of column key-paths to order the results by, represented as:
	///     - `.ascending(keyPath)`: equivalent to SQL `ORDER BY keyPath`
	///     - `.descending(keyPath)`: equivalent to SQL `ORDER BY keyPath DESC`
	///
	///     If not specified, the order of results is undefined.
	///   - limit: An optional limit to how many results will be returned. If not specified, all matching results will be returned.
	/// - Returns: An array of decoded instances matching the query.
	///
	/// ## Example
	/// ```swift
	/// let posts = try await Post.read(
	///     from: db,
	///     matching: \.$id == 123 && \.$title == "Hi",
	///     orderBy: .ascending(\.$id),
	///     limit: 1
	/// )
	/// // Equivalent to:
	/// // "SELECT * FROM Post WHERE id = 123 AND title = 'Hi' ORDER BY id LIMIT 1"
	/// ```
	static func read(from database: Ironbird.Database, matching: IronbirdModelColumnExpression<Self>? = nil, orderBy: IronbirdModelOrderClause<Self> ..., limit: Int? = nil, offset: Int? = nil) async throws -> [Self] {
		let decoded = DecodedStructuredQuery(matching: matching, orderBy: orderBy, limit: limit, offset: offset)
		return try await self._cacheableStructuredResult(database: database, decoded: decoded) { database in
			try await _queryInternal(in: database, decoded.query, arguments: decoded.arguments).map {
				let decoder = IronbirdSQLiteDecoder(database: database, row: $0.row)
				return try Self(from: decoder)
			}
		}
	}

	/// Synchronous version of ``read(from:matching:orderBy:limit:)``  for use when the database actor is isolated within calls to ``Ironbird/Database/transaction(_:)`` or ``Ironbird/Database/cancellableTransaction(_:)``.
	static func readIsolated(from database: Ironbird.Database, core: isolated Ironbird.Database.Core, matching: IronbirdModelColumnExpression<Self>? = nil, orderBy: IronbirdModelOrderClause<Self> ..., limit: Int? = nil, offset: Int? = nil) throws -> [Self] {
		let decoded = DecodedStructuredQuery(matching: matching, orderBy: orderBy, limit: limit, offset: offset)
		return try self._cacheableStructuredResultIsolated(database: database, core: core, decoded: decoded) { database, core in
			try _queryInternalIsolated(in: database, core: core, decoded.query, arguments: decoded.arguments).map {
				let decoder = IronbirdSQLiteDecoder(database: database, row: $0.row)
				return try Self(from: decoder)
			}
		}
	}

	/// Selects a subset of the table's columns matching the given column values, using column key-paths for this model type.
	/// - Parameters:
	///   - database: The ``Ironbird/Database`` instance to query.
	///   - columns: An array of column key-paths of this IronbirdModel type. The returned rows will contain only these columns.
	///   - matching: An optional filtering expression using column key-paths, e.g. `\.$id == 1`, to be used in the resulting SQL query as a `WHERE` clause. See ``IronbirdModelColumnExpression``.
	///   - orderBy: An optional series of column key-paths to order the results by, represented as:
	///     - `.ascending(keyPath)`: equivalent to SQL `ORDER BY keyPath`
	///     - `.descending(keyPath)`: equivalent to SQL `ORDER BY keyPath DESC`
	///
	///     If not specified, the order of results is undefined.
	///   - limit: An optional limit to how many results will be returned. If not specified, all matching results will be returned.
	/// - Returns: An array of matching rows, each containing only the columns specified.
	static func query(in database: Ironbird.Database, columns: [IronbirdColumnKeyPath], matching: IronbirdModelColumnExpression<Self>? = nil, orderBy: IronbirdModelOrderClause<Self> ..., limit: Int? = nil) async throws -> [Ironbird.ModelRow<Self>] {
		let decoded = DecodedStructuredQuery(selectColumnSubset: columns, matching: matching, orderBy: orderBy, limit: limit)
		return try await self._cacheableStructuredResult(database: database, decoded: decoded) {
			try await _queryInternal(in: $0, decoded.query, arguments: decoded.arguments)
		}
	}

	/// Synchronous version of ``query(in:columns:matching:orderBy:limit:)`` for use when the database actor is isolated within calls to ``Ironbird/Database/transaction(_:)`` or ``Ironbird/Database/cancellableTransaction(_:)``.
	static func queryIsolated(in database: Ironbird.Database, core: isolated Ironbird.Database.Core, columns: [IronbirdColumnKeyPath], matching: IronbirdModelColumnExpression<Self>? = nil, orderBy: IronbirdModelOrderClause<Self> ..., limit: Int? = nil) throws -> [Ironbird.ModelRow<Self>] {
		let decoded = DecodedStructuredQuery(selectColumnSubset: columns, matching: matching, orderBy: orderBy, limit: limit)
		return try self._cacheableStructuredResultIsolated(database: database, core: core, decoded: decoded) {
			try _queryInternalIsolated(in: $0, core: $1, decoded.query, arguments: decoded.arguments)
		}
	}

	/// Selects a subset of the table's columns matching the given column values, using column key-paths for this model type.
	/// - Parameters:
	///   - database: The ``Ironbird/Database`` instance to query.
	///   - columns: An array of column key-paths of this IronbirdModel type. The returned rows will contain only these columns.
	///   - primaryKey: The single-column primary-key value to match.
	///
	/// - Returns: A row with the requested column values for the given primary-key value, or `nil` if no row matches the supplied primary-key value.
	static func query(in database: Ironbird.Database, columns: [IronbirdColumnKeyPath], primaryKey: Any) async throws -> Ironbird.ModelRow<Self>? {
		try await self.query(in: database, columns: columns, multicolumnPrimaryKey: [primaryKey])
	}

	/// Synchronous version of ``query(in:columns:primaryKey:)`` for use when the database actor is isolated within calls to ``Ironbird/Database/transaction(_:)`` or ``Ironbird/Database/cancellableTransaction(_:)``.
	static func queryIsolated(in database: Ironbird.Database, core: isolated Ironbird.Database.Core, columns: [IronbirdColumnKeyPath], primaryKey: Any) throws -> Ironbird.ModelRow<Self>? {
		try self.queryIsolated(in: database, core: core, columns: columns, multicolumnPrimaryKey: [primaryKey])
	}

	/// Selects a subset of the table's columns matching the given column values, using column key-paths for this model type.
	/// - Parameters:
	///   - database: The ``Ironbird/Database`` instance to query.
	///   - columns: An array of column key-paths of this IronbirdModel type. The returned rows will contain only these columns.
	///   - multicolumnPrimaryKey: The multi-column primary-key value set to match.
	///
	/// - Returns: A row with the requested column values for the given primary-key value, or `nil` if no row matches the supplied primary-key value.
	static func query(in database: Ironbird.Database, columns: [IronbirdColumnKeyPath], multicolumnPrimaryKey: [Any]) async throws -> Ironbird.ModelRow<Self>? {
		let decoded = DecodedStructuredQuery(selectColumnSubset: columns, forMulticolumnPrimaryKey: multicolumnPrimaryKey)
		return try await self._cacheableStructuredResult(database: database, decoded: decoded) {
			try await _queryInternal(in: $0, decoded.query, arguments: decoded.arguments).first
		}
	}

	/// Synchronous version of ``query(in:columns:multicolumnPrimaryKey:)`` for use when the database actor is isolated within calls to ``Ironbird/Database/transaction(_:)`` or ``Ironbird/Database/cancellableTransaction(_:)``.
	static func queryIsolated(in database: Ironbird.Database, core: isolated Ironbird.Database.Core, columns: [IronbirdColumnKeyPath], multicolumnPrimaryKey: [Any]) throws -> Ironbird.ModelRow<Self>? {
		let decoded = DecodedStructuredQuery(selectColumnSubset: columns, forMulticolumnPrimaryKey: multicolumnPrimaryKey)
		return try self._cacheableStructuredResultIsolated(database: database, core: core, decoded: decoded) {
			try _queryInternalIsolated(in: $0, core: $1, decoded.query, arguments: decoded.arguments).first
		}
	}

	/// Changes a subset of the table's rows matching the given column values, using column key-paths for this model type.
	/// - Parameters:
	///   - database: The ``Ironbird/Database`` instance to query.
	///   - changes: A dictionary of column key-paths of this IronbirdModel type and corresponding values to set them to, e.g. `[ \.$title : "New title" ]`.
	///   - matching: A filtering expression using column key-paths, e.g. `\.$id == 1`, to be used in the resulting SQL query as a `WHERE` clause. See ``IronbirdModelColumnExpression``.
	///
	///       Use `.all` to delete all rows in the table (executes an SQL `UPDATE` without a `WHERE` clause).
	///
	/// ## Example
	/// ```swift
	/// try await Post.update(
	///     in: db,
	///     set: [ \.$title = "Hi" ]
	///     matching: \.$id < 100 || \.$title == nil
	/// )
	/// // Equivalent to:
	/// // "UPDATE Post SET title = 'Hi' WHERE id < 100 OR title IS NULL"
	/// ```
	///
	/// If matching against specific primary-key values, use ``update(in:set:forPrimaryKeys:)`` instead.
	static func update(in database: Ironbird.Database, set changes: [IronbirdColumnKeyPath: Sendable?], matching: IronbirdModelColumnExpression<Self>) async throws {
		if changes.isEmpty { return }
		try await self.updateIsolated(in: database, core: database.core, set: changes, matching: matching)
	}

	static func update(in database: Ironbird.Database, set changes: [IronbirdColumnKeyPath: IronbirdColumnExpression<Self>], matching: IronbirdModelColumnExpression<Self>) async throws {
		if changes.isEmpty { return }
		try await self.updateIsolated(in: database, core: database.core, set: changes, matching: matching)
	}

	static func updateIsolated(in database: Ironbird.Database, core: isolated Ironbird.Database.Core, set changes: [IronbirdColumnKeyPath: IronbirdColumnExpression<Self>], matching: IronbirdModelColumnExpression<Self>) throws {
		try self.updateIsolated(in: database, core: core, set: changes as [IronbirdColumnKeyPath: Sendable?], matching: matching)
	}

	/// Synchronous version of ``update(in:set:matching:)`` for use when the database actor is isolated within calls to ``Ironbird/Database/transaction(_:)`` or ``Ironbird/Database/cancellableTransaction(_:)``.
	static func updateIsolated(in database: Ironbird.Database, core: isolated Ironbird.Database.Core, set changes: [IronbirdColumnKeyPath: Sendable?], matching: IronbirdModelColumnExpression<Self>) throws {
		if database.options.contains(.readOnly) { fatalError("Cannot update IronbirdModels in a read-only database") }
		if changes.isEmpty { return }
		let table = Self.table
		try table.resolveWithDatabaseIsolated(type: Self.self, database: database, core: core) { try Self.validateSchema(database: $0, core: $1) }
		let decoded = DecodedStructuredQuery(operation: "UPDATE", matching: matching, updating: changes)

		let changeCountBefore = core.changeCount
		database.changeReporter.ignoreWritesToTable(Self.tableName, beginBufferingRowIDs: true)
		defer {
			let changedRowIDs = database.changeReporter.stopIgnoringWrites()
			let changeCount = core.changeCount - changeCountBefore
			var primaryKeys = try? primaryKeysFromRowIDs(in: database, core: core, rowIDs: changedRowIDs)
			if primaryKeys != nil, primaryKeys!.count != changeCount { primaryKeys = nil }

			if changeCount > 0 {
				database.changeReporter.reportChange(tableName: Self.tableName, primaryKeys: primaryKeys, changedColumns: decoded.changedColumns)
			}
		}
		try core.query(decoded.query, arguments: decoded.arguments)
	}

	private static func primaryKeysFromRowIDs(in database: Ironbird.Database, core: isolated Ironbird.Database.Core, rowIDs: Set<Int64>) throws -> [[Ironbird.Value]]? {
		if rowIDs.isEmpty { return [] }
		if rowIDs.count > database.maxQueryVariableCount { return nil }

		let table = Self.table
		let columnList = "`\(table.primaryKeys.map(\.name).joined(separator: "`,`"))`"
		let placeholderStr = Array(repeating: "?", count: rowIDs.count).joined(separator: ",")

		var primaryKeys: [[Ironbird.Value]] = []
		for row in try core.query("SELECT \(columnList) FROM \(table.name) WHERE _rowid_ IN (\(placeholderStr))", arguments: Array(rowIDs)) {
			primaryKeys.append(table.primaryKeys.map { row[$0.name]! })
		}
		return primaryKeys
	}

	/// Changes a subset of the table's rows by primary-key values, using column key-paths for this model type.
	/// - Parameters:
	///   - database: The ``Ironbird/Database`` instance to query.
	///   - changes: A dictionary of column key-paths of this IronbirdModel type and corresponding values to set them to, e.g. `[ \.$title : "New title" ]`.
	///   - forPrimaryKeys: A collection of primary-key values on which to apply the changes if present in the database.
	///
	/// This is preferred over ``update(in:set:matching:)`` when the only matching criteria is primary-key value, since the change reporter can subsequently send the specific primary-key values that have potentially changed.
	///
	/// ## Example
	/// ```swift
	/// try await Post.update(
	///     in: db,
	///     set: [ \.$title = "Hi" ]
	///     forPrimaryKeys: [1, 2, 3]
	/// )
	/// // Equivalent to:
	/// // "UPDATE Post SET title = 'Hi' WHERE (id = 1 OR id = 2 OR id = 3)"
	/// ```
	/// For tables with multi-column primary keys, use ``update(in:set:forMulticolumnPrimaryKeys:)``.
	static func update(in database: Ironbird.Database, set changes: [IronbirdColumnKeyPath: Sendable?], forPrimaryKeys: [Sendable]) async throws {
		if changes.isEmpty { return }
		try await self.updateIsolated(in: database, core: database.core, set: changes, forMulticolumnPrimaryKeys: forPrimaryKeys.map { [$0] })
	}

	static func update(in database: Ironbird.Database, set changes: [IronbirdColumnKeyPath: IronbirdColumnExpression<Self>], forPrimaryKeys: [Sendable]) async throws {
		if changes.isEmpty { return }
		try await self.updateIsolated(in: database, core: database.core, set: changes, forMulticolumnPrimaryKeys: forPrimaryKeys.map { [$0] })
	}

	/// Changes a subset of the table's rows by multi-column primary-key values, using column key-paths for this model type.
	/// - Parameters:
	///   - database: The ``Ironbird/Database`` instance to query.
	///   - changes: A dictionary of column key-paths of this IronbirdModel type and corresponding values to set them to, e.g. `[ \.$title : "New title" ]`.
	///   - forMulticolumnPrimaryKeys: A collection of multicolumn-primary-key value arrays on which to apply the changes if present in the database.
	///
	/// This is preferred over ``update(in:set:matching:)`` when the only matching criteria is primary-key value, since the change reporter can subsequently send the specific primary-key values that have potentially changed.
	///
	/// ## Example
	/// ```swift
	/// // Given a two-column primary-key of (id, title):
	/// try await Post.update(
	///     in: db,
	///     set: [ \.$title = "Hi" ]
	///     forMulticolumnPrimaryKeys: Set([1, "Title1"], [2, "Title 2"])
	/// )
	/// // Equivalent to:
	/// // "UPDATE Post SET title = 'Hi' WHERE (id = 1 AND title = 'Title1') OR (id = 2 AND title = 'Title2')"
	/// ```
	///
	/// For tables with single-column primary keys, ``update(in:set:forPrimaryKeys:)`` may also be used.
	static func update(in database: Ironbird.Database, set changes: [IronbirdColumnKeyPath: Sendable?], forMulticolumnPrimaryKeys: [[Sendable]]) async throws {
		if changes.isEmpty { return }
		try await self.updateIsolated(in: database, core: database.core, set: changes, forMulticolumnPrimaryKeys: forMulticolumnPrimaryKeys)
	}

	static func update(in database: Ironbird.Database, set changes: [IronbirdColumnKeyPath: IronbirdColumnExpression<Self>], forMulticolumnPrimaryKeys: [[Sendable]]) async throws {
		if changes.isEmpty { return }
		try await self.updateIsolated(in: database, core: database.core, set: changes, forMulticolumnPrimaryKeys: forMulticolumnPrimaryKeys)
	}

	/// Synchronous version of ``update(in:set:forPrimaryKeys:)`` for use when the database actor is isolated within calls to ``Ironbird/Database/transaction(_:)`` or ``Ironbird/Database/cancellableTransaction(_:)``.
	static func updateIsolated(in database: Ironbird.Database, core: isolated Ironbird.Database.Core, set changes: [IronbirdColumnKeyPath: Sendable?], forPrimaryKeys: [Sendable]) throws {
		try self.updateIsolated(in: database, core: core, set: changes, forMulticolumnPrimaryKeys: forPrimaryKeys.map { [$0] })
	}

	static func updateIsolated(in database: Ironbird.Database, core: isolated Ironbird.Database.Core, set changes: [IronbirdColumnKeyPath: IronbirdColumnExpression<Self>], forPrimaryKeys: [Sendable]) throws {
		try self.updateIsolated(in: database, core: core, set: changes, forMulticolumnPrimaryKeys: forPrimaryKeys.map { [$0] })
	}

	static func updateIsolated(in database: Ironbird.Database, core: isolated Ironbird.Database.Core, set changes: [IronbirdColumnKeyPath: IronbirdColumnExpression<Self>], forMulticolumnPrimaryKeys primaryKeyValues: [[Sendable]]) throws {
		try self.updateIsolated(in: database, core: core, set: changes as [IronbirdColumnKeyPath: Sendable?], forMulticolumnPrimaryKeys: primaryKeyValues)
	}

	/// Synchronous version of ``update(in:set:forMulticolumnPrimaryKeys:)`` for use when the database actor is isolated within calls to ``Ironbird/Database/transaction(_:)`` or ``Ironbird/Database/cancellableTransaction(_:)``.
	static func updateIsolated(in database: Ironbird.Database, core: isolated Ironbird.Database.Core, set changes: [IronbirdColumnKeyPath: Sendable?], forMulticolumnPrimaryKeys primaryKeyValues: [[Sendable]]) throws {
		if database.options.contains(.readOnly) { fatalError("Cannot update IronbirdModels in a read-only database") }
		if changes.isEmpty { return }
		let primaryKeyValues = Array(primaryKeyValues)
		let table = Self.table
		_ = try table.resolveWithDatabaseIsolated(type: Self.self, database: database, core: core) { try Self.validateSchema(database: $0, core: $1) }

		let decoded = DecodedStructuredQuery(operation: "UPDATE", updating: changes, updateWhereAutoOptimization: false)

		var arguments = decoded.arguments
		var keyClauses: [String] = []
		let keyColumns = table.primaryKeys
		var changedPrimaryKeys: [[Ironbird.Value]] = []
		for primaryKeyValueSet in primaryKeyValues {
			if primaryKeyValueSet.count != keyColumns.count {
				fatalError("\(String(describing: self)): Invalid number of primary-key values: expected \(keyColumns.count), got \(primaryKeyValues.count)")
			}
			let primaryKeyValueSet = primaryKeyValueSet.map { try! Ironbird.Value.fromAny($0) }
			changedPrimaryKeys.append(primaryKeyValueSet)

			var keySetClauses: [String] = []
			for i in 0..<keyColumns.count {
				keySetClauses.append("`\(keyColumns[i].name)` = ?")
				arguments.append(primaryKeyValueSet[i])
			}
			keyClauses.append("(\(keySetClauses.joined(separator: " AND ")))")
		}
		let keyWhere = keyClauses.joined(separator: " OR ")

		let query = "\(decoded.query) WHERE \(keyWhere)"

		let changeCountBefore = core.changeCount
		database.changeReporter.ignoreWritesToTable(Self.tableName)
		defer {
			database.changeReporter.stopIgnoringWrites()
			if core.changeCount != changeCountBefore {
				database.changeReporter.reportChange(tableName: Self.tableName, primaryKeys: changedPrimaryKeys, changedColumns: decoded.changedColumns)
			}
		}
		try core.query(query, arguments: arguments)
	}

	/// Deletes a subset of the table's columns matching the given column values, using column key-paths for this model type.
	/// - Parameters:
	///   - database: The ``Ironbird/Database`` instance to query.
	///   - matching: A filtering expression using column key-paths, e.g. `\.$id == 1`, to be used in the resulting SQL query as a `WHERE` clause. See ``IronbirdModelColumnExpression``.
	///
	///       Use `.all` to delete all rows in the table (executes an SQL `DELETE` without a `WHERE` clause).
	/// - Returns: An array of matching rows, each containing only the columns specified.
	///
	/// ## Example
	/// ```swift
	/// try await Post.delete(in: db, matching: \.$id == 123)
	/// // Equivalent to:
	/// // "DELETE FROM Post WHERE id = 123"
	/// ```
	static func delete(from database: Ironbird.Database, matching: IronbirdModelColumnExpression<Self>) async throws {
		try await self.deleteIsolated(from: database, core: database.core, matching: matching)
	}

	/// Synchronous version of ``delete(from:matching:)`` for use when the database actor is isolated within calls to ``Ironbird/Database/transaction(_:)`` or ``Ironbird/Database/cancellableTransaction(_:)``.
	static func deleteIsolated(from database: Ironbird.Database, core: isolated Ironbird.Database.Core, matching: IronbirdModelColumnExpression<Self>) throws {
		if database.options.contains(.readOnly) { fatalError("Cannot delete IronbirdModels from a read-only database") }
		let table = Self.table
		try table.resolveWithDatabaseIsolated(type: Self.self, database: database, core: core) { try Self.validateSchema(database: $0, core: $1) }

		let decoded = DecodedStructuredQuery(operation: "DELETE FROM", matching: matching)

		var affectedPrimaryKeys: [[Ironbird.Value]]? = nil
		if let whereClause = decoded.whereClause, let whereArguments = decoded.whereArguments {
			let primaryKeyColumnList = "`\(table.primaryKeys.map(\.name).joined(separator: "`,`"))`"
			affectedPrimaryKeys =
				try core.query("SELECT \(primaryKeyColumnList) FROM \(table.name) WHERE \(whereClause)", arguments: whereArguments)
				.map { row in
					table.primaryKeys.map { row[$0.name]! }
				}
		}

		let changeCountBefore = core.changeCount
		database.changeReporter.ignoreWritesToTable(Self.tableName)
		defer {
			database.changeReporter.stopIgnoringWrites()
			let changeCount = core.changeCount - changeCountBefore
			if affectedPrimaryKeys != nil, affectedPrimaryKeys!.count != changeCount { affectedPrimaryKeys = nil }

			if changeCount > 0 {
				database.changeReporter.reportChange(tableName: Self.tableName, primaryKeys: affectedPrimaryKeys, changedColumns: nil)
			}
		}
		try core.query(decoded.query, arguments: decoded.arguments)
	}
}

// MARK: - Where-expression DSL

/*
    This is what enables the "matching:" parameters with structured properties like this:

        Test.read(from: db, matching: \.$id == 123)
        Test.read(from: db, matching: \.$id == 123 && \.$title == "Hi" || \.$id > 2)
        Test.read(from: db, matching: \.$url != nil)

    ...by overriding those operators on IronbirdColumnKeyPaths to return IronbirdModelColumnExpressions.

 */

public func == <T: IronbirdModel>(lhs: T.IronbirdColumnKeyPath, rhs: Sendable?) -> IronbirdModelColumnExpression<T> {
	if let rhs { return .equals(lhs, rhs) } else { return .isNull(lhs) }
}

public func != <T: IronbirdModel>(lhs: T.IronbirdColumnKeyPath, rhs: Sendable?) -> IronbirdModelColumnExpression<T> {
	if let rhs { return .notEquals(lhs, rhs) } else { return .isNotNull(lhs) }
}

public prefix func ! <T: IronbirdModel>(lhs: IronbirdModelColumnExpression<T>) -> IronbirdModelColumnExpression<T> { .not(lhs) }
public func < <T: IronbirdModel>(lhs: T.IronbirdColumnKeyPath, rhs: Sendable) -> IronbirdModelColumnExpression<T> { .lessThan(lhs, rhs) }
public func > <T: IronbirdModel>(lhs: T.IronbirdColumnKeyPath, rhs: Sendable) -> IronbirdModelColumnExpression<T> { .greaterThan(lhs, rhs) }
public func <= <T: IronbirdModel>(lhs: T.IronbirdColumnKeyPath, rhs: Sendable) -> IronbirdModelColumnExpression<T> { .lessThanOrEqual(lhs, rhs) }
public func >= <T: IronbirdModel>(lhs: T.IronbirdColumnKeyPath, rhs: Sendable) -> IronbirdModelColumnExpression<T> { .greaterThanOrEqual(lhs, rhs) }
public func && <T: IronbirdModel>(lhs: IronbirdModelColumnExpression<T>, rhs: IronbirdModelColumnExpression<T>) -> IronbirdModelColumnExpression<T> { .and(lhs, rhs) }
public func || <T: IronbirdModel>(lhs: IronbirdModelColumnExpression<T>, rhs: IronbirdModelColumnExpression<T>) -> IronbirdModelColumnExpression<T> { .or(lhs, rhs) }

/// A filtering expression using column key-paths to be used in SQL queries as `WHERE` clauses.
///
/// Supported operators:
/// - `==`, `!=`, `<`, `>`, `<=`, and `>=`, where the left-hand operand is a column key-path and the right-hand operand is a SQL-compatible value or `nil`.
/// - `||` or `&&` to combine multiple expressions.
///
/// Examples:
/// - `.all`: equivalent to not using a `WHERE` clause
/// - `\.$id == 1`: equivalent to `WHERE id = 1`
/// - `\.$id > 1`: equivalent to `WHERE id > 1`
/// - `\.$id >= 1`: equivalent to `WHERE id >= 1`
/// - `\.$id < 1`: equivalent to `WHERE id < 1`
/// - `\.$id <= 1`: equivalent to `WHERE id <= 1`
/// - `\.$id == nil`: equivalent to `WHERE id IS NULL`
/// - `\.$id != nil`: equivalent to `WHERE id IS NOT NULL`
/// - `\.$id > 0 && \.$title != "a"`: equivalent to `WHERE id > 0 AND title != 'a'`
/// - `\.$id != nil || \.$title == nil`: equivalent to `WHERE id IS NOT NULL OR title IS NULL`
/// - `.literal("id % 3 = ?", 1)`: equivalent to `WHERE id % 3 = 1`
/// - `.valueIn(\.$id, [1, 2, 3])`: equivalent to `WHERE id IN (1,2,3)`
/// - `.like(\.$title, "the%")`: equivalent to `WHERE title LIKE 'the%'`
///
/// Used as a `matching:` expression in ``IronbirdModel`` functions such as:
/// - ``IronbirdModel/query(in:columns:matching:orderBy:limit:)``
/// - ``IronbirdModel/read(from:matching:orderBy:limit:)``
/// - ``IronbirdModel/update(in:set:matching:)``
/// - ``IronbirdModel/delete(from:matching:)``
public struct IronbirdModelColumnExpression<Model: IronbirdModel>: Sendable, IronbirdQueryExpression, CustomDebugStringConvertible {
	/// Use `.all` to operate on all rows in the table without a `WHERE` clause.
	public static var all: Self {
		IronbirdModelColumnExpression<Model>()
	}

	enum BinaryOperator: String {
		case equal = "="
		case notEqual = "!="
		case lessThan = "<"
		case greaterThan = ">"
		case lessThanOrEqual = "<="
		case greaterThanOrEqual = ">="
	}

	enum UnaryOperator: String {
		case isNull = "IS NULL"
		case isNotNull = "IS NOT NULL"
	}

	enum CombiningOperator: String {
		case and = "AND"
		case or = "OR"
	}

	private let expression: IronbirdQueryExpression

	public var debugDescription: String { self.expression.compile(table: Model.table, queryingFullTextIndex: true).whereClause ?? String(describing: self) }

	init(column: Model.IronbirdColumnKeyPath, sqlOperator: UnaryOperator) {
		self.expression = IronbirdColumnUnaryExpression(column: column, sqlOperator: sqlOperator)
	}

	init(column: Model.IronbirdColumnKeyPath, sqlOperator: BinaryOperator, value: Sendable) {
		self.expression = IronbirdColumnBinaryExpression(column: column, sqlOperator: sqlOperator, value: value)
	}

	init(column: Model.IronbirdColumnKeyPath, valueIn values: [Sendable]) {
		self.expression = IronbirdColumnInExpression(column: column, values: values)
	}

	init(column: Model.IronbirdColumnKeyPath, valueLike pattern: String) {
		self.expression = IronbirdColumnLikeExpression(column: column, pattern: pattern)
	}

	init(column: Model.IronbirdColumnKeyPath?, fullTextMatch pattern: String, syntaxMode: IronbirdFullTextQuerySyntaxMode) {
		self.expression = IronbirdColumnFTSMatchExpression(column: column, pattern: pattern, syntaxMode: syntaxMode)
	}

	init(lhs: IronbirdModelColumnExpression<Model>, sqlOperator: CombiningOperator, rhs: IronbirdModelColumnExpression<Model>) {
		self.expression = IronbirdCombiningExpression(lhs: lhs, rhs: rhs, sqlOperator: sqlOperator)
	}

	init(not expression: IronbirdModelColumnExpression<Model>) {
		self.expression = IronbirdColumnNotExpression<Model>(type: Model.self, expression: expression)
	}

	init(expressionLiteral: String, arguments: [Sendable]) {
		self.expression = IronbirdColumnLiteralExpression(literal: expressionLiteral, arguments: arguments)
	}

	init() {
		self.expression = IronbirdColumnNoExpression()
	}

	func compile(table: Ironbird.Table, queryingFullTextIndex: Bool) -> (whereClause: String?, values: [Ironbird.Value]) { self.expression.compile(table: table, queryingFullTextIndex: queryingFullTextIndex) }

	static func isNull<T: IronbirdModel>(_ columnKeyPath: T.IronbirdColumnKeyPath) -> IronbirdModelColumnExpression<T> {
		IronbirdModelColumnExpression<T>(column: columnKeyPath, sqlOperator: .isNull)
	}

	static func isNotNull<T: IronbirdModel>(_ columnKeyPath: T.IronbirdColumnKeyPath) -> IronbirdModelColumnExpression<T> {
		IronbirdModelColumnExpression<T>(column: columnKeyPath, sqlOperator: .isNotNull)
	}

	static func equals<T: IronbirdModel>(_ columnKeyPath: T.IronbirdColumnKeyPath, _ value: Sendable) -> IronbirdModelColumnExpression<T> {
		IronbirdModelColumnExpression<T>(column: columnKeyPath, sqlOperator: .equal, value: value)
	}

	static func notEquals<T: IronbirdModel>(_ columnKeyPath: T.IronbirdColumnKeyPath, _ value: Sendable) -> IronbirdModelColumnExpression<T> {
		IronbirdModelColumnExpression<T>(column: columnKeyPath, sqlOperator: .notEqual, value: value)
	}

	static func lessThan<T: IronbirdModel>(_ columnKeyPath: T.IronbirdColumnKeyPath, _ value: Sendable) -> IronbirdModelColumnExpression<T> {
		IronbirdModelColumnExpression<T>(column: columnKeyPath, sqlOperator: .lessThan, value: value)
	}

	static func greaterThan<T: IronbirdModel>(_ columnKeyPath: T.IronbirdColumnKeyPath, _ value: Sendable) -> IronbirdModelColumnExpression<T> {
		IronbirdModelColumnExpression<T>(column: columnKeyPath, sqlOperator: .greaterThan, value: value)
	}

	static func lessThanOrEqual<T: IronbirdModel>(_ columnKeyPath: T.IronbirdColumnKeyPath, _ value: Sendable) -> IronbirdModelColumnExpression<T> {
		IronbirdModelColumnExpression<T>(column: columnKeyPath, sqlOperator: .lessThanOrEqual, value: value)
	}

	static func greaterThanOrEqual<T: IronbirdModel>(_ columnKeyPath: T.IronbirdColumnKeyPath, _ value: Sendable) -> IronbirdModelColumnExpression<T> {
		IronbirdModelColumnExpression<T>(column: columnKeyPath, sqlOperator: .greaterThanOrEqual, value: value)
	}

	static func and<T: IronbirdModel>(_ lhs: IronbirdModelColumnExpression<T>, _ rhs: IronbirdModelColumnExpression<T>) -> IronbirdModelColumnExpression<T> {
		IronbirdModelColumnExpression<T>(lhs: lhs, sqlOperator: .and, rhs: rhs)
	}

	static func or<T: IronbirdModel>(_ lhs: IronbirdModelColumnExpression<T>, _ rhs: IronbirdModelColumnExpression<T>) -> IronbirdModelColumnExpression<T> {
		IronbirdModelColumnExpression<T>(lhs: lhs, sqlOperator: .or, rhs: rhs)
	}

	static func not<T: IronbirdModel>(_ expression: IronbirdModelColumnExpression<T>) -> IronbirdModelColumnExpression<T> {
		IronbirdModelColumnExpression<T>(not: expression)
	}

	/// Specify an `IN` condition to be used in a `WHERE` clause.
	///
	/// Example: `.valueIn(\.$id, [1, 2, 3])`
	///
	/// This would create the SQL clause: `WHERE id IN (1,2,3)`
	///
	/// **Warning:** Do not use with very large numbers of values. The total number of arguments in a query cannot exceed its database's ``Ironbird/Database/maxQueryVariableCount``.
	public static func valueIn<T: IronbirdModel>(_ column: T.IronbirdColumnKeyPath, _ values: [Sendable]) -> IronbirdModelColumnExpression<T> {
		IronbirdModelColumnExpression<T>(column: column, valueIn: values)
	}

	/// Specify an SQLite `LIKE` expression to be used in a `WHERE` clause.
	/// - Parameters:
	///   - column: The column key-path to match, e.g. `\.$title`.
	///   - pattern: A pattern string to match.
	///
	/// The pattern string may contain:
	/// * A percent symbol (`%`) to match any sequence of zero or more characters
	/// * An underscore (`_`) to match any single character
	///
	/// Example: `.like(\.$title, "the%")`
	///
	/// This would create the SQL clause: `WHERE title LIKE 'the%'`, and any title beginning with "the" would match.
	///
	/// > Note: SQLite's `LIKE` operator is **case-insensitive** for characters in the ASCII range.
	/// >
	/// > See the [SQLite documentation](https://www.sqlite.org/lang_expr.html#the_like_glob_regexp_match_and_extract_operators) for details.
	public static func like<T: IronbirdModel>(_ column: T.IronbirdColumnKeyPath, _ pattern: String) -> IronbirdModelColumnExpression<T> {
		IronbirdModelColumnExpression<T>(column: column, valueLike: pattern)
	}

	/// Perform a text search in the model's full-text index.
	/// - Parameters:
	///   - column: The full-text-indexed column to match against. If `nil` or unspecified, all indexed text columns are searched.
	///   - searchQuery: The text to search for.
	///   - syntaxMode: How and whether the query is escaped or processed.
	///
	/// This operator only works for models declaring ``IronbirdModel/fullTextSearchableColumns`` and when using ``IronbirdModel/fullTextSearch(from:matching:limit:options:)``.
	public static func match<T: IronbirdModel>(column: T.IronbirdColumnKeyPath? = nil, _ searchQuery: String, syntaxMode: IronbirdFullTextQuerySyntaxMode = .escapeQuerySyntax) -> IronbirdModelColumnExpression<T> {
		if let column {
			guard let config = T.fullTextSearchableColumns[column], config.indexed else {
				fatalError("[Ironbird] .match() can only be used on `\(String(describing: T.self)).fullTextSearchableColumns` entries specified as `.text`")
			}
		}

		return IronbirdModelColumnExpression<T>(column: column, fullTextMatch: searchQuery, syntaxMode: syntaxMode)
	}

	/// Specify a literal expression to be used in a `WHERE` clause.
	///
	/// Example: `.literal("id % 5 = ?", 1)`
	public static func literal<T: IronbirdModel>(_ expressionLiteral: String, _ arguments: Sendable...) -> IronbirdModelColumnExpression<T> {
		IronbirdModelColumnExpression<T>(expressionLiteral: expressionLiteral, arguments: arguments)
	}
}

protocol IronbirdQueryExpression: Sendable {
	func compile(table: Ironbird.Table, queryingFullTextIndex: Bool) -> (whereClause: String?, values: [Ironbird.Value])
}

struct IronbirdColumnNoExpression: IronbirdQueryExpression {
	func compile(table: Ironbird.Table, queryingFullTextIndex: Bool) -> (whereClause: String?, values: [Ironbird.Value]) {
		(whereClause: nil, values: [])
	}
}

struct IronbirdColumnBinaryExpression<T: IronbirdModel>: IronbirdQueryExpression {
	let column: T.IronbirdColumnKeyPath
	let sqlOperator: IronbirdModelColumnExpression<T>.BinaryOperator
	let value: Sendable

	func compile(table: Ironbird.Table, queryingFullTextIndex: Bool) -> (whereClause: String?, values: [Ironbird.Value]) {
		let columnName = queryingFullTextIndex ? table.keyPathToFTSColumnName(keyPath: self.column) : table.keyPathToColumnName(keyPath: self.column)
		var whereClause = "`\(columnName)` \(sqlOperator.rawValue) ?"
		let value = try! Ironbird.Value.fromAny(value)
		var values = [value]
		if value == .null {
			if self.sqlOperator == .equal { values = []; whereClause = "`\(table.keyPathToColumnName(keyPath: self.column))` IS NULL" }
			else if self.sqlOperator == .notEqual { values = []; whereClause = "`\(table.keyPathToColumnName(keyPath: self.column))` IS NOT NULL" }
		}
		return (whereClause: whereClause, values: values)
	}
}

struct IronbirdColumnLiteralExpression: IronbirdQueryExpression {
	let literal: String
	let arguments: [Sendable]

	func compile(table: Ironbird.Table, queryingFullTextIndex: Bool) -> (whereClause: String?, values: [Ironbird.Value]) {
		(whereClause: "\(self.literal)", values: self.arguments.map { try! Ironbird.Value.fromAny($0) })
	}
}

struct IronbirdColumnInExpression<T: IronbirdModel>: IronbirdQueryExpression {
	let column: T.IronbirdColumnKeyPath
	let values: [Sendable]

	func compile(table: Ironbird.Table, queryingFullTextIndex: Bool) -> (whereClause: String?, values: [Ironbird.Value]) {
		let columnName = queryingFullTextIndex ? table.keyPathToFTSColumnName(keyPath: self.column) : table.keyPathToColumnName(keyPath: self.column)
		let placeholderStr = Array(repeating: "?", count: values.count).joined(separator: ",")
		return (whereClause: "`\(columnName)` IN (\(placeholderStr))", values: self.values.map { try! Ironbird.Value.fromAny($0) })
	}
}

struct IronbirdColumnLikeExpression<T: IronbirdModel>: IronbirdQueryExpression {
	let column: T.IronbirdColumnKeyPath
	let pattern: String

	func compile(table: Ironbird.Table, queryingFullTextIndex: Bool) -> (whereClause: String?, values: [Ironbird.Value]) {
		let columnName = queryingFullTextIndex ? table.keyPathToFTSColumnName(keyPath: self.column) : table.keyPathToColumnName(keyPath: self.column)
		return (whereClause: "`\(columnName)` LIKE ?", values: [.text(self.pattern)])
	}
}

struct IronbirdColumnUnaryExpression<T: IronbirdModel>: IronbirdQueryExpression {
	let column: T.IronbirdColumnKeyPath
	let sqlOperator: IronbirdModelColumnExpression<T>.UnaryOperator

	func compile(table: Ironbird.Table, queryingFullTextIndex: Bool) -> (whereClause: String?, values: [Ironbird.Value]) {
		let columnName = queryingFullTextIndex ? table.keyPathToFTSColumnName(keyPath: self.column) : table.keyPathToColumnName(keyPath: self.column)
		return (whereClause: "`\(columnName)` \(self.sqlOperator.rawValue)", values: [])
	}
}

struct IronbirdColumnNotExpression<T: IronbirdModel>: IronbirdQueryExpression {
	let type: T.Type
	let expression: IronbirdQueryExpression

	func compile(table: Ironbird.Table, queryingFullTextIndex: Bool) -> (whereClause: String?, values: [Ironbird.Value]) {
		let compiled = self.expression.compile(table: table, queryingFullTextIndex: queryingFullTextIndex)
		if let whereClause = compiled.whereClause {
			return (whereClause: "NOT (\(whereClause))", values: compiled.values)
		} else {
			return (whereClause: "FALSE", values: [])
		}
	}
}

struct IronbirdCombiningExpression<T: IronbirdModel>: IronbirdQueryExpression {
	let lhs: IronbirdQueryExpression
	let rhs: IronbirdQueryExpression
	let sqlOperator: IronbirdModelColumnExpression<T>.CombiningOperator

	func compile(table: Ironbird.Table, queryingFullTextIndex: Bool) -> (whereClause: String?, values: [Ironbird.Value]) {
		let l = self.lhs.compile(table: table, queryingFullTextIndex: queryingFullTextIndex)
		let r = self.rhs.compile(table: table, queryingFullTextIndex: queryingFullTextIndex)

		var combinedValues = l.values
		combinedValues.append(contentsOf: r.values)

		var wheres: [String] = []
		if let whereL = l.whereClause { wheres.append(whereL) }
		if let whereR = r.whereClause { wheres.append(whereR) }
		return (whereClause: "(\(wheres.joined(separator: " \(self.sqlOperator.rawValue) ")))", values: combinedValues)
	}
}

struct IronbirdColumnFTSMatchExpression<T: IronbirdModel>: IronbirdQueryExpression {
	let column: T.IronbirdColumnKeyPath?
	let pattern: String
	let syntaxMode: IronbirdFullTextQuerySyntaxMode

	func compile(table: Ironbird.Table, queryingFullTextIndex: Bool) -> (whereClause: String?, values: [Ironbird.Value]) {
		guard queryingFullTextIndex else { fatalError("[Ironbird] .match() is only available on full-text searches.") }

		let columnOrFTSTableName: String
		if let column { columnOrFTSTableName = table.keyPathToFTSColumnName(keyPath: column) }
		else { columnOrFTSTableName = Ironbird.Table.FullTextIndexSchema.ftsTableName(T.tableName) }

		let escapedQuery = T.fullTextQueryEscape(self.pattern, mode: self.syntaxMode)

		return (whereClause: "`\(columnOrFTSTableName)` MATCH ?", values: [.text(escapedQuery)])
	}
}

// MARK: - Update expressions

public prefix func ! <T: IronbirdModel>(lhs: T.IronbirdColumnKeyPath) -> IronbirdColumnExpression<T> { .not(keyPath: lhs) }
public func * <T: IronbirdModel>(lhs: T.IronbirdColumnKeyPath, rhs: Sendable) -> IronbirdColumnExpression<T> { .multiply(keyPath: lhs, value: rhs) }
public func / <T: IronbirdModel>(lhs: T.IronbirdColumnKeyPath, rhs: Sendable) -> IronbirdColumnExpression<T> { .divide(keyPath: lhs, value: rhs) }
public func + <T: IronbirdModel>(lhs: T.IronbirdColumnKeyPath, rhs: Sendable) -> IronbirdColumnExpression<T> { .add(keyPath: lhs, value: rhs) }
public func - <T: IronbirdModel>(lhs: T.IronbirdColumnKeyPath, rhs: Sendable) -> IronbirdColumnExpression<T> { .subtract(keyPath: lhs, value: rhs) }

public enum IronbirdColumnExpression<T: IronbirdModel>: Sendable, ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByNilLiteral {
	public init(nilLiteral: ()) { self = .value(nil) }
	public init(stringLiteral value: StaticString) { self = .value(value) }
	public init(floatLiteral value: Double) { self = .value(value) }
	public init(integerLiteral value: Int64) { self = .value(value) }
	public init(booleanLiteral value: Bool) { self = .value(value) }

	case value(_ value: Sendable?)
	case not(keyPath: T.IronbirdColumnKeyPath)
	case multiply(keyPath: T.IronbirdColumnKeyPath, value: Sendable)
	case divide(keyPath: T.IronbirdColumnKeyPath, value: Sendable)
	case add(keyPath: T.IronbirdColumnKeyPath, value: Sendable)
	case subtract(keyPath: T.IronbirdColumnKeyPath, value: Sendable)

	var constantValue: Ironbird.Value? {
		switch self {
			case .value(let v): try! Ironbird.Value.fromAny(v)
			default: nil
		}
	}

	func expressionInUpdateQuery(table: Ironbird.Table) -> (queryExpression: String, arguments: [Ironbird.Value]) {
		switch self {
			case .value(let value): ("?", [try! Ironbird.Value.fromAny(value)])
			case .not(let keyPath): ("NOT(`\(table.keyPathToColumnName(keyPath: keyPath))`)", [])
			case .multiply(let keyPath, let value): ("`\(table.keyPathToColumnName(keyPath: keyPath))` * ?", [try! Ironbird.Value.fromAny(value)])
			case .divide(let keyPath, let value): ("`\(table.keyPathToColumnName(keyPath: keyPath))` / ?", [try! Ironbird.Value.fromAny(value)])
			case .add(let keyPath, let value): ("`\(table.keyPathToColumnName(keyPath: keyPath))` + ?", [try! Ironbird.Value.fromAny(value)])
			case .subtract(let keyPath, let value): ("`\(table.keyPathToColumnName(keyPath: keyPath))` - ?", [try! Ironbird.Value.fromAny(value)])
		}
	}
}
