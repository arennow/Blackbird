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
//  BlackbirdCache.swift
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

import Foundation
import Synchronization

extension Blackbird.Database {
    public struct CachePerformanceMetrics: Sendable {
        public let hits: Int
        public let misses: Int
        public let writes: Int
        public let rowInvalidations: Int
        public let queryInvalidations: Int
        public let tableInvalidations: Int
        public let evictions: Int
        public let lowMemoryFlushes: Int
    }
    
    public func cachePerformanceMetricsByTableName() -> [String: CachePerformanceMetrics] { cache.performanceMetrics() }
    public func resetCachePerformanceMetrics(tableName: String) { cache.resetPerformanceMetrics(tableName: tableName) }
    
    public func debugPrintCachePerformanceMetrics() {
        print("===== Blackbird.Database cache performance metrics =====")
        for (tableName, metrics) in cache.performanceMetrics() {
            let totalRequests = metrics.hits + metrics.misses
            let hitPercentStr =
                totalRequests == 0 ? "0%" :
                "\(Int(100.0 * Double(metrics.hits) / Double(totalRequests)))%"
                
            print("\(tableName): \(metrics.hits) hits (\(hitPercentStr)), \(metrics.misses) misses, \(metrics.writes) writes, \(metrics.rowInvalidations) row invalidations, \(metrics.queryInvalidations) query invalidations, \(metrics.tableInvalidations) table invalidations, \(metrics.evictions) evictions, \(metrics.lowMemoryFlushes) low-memory flushes")
        }
    }

    internal final class Cache: Sendable {
        private class CacheEntry<T: Sendable> {
            typealias AccessTime = UInt64
            private let _value: T
            var lastAccessed: AccessTime
            
            init(_ value: T) {
                _value = value
                lastAccessed = mach_absolute_time()
            }
            
            public func value() -> T {
                lastAccessed = mach_absolute_time()
                return _value
            }
        }

        internal enum CachedQueryResult: Sendable {
            case miss
            case hit(value: Sendable?)
        }

        private let lowMemoryEventSource: DispatchSourceMemoryPressure
        public init() {
            lowMemoryEventSource = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])
            lowMemoryEventSource.setEventHandler { [weak self] in
                self?.entriesByTableName.withLock { entries in
                    //
                    // To avoid loading potentially-compressed memory pages and exacerbating memory pressure,
                    //  or taking precious time to walk the cache contents with the normal prune() operation,
                    //  just dump everything.
                    //
                    for (_, cache) in entries { cache.flushForLowMemory() }
                }
            }
            lowMemoryEventSource.resume()
        }
        
        deinit {
            lowMemoryEventSource.cancel()
        }
    
        private final class TableCache: Sendable {
            private struct State {
                var modelsByPrimaryKey: [Blackbird.Value: CacheEntry<any BlackbirdModel>] = [:]
                var cachedQueries: [[Blackbird.Value]: CacheEntry<Sendable>] = [:]
                var hits: Int = 0
                var misses: Int = 0
                var writes: Int = 0
                var rowInvalidations: Int = 0
                var queryInvalidations: Int = 0
                var tableInvalidations: Int = 0
                var evictions: Int = 0
                var lowMemoryFlushes: Int = 0
            }

            private let state = Mutex(State())

            func get(primaryKey: Blackbird.Value) -> (any BlackbirdModel)? {
                state.withLock { s in
                    if let hit = s.modelsByPrimaryKey[primaryKey] {
                        hit.lastAccessed = mach_absolute_time()
                        s.hits += 1
                        return hit.value()
                    } else {
                        s.misses += 1
                        return nil
                    }
                }
            }

            func get(primaryKeys: [Blackbird.Value]) -> (hits: [any BlackbirdModel], missedKeys: [Blackbird.Value]) {
                state.withLock { s in
                    var hitResults: [any BlackbirdModel] = []
                    var missedKeys: [Blackbird.Value] = []
                    for key in primaryKeys {
                        if let hit = s.modelsByPrimaryKey[key] { hitResults.append(hit.value()) } else { missedKeys.append(key) }
                    }
                    s.hits += hitResults.count
                    s.misses += missedKeys.count
                    return (hits: hitResults, missedKeys: missedKeys)
                }
            }

            func getQuery(cacheKey: [Blackbird.Value]) -> CachedQueryResult {
                state.withLock { s in
                    if let hit = s.cachedQueries[cacheKey] {
                        s.hits += 1
                        return .hit(value: hit.value())
                    } else {
                        s.misses += 1
                        return .miss
                    }
                }
            }

            func add(primaryKey: Blackbird.Value, instance: any BlackbirdModel, pruneToLimit: Int? = nil) {
                state.withLock { s in
                    s.modelsByPrimaryKey[primaryKey] = CacheEntry(instance)
                    s.writes += 1
                    if let pruneToLimit { Self.prune(&s, entryLimit: pruneToLimit) }
                }
            }

            func addQuery(cacheKey: [Blackbird.Value], result: Sendable?, pruneToLimit: Int? = nil) {
                state.withLock { s in
                    s.cachedQueries[cacheKey] = CacheEntry(result)
                    s.writes += 1
                    if let pruneToLimit { Self.prune(&s, entryLimit: pruneToLimit) }
                }
            }

            func delete(primaryKey: Blackbird.Value) {
                state.withLock { s in
                    _ = s.modelsByPrimaryKey.removeValue(forKey: primaryKey)
                    s.writes += 1
                }
            }

            private static func prune(_ s: inout State, entryLimit: Int) {
                if s.modelsByPrimaryKey.count + s.cachedQueries.count <= entryLimit { return }

                // As a table hits its entry limit, to avoid running the expensive pruning operation after EVERY addition,
                //  we prune the cache to HALF of its size limit to give it some headroom until the next prune is needed.
                let pruneToEntryLimit = entryLimit / 2

                if pruneToEntryLimit < 1 {
                    s.modelsByPrimaryKey.removeAll()
                    s.cachedQueries.removeAll()
                    return
                }

                var accessTimes: [CacheEntry.AccessTime] = []
                for (_, entry) in s.modelsByPrimaryKey { accessTimes.append(entry.lastAccessed) }
                for (_, entry) in s.cachedQueries      { accessTimes.append(entry.lastAccessed) }
                accessTimes.sort(by: >)

                let evictionCount = accessTimes.count - pruneToEntryLimit
                guard evictionCount > 0 else { return }
                let accessTimeThreshold = accessTimes[pruneToEntryLimit]
                s.modelsByPrimaryKey = s.modelsByPrimaryKey.filter { (_, value) in value.lastAccessed > accessTimeThreshold }
                s.cachedQueries      = s.cachedQueries.filter      { (_, value) in value.lastAccessed > accessTimeThreshold }
                s.evictions += evictionCount
            }

            func invalidate(primaryKeyValue: Blackbird.Value? = nil) {
                state.withLock { s in
                    if let primaryKeyValue {
                        if nil != s.modelsByPrimaryKey.removeValue(forKey: primaryKeyValue) {
                            s.rowInvalidations += 1
                        }
                    } else {
                        if !s.modelsByPrimaryKey.isEmpty {
                            s.modelsByPrimaryKey.removeAll()
                            s.tableInvalidations += 1
                        }
                    }

                    if !s.cachedQueries.isEmpty {
                        s.cachedQueries.removeAll()
                        s.queryInvalidations += 1
                    }
                }
            }

            func flushForLowMemory() {
                state.withLock { s in
                    s.modelsByPrimaryKey.removeAll(keepingCapacity: false)
                    s.cachedQueries.removeAll(keepingCapacity: false)
                    s.lowMemoryFlushes += 1
                }
            }

            func resetPerformanceMetrics() {
                state.withLock { s in
                    s.hits = 0
                    s.misses = 0
                    s.writes = 0
                    s.evictions = 0
                    s.rowInvalidations = 0
                    s.queryInvalidations = 0
                    s.tableInvalidations = 0
                    s.lowMemoryFlushes = 0
                }
            }

            func getPerformanceMetrics() -> CachePerformanceMetrics {
                state.withLock { s in
                    CachePerformanceMetrics(hits: s.hits, misses: s.misses, writes: s.writes, rowInvalidations: s.rowInvalidations, queryInvalidations: s.queryInvalidations, tableInvalidations: s.tableInvalidations, evictions: s.evictions, lowMemoryFlushes: s.lowMemoryFlushes)
                }
            }
        }
    
        private let entriesByTableName = Mutex<[String: TableCache]>([:])
    
        internal func invalidate(tableName: String? = nil, primaryKeyValue: Blackbird.Value? = nil) {
            entriesByTableName.withLock {
                if let tableName {
                    $0[tableName]?.invalidate(primaryKeyValue: primaryKeyValue)
                } else {
                    for (_, entry) in $0 { entry.invalidate() }
                }
            }
        }
        
        internal func readModel(tableName: String, primaryKey: Blackbird.Value) -> (any BlackbirdModel)? {
            entriesByTableName.withLock {
                let tableCache: TableCache
                if let existingCache = $0[tableName] { tableCache = existingCache }
                else {
                    tableCache = TableCache()
                    $0[tableName] = tableCache
                }
                
                return tableCache.get(primaryKey: primaryKey)
            }
        }

        internal func readModels(tableName: String, primaryKeys: [Blackbird.Value]) -> (hits: [any BlackbirdModel], missedKeys: [Blackbird.Value]) {
            entriesByTableName.withLock {
                let tableCache: TableCache
                if let existingCache = $0[tableName] { tableCache = existingCache }
                else {
                    tableCache = TableCache()
                    $0[tableName] = tableCache
                }
            
                return tableCache.get(primaryKeys: primaryKeys)
            }
        }

        internal func writeModel(tableName: String, primaryKey: Blackbird.Value, instance: any BlackbirdModel, entryLimit: Int) {
            entriesByTableName.withLock {
                let tableCache: TableCache
                if let existingCache = $0[tableName] { tableCache = existingCache }
                else {
                    tableCache = TableCache()
                    $0[tableName] = tableCache
                }
                
                tableCache.add(primaryKey: primaryKey, instance: instance, pruneToLimit: entryLimit)
            }
        }

        internal func deleteModel(tableName: String, primaryKey: Blackbird.Value) {
            entriesByTableName.withLock {
                let tableCache: TableCache
                if let existingCache = $0[tableName] { tableCache = existingCache }
                else {
                    tableCache = TableCache()
                    $0[tableName] = tableCache
                }
                
                tableCache.delete(primaryKey: primaryKey)
            }
        }

        internal func readQueryResult(tableName: String, cacheKey: [Blackbird.Value]) -> CachedQueryResult {
            entriesByTableName.withLock {
                let tableCache: TableCache
                if let existingCache = $0[tableName] { tableCache = existingCache }
                else {
                    tableCache = TableCache()
                    $0[tableName] = tableCache
                }
                return tableCache.getQuery(cacheKey: cacheKey)
            }
        }

        internal func writeQueryResult(tableName: String, cacheKey: [Blackbird.Value], result: Sendable, entryLimit: Int) {
            entriesByTableName.withLock {
                let tableCache: TableCache
                if let existingCache = $0[tableName] { tableCache = existingCache }
                else {
                    tableCache = TableCache()
                    $0[tableName] = tableCache
                }
                
                tableCache.addQuery(cacheKey: cacheKey, result: result, pruneToLimit: entryLimit)
            }
        }
        
        internal func performanceMetrics() -> [String: CachePerformanceMetrics] {
            entriesByTableName.withLock { tableCaches in
                tableCaches.mapValues { $0.getPerformanceMetrics() }
            }
        }

        internal func resetPerformanceMetrics(tableName: String) {
            entriesByTableName.withLock { $0[tableName]?.resetPerformanceMetrics() }
        }
    }
}


extension BlackbirdModel {
    internal func _saveCachedInstance(for database: Blackbird.Database) {
        let cacheLimit = Self.cacheLimit
        if cacheLimit > 0, let pkValues = try? self.primaryKeyValues(), pkValues.count == 1, let pk = try? Blackbird.Value.fromAny(pkValues.first!) {
            database.cache.writeModel(tableName: Self.tableName, primaryKey: pk, instance: self, entryLimit: cacheLimit)
        }
    }

    internal func _deleteCachedInstance(for database: Blackbird.Database) {
        if Self.cacheLimit > 0, let pkValues = try? self.primaryKeyValues(), pkValues.count == 1, let pk = try? Blackbird.Value.fromAny(pkValues.first!) {
            database.cache.deleteModel(tableName: Self.tableName, primaryKey: pk)
        }
    }

    internal static func _cachedInstance(for database: Blackbird.Database, primaryKeyValue: Blackbird.Value) -> Self? {
        guard Self.cacheLimit > 0 else { return nil }
        return database.cache.readModel(tableName: Self.tableName, primaryKey: primaryKeyValue) as? Self
    }

    internal static func _cachedInstances(for database: Blackbird.Database, primaryKeyValues: [Blackbird.Value]) -> (hits: [Self], missedKeys: [Blackbird.Value]) {
        guard Self.cacheLimit > 0 else { return (hits: [], missedKeys: primaryKeyValues) }
        let results = database.cache.readModels(tableName: Self.tableName, primaryKeys: primaryKeyValues)

        var hits: [Self] = []
        for hit in results.hits {
            guard let hit = hit as? Self else { return (hits: [], missedKeys: primaryKeyValues) }
            hits.append(hit)
        }
        return (hits: hits, missedKeys: results.missedKeys)
    }
}
