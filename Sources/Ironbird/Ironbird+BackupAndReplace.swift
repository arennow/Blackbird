//  SPDX-License-Identifier: MIT
//  Copyright 2026 Aaron Rennow
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

#if canImport(SQLite3)
	import SQLite3
#elseif canImport(CSQLite3)
	import CSQLite3
#endif
import Foundation

extension Ironbird.Database {
	/// Replaces the entire contents and structure of this database with the contents of the database at the given file path.
	///
	/// This is intended for restoring from a backup. The source database file is opened read-only and
	/// copied into this database using the SQLite backup API. The operation runs synchronously within
	/// actor isolation and does not yield.
	///
	/// After the restore, all cached state (prepared statements, model caches, resolved table schemas)
	/// is invalidated, and change observers are notified.
	public func replaceDatabase(from sourcePath: String) async throws {
		try await self.core.replaceDatabase(fromPath: sourcePath)
	}

	/// Replaces the entire contents and structure of this database with the contents of another open database.
	///
	/// This is the same operation as ``replaceDatabase(from:)`` but accepts an already-open
	/// ``Database`` instance as the source, which is useful for in-memory databases or testing.
	func replaceDatabase(from sourceDB: Ironbird.Database) async throws {
		let sourceHandle = await sourceDB.core.dbHandle
		try await self.core.replaceDatabase(from: sourceHandle)
	}
}

extension Ironbird.Database.Core {
	func replaceDatabase(from sourceHandle: SQLiteDBHandle) throws {
		if self.isClosed { throw Ironbird.Database.Error.databaseIsClosed }

		guard let backup = sqlite3_backup_init(dbHandle.pointer, "main", sourceHandle.pointer, "main") else {
			throw Ironbird.Database.Error.restoreError(description: self.errorDesc(self.dbHandle))
		}

		let stepResult = sqlite3_backup_step(backup, -1)
		sqlite3_backup_finish(backup)

		guard stepResult == SQLITE_DONE else {
			throw Ironbird.Database.Error.restoreError(description: self.errorDesc(self.dbHandle))
		}

		self.cleanupAfterRestore()

		// Re-apply WAL mode since the restore overwrites the entire database
		sqlite3_exec(self.dbHandle.pointer, "PRAGMA journal_mode = WAL", nil, nil, nil)
		sqlite3_exec(self.dbHandle.pointer, "PRAGMA synchronous = NORMAL", nil, nil, nil)
	}

	func replaceDatabase(fromPath sourcePath: String) throws {
		if self.isClosed { throw Ironbird.Database.Error.databaseIsClosed }

		var rawSourceHandle: OpaquePointer? = nil
		let openResult = sqlite3_open_v2(sourcePath, &rawSourceHandle, SQLITE_OPEN_READONLY, nil)

		guard let rawSourceHandle else {
			throw Ironbird.Database.Error.cannotOpenDatabaseAtPath(path: sourcePath, description: "SQLite cannot allocate memory")
		}

		defer { sqlite3_close(rawSourceHandle) }

		guard openResult == SQLITE_OK else {
			let code = sqlite3_errcode(rawSourceHandle)
			let msg = String(cString: sqlite3_errmsg(rawSourceHandle), encoding: .utf8) ?? "(unknown)"
			throw Ironbird.Database.Error.cannotOpenDatabaseAtPath(path: sourcePath, description: "SQLite error code \(code): \(msg)")
		}

		try self.replaceDatabase(from: SQLiteDBHandle(rawSourceHandle))
	}
}
