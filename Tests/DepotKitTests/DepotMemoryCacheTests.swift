// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

@Suite
struct DepotMemoryCacheTests {
    private let now = Date()

    private func makeKey(_ name: String) -> DistinctKey {
        DistinctKey([KeyComponent.segment(identifier: name)])
    }

    private func lookupValue<V: Sendable>(_ cache: DepotMemoryCache, key: DistinctKey, at date: Date) -> V? {
        switch cache.lookup(valueFor: key, at: date) as DepotMemoryCache.CacheLookupResult<V> {
        case let .hit(value): return value
        default: return nil
        }
    }

    // MARK: - lookup returns miss/confirmedAbsent

    @Test("lookup returns miss for key never set")
    func lookupReturnsMissForMissingKey() {
        let cache = DepotMemoryCache(totalCostLimit: 1000)
        let key = makeKey("missing")
        let result: DepotMemoryCache.CacheLookupResult<String> = cache.lookup(valueFor: key, at: now)
        if case .miss = result {
            // pass
        } else {
            Issue.record("Expected miss, got \(result)")
        }
    }

    @Test("lookup returns confirmedAbsent after value is removed")
    func lookupReturnsAbsentAfterRemoval() {
        let cache = DepotMemoryCache(totalCostLimit: 1000)
        let key = makeKey("item")
        cache.set(value: "hello", for: key, cost: 5)
        cache.remove(valuesFor: key)
        let result: DepotMemoryCache.CacheLookupResult<String> = cache.lookup(valueFor: key, at: now)
        if case .confirmedAbsent = result {
            // pass
        } else {
            Issue.record("Expected confirmedAbsent, got \(result)")
        }
    }

    // MARK: - LRU Eviction

    /// The payload cost that makes the cache charge `charge` in total for `key`.
    private func payloadCost(charging charge: Int, for key: DistinctKey) -> Int {
        charge - DepotMemoryCache.cost(of: key, payloadCost: 0)
    }

    @Test("evicts LRU entries when cost limit exceeded")
    func evictsLRUEntries() {
        let cache = DepotMemoryCache(totalCostLimit: 1000)
        let key1 = makeKey("k1")
        let key2 = makeKey("k2")
        let key3 = makeKey("k3")

        cache.set(value: "v1", for: key1, cost: payloadCost(charging: 400, for: key1))
        cache.set(value: "v2", for: key2, cost: payloadCost(charging: 400, for: key2))
        // Total is 800, under limit. Now push over:
        cache.set(value: "v3", for: key3, cost: payloadCost(charging: 400, for: key3))
        // Total would be 1200, exceeds 1000. Evicts to 60%.
        // key1 is LRU tail, key3 is protected (just inserted).

        let v1: String? = lookupValue(cache, key: key1, at: now)
        let v3: String? = lookupValue(cache, key: key3, at: now)
        #expect(v1 == nil, "LRU entry should be evicted")
        #expect(v3 == "v3", "Most recently inserted entry should survive")
    }

    @Test("eviction protects the key that triggered it")
    func evictionProtectsNewKey() {
        let cache = DepotMemoryCache(totalCostLimit: 500)
        let key1 = makeKey("a")
        let key2 = makeKey("b")

        cache.set(value: 1, for: key1, cost: payloadCost(charging: 300, for: key1))
        cache.set(value: 2, for: key2, cost: payloadCost(charging: 300, for: key2))
        // Total 600 > 500, evicts to 300. key1 is LRU, key2 is protected.

        let v1: Int? = lookupValue(cache, key: key1, at: now)
        let v2: Int? = lookupValue(cache, key: key2, at: now)
        #expect(v1 == nil)
        #expect(v2 == 2)
    }

    @Test("accessing a key promotes it in LRU order")
    func accessPromotesInLRU() {
        // Limit 2000, evicts to 1200. Use 4 entries so we can observe which one gets evicted.
        let cache = DepotMemoryCache(totalCostLimit: 2000)
        let key1 = makeKey("first")
        let key2 = makeKey("second")
        let key3 = makeKey("third")
        let key4 = makeKey("fourth")

        // Insert in order: key1 is oldest (LRU tail)
        cache.set(value: "a", for: key1, cost: payloadCost(charging: 500, for: key1))
        cache.set(value: "b", for: key2, cost: payloadCost(charging: 500, for: key2))
        cache.set(value: "c", for: key3, cost: payloadCost(charging: 500, for: key3))
        // Total = 1500, under limit of 2000.

        // Access key1 to promote it to head (MRU). LRU order is now: key2 (tail), key3, key1 (head).
        let _: String? = lookupValue(cache, key: key1, at: now)

        // A total of exactly 2000 would not exceed the limit, so key4 is charged a bit more.
        cache.set(value: "d", for: key4, cost: payloadCost(charging: 600, for: key4))
        // Total = 2100 > 2000. Evicts to 1200. key4 is protected.
        // LRU tail is key2 (500), evict → 1600. Still > 1200.
        // Next LRU is key3 (500), evict → 1100. Now <= 1200, done.

        let v1: String? = lookupValue(cache, key: key1, at: now)
        let v2: String? = lookupValue(cache, key: key2, at: now)
        let v3: String? = lookupValue(cache, key: key3, at: now)
        let v4: String? = lookupValue(cache, key: key4, at: now)
        #expect(v1 == "a", "Promoted key should survive")
        #expect(v2 == nil, "LRU tail should be evicted first")
        #expect(v3 == nil, "Second-oldest should be evicted second")
        #expect(v4 == "d", "Protected key should survive")
    }

    @Test("no eviction when totalCostLimit is 0")
    func noEvictionWithZeroLimit() {
        let cache = DepotMemoryCache(totalCostLimit: 0)
        let key1 = makeKey("x")
        let key2 = makeKey("y")

        cache.set(value: "a", for: key1, cost: 999)
        cache.set(value: "b", for: key2, cost: 999)

        let v1: String? = lookupValue(cache, key: key1, at: now)
        let v2: String? = lookupValue(cache, key: key2, at: now)
        #expect(v1 == "a")
        #expect(v2 == "b")
    }

    // MARK: - invalidate(modified:removed:)

    @Test("invalidate removes cached values for modified keys")
    func invalidateModified() {
        let cache = DepotMemoryCache(totalCostLimit: 1000)
        let key1 = makeKey("mod1")
        let key2 = makeKey("mod2")

        cache.set(value: "old1", for: key1, cost: 10)
        cache.set(value: "old2", for: key2, cost: 10)

        cache.invalidate(modified: Set([key1]), removed: Set<DistinctKey>())

        // Modified key's cached value is gone
        let v1: String? = lookupValue(cache, key: key1, at: now)
        #expect(v1 == nil)

        // Cache can't confirm existence without entry (returns nil = unknown)
        let has = cache.has(valuesFor: key1, at: now)
        #expect(has == nil)

        // Unaffected key remains
        let v2: String? = lookupValue(cache, key: key2, at: now)
        #expect(v2 == "old2")
    }

    @Test("invalidate marks removed keys as absent")
    func invalidateRemoved() {
        let cache = DepotMemoryCache(totalCostLimit: 1000)
        let key1 = makeKey("rm1")
        let key2 = makeKey("rm2")

        cache.set(value: 42, for: key1, cost: 10)
        cache.set(value: 99, for: key2, cost: 10)

        cache.invalidate(modified: Set<DistinctKey>(), removed: Set([key1]))

        // Removed key is gone and marked absent
        let v1: Int? = lookupValue(cache, key: key1, at: now)
        #expect(v1 == nil)
        let has = cache.has(valuesFor: key1, at: now)
        #expect(has == false)

        // Unaffected key remains
        let v2: Int? = lookupValue(cache, key: key2, at: now)
        #expect(v2 == 99)
    }

    @Test("invalidate handles both modified and removed together")
    func invalidateBoth() {
        let cache = DepotMemoryCache(totalCostLimit: 1000)
        let modKey = makeKey("changed")
        let rmKey = makeKey("deleted")
        let safeKey = makeKey("safe")

        cache.set(value: "a", for: modKey, cost: 5)
        cache.set(value: "b", for: rmKey, cost: 5)
        cache.set(value: "c", for: safeKey, cost: 5)

        cache.invalidate(modified: Set([modKey]), removed: Set([rmKey]))

        let vMod: String? = lookupValue(cache, key: modKey, at: now)
        let vRm: String? = lookupValue(cache, key: rmKey, at: now)
        let vSafe: String? = lookupValue(cache, key: safeKey, at: now)

        #expect(vMod == nil)
        #expect(vRm == nil)
        #expect(vSafe == "c")

        #expect(cache.has(valuesFor: modKey, at: now) == nil)
        #expect(cache.has(valuesFor: rmKey, at: now) == false)
    }

    @Test("invalidate on keys not in cache does not crash")
    func invalidateUnknownKeys() {
        let cache = DepotMemoryCache(totalCostLimit: 1000)
        let unknown = makeKey("never-set")

        cache.invalidate(modified: Set([unknown]), removed: Set<DistinctKey>())
        cache.invalidate(modified: Set<DistinctKey>(), removed: Set([unknown]))
        // No crash = pass
    }

    // MARK: - lookup confirmedAbsent

    @Test("lookup returns confirmedAbsent after set nil")
    func lookupConfirmedAbsent() {
        let cache = DepotMemoryCache(totalCostLimit: 1000)
        let key = makeKey("gone")

        cache.set(value: nil as String?, for: key)

        let result: DepotMemoryCache.CacheLookupResult<String> = cache.lookup(valueFor: key, at: now)
        if case .confirmedAbsent = result {
            // pass
        } else {
            Issue.record("Expected confirmedAbsent, got \(result)")
        }
    }

    @Test("lookup returns hit for cached value")
    func lookupHit() {
        let cache = DepotMemoryCache(totalCostLimit: 1000)
        let key = makeKey("present")
        cache.set(value: 42, for: key, cost: 4)

        let result: DepotMemoryCache.CacheLookupResult<Int> = cache.lookup(valueFor: key, at: now)
        if case let .hit(value) = result {
            #expect(value == 42)
        } else {
            Issue.record("Expected hit, got \(result)")
        }
    }

    @Test("lookup returns miss for unknown key")
    func lookupMiss() {
        let cache = DepotMemoryCache(totalCostLimit: 1000)
        let key = makeKey("unknown")

        let result: DepotMemoryCache.CacheLookupResult<Int> = cache.lookup(valueFor: key, at: now)
        if case .miss = result {
            // pass
        } else {
            Issue.record("Expected miss, got \(result)")
        }
    }
}
