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
import Synchronization

public extension Blackbird {
    /// A change to a table in a Blackbird database, as emitted by a ``ChangeSequence``.
    ///
    /// For `BlackbirdModel` tables, ``BlackbirdModel/changeSequence(in:)`` provides a typed ``ModelChange`` instead.
    struct Change: Sendable {
        internal let table: String
        internal let primaryKeys: PrimaryKeyValues?
        internal let columnNames: Blackbird.ColumnNames?
        
        /// Determine if a specific primary-key value may have changed.
        /// - Parameter key: The single-column primary-key value in question.
        /// - Returns: Whether the row with this primary-key value may have changed. Note that changes may be over-reported.
        ///
        /// For tables with multi-column primary keys, use ``hasMulticolumnPrimaryKeyChanged(_:)``.
        public func hasPrimaryKeyChanged(_ key: Any) -> Bool {
            guard let primaryKeys else { return true }
            return primaryKeys.contains([try! Blackbird.Value.fromAny(key)])
        }
        
        /// Determine if a specific primary-key value may have changed in a table with a multi-column primary key.
        /// - Parameter key: The multi-column primary-key value array in question.
        /// - Returns: Whether the row with these primary-key values may have changed. Note that changes may be over-reported.
        ///
        /// For tables with single-column primary keys, use ``hasPrimaryKeyChanged(_:)``.
        public func hasMulticolumnPrimaryKeyChanged(_ key: [Any]) -> Bool {
            guard let primaryKeys else { return true }
            return primaryKeys.contains(key.map { try! Blackbird.Value.fromAny($0) })
        }
        
        /// Determine if a specific column may have changed.
        /// - Parameter columnName: The column name.
        /// - Returns: Whether this column may have changed in any rows. Note that changes may be over-reported.
        public func hasColumnChanged(_ columnName: String) -> Bool {
            guard let columnNames else { return true }
            return columnNames.contains(columnName)
        }
    }

    /// An `AsyncSequence` that emits when data in a Blackbird table has changed.
    ///
    /// The ``Blackbird/Change`` passed indicates which rows and columns in the table have changed.
    typealias ChangeSequence = AsyncPassthroughSubject<Change>

    /// A change to a table in a Blackbird database, as emitted by a ``ChangeSequence``.
    struct ModelChange<T: BlackbirdModel>: Sendable {
        internal let type: T.Type
        internal let primaryKeys: PrimaryKeyValues?
        internal let columnNames: Blackbird.ColumnNames?

        /// Determine if a specific primary-key value may have changed.
        /// - Parameter key: The single-column primary-key value in question.
        /// - Returns: Whether the row with this primary-key value may have changed. Note that changes may be over-reported.
        ///
        /// For tables with multi-column primary keys, use ``hasMulticolumnPrimaryKeyChanged(_:)``.
        public func hasPrimaryKeyChanged(_ key: Any) -> Bool {
            guard let primaryKeys else { return true }
            return primaryKeys.contains([try! Blackbird.Value.fromAny(key)])
        }
        
        /// Determine if a specific primary-key value may have changed in a table with a multi-column primary key.
        /// - Parameter key: The multi-column primary-key value array in question.
        /// - Returns: Whether the row with these primary-key values may have changed. Note that changes may be over-reported.
        ///
        /// For tables with single-column primary keys, use ``hasPrimaryKeyChanged(_:)``.
        public func hasMulticolumnPrimaryKeyChanged(_ key: [Any]) -> Bool {
            guard let primaryKeys else { return true }
            return primaryKeys.contains(key.map { try! Blackbird.Value.fromAny($0) })
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
        public func hasColumnChanged(_ keyPath: T.BlackbirdColumnKeyPath) -> Bool {
            guard let columnNames else { return true }
            return columnNames.contains(T.table.keyPathToColumnName(keyPath: keyPath))
        }
        
        /// The set of primary-key values that may have changed, or `nil` if any primary key may have changed.
        public var changedPrimaryKeys: PrimaryKeyValues? {
            if let primaryKeys, primaryKeys.count > 0 { return primaryKeys }
            return nil
        }

        internal init(type: T.Type, from change: Change) {
            self.type = type
            self.primaryKeys = change.primaryKeys
            self.columnNames = change.columnNames
        }
    }

    /// An AsyncSequence that emits when data in a BlackbirdModel table has changed.
    ///
    /// The ``Blackbird/ModelChange`` passed indicates which rows and columns in the table have changed.
    typealias ModelChangeSequence<T: BlackbirdModel> = AsyncPassthroughSubject<ModelChange<T>>

    internal static func isRelevantPrimaryKeyChange(watchedPrimaryKeys: Blackbird.PrimaryKeyValues?, changedPrimaryKeys: Blackbird.PrimaryKeyValues?) -> Bool {
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

extension Blackbird.Database {

    /// The ``Blackbird/ChangeSequence`` for the specified table.
    /// - Parameter tableName: The table name.
    /// - Returns: A ``Blackbird/ChangeSequence`` that emits ``Blackbird/Change`` objects for each change in the specified table.
    ///
    /// For `BlackbirdModel` tables, ``BlackbirdModel/changeSequence(in:)`` provides a typed ``Blackbird/ModelChange`` instead.
    ///
    /// > - Changes may be over-reported.
    public func changeSequence(for tableName: String) -> Blackbird.ChangeSequence { changeReporter.changeSequence(for: tableName) }

    internal final class ChangeReporter: Sendable {
        internal struct AccumulatedChanges {
            var primaryKeys: Blackbird.PrimaryKeyValues? = Blackbird.PrimaryKeyValues()
            var columnNames: Blackbird.ColumnNames? = Blackbird.ColumnNames()
            static func entireTableChange(columnsIfKnown: Blackbird.ColumnNames? = nil) -> Self {
                Self(primaryKeys: nil, columnNames: columnsIfKnown)
            }
        }
    
        private struct State {
            var activeTransactions = Set<Int64>()
            var ignoreWritesToTableName: String? = nil
            var bufferRowIDsForIgnoredTable = false
            var bufferedRowIDsForIgnoredTable = Set<Int64>()
            var accumulatedChangesByTable: [String: AccumulatedChanges] = [:]
            var tableChangeSubjects: [String: AsyncPassthroughSubject<Blackbird.Change>] = [:]
        }

        private let state = Mutex(State())
        private let debugPrintEveryReportedChange: Bool
        private let cache: Blackbird.Database.Cache
        private let _numChangesReportedByUpdateHook = Atomic<UInt64>(0)

        internal var numChangesReportedByUpdateHook: UInt64 {
            _numChangesReportedByUpdateHook.load(ordering: .relaxed)
        }

        internal func incrementUpdateHookCount() {
            _numChangesReportedByUpdateHook.wrappingAdd(1, ordering: .relaxed)
        }

        init(options: Options, cache: Blackbird.Database.Cache) {
            debugPrintEveryReportedChange = options.contains(.debugPrintEveryReportedChange)
            self.cache = cache
        }

        internal func changeSequence(for tableName: String) -> Blackbird.ChangeSequence {
            state.withLock { s in
                if let existing = s.tableChangeSubjects[tableName] { return existing }
                let new = AsyncPassthroughSubject<Blackbird.Change>()
                s.tableChangeSubjects[tableName] = new
                return new
            }
        }

        internal func ignoreWritesToTable(_ name: String, beginBufferingRowIDs: Bool = false) {
            state.withLock { s in
                s.ignoreWritesToTableName = name
                s.bufferRowIDsForIgnoredTable = beginBufferingRowIDs
                s.bufferedRowIDsForIgnoredTable.removeAll()
            }
        }

        @discardableResult
        internal func stopIgnoringWrites() -> Set<Int64> {
            state.withLock { s in
                s.ignoreWritesToTableName = nil
                s.bufferRowIDsForIgnoredTable = false
                let rowIDs = s.bufferedRowIDsForIgnoredTable
                s.bufferedRowIDsForIgnoredTable.removeAll()
                return rowIDs
            }
        }

        internal func beginTransaction(_ transactionID: Int64) {
            state.withLock { _ = $0.activeTransactions.insert(transactionID) }
        }

        internal func endTransaction(_ transactionID: Int64) {
            let needsFlush = state.withLock { s in
                _ = s.activeTransactions.remove(transactionID)
                return s.activeTransactions.isEmpty && !s.accumulatedChangesByTable.isEmpty
            }
            if needsFlush { flush() }
        }

        internal func reportEntireDatabaseChange() {
            if debugPrintEveryReportedChange { print("[Blackbird.ChangeReporter] ⚠️ database changed externally, reporting changes to all tables!") }
            cache.invalidate()

            let needsFlush = state.withLock { s in
                for tableName in s.tableChangeSubjects.keys { s.accumulatedChangesByTable[tableName] = AccumulatedChanges.entireTableChange() }
                return s.activeTransactions.isEmpty
            }
            if needsFlush { flush() }
        }

        internal func reportChange(tableName: String, primaryKeys: [[Blackbird.Value]]? = nil, rowID: Int64? = nil, changedColumns: Blackbird.ColumnNames?) {
            let needsFlush = state.withLock { s in
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
                            if primaryKey.count == 1 { cache.invalidate(tableName: tableName, primaryKeyValue: primaryKey.first) }
                            else { cache.invalidate(tableName: tableName) }
                        }
                    } else {
                        s.accumulatedChangesByTable[tableName] = AccumulatedChanges.entireTableChange(columnsIfKnown: changedColumns)
                        cache.invalidate(tableName: tableName)
                    }

                    return s.activeTransactions.isEmpty
                }
            }
            if needsFlush { flush() }
        }

        private func flush() {
            let (subjects, changesByTable) = state.withLock { s in
                let result = (s.tableChangeSubjects, s.accumulatedChangesByTable)
                s.accumulatedChangesByTable.removeAll()
                return result
            }

            for (tableName, accumulatedChanges) in changesByTable {
                if let keys = accumulatedChanges.primaryKeys {
                    if debugPrintEveryReportedChange {
                        print("[Blackbird.ChangeReporter] changed \(tableName) (\(keys.count) keys, fields: \(accumulatedChanges.columnNames?.joined(separator: ",") ?? "(all/unknown)"))")
                    }
                    if let sequence = subjects[tableName] { sequence.send(Blackbird.Change(table: tableName, primaryKeys: keys, columnNames: accumulatedChanges.columnNames)) }
                } else {
                    if debugPrintEveryReportedChange { print("[Blackbird.ChangeReporter] changed \(tableName) (unknown keys, fields: \(accumulatedChanges.columnNames?.joined(separator: ",") ?? "(all/unknown)"))") }
                    if let sequence = subjects[tableName] { sequence.send(Blackbird.Change(table: tableName, primaryKeys: nil, columnNames: accumulatedChanges.columnNames)) }
                }
            }
        }        
    }
}




