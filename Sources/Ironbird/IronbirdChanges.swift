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
//  BlackbirdChanges.swift
//  Created by Marco Arment on 11/17/22.
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

import AsyncExtensions
import Foundation
import Loggable
import Synchronization

public extension Ironbird {
	/// A change to a table in a Ironbird database, as emitted by a ``ChangeSequence``.
	///
	/// For `IronbirdModel` tables, ``IronbirdModel/changeSequence(in:)`` provides a typed ``ModelChange`` instead.
	struct Change: Sendable {
		let table: String
		let primaryKeys: PrimaryKeyValues?
		let columnNames: Ironbird.ColumnNames?

		/// Determine if a specific primary-key value may have changed.
		/// - Parameter key: The single-column primary-key value in question.
		/// - Returns: Whether the row with this primary-key value may have changed. Note that changes may be over-reported.
		///
		/// For tables with multi-column primary keys, use ``hasMulticolumnPrimaryKeyChanged(_:)``.
		public func hasPrimaryKeyChanged(_ key: Any) -> Bool {
			guard let primaryKeys else { return true }
			return primaryKeys.contains([try! Ironbird.Value.fromAny(key)])
		}

		/// Determine if a specific primary-key value may have changed in a table with a multi-column primary key.
		/// - Parameter key: The multi-column primary-key value array in question.
		/// - Returns: Whether the row with these primary-key values may have changed. Note that changes may be over-reported.
		///
		/// For tables with single-column primary keys, use ``hasPrimaryKeyChanged(_:)``.
		public func hasMulticolumnPrimaryKeyChanged(_ key: [Any]) -> Bool {
			guard let primaryKeys else { return true }
			return primaryKeys.contains(key.map { try! Ironbird.Value.fromAny($0) })
		}

		/// Determine if a specific column may have changed.
		/// - Parameter columnName: The column name.
		/// - Returns: Whether this column may have changed in any rows. Note that changes may be over-reported.
		public func hasColumnChanged(_ columnName: String) -> Bool {
			guard let columnNames else { return true }
			return columnNames.contains(columnName)
		}
	}

	/// An `AsyncSequence` that emits when data in a Ironbird table has changed.
	///
	/// The ``Ironbird/Change`` passed indicates which rows and columns in the table have changed.
	typealias ChangeSequence = AsyncPassthroughSubject<Change>

	/// A change to a table in a Ironbird database, as emitted by a ``ChangeSequence``.
	struct ModelChange<T: IronbirdModel>: Sendable {
		let type: T.Type
		let primaryKeys: PrimaryKeyValues?
		let columnNames: Ironbird.ColumnNames?

		/// Determine if a specific primary-key value may have changed.
		/// - Parameter key: The single-column primary-key value in question.
		/// - Returns: Whether the row with this primary-key value may have changed. Note that changes may be over-reported.
		///
		/// For tables with multi-column primary keys, use ``hasMulticolumnPrimaryKeyChanged(_:)``.
		public func hasPrimaryKeyChanged(_ key: Any) -> Bool {
			guard let primaryKeys else { return true }
			return primaryKeys.contains([try! Ironbird.Value.fromAny(key)])
		}

		/// Determine if a specific primary-key value may have changed in a table with a multi-column primary key.
		/// - Parameter key: The multi-column primary-key value array in question.
		/// - Returns: Whether the row with these primary-key values may have changed. Note that changes may be over-reported.
		///
		/// For tables with single-column primary keys, use ``hasPrimaryKeyChanged(_:)``.
		public func hasMulticolumnPrimaryKeyChanged(_ key: [Any]) -> Bool {
			guard let primaryKeys else { return true }
			return primaryKeys.contains(key.map { try! Ironbird.Value.fromAny($0) })
		}

		/// Determine if a specific column name may have changed.
		/// - Parameter columnName: The column name.
		/// - Returns: Whether this column may have changed in any rows. Note that changes may be over-reported.
		public func hasColumnChanged(_ columnName: String) -> Bool {
			guard let columnNames else { return true }
			return columnNames.contains(columnName)
		}

		/// Determine if a specific column key-path may have changed.
		/// - Parameter keyPath: The column key-path using its `$`-prefixed wrapper, e.g. `\.$title`.
		/// - Returns: Whether this column may have changed in any rows. Note that changes may be over-reported.
		public func hasColumnChanged(_ keyPath: T.IronbirdColumnKeyPath) -> Bool {
			guard let columnNames else { return true }
			return columnNames.contains(T.table.keyPathToColumnName(keyPath: keyPath))
		}

		/// The set of primary-key values that may have changed, or `nil` if any primary key may have changed.
		public var changedPrimaryKeys: PrimaryKeyValues? {
			if let primaryKeys, primaryKeys.count > 0 { return primaryKeys }
			return nil
		}

		init(type: T.Type, from change: Change) {
			self.type = type
			self.primaryKeys = change.primaryKeys
			self.columnNames = change.columnNames
		}
	}

	/// An AsyncSequence that emits when data in a IronbirdModel table has changed.
	///
	/// The ``Ironbird/ModelChange`` passed indicates which rows and columns in the table have changed.
	typealias ModelChangeSequence<T: IronbirdModel> = AsyncPassthroughSubject<ModelChange<T>>

	internal static func isRelevantPrimaryKeyChange(watchedPrimaryKeys: Ironbird.PrimaryKeyValues?, changedPrimaryKeys: Ironbird.PrimaryKeyValues?) -> Bool {
		guard let watchedPrimaryKeys else {
			// Not watching any particular keys -- always update for any table change
			return true
		}

		guard let changedPrimaryKeys else {
			// Change sent for unknown/all keys -- always update
			return true
		}

		if !watchedPrimaryKeys.isDisjoint(with: changedPrimaryKeys) {
			// Overlapping keys -- update
			return true
		}

		return false
	}
}

// MARK: - Change sequence

extension Ironbird.Database {
	/// The ``Ironbird/ChangeSequence`` for the specified table.
	/// - Parameter tableName: The table name.
	/// - Returns: A ``Ironbird/ChangeSequence`` that emits ``Ironbird/Change`` objects for each change in the specified table.
	///
	/// For `IronbirdModel` tables, ``IronbirdModel/changeSequence(in:)`` provides a typed ``Ironbird/ModelChange`` instead.
	///
	/// > - Changes may be over-reported.
	public func changeSequence(for tableName: String) -> Ironbird.ChangeSequence { changeReporter.changeSequence(for: tableName) }

	final class ChangeReporter: Sendable, IBLoggable {
		struct AccumulatedChanges {
			var primaryKeys: Ironbird.PrimaryKeyValues? = Ironbird.PrimaryKeyValues()
			var columnNames: Ironbird.ColumnNames? = Ironbird.ColumnNames()
			static func entireTableChange(columnsIfKnown: Ironbird.ColumnNames? = nil) -> Self {
				Self(primaryKeys: nil, columnNames: columnsIfKnown)
			}
		}

		private struct State {
			var activeTransactions = Set<Int64>()
			var ignoreWritesToTableName: String?
			var bufferRowIDsForIgnoredTable = false
			var bufferedRowIDsForIgnoredTable = Set<Int64>()
			var accumulatedChangesByTable: [String: AccumulatedChanges] = [:]
			var tableChangeSubjects: [String: AsyncPassthroughSubject<Ironbird.Change>] = [:]
		}

		private let state = Mutex(State())
		private let debugPrintEveryReportedChange: Bool
		private let cache: Ironbird.Database.Cache
		private let _numChangesReportedByUpdateHook = Atomic<UInt64>(0)

		var numChangesReportedByUpdateHook: UInt64 {
			self._numChangesReportedByUpdateHook.load(ordering: .relaxed)
		}

		func incrementUpdateHookCount() {
			self._numChangesReportedByUpdateHook.wrappingAdd(1, ordering: .relaxed)
		}

		init(options: Options, cache: Ironbird.Database.Cache) {
			self.debugPrintEveryReportedChange = options.contains(.debugPrintEveryReportedChange)
			self.cache = cache
		}

		func changeSequence(for tableName: String) -> Ironbird.ChangeSequence {
			self.state.withLock { s in
				if let existing = s.tableChangeSubjects[tableName] { return existing }
				let new = AsyncPassthroughSubject<Ironbird.Change>()
				s.tableChangeSubjects[tableName] = new
				return new
			}
		}

		func ignoreWritesToTable(_ name: String, beginBufferingRowIDs: Bool = false) {
			self.state.withLock { s in
				s.ignoreWritesToTableName = name
				s.bufferRowIDsForIgnoredTable = beginBufferingRowIDs
				s.bufferedRowIDsForIgnoredTable.removeAll()
			}
		}

		@discardableResult
		func stopIgnoringWrites() -> Set<Int64> {
			self.state.withLock { s in
				s.ignoreWritesToTableName = nil
				s.bufferRowIDsForIgnoredTable = false
				let rowIDs = s.bufferedRowIDsForIgnoredTable
				s.bufferedRowIDsForIgnoredTable.removeAll()
				return rowIDs
			}
		}

		func beginTransaction(_ transactionID: Int64) {
			self.state.withLock { _ = $0.activeTransactions.insert(transactionID) }
		}

		func endTransaction(_ transactionID: Int64) {
			let needsFlush = self.state.withLock { s in
				_ = s.activeTransactions.remove(transactionID)
				return s.activeTransactions.isEmpty && !s.accumulatedChangesByTable.isEmpty
			}
			if needsFlush { self.flush() }
		}

		func reportEntireDatabaseChange() {
			if self.debugPrintEveryReportedChange { Self.logger.debug("Database changed externally, reporting changes to all tables") }
			self.cache.invalidate()

			let needsFlush = self.state.withLock { s in
				for tableName in s.tableChangeSubjects.keys {
					s.accumulatedChangesByTable[tableName] = AccumulatedChanges.entireTableChange()
				}
				return s.activeTransactions.isEmpty
			}
			if needsFlush { self.flush() }
		}

		func reportChange(tableName: String, primaryKeys: [[Ironbird.Value]]? = nil, rowID: Int64? = nil, changedColumns: Ironbird.ColumnNames?) {
			let needsFlush = self.state.withLock { s in
				if tableName == s.ignoreWritesToTableName {
					if let rowID, s.bufferRowIDsForIgnoredTable { _ = s.bufferedRowIDsForIgnoredTable.insert(rowID) }
					return false
				} else {
					if let primaryKeys, !primaryKeys.isEmpty {
						if s.accumulatedChangesByTable[tableName] == nil { s.accumulatedChangesByTable[tableName] = AccumulatedChanges() }
						s.accumulatedChangesByTable[tableName]!.primaryKeys?.formUnion(primaryKeys)

						if let changedColumns {
							s.accumulatedChangesByTable[tableName]!.columnNames?.formUnion(changedColumns)
						} else {
							s.accumulatedChangesByTable[tableName]!.columnNames = nil
						}

						for primaryKey in primaryKeys {
							if primaryKey.count == 1 { self.cache.invalidate(tableName: tableName, primaryKeyValue: primaryKey.first) }
							else { self.cache.invalidate(tableName: tableName) }
						}
					} else {
						s.accumulatedChangesByTable[tableName] = AccumulatedChanges.entireTableChange(columnsIfKnown: changedColumns)
						self.cache.invalidate(tableName: tableName)
					}

					return s.activeTransactions.isEmpty
				}
			}
			if needsFlush { self.flush() }
		}

		private func flush() {
			let (subjects, changesByTable) = self.state.withLock { s in
				let result = (s.tableChangeSubjects, s.accumulatedChangesByTable)
				s.accumulatedChangesByTable.removeAll()
				return result
			}

			for (tableName, accumulatedChanges) in changesByTable {
				if let keys = accumulatedChanges.primaryKeys {
					if self.debugPrintEveryReportedChange {
						Self.logger.debug("Changed \(tableName) (\(keys.count) keys, fields: \(accumulatedChanges.columnNames?.joined(separator: ",") ?? "(all/unknown)"))")
					}
					if let sequence = subjects[tableName] { sequence.send(Ironbird.Change(table: tableName, primaryKeys: keys, columnNames: accumulatedChanges.columnNames)) }
				} else {
					if self.debugPrintEveryReportedChange { Self.logger.debug("Changed \(tableName) (unknown keys, fields: \(accumulatedChanges.columnNames?.joined(separator: ",") ?? "(all/unknown)"))") }
					if let sequence = subjects[tableName] { sequence.send(Ironbird.Change(table: tableName, primaryKeys: nil, columnNames: accumulatedChanges.columnNames)) }
				}
			}
		}
	}
}
