// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

/// Every cache entry is charged its payload, its key and a fixed overhead, so the
/// number of entries is bounded even when payloads are tiny or free.
@Suite
struct CacheEntryChargeTests {
    private let now = Date()
    private let limit = 2048

    private func makeKey(_ name: String) -> DistinctKey {
        DistinctKey([.segment(identifier: name)])
    }

    private func keyByteCount(_ key: DistinctKey) -> Int {
        key.components.reduce(0) { total, component in
            if case let .segment(identifier) = component {
                total + identifier.utf8.count
            } else {
                total
            }
        }
    }

    private func expectedCharge(for key: DistinctKey, payload: Int) -> Int {
        DepotMemoryCache.entryOverheadCost + keyByteCount(key) + payload
    }

    private func lookup<V: Sendable>(
        _ cache: DepotMemoryCache,
        _ key: DistinctKey,
        as _: V.Type = V.self,
    ) -> DepotMemoryCache.CacheLookupResult<V> {
        cache.lookup(valueFor: key, at: now)
    }

    @Test("values and absences are charged their key and a fixed overhead")
    func chargesKeyAndOverhead() {
        let cache = DepotMemoryCache(totalCostLimit: 1_000_000)
        let value = Key.from("users" / "alice") as DistinctKey
        let absent = Key.from("users" / "bob") as DistinctKey

        cache.set(value: 1, for: value, cost: 10)
        #expect(cache.totalCost == expectedCharge(for: value, payload: 10))

        cache.set(value: nil as Int?, for: absent)
        #expect(cache.totalCost == expectedCharge(for: value, payload: 10) + expectedCharge(for: absent, payload: 0))

        cache.set(value: 2, for: value, cost: 0)
        #expect(cache.totalCost == expectedCharge(for: value, payload: 0) + expectedCharge(for: absent, payload: 0))
    }

    @Test("values without payload cost still consume finite accounting")
    func zeroCostValuesAreBounded() {
        let cache = DepotMemoryCache(totalCostLimit: limit)
        for index in 0..<2000 {
            cache.set(value: index, for: makeKey("value-\(index)"), cost: 0)
        }

        #expect(cache.totalCost <= limit)
        #expect(cache.knowledgeEntryCount <= limit / DepotMemoryCache.entryOverheadCost)
        guard case .hit(1999) = lookup(cache, makeKey("value-1999"), as: Int.self) else {
            Issue.record("The newest entry must stay cached")
            return
        }
    }

    @Test("a value larger than the capacity is not cached and does not flush the cache")
    func oversizedValueIsNotCached() {
        let cache = DepotMemoryCache(totalCostLimit: limit)
        let small = makeKey("small")
        let large = makeKey("large")
        cache.set(value: 1, for: small, cost: 16)
        cache.set(value: 2, for: large, cost: 16)
        let costBefore = cache.totalCost

        cache.set(value: 3, for: large, cost: limit)

        guard case .miss = lookup(cache, large, as: Int.self) else {
            Issue.record("An oversized value must be read from storage, not from the cache")
            return
        }
        guard case .hit(1) = lookup(cache, small, as: Int.self) else {
            Issue.record("An oversized value must not evict other entries")
            return
        }
        #expect(cache.totalCost == costBefore - expectedCharge(for: large, payload: 16))
        #expect(cache.totalCost <= limit)
    }

    @Test("a key longer than the capacity is not cached, neither as value nor as absence")
    func oversizedKeyIsNotCached() {
        let cache = DepotMemoryCache(totalCostLimit: limit)
        let small = makeKey("small")
        let long = makeKey(String(repeating: "x", count: limit))
        cache.set(value: 1, for: small, cost: 16)

        cache.set(value: 42, for: long, cost: 0)
        #expect(cache.has(valuesFor: long, at: now) == nil)
        cache.set(value: nil as Int?, for: long)
        #expect(cache.has(valuesFor: long, at: now) == nil)

        guard case .hit(1) = lookup(cache, small, as: Int.self) else {
            Issue.record("An oversized key must not evict other entries")
            return
        }
        #expect(cache.totalCost <= limit)
    }

    @Test("an unlimited cache keeps entries of any size")
    func unlimitedCacheKeepsLargeEntries() {
        let cache = DepotMemoryCache(totalCostLimit: 0)
        let key = makeKey("large")
        cache.set(value: 1, for: key, cost: 1 << 40)
        guard case .hit(1) = lookup(cache, key, as: Int.self) else {
            Issue.record("An unlimited cache must keep every entry")
            return
        }
    }

    @Test("freed LRU slots do not retain keys")
    func freedSlotsReleaseKeys() {
        let cache = DepotMemoryCache(totalCostLimit: limit)
        let key = makeKey("entry")

        cache.set(value: 1, for: key, cost: 16)
        cache.invalidate(modified: Set([key]), removed: Set<DistinctKey>())
        #expect(cache.knowledgeEntryCount == 0)
        #expect(cache.retainedSlotKeyCount == 0)

        for index in 0..<200 {
            cache.set(value: index, for: makeKey("entry-\(index)-" + String(repeating: "k", count: 200)), cost: 16)
        }
        cache.remove(valuesFor: makeKey("entry-199-" + String(repeating: "k", count: 200)))
        cache.invalidate(
            modified: Set([makeKey("entry-198-" + String(repeating: "k", count: 200))]),
            removed: Set<DistinctKey>()
        )
        #expect(cache.retainedSlotKeyCount == cache.knowledgeEntryCount)
        #expect(cache.slotCount > cache.knowledgeEntryCount)

        cache.removeAll()
        #expect(cache.retainedSlotKeyCount == 0)
    }

    @Test("batch writes and removals keep lookup semantics")
    func batchValues() {
        let cache = DepotMemoryCache(totalCostLimit: 4096)
        let first = makeKey("first")
        let second = makeKey("second")
        let removed = makeKey("removed")
        let oversized = makeKey("oversized")
        cache.set(value: 3, for: removed, cost: 4)
        cache.set(value: 4, for: oversized, cost: 4)

        cache.applyBatch(
            writes: [
                .init(key: first, value: 1, cost: 4, expiresAt: nil),
                .init(key: second, value: 2, cost: 4, expiresAt: nil),
                .init(key: oversized, value: 5, cost: 8192, expiresAt: nil),
            ],
            removals: [removed],
        )

        guard case .hit(1) = lookup(cache, first, as: Int.self),
            case .hit(2) = lookup(cache, second, as: Int.self)
        else {
            Issue.record("A batch must publish its fitting writes")
            return
        }
        guard case .miss = lookup(cache, oversized, as: Int.self) else {
            Issue.record("An oversized batch write must neither be cached nor leave the previous value")
            return
        }
        #expect(cache.has(valuesFor: removed, at: now) == false)
    }

    @Test("a file-backed depot reads values larger than its cache from disk")
    func oversizedValuesInDepot() async throws {
        let depot = Depot.temporary(memoryCache: .init(byteCount: 1024))
        defer { try? FileManager.default.removeItem(at: depot.configuration.directoryURL!) }
        depot.register(key: Key.all, coder: .data() as AnyCoder<Data>)
        let small = Key.from("small", as: Data.self)
        let large = Key.from("large", as: Data.self)
        let largeValue = Data(repeating: 7, count: 4096)

        try await depot.set(value: Data([1]), for: small)
        try await depot.set(value: largeValue, for: large)
        #expect(try await depot.get(valueFor: large) == largeValue)

        let cache = try #require(depot.memoryCache)
        #expect(cache.totalCost <= 1024)
        #expect(cache.has(valuesFor: DistinctKey(small), at: Date()) == true)
        #expect(cache.has(valuesFor: DistinctKey(large), at: Date()) == nil)
    }
}
