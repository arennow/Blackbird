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
//  BlackbirdDatabase.swift
//  Created by Marco Arment on 11/28/22.
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
import Loggable
#if canImport(SQLite3)
	import SQLite3
#elseif canImport(CSQLite3)
	import CSQLite3
#endif
import Synchronization

public extension Ironbird {
	enum TransactionResult<R: Sendable>: Sendable {
		case rolledBack
		case committed(R)
	}
}

protocol IronbirdQueryable {
	/// Executes arbitrary SQL queries without returning a value.
	///
	/// - Parameter query: The SQL string to execute. May contain multiple queries separated by semicolons (`;`).
	///
	/// Queries are passed to SQLite without any additional parameters or automatic replacements.
	///
	/// Any type of query valid in SQLite may be used here.
	///
	/// ## Example
	/// ```swift
	/// try await db.execute("PRAGMA user_version = 1; UPDATE posts SET deleted = 0")
	/// ```
	func execute(_ query: String) async throws

	/// Performs an atomic, cancellable transaction with synchronous database access and batched change notifications.
	/// - Parameters:
	///     - action: The actions to perform in the transaction. If an error is thrown, the transaction is rolled back and the error is rethrown to the caller.
	///
	///         Use ``Ironbird/Database/cancellableTransaction(_:)`` to roll back transactions without throwing errors.
	///
	/// While inside the transaction's `action`:
	/// * Queries against the isolated ``Ironbird/Database/Core`` can be executed synchronously (using `try` instead of `try await`).
	/// * Change notifications for this database via ``Ironbird/ChangeSequence`` are queued until the transaction is completed. When delivered, multiple changes for the same table are consolidated into a single notification with every affected primary-key value.
	///
	///     __Note:__ Notifications may be sent for changes occurring during the transaction even if the transaction is rolled back.
	///
	/// ## Example
	/// ```swift
	/// try await db.transaction { core in
	///     try core.query("INSERT INTO posts (id, title) VALUES (?, ?)", 1, "Title 1")
	///     try core.query("INSERT INTO posts (id, title) VALUES (?, ?)", 2, "Title 2")
	///     //...
	///     try core.query("INSERT INTO posts (id, title) VALUES (?, ?)", 999, "Title 999")
	/// }
	/// ```
	///
	/// > Performing large quantities of database writes is typically much faster inside a transaction.
	///
	/// ## See also
	/// ``Ironbird/Database/cancellableTransaction(_:)``
	@discardableResult
	func transaction<R: Sendable>(_ action: (@Sendable (_ core: isolated Ironbird.Database.Core) async throws -> R)) async throws -> R

	/// Equivalent to ``Ironbird/Database/transaction(_:)``, but with the ability to cancel.
	/// - Parameter action: The actions to perform in the transaction. Throw ``Ironbird/Error/cancelTransaction`` within the action to cancel and roll back the transaction. This error will not be rethrown.
	///
	/// If any other error is thrown, the transaction is rolled back and the error is rethrown to the caller.
	///
	/// See ``Ironbird/Database/transaction(_:)`` for details.
	///
	/// ## Example
	/// ```swift
	/// try await db.cancellableTransaction { core in
	///     try core.query("INSERT INTO posts (id, title) VALUES (?, ?)", 1, "Title 1")
	///     try core.query("INSERT INTO posts (id, title) VALUES (?, ?)", 2, "Title 2")
	///     //...
	///     try core.query("INSERT INTO posts (id, title) VALUES (?, ?)", 999, "Title 999")
	///
	///     let areWeReadyForCommitment: Bool = //...
	///     return areWeReadyForCommitment
	/// }
	/// ```
	@discardableResult
	func cancellableTransaction<R: Sendable>(_ action: (@Sendable (_ core: isolated Ironbird.Database.Core) async throws -> R)) async throws -> Ironbird.TransactionResult<R>

	/// Queries the database.
	/// - Parameter query: An SQL query.
	/// - Returns: An array of rows matching the query if applicable, or an empty array otherwise.
	///
	/// ## Example
	/// ```swift
	/// let ids = try await db.query("SELECT id FROM posts WHERE state = 1")
	/// ```
	@discardableResult func query(_ query: String) async throws -> [Ironbird.Row]

	/// Queries the database with an optional list of arguments.
	/// - Parameters:
	///   - query: An SQL query that may contain placeholders specified as a question mark (`?`).
	///   - arguments: Values corresponding to any placeholders in the query.
	/// - Returns: An array of rows matching the query if applicable, or an empty array otherwise.
	///
	/// ## Example
	/// ```swift
	/// let rows = try await db.query(
	///     "SELECT id FROM posts WHERE state = ? OR title = ?",
	///     1,           // value for state
	///     "Test Title" // value for title
	/// )
	/// ```
	@discardableResult func query(_ query: String, _ arguments: Sendable...) async throws -> [Ironbird.Row]

	/// Queries the database with an array of arguments.
	/// - Parameters:
	///   - query: An SQL query that may contain placeholders specified as a question mark (`?`).
	///   - arguments: An array of values corresponding to any placeholders in the query.
	/// - Returns: An array of rows matching the query if applicable, or an empty array otherwise.
	///
	/// ## Example
	/// ```swift
	/// let rows = try await db.query(
	///     "SELECT id FROM posts WHERE state = ? OR title = ?",
	///     arguments: [1 /* value for state */, "Test Title" /* value for title */]
	/// )
	/// ```
	@discardableResult func query(_ query: String, arguments: [Sendable]) async throws -> [Ironbird.Row]

	/// Queries the database using a dictionary of named arguments.
	///
	/// - Parameters:
	///   - query: An SQL query that may contain named placeholders prefixed by a colon (`:`), at-sign (`@`), or dollar sign (`$`) as described in the [SQLite documentation](https://www.sqlite.org/c3ref/bind_blob.html).
	///   - arguments: A dictionary of placeholder names used in the query and their corresponding values. Names must include the prefix character used.
	/// - Returns: An array of rows matching the query if applicable, or an empty array otherwise.
	///
	/// ## Example
	/// ```swift
	/// let rows = try await db.query(
	///     "SELECT id FROM posts WHERE state = :state OR title = :title",
	///     arguments: [":state": 1, ":title": "Test Title"]
	/// )
	/// ```
	@discardableResult func query(_ query: String, arguments: [String: Sendable]) async throws -> [Ironbird.Row]
}

public extension Ironbird {
	/// A managed SQLite database.
	///
	/// A lightweight wrapper around [SQLite](https://www.sqlite.org/).
	///
	/// ### Basic usage
	/// The database is accessed primarily via `async` calls, internally using an `actor` for performance, concurrency, and isolation.
	///
	/// ```swift
	/// let db = try Ironbird.Database(path: "/tmp/test.sqlite")
	///
	/// // SELECT with structured arguments and returned rows
	/// for row in try await db.query("SELECT id FROM posts WHERE state = ?", 1) {
	///     let id = row["id"]
	///     // ...
	/// }
	///
	/// // Run direct queries
	/// try await db.execute("UPDATE posts SET comments = NULL")
	/// ```
	///
	/// ### Synchronous transactions
	/// The isolated actor can also be accessed from ``transaction(_:)`` for synchronous functionality or high-performance batch operations:
	/// ```swift
	/// try await db.transaction { core in
	///     try core.query("INSERT INTO posts VALUES (?, ?)", 16, "Sports!")
	///     try core.query("INSERT INTO posts VALUES (?, ?)", 17, "Dewey Defeats Truman")
	///     //...
	///     try core.query("INSERT INTO posts VALUES (?, ?)", 89, "Florida Man At It Again")
	/// }
	/// ```
	///
	final class Database: Identifiable, Hashable, Equatable, IronbirdQueryable, Sendable {
		/// Process-unique identifiers for Database instances. Used internally.
		public typealias InstanceID = Int64

		/// A process-unique identifier for this instance. Used internally.
		public let id: InstanceID

		public static func == (lhs: Database, rhs: Database) -> Bool { lhs.id == rhs.id }

		public func hash(into hasher: inout Hasher) { hasher.combine(self.id) }

		public enum Error: Swift.Error, Equatable {
			case anotherInstanceExistsWithPath(path: String)
			case cannotOpenDatabaseAtPath(path: String, description: String)
			case unsupportedConfigurationAtPath(path: String)
			case queryError(query: String, description: String)
			case backupError(description: String)
			case queryArgumentNameError(query: String, name: String)
			case queryArgumentValueError(query: String, description: String)
			case queryExecutionError(query: String, description: String)
			case queryResultValueError(query: String, column: String)
			case uniqueConstraintFailed
			case databaseIsClosed
		}

		/// Options for customizing database behavior.
		public struct Options: OptionSet, Sendable {
			public let rawValue: Int
			public init(rawValue: Int) { self.rawValue = rawValue }

			static let inMemoryDatabase = Options(rawValue: 1 << 0)

			/// Sets the database to read-only. Any calls to ``IronbirdModel`` write functions with a read-only database will terminate with a fatal error.
			public static let readOnly = Options(rawValue: 1 << 1)

			/// Monitor for changes to the database file from outside of this connection, such as from a different process or a different SQLite library within the same process.
			///
			/// > Note: This option is only available on Darwin platforms. It has no effect on Linux.
			#if canImport(Darwin)
				public static let monitorForExternalChanges = Options(rawValue: 1 << 2)
			#endif

			/// Logs every query. Useful for debugging.
			public static let debugPrintEveryQuery = Options(rawValue: 1 << 3)

			/// When using ``debugPrintEveryQuery``, parameterized query values will be included in the logged query strings instead of their placeholders. Useful for debugging.
			public static let debugPrintQueryParameterValues = Options(rawValue: 1 << 4)

			/// Logs every change reported by ``Ironbird/ChangeSequence`` instances for this database. Useful for debugging.
			public static let debugPrintEveryReportedChange = Options(rawValue: 1 << 5)

			/// Logs cache hits and misses. Useful for debugging.
			public static let debugPrintCacheActivity = Options(rawValue: 1 << 6)

			/// Require the calling of ``IronbirdModel/resolveSchema(in:)`` before any queries to a `IronbirdModel` type.
			///
			/// Without this option, schema validation and any needed migrations are performed upon the first query to a ``IronbirdModel`` type.
			/// This is convenient, but has downsides:
			///
			/// - Schema migrations occurring at unpredictable times may cause unpredictable performance.
			/// - The callsite for failed validations or schema migrations is unpredictable, making it difficult to build recovery logic.
			/// - If using multiple ``Ironbird/Database`` instances, subtle bugs may be introduced if a ``IronbirdModel`` is inadvertently queried with the wrong database.
			///
			/// With this option set, any ``IronbirdModel`` type must first call ``IronbirdModel/resolveSchema(in:)`` before any queries are performed against it for this database.
			///
			/// If any queries are performed without first having called ``IronbirdModel/resolveSchema(in:)``, a fatal error occurs.
			///
			/// In addition to creating more predictable performance, this is useful to enforce the consolidation of schema validation and migrations to database-opening time so the caller can take appropriate action.
			///
			/// ## Example
			/// ```swift
			/// do {
			///     let db = try Ironbird.Database(path: …, options: [.requireModelSchemaValidationBeforeUse])
			///
			///     for modelType in [
			///         // List all IronbirdModel types to be used with this database:
			///         Author.self,
			///         Post.self,
			///         Genre.self,
			///     ] {
			///         // Validate schema and attempt any needed migrations
			///         try await modelType.resolveSchema(in: db)
			///     }
			/// } catch {
			///     // Perform appropriate recovery actions, such as
			///     //  deleting the database file so it can be recreated:
			///     try? Ironbird.Database.delete(atPath: …)
			/// }
			/// ```
			public static let requireModelSchemaValidationBeforeUse = Options(rawValue: 1 << 7)
		}

		/// Returns all filenames expected to be used by a database if created at the given file path.
		///
		/// SQLite typically uses three files for a database:
		/// - The supplied path
		/// - A second file at the path with `-wal` appended
		/// - A third file at the path with `-shm` appended
		///
		/// This method returns all three expected filenames based on the given path.
		public static func allFilePaths(for path: String) -> [String] {
			// Can't use sqlite3_filename_wal(), etc. because we don't have a DB connection.
			[path, "\(path)-wal", "\(path)-shm"]
		}

		/// Delete the database files, if they exist, at the given path.
		///
		/// > Note: This will delete multiple files. See ``allFilePaths(for:)``.
		public static func delete(atPath path: String) throws {
			for dbFilePath in self.allFilePaths(for: path) {
				if FileManager.default.fileExists(atPath: dbFilePath) {
					try FileManager.default.removeItem(atPath: dbFilePath)
				}
			}
		}

		final class InstancePool: Sendable {
			private static let _nextInstanceID = Atomic<InstanceID>(0)
			private static let pathsOfCurrentInstances = Mutex(Set<String>())

			static func nextInstanceID() -> InstanceID {
				self._nextInstanceID.wrappingAdd(1, ordering: .relaxed).newValue
			}

			static func addInstance(path: String) -> Bool {
				self.pathsOfCurrentInstances.withLock { let (inserted, _) = $0.insert(path); return inserted }
			}

			static func removeInstance(path: String) {
				_ = self.pathsOfCurrentInstances.withLock { $0.remove(path) }
			}
		}

		/// The path to the database file, or `nil` for in-memory databases.
		public let path: String?

		/// The ``Options-swift.struct`` used to create the database.
		public let options: Options

		/// The maximum number of parameters (`?`) supported in database queries. (The value of `SQLITE_LIMIT_VARIABLE_NUMBER` of the backing SQLite instance.)
		public let maxQueryVariableCount: Int

		let core: Core
		let changeReporter: ChangeReporter
		let cache: Cache
		let perfLog: PerformanceLogger
		let fileChangeMonitor: FileChangeMonitor?

		private let _isClosed = Atomic<Bool>(false)

		/// Whether ``close()`` has been called on this database yet. Does **not** indicate whether the close operation has completed.
		///
		/// > Note: Once an instance is closed, it is never reopened.
		public var isClosed: Bool { self._isClosed.load(ordering: .relaxed) }

		/// Instantiates a new SQLite database in memory, without persisting to a file.
		public static func inMemoryDatabase(options: Options = []) -> Database {
			try! Database(path: "", options: options.union([.inMemoryDatabase]))
		}

		/// Instantiates a new SQLite database as a file on disk.
		///
		/// - Parameters:
		///   - path: The path to the database file. If no file exists at `path`, it will be created.
		///   - options: Any custom behavior desired.
		///
		/// At most one instance per database filename may exist at a time.
		///
		/// An error will be thrown if another instance exists with the same filename, the database cannot be created, or the linked version of SQLite lacks the required capabilities.
		public init(path: String, options: Options = []) throws {
			// Use a local because we can't use self until everything has been initalized
			let performanceLog = PerformanceLogger(subsystem: Ironbird.loggingSubsystem, category: "Database")
			let spState = performanceLog.begin(signpost: .openDatabase)
			defer { performanceLog.end(state: spState) }

			var normalizedOptions = options
			if path.isEmpty || path == ":memory:" {
				normalizedOptions.insert(.inMemoryDatabase)
				#if canImport(Darwin)
					normalizedOptions.remove(.monitorForExternalChanges)
				#endif
			}

			let isUniqueInstanceForPath = normalizedOptions.contains(.inMemoryDatabase) || InstancePool.addInstance(path: path)
			if !isUniqueInstanceForPath { throw Error.anotherInstanceExistsWithPath(path: path) }
			self.id = InstancePool.nextInstanceID()

			self.options = normalizedOptions
			self.path = normalizedOptions.contains(.inMemoryDatabase) ? nil : path
			self.cache = Cache()
			self.changeReporter = ChangeReporter(options: options, cache: self.cache)

			var handle: OpaquePointer? = nil
			let flags: Int32 = (options.contains(.readOnly) ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_NOMUTEX
			let result = sqlite3_open_v2(self.path ?? ":memory:", &handle, flags, nil)
			guard let handle else {
				if let path = self.path { InstancePool.removeInstance(path: path) }
				throw Error.cannotOpenDatabaseAtPath(path: path, description: "SQLite cannot allocate memory")
			}
			guard result == SQLITE_OK else {
				let code = sqlite3_errcode(handle)
				let msg = String(cString: sqlite3_errmsg(handle), encoding: .utf8) ?? "(unknown)"
				sqlite3_close(handle)
				if let path = self.path { InstancePool.removeInstance(path: path) }
				throw Error.cannotOpenDatabaseAtPath(path: path, description: "SQLite error code \(code): \(msg)")
			}

			self.maxQueryVariableCount = Int(sqlite3_limit(handle, SQLITE_LIMIT_VARIABLE_NUMBER, -1))

			if !normalizedOptions.contains(.readOnly), SQLITE_OK != sqlite3_exec(handle, "PRAGMA journal_mode = WAL", nil, nil, nil) || SQLITE_OK != sqlite3_exec(handle, "PRAGMA synchronous = NORMAL", nil, nil, nil) {
				sqlite3_close(handle)
				if let path = self.path { InstancePool.removeInstance(path: path) }
				throw Error.unsupportedConfigurationAtPath(path: path)
			}

			#if canImport(Darwin)
				if options.contains(.monitorForExternalChanges), let sqliteFilenameRef = sqlite3_db_filename(handle, nil) {
					self.fileChangeMonitor = FileChangeMonitor()

					if let cStr = sqlite3_filename_database(sqliteFilenameRef), let dbFilename = String(cString: cStr, encoding: .utf8), !dbFilename.isEmpty {
						self.fileChangeMonitor?.addFile(filePath: dbFilename)
					}

					if let cStr = sqlite3_filename_wal(sqliteFilenameRef), let walFilename = String(cString: cStr, encoding: .utf8), !walFilename.isEmpty {
						self.fileChangeMonitor?.addFile(filePath: walFilename)
					}
				} else {
					self.fileChangeMonitor = nil
				}
			#else
				self.fileChangeMonitor = nil
			#endif

			self.core = Core(SQLiteDBHandle(handle), databaseID: self.id, changeReporter: self.changeReporter, cache: self.cache, fileChangeMonitor: self.fileChangeMonitor, options: options)
			self.perfLog = performanceLog

			sqlite3_update_hook(handle, { ctx, _, _, tableName, rowid in
				guard let ctx else { return }
				let changeReporter = Unmanaged<ChangeReporter>.fromOpaque(ctx).takeUnretainedValue()
				changeReporter.incrementUpdateHookCount()
				if let tableName, let tableNameStr = String(cString: tableName, encoding: .utf8) {
					changeReporter.reportChange(tableName: tableNameStr, rowID: rowid, changedColumns: nil)
				}
			}, Unmanaged<ChangeReporter>.passUnretained(self.changeReporter).toOpaque())

			self.fileChangeMonitor?.onChange { [weak self] in
				guard let self else { return }
				Task { await self.core.checkForExternalDatabaseChange() }
			}
		}

		deinit {
			if let path { InstancePool.removeInstance(path: path) }
		}

		/// Close the current database manually.
		///
		/// Optional. If not called, databases automatically close when deallocated.
		///
		/// This is useful if actions must be taken after the database is definitely closed, such as moving it, deleting it, or instantiating another ``Ironbird/Database`` instance for the same file.
		///
		/// Sending any queries to a closed database throws an error.
		public func close() async {
			let spState = self.perfLog.begin(signpost: .closeDatabase)
			defer { perfLog.end(state: spState) }

			self._isClosed.store(true, ordering: .relaxed)
			await self.core.close()

			if let path { InstancePool.removeInstance(path: path) }
		}

		// MARK: - Forwarded Core functions

		public func execute(_ query: String) async throws { try await self.core.execute(query) }

		@discardableResult
		public func transaction<R: Sendable>(_ action: (@Sendable (_ core: isolated Core) async throws -> R)) async throws -> R { try await self.core.transaction(action) }

		@discardableResult
		public func cancellableTransaction<R: Sendable>(_ action: (@Sendable (_ core: isolated Core) async throws -> R)) async throws -> Ironbird.TransactionResult<R> { try await self.core.cancellableTransaction(action) }

		@discardableResult public func query(_ query: String) async throws -> [Ironbird.Row] { try await self.core.query(query, [Sendable]()) }

		@discardableResult public func query(_ query: String, _ arguments: Sendable...) async throws -> [Ironbird.Row] { try await self.core.query(query, arguments) }

		@discardableResult public func query(_ query: String, arguments: [Sendable]) async throws -> [Ironbird.Row] { try await self.core.query(query, arguments) }

		@discardableResult public func query(_ query: String, arguments: [String: Sendable]) async throws -> [Ironbird.Row] { try await self.core.query(query, arguments: arguments) }

		public func setArtificialQueryDelay(_ delay: TimeInterval?) async { await self.core.setArtificialQueryDelay(delay) }

		/// Creates a backup of the whole database.
		///
		/// - Parameters:
		///   - targetPath: The path to the backup file to be created.
		///   - pagesPerStep: The number of [pages](https://www.sqlite.org/fileformat.html#pages) to copy in a single step (optional; defaults to 100).
		///
		/// An error will be thrown if a file already exists at `targetPath`,  the backup database cannot be created or the backup process fails.
		public func backup(to targetPath: String, pagesPerStep: Int32 = 100) async throws { try await self.core.backup(to: targetPath, pagesPerStep: pagesPerStep) }

		// MARK: - Core

		/// An actor for protected concurrent access to a database.
		public actor Core: IronbirdQueryable {
			private struct PreparedStatement {
				let handle: SQLiteStatementHandle
				let isReadOnly: Bool
			}

			private static let queryLogger = Logger.with(subsystem: Ironbird.loggingSubsystem, category: "DatabaseQuery")
			private static let generalLogger = Logger.with(subsystem: Ironbird.loggingSubsystem, category: "DatabaseGeneral")

			private var debugPrintEveryQuery = false
			private var debugPrintQueryParameterValues = false

			var dbHandle: SQLiteDBHandle
			private let databaseID: Database.InstanceID
			private weak var changeReporter: ChangeReporter?
			private weak var fileChangeMonitor: FileChangeMonitor?
			private weak var cache: Cache?
			private var cachedStatements: [String: PreparedStatement] = [:]
			private var isClosed = false
			private var nextTransactionID: Int64 = 0

			private var dataVersionStmt: OpaquePointer?
			private var previousDataVersion: Int64 = 0

			private var perfLog = PerformanceLogger(subsystem: Ironbird.loggingSubsystem, category: "Database.Core")

			init(_ dbHandle: SQLiteDBHandle, databaseID: Database.InstanceID, changeReporter: ChangeReporter?, cache: Cache?, fileChangeMonitor: FileChangeMonitor?, options: Database.Options) {
				self.dbHandle = dbHandle
				self.databaseID = databaseID
				self.changeReporter = changeReporter
				self.fileChangeMonitor = fileChangeMonitor
				self.cache = cache
				self.debugPrintEveryQuery = options.contains(.debugPrintEveryQuery)
				self.debugPrintQueryParameterValues = options.contains(.debugPrintQueryParameterValues)

				#if canImport(Darwin)
					if options.contains(.monitorForExternalChanges), SQLITE_OK == sqlite3_prepare_v3(dbHandle.pointer, "PRAGMA data_version", -1, UInt32(SQLITE_PREPARE_PERSISTENT), &self.dataVersionStmt, nil) {
						if SQLITE_ROW == sqlite3_step(self.dataVersionStmt) { self.previousDataVersion = sqlite3_column_int64(self.dataVersionStmt, 0) }
						sqlite3_reset(self.dataVersionStmt)
					}
				#endif
			}

			deinit {
				if !isClosed {
					for (_, statement) in cachedStatements {
						sqlite3_finalize(statement.handle.pointer)
					}
					sqlite3_close(dbHandle.pointer)
					isClosed = true
				}
			}

			fileprivate func close() {
				if self.isClosed { return }
				let spState = self.perfLog.begin(signpost: .closeDatabase)
				defer { perfLog.end(state: spState) }
				for (_, statement) in self.cachedStatements {
					sqlite3_finalize(statement.handle.pointer)
				}
				sqlite3_close(self.dbHandle.pointer)
				self.isClosed = true
			}

			private var artificialQueryDelay: TimeInterval?
			public func setArtificialQueryDelay(_ delay: TimeInterval?) {
				self.artificialQueryDelay = delay
			}

			var changeCount: Int64 {
				if #available(macOS 12.3, iOS 15.4, tvOS 15.4, watchOS 8.5, *) {
					return Int64(sqlite3_total_changes64(self.dbHandle.pointer))
				} else {
					return Int64(sqlite3_total_changes(self.dbHandle.pointer))
				}
			}

			func checkForExternalDatabaseChange() {
				guard let dataVersionStmt else { return }
				if self.debugPrintEveryQuery { Self.queryLogger.debug("PRAGMA data_version") }

				var newVersion: Int64 = 0
				if SQLITE_ROW == sqlite3_step(dataVersionStmt) { newVersion = sqlite3_column_int64(dataVersionStmt, 0) }
				sqlite3_reset(dataVersionStmt)

				if newVersion != self.previousDataVersion {
					self.previousDataVersion = newVersion
					self.changeReporter?.reportEntireDatabaseChange()
				}
			}

			/// Reset internal notion of what Swift type corresponds to what SQL table
			package func resetResolvedTables() {
				Table.resetResolvedTables(for: self.databaseID)
			}

			// Exactly like the function below, but accepts an async action
			public func transaction<R: Sendable>(_ action: (@Sendable (_ core: isolated Ironbird.Database.Core) async throws -> R)) async throws -> R {
				let result = try await cancellableTransaction { core in
					try await action(core)
				}

				switch result {
					case .committed(let r): return r
					case .rolledBack: fatalError("should never get here")
				}
			}

			// Exactly like the function above, but requires action to be synchronous
			public func transaction<R: Sendable>(_ action: (@Sendable (_ core: isolated Ironbird.Database.Core) throws -> R)) throws -> R {
				let result = try cancellableTransaction { core in
					try action(core)
				}

				switch result {
					case .committed(let r): return r
					case .rolledBack: fatalError("should never get here")
				}
			}

			// These next two properties are only used in the async-taking version of `cancellableTransaction`
			private var isAsyncTransactionInProgress = false
			private var asyncTransactionContinuations = Array<CheckedContinuation<Void, Never>>()

			// Exactly like the function below, but accepts an async action
			public func cancellableTransaction<R: Sendable>(_ action: (@Sendable (_ core: isolated Ironbird.Database.Core) async throws -> R)) async throws -> Ironbird.TransactionResult<R> {
				// This is a little weird. It's basically a semaphore but it doesn't yield
				// (and thus drop isolation) in the uncontended case, which turns out to be
				// really important for the migrate-and-open use case
				if self.isAsyncTransactionInProgress {
					await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
						self.asyncTransactionContinuations.append(continuation)
					}
				} else {
					self.isAsyncTransactionInProgress = true
				}

				defer {
					if let next = self.asyncTransactionContinuations.popLast() {
						next.resume()
					} else {
						self.isAsyncTransactionInProgress = false
					}
				}

				if self.isClosed { throw Error.databaseIsClosed }
				let transactionID = self.nextTransactionID
				self.nextTransactionID += 1
				self.changeReporter?.beginTransaction(transactionID)
				self.fileChangeMonitor?.beginExpectedChange(transactionID)
				defer {
					changeReporter?.endTransaction(transactionID)
					fileChangeMonitor?.endExpectedChange(transactionID)
					checkForExternalDatabaseChange()
				}

				let spState = self.perfLog.begin(signpost: .cancellableTransaction, message: "Transaction ID: \(transactionID)")
				defer { perfLog.end(state: spState) }

				try self.execute("SAVEPOINT \"\(transactionID)\"")
				do {
					let result: R = try await action(self)
					try execute("RELEASE SAVEPOINT \"\(transactionID)\"")
					return .committed(result)
				} catch Ironbird.Error.cancelTransaction {
					try self.execute("ROLLBACK TO SAVEPOINT \"\(transactionID)\"")
					self.cache?.invalidate()
					return .rolledBack
				} catch {
					try self.execute("ROLLBACK TO SAVEPOINT \"\(transactionID)\"")
					self.cache?.invalidate()
					throw error
				}
			}

			// Exactly like the function above, but requires action to be synchronous
			public func cancellableTransaction<R: Sendable>(_ action: (@Sendable (_ core: isolated Ironbird.Database.Core) throws -> R)) throws -> Ironbird.TransactionResult<R> {
				if self.isClosed { throw Error.databaseIsClosed }
				let transactionID = self.nextTransactionID
				self.nextTransactionID += 1
				self.changeReporter?.beginTransaction(transactionID)
				self.fileChangeMonitor?.beginExpectedChange(transactionID)
				defer {
					changeReporter?.endTransaction(transactionID)
					fileChangeMonitor?.endExpectedChange(transactionID)
					checkForExternalDatabaseChange()
				}

				let spState = self.perfLog.begin(signpost: .cancellableTransaction, message: "Transaction ID: \(transactionID)")
				defer { perfLog.end(state: spState) }

				try self.execute("SAVEPOINT \"\(transactionID)\"")
				do {
					let result: R = try action(self)
					try execute("RELEASE SAVEPOINT \"\(transactionID)\"")
					return .committed(result)
				} catch Ironbird.Error.cancelTransaction {
					try self.execute("ROLLBACK TO SAVEPOINT \"\(transactionID)\"")
					self.cache?.invalidate()
					return .rolledBack
				} catch {
					try self.execute("ROLLBACK TO SAVEPOINT \"\(transactionID)\"")
					self.cache?.invalidate()
					throw error
				}
			}

			public func execute(_ query: String) throws {
				if self.debugPrintEveryQuery { Self.queryLogger.debug("\(query)") }
				if self.isClosed { throw Error.databaseIsClosed }

				let spState = self.perfLog.begin(signpost: .execute, message: query)
				defer { perfLog.end(state: spState) }

				if let artificialQueryDelay { Thread.sleep(forTimeInterval: artificialQueryDelay) }

				let transactionID = self.nextTransactionID
				self.nextTransactionID += 1
				self.changeReporter?.beginTransaction(transactionID)
				self.fileChangeMonitor?.beginExpectedChange(transactionID)
				defer {
					changeReporter?.endTransaction(transactionID)
					fileChangeMonitor?.endExpectedChange(transactionID)
					checkForExternalDatabaseChange()
				}

				try self._checkForUpdateHookBypass {
					let result = sqlite3_exec(dbHandle.pointer, query, nil, nil, nil)
					if result != SQLITE_OK { throw Error.queryError(query: query, description: self.errorDesc(self.dbHandle)) }
				}
			}

			nonisolated func errorDesc(_ dbHandle: SQLiteDBHandle?, _ query: String? = nil) -> String {
				guard let dbHandle else { return "No SQLite handle" }
				let code = sqlite3_errcode(dbHandle.pointer)
				let msg = String(cString: sqlite3_errmsg(dbHandle.pointer), encoding: .utf8) ?? "(unknown)"

				if #available(iOS 16, watchOS 9, macOS 13, tvOS 16, *), case let offset = sqlite3_error_offset(dbHandle.pointer), offset >= 0 {
					return "SQLite error code \(code) at index \(offset): \(msg)"
				} else {
					return "SQLite error code \(code): \(msg)"
				}
			}

			// Check for SQLite changes occurring during the given operation that bypass the update_hook, such as
			// the truncate optimization: https://www.sqlite.org/lang_delete.html#the_truncate_optimization
			//
			// Thanks, Gwendal Roué of GRDB: https://hachyderm.io/@groue/110038488774903347
			private func _checkForUpdateHookBypass<T>(statement: PreparedStatement? = nil, _ action: (() throws -> T)) rethrows -> T {
				guard let changeReporter else { return try action() }
				if let statement, statement.isReadOnly { return try action() }

				let changeCountBefore = self.changeCount
				let changesReportedBefore = changeReporter.numChangesReportedByUpdateHook
				let result = try action()

				if self.changeCount != changeCountBefore, changesReportedBefore == changeReporter.numChangesReportedByUpdateHook {
					// Catch the SQLite truncate optimization
					changeReporter.reportEntireDatabaseChange()
				}

				return result
			}

			@discardableResult
			public func query(_ query: String) throws -> [Ironbird.Row] { try self.query(query, [Sendable]()) }

			@discardableResult
			public func query(_ query: String, _ arguments: Sendable...) throws -> [Ironbird.Row] { try self.query(query, arguments: arguments) }

			@discardableResult
			public func query(_ query: String, arguments: [Sendable]) throws -> [Ironbird.Row] {
				if self.isClosed { throw Error.databaseIsClosed }
				let statement = try preparedStatement(query)
				let statementHandle = statement.handle.pointer
				var idx = 1 // SQLite bind-parameter indexes start at 1, not 0!
				for any in arguments {
					let value = try Value.fromAny(any)
					try value.bind(database: self, statement: statementHandle, index: Int32(idx), for: query)
					idx += 1
				}

				return try self._checkForUpdateHookBypass(statement: statement) {
					try self.rowsByExecutingPreparedStatement(statement, from: query)
				}
			}

			@discardableResult
			public func query(_ query: String, arguments: [String: Sendable]) throws -> [Ironbird.Row] {
				if self.isClosed { throw Error.databaseIsClosed }
				let statement = try preparedStatement(query)
				let statementHandle = statement.handle.pointer
				for (name, any) in arguments {
					let value = try Value.fromAny(any)
					try value.bind(database: self, statement: statementHandle, name: name, for: query)
				}

				return try self._checkForUpdateHookBypass(statement: statement) {
					try self.rowsByExecutingPreparedStatement(statement, from: query)
				}
			}

			private func preparedStatement(_ query: String) throws -> PreparedStatement {
				if let cached = cachedStatements[query] { return cached }
				var statementHandle: OpaquePointer? = nil
				let result = sqlite3_prepare_v3(dbHandle.pointer, query, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statementHandle, nil)
				guard result == SQLITE_OK, let statementHandle else { throw Error.queryError(query: query, description: self.errorDesc(self.dbHandle)) }

				let statement = PreparedStatement(handle: SQLiteStatementHandle(statementHandle), isReadOnly: sqlite3_stmt_readonly(statementHandle) > 0)
				self.cachedStatements[query] = statement
				return statement
			}

			private func rowsByExecutingPreparedStatement(_ statement: PreparedStatement, from query: String) throws -> [Ironbird.Row] {
				if self.debugPrintEveryQuery {
					if self.debugPrintQueryParameterValues, let cStr = sqlite3_expanded_sql(statement.handle.pointer), let expandedQuery = String(cString: cStr, encoding: .utf8) {
						Self.queryLogger.debug("\(expandedQuery)")
					} else {
						Self.queryLogger.debug("\(query)")
					}
				}
				let statementHandle = statement.handle.pointer

				let spState = self.perfLog.begin(signpost: .rowsByPreparedFunc, message: query)
				defer { perfLog.end(state: spState) }

				if let artificialQueryDelay { Thread.sleep(forTimeInterval: artificialQueryDelay) }

				let transactionID = self.nextTransactionID
				self.nextTransactionID += 1
				self.changeReporter?.beginTransaction(transactionID)
				if !statement.isReadOnly { self.fileChangeMonitor?.beginExpectedChange(transactionID) }
				defer {
					changeReporter?.endTransaction(transactionID)
					if !statement.isReadOnly {
						fileChangeMonitor?.endExpectedChange(transactionID)
						checkForExternalDatabaseChange()
					}
				}

				var result = sqlite3_step(statementHandle)

				guard result == SQLITE_ROW || result == SQLITE_DONE else {
					sqlite3_reset(statementHandle)
					sqlite3_clear_bindings(statementHandle)
					switch result {
						case SQLITE_CONSTRAINT: throw Error.uniqueConstraintFailed
						default: throw Error.queryExecutionError(query: query, description: self.errorDesc(self.dbHandle))
					}
				}

				let columnCount = sqlite3_column_count(statementHandle)
				if columnCount == 0 {
					guard sqlite3_reset(statementHandle) == SQLITE_OK, sqlite3_clear_bindings(statementHandle) == SQLITE_OK else {
						throw Error.queryExecutionError(query: query, description: self.errorDesc(self.dbHandle))
					}
					return []
				}

				var columnNames: [String] = []
				for i in 0..<columnCount {
					guard let charPtr = sqlite3_column_name(statementHandle, i), case let name = String(cString: charPtr) else {
						throw Error.queryExecutionError(query: query, description: self.errorDesc(self.dbHandle))
					}
					columnNames.append(name)
				}

				var rows: [Ironbird.Row] = []
				while result == SQLITE_ROW {
					var row: Ironbird.Row = [:]
					for i in 0..<Int(columnCount) {
						switch sqlite3_column_type(statementHandle, Int32(i)) {
							case SQLITE_NULL: row[columnNames[i]] = .null

							case SQLITE_INTEGER: row[columnNames[i]] = .integer(sqlite3_column_int64(statementHandle, Int32(i)))

							case SQLITE_FLOAT: row[columnNames[i]] = .double(sqlite3_column_double(statementHandle, Int32(i)))

							case SQLITE_TEXT:
								guard let charPtr = sqlite3_column_text(statementHandle, Int32(i)) else { throw Error.queryResultValueError(query: query, column: columnNames[i]) }
								row[columnNames[i]] = .text(String(cString: charPtr))

							case SQLITE_BLOB:
								let byteLength = sqlite3_column_bytes(statementHandle, Int32(i))
								if byteLength > 0 {
									guard let bytes = sqlite3_column_blob(statementHandle, Int32(i)) else { throw Error.queryResultValueError(query: query, column: columnNames[i]) }
									row[columnNames[i]] = .data(Data(bytes: bytes, count: Int(byteLength)))
								} else {
									row[columnNames[i]] = .data(Data())
								}

							default: throw Error.queryExecutionError(query: query, description: self.errorDesc(self.dbHandle))
						}
					}
					rows.append(row)

					result = sqlite3_step(statementHandle)
				}
				if result != SQLITE_DONE { throw Error.queryExecutionError(query: query, description: self.errorDesc(self.dbHandle)) }

				guard sqlite3_reset(statementHandle) == SQLITE_OK, sqlite3_clear_bindings(statementHandle) == SQLITE_OK else {
					throw Error.queryExecutionError(query: query, description: self.errorDesc(self.dbHandle))
				}
				return rows
			}

			public func backup(to targetPath: String, pagesPerStep: Int32, printProgress: Bool = false) async throws {
				guard !FileManager.default.fileExists(atPath: targetPath) else {
					throw Ironbird.Database.Error.backupError(description: "File already exists at `\(targetPath)`")
				}

				var rawTargetHandle: OpaquePointer? = nil
				let flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
				let openResult = sqlite3_open_v2(targetPath, &rawTargetHandle, flags, nil)

				guard let rawTargetHandle else {
					throw Error.cannotOpenDatabaseAtPath(path: targetPath, description: "SQLite cannot allocate memory")
				}
				let targetDbHandle = SQLiteDBHandle(rawTargetHandle)

				defer { sqlite3_close(targetDbHandle.pointer) }

				guard openResult == SQLITE_OK else {
					let code = sqlite3_errcode(targetDbHandle.pointer)
					let msg = String(cString: sqlite3_errmsg(targetDbHandle.pointer), encoding: .utf8) ?? "(unknown)"
					sqlite3_close(targetDbHandle.pointer)
					throw Error.cannotOpenDatabaseAtPath(path: targetPath, description: "SQLite error code \(code): \(msg)")
				}

				guard let backup = sqlite3_backup_init(targetDbHandle.pointer, "main", dbHandle.pointer, "main") else {
					throw Ironbird.Database.Error.backupError(description: self.errorDesc(targetDbHandle))
				}

				defer { sqlite3_backup_finish(backup) }

				var stepResult = SQLITE_OK
				while stepResult == SQLITE_OK || stepResult == SQLITE_BUSY || stepResult == SQLITE_LOCKED {
					stepResult = sqlite3_backup_step(backup, pagesPerStep)

					if printProgress {
						let remainingPages = sqlite3_backup_remaining(backup)
						let totalPages = sqlite3_backup_pagecount(backup)
						let backedUpPages = totalPages - remainingPages
						Self.generalLogger.debug("Backed up \(backedUpPages) pages of \(totalPages)")
					}

					await Task.yield()
				}

				guard stepResult == SQLITE_DONE else {
					throw Ironbird.Database.Error.backupError(description: self.errorDesc(targetDbHandle))
				}
			}
		}
	}
}
