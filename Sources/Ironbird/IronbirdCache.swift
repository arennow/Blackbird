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
import Loggable
import Synchronization

public extension Ironbird.Database {
	struct CachePerformanceMetrics: Sendable {
		public let hits: Int
		public let misses: Int
		public let writes: Int
		public let rowInvalidations: Int
		public let queryInvalidations: Int
		public let tableInvalidations: Int
		public let evictions: Int
		public let lowMemoryFlushes: Int
	}

	private static let cacheLogger = Logger.with(subsystem: Ironbird.loggingSubsystem, category: "DatabaseCache")

	func cachePerformanceMetricsByTableName() -> [String: CachePerformanceMetrics] { cache.performanceMetrics() }
	func resetCachePerformanceMetrics(tableName: String) { cache.resetPerformanceMetrics(tableName: tableName) }

	func debugPrintCachePerformanceMetrics() {
		for (tableName, metrics) in cache.performanceMetrics() {
			let totalRequests = metrics.hits + metrics.misses
			let hitPercentStr =
				totalRequests == 0 ? "0%" :
				"\(Int(100.0 * Double(metrics.hits) / Double(totalRequests)))%"

			Self.cacheLogger.debug("\(tableName): \(metrics.hits) hits (\(hitPercentStr)), \(metrics.misses) misses, \(metrics.writes) writes, \(metrics.rowInvalidations) row invalidations, \(metrics.queryInvalidations) query invalidations, \(metrics.tableInvalidations) table invalidations, \(metrics.evictions) evictions, \(metrics.lowMemoryFlushes) low-memory flushes")
		}
	}

	internal final class Cache: Sendable {
		private class CacheEntry<T: Sendable> {
			typealias AccessTime = UInt64
			private let _value: T
			var lastAccessed: AccessTime

			init(_ value: T) {
				self._value = value
				self.lastAccessed = mach_absolute_time()
			}

			public func value() -> T {
				self.lastAccessed = mach_absolute_time()
				return self._value
			}
		}

		enum CachedQueryResult {
			case miss
			case hit(value: Sendable?)
		}

		private let lowMemoryEventSource: DispatchSourceMemoryPressure
		public init() {
			self.lowMemoryEventSource = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])
			self.lowMemoryEventSource.setEventHandler { [weak self] in
				self?.entriesByTableName.withLock { entries in
					//
					// To avoid loading potentially-compressed memory pages and exacerbating memory pressure,
					//  or taking precious time to walk the cache contents with the normal prune() operation,
					//  just dump everything.
					//
					for (_, cache) in entries {
						cache.flushForLowMemory()
					}
				}
			}
			self.lowMemoryEventSource.resume()
		}

		deinit {
			lowMemoryEventSource.cancel()
		}

		private final class TableCache: Sendable {
			private struct State {
				var modelsByPrimaryKey: [Ironbird.Value: CacheEntry<any IronbirdModel>] = [:]
				var cachedQueries: [[Ironbird.Value]: CacheEntry<Sendable>] = [:]
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

			func get(primaryKey: Ironbird.Value) -> (any IronbirdModel)? {
				self.state.withLock { s in
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

			func get(primaryKeys: [Ironbird.Value]) -> (hits: [any IronbirdModel], missedKeys: [Ironbird.Value]) {
				self.state.withLock { s in
					var hitResults: [any IronbirdModel] = []
					var missedKeys: [Ironbird.Value] = []
					for key in primaryKeys {
						if let hit = s.modelsByPrimaryKey[key] { hitResults.append(hit.value()) } else { missedKeys.append(key) }
					}
					s.hits += hitResults.count
					s.misses += missedKeys.count
					return (hits: hitResults, missedKeys: missedKeys)
				}
			}

			func getQuery(cacheKey: [Ironbird.Value]) -> CachedQueryResult {
				self.state.withLock { s in
					if let hit = s.cachedQueries[cacheKey] {
						s.hits += 1
						return .hit(value: hit.value())
					} else {
						s.misses += 1
						return .miss
					}
				}
			}

			func add(primaryKey: Ironbird.Value, instance: any IronbirdModel, pruneToLimit: Int? = nil) {
				self.state.withLock { s in
					s.modelsByPrimaryKey[primaryKey] = CacheEntry(instance)
					s.writes += 1
					if let pruneToLimit { Self.prune(&s, entryLimit: pruneToLimit) }
				}
			}

			func addQuery(cacheKey: [Ironbird.Value], result: Sendable?, pruneToLimit: Int? = nil) {
				self.state.withLock { s in
					s.cachedQueries[cacheKey] = CacheEntry(result)
					s.writes += 1
					if let pruneToLimit { Self.prune(&s, entryLimit: pruneToLimit) }
				}
			}

			func delete(primaryKey: Ironbird.Value) {
				self.state.withLock { s in
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
				for (_, entry) in s.modelsByPrimaryKey {
					accessTimes.append(entry.lastAccessed)
				}
				for (_, entry) in s.cachedQueries {
					accessTimes.append(entry.lastAccessed)
				}
				accessTimes.sort(by: >)

				let evictionCount = accessTimes.count - pruneToEntryLimit
				guard evictionCount > 0 else { return }
				let accessTimeThreshold = accessTimes[pruneToEntryLimit]
				s.modelsByPrimaryKey = s.modelsByPrimaryKey.filter { (_, value) in value.lastAccessed > accessTimeThreshold }
				s.cachedQueries = s.cachedQueries.filter { (_, value) in value.lastAccessed > accessTimeThreshold }
				s.evictions += evictionCount
			}

			func invalidate(primaryKeyValue: Ironbird.Value? = nil) {
				self.state.withLock { s in
					if let primaryKeyValue {
						if s.modelsByPrimaryKey.removeValue(forKey: primaryKeyValue) != nil {
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
				self.state.withLock { s in
					s.modelsByPrimaryKey.removeAll(keepingCapacity: false)
					s.cachedQueries.removeAll(keepingCapacity: false)
					s.lowMemoryFlushes += 1
				}
			}

			func resetPerformanceMetrics() {
				self.state.withLock { s in
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
				self.state.withLock { s in
					CachePerformanceMetrics(hits: s.hits, misses: s.misses, writes: s.writes, rowInvalidations: s.rowInvalidations, queryInvalidations: s.queryInvalidations, tableInvalidations: s.tableInvalidations, evictions: s.evictions, lowMemoryFlushes: s.lowMemoryFlushes)
				}
			}
		}

		private let entriesByTableName = Mutex<[String: TableCache]>([:])

		func invalidate(tableName: String? = nil, primaryKeyValue: Ironbird.Value? = nil) {
			self.entriesByTableName.withLock {
				if let tableName {
					$0[tableName]?.invalidate(primaryKeyValue: primaryKeyValue)
				} else {
					for (_, entry) in $0 {
						entry.invalidate()
					}
				}
			}
		}

		func readModel(tableName: String, primaryKey: Ironbird.Value) -> (any IronbirdModel)? {
			self.entriesByTableName.withLock {
				let tableCache: TableCache
				if let existingCache = $0[tableName] { tableCache = existingCache }
				else {
					tableCache = TableCache()
					$0[tableName] = tableCache
				}

				return tableCache.get(primaryKey: primaryKey)
			}
		}

		func readModels(tableName: String, primaryKeys: [Ironbird.Value]) -> (hits: [any IronbirdModel], missedKeys: [Ironbird.Value]) {
			self.entriesByTableName.withLock {
				let tableCache: TableCache
				if let existingCache = $0[tableName] { tableCache = existingCache }
				else {
					tableCache = TableCache()
					$0[tableName] = tableCache
				}

				return tableCache.get(primaryKeys: primaryKeys)
			}
		}

		func writeModel(tableName: String, primaryKey: Ironbird.Value, instance: any IronbirdModel, entryLimit: Int) {
			self.entriesByTableName.withLock {
				let tableCache: TableCache
				if let existingCache = $0[tableName] { tableCache = existingCache }
				else {
					tableCache = TableCache()
					$0[tableName] = tableCache
				}

				tableCache.add(primaryKey: primaryKey, instance: instance, pruneToLimit: entryLimit)
			}
		}

		func deleteModel(tableName: String, primaryKey: Ironbird.Value) {
			self.entriesByTableName.withLock {
				let tableCache: TableCache
				if let existingCache = $0[tableName] { tableCache = existingCache }
				else {
					tableCache = TableCache()
					$0[tableName] = tableCache
				}

				tableCache.delete(primaryKey: primaryKey)
			}
		}

		func readQueryResult(tableName: String, cacheKey: [Ironbird.Value]) -> CachedQueryResult {
			self.entriesByTableName.withLock {
				let tableCache: TableCache
				if let existingCache = $0[tableName] { tableCache = existingCache }
				else {
					tableCache = TableCache()
					$0[tableName] = tableCache
				}
				return tableCache.getQuery(cacheKey: cacheKey)
			}
		}

		func writeQueryResult(tableName: String, cacheKey: [Ironbird.Value], result: Sendable, entryLimit: Int) {
			self.entriesByTableName.withLock {
				let tableCache: TableCache
				if let existingCache = $0[tableName] { tableCache = existingCache }
				else {
					tableCache = TableCache()
					$0[tableName] = tableCache
				}

				tableCache.addQuery(cacheKey: cacheKey, result: result, pruneToLimit: entryLimit)
			}
		}

		func performanceMetrics() -> [String: CachePerformanceMetrics] {
			self.entriesByTableName.withLock { tableCaches in
				tableCaches.mapValues { $0.getPerformanceMetrics() }
			}
		}

		func resetPerformanceMetrics(tableName: String) {
			self.entriesByTableName.withLock { $0[tableName]?.resetPerformanceMetrics() }
		}
	}
}

extension IronbirdModel {
	func _saveCachedInstance(for database: Ironbird.Database) {
		let cacheLimit = Self.cacheLimit
		if cacheLimit > 0, let pkValues = try? self.primaryKeyValues(), pkValues.count == 1, let pk = try? Ironbird.Value.fromAny(pkValues.first!) {
			database.cache.writeModel(tableName: Self.tableName, primaryKey: pk, instance: self, entryLimit: cacheLimit)
		}
	}

	func _deleteCachedInstance(for database: Ironbird.Database) {
		if Self.cacheLimit > 0, let pkValues = try? self.primaryKeyValues(), pkValues.count == 1, let pk = try? Ironbird.Value.fromAny(pkValues.first!) {
			database.cache.deleteModel(tableName: Self.tableName, primaryKey: pk)
		}
	}

	static func _cachedInstance(for database: Ironbird.Database, primaryKeyValue: Ironbird.Value) -> Self? {
		guard Self.cacheLimit > 0 else { return nil }
		return database.cache.readModel(tableName: Self.tableName, primaryKey: primaryKeyValue) as? Self
	}

	static func _cachedInstances(for database: Ironbird.Database, primaryKeyValues: [Ironbird.Value]) -> (hits: [Self], missedKeys: [Ironbird.Value]) {
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
