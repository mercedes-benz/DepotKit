// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

// MARK: - Unit level

@Suite("Bounded cache presence/absence bookkeeping")
struct CacheBookkeepingBoundsTests {
    private let now = Date()
    private let limit = 4096
    private let uniqueKeyCount = 5_000
    private let valueCost = 32

    /// Every entry is charged against the budget, so their number cannot exceed this.
    private var maximumEntryCount: Int {
        limit / min(valueCost, DepotMemoryCache.entryOverheadCost) + 1
    }

    /// The bound when the cache only remembers absent keys.
    private var maximumAbsenceEntryCount: Int {
        limit / DepotMemoryCache.entryOverheadCost + 1
    }

    private func makeKey(_ name: String) -> DistinctKey {
        DistinctKey([.segment(identifier: name)])
    }

    private func makeKey(_ parent: String, _ name: String) -> DistinctKey {
        DistinctKey([.segment(identifier: parent), .segment(identifier: name)])
    }

    private func expectBounded(
        _ cache: DepotMemoryCache,
        absencesOnly: Bool = false,
        sourceLocation: SourceLocation = #_sourceLocation,
    ) {
        let bound = absencesOnly ? maximumAbsenceEntryCount : maximumEntryCount
        #expect(cache.knowledgeEntryCount <= bound, sourceLocation: sourceLocation)
        #expect(cache.slotCount <= bound, sourceLocation: sourceLocation)
    }

    private func lookup(_ cache: DepotMemoryCache, _ key: DistinctKey) -> DepotMemoryCache.CacheLookupResult<Int> {
        cache.lookup(valueFor: key, at: now)
    }

    @Test("misses for unique keys keep bookkeeping bounded")
    func uniqueMissesAreBounded() {
        let cache = DepotMemoryCache(totalCostLimit: limit)
        for index in 0..<uniqueKeyCount {
            cache.set(value: nil as Int?, for: makeKey("miss-\(index)"))
        }
        expectBounded(cache, absencesOnly: true)
    }

    @Test("removals of unique keys keep bookkeeping bounded")
    func uniqueRemovalsAreBounded() {
        let cache = DepotMemoryCache(totalCostLimit: limit)
        for index in 0..<uniqueKeyCount {
            let key = makeKey("removed-\(index)")
            cache.set(value: index, for: key, cost: valueCost)
            cache.remove(valuesFor: key)
        }
        expectBounded(cache)
    }

    @Test("pattern removals keep bookkeeping bounded")
    func patternRemovalsAreBounded() {
        let cache = DepotMemoryCache(totalCostLimit: limit)
        let pattern = Key([.segment(identifier: "items"), .wildcard])
        for round in 0..<(uniqueKeyCount / 10) {
            for index in 0..<10 {
                cache.set(value: index, for: makeKey("items", "\(round)-\(index)"), cost: valueCost)
            }
            cache.remove(valuesFor: pattern)
        }
        expectBounded(cache)
        #expect(cache.has(valuesFor: pattern, at: now) == nil)
    }

    @Test("TTL expiry of unique keys keeps bookkeeping bounded")
    func uniqueExpirationsAreBounded() {
        let cache = DepotMemoryCache(totalCostLimit: limit)
        for index in 0..<uniqueKeyCount {
            let key = makeKey("expired-\(index)")
            cache.set(value: index, for: key, cost: valueCost, expiresAt: now)
            if case .expired = lookup(cache, key) {
                cache.markExpired(for: key)
            } else {
                Issue.record("expected an expired entry")
            }
        }
        expectBounded(cache)
    }

    @Test("external invalidations of unique keys keep bookkeeping bounded")
    func uniqueExternalInvalidationsAreBounded() {
        let cache = DepotMemoryCache(totalCostLimit: limit)
        let modified = Set((0..<uniqueKeyCount).map { makeKey("modified-\($0)") })
        let removed = Set((0..<uniqueKeyCount).map { makeKey("removed-\($0)") })

        cache.invalidate(modified: modified, removed: Set<DistinctKey>())
        // Knowing that an uncached key changed carries no information worth keeping.
        #expect(cache.knowledgeEntryCount == 0)

        cache.invalidate(modified: Set<DistinctKey>(), removed: removed)
        expectBounded(cache, absencesOnly: true)
    }

    @Test("transaction batch removals keep bookkeeping bounded")
    func uniqueBatchRemovalsAreBounded() {
        let cache = DepotMemoryCache(totalCostLimit: limit)
        for batch in 0..<(uniqueKeyCount / 100) {
            let removals = (0..<100).map { makeKey("batch-\(batch)-\($0)") }
            let writes = (0..<10).map {
                DepotMemoryCache.DeferredUpdate(
                    key: makeKey("absent-\(batch)-\($0)"),
                    value: nil,
                    cost: 0,
                    expiresAt: nil
                )
            }
            cache.applyBatch(writes: writes, removals: removals)
        }
        expectBounded(cache, absencesOnly: true)
    }

    @Test("an evicted absence entry becomes unknown, not absent")
    func evictedAbsenceIsUnknown() {
        let cache = DepotMemoryCache(totalCostLimit: limit)
        let target = makeKey("target")
        cache.set(value: nil as Int?, for: target)
        guard case .confirmedAbsent = lookup(cache, target) else {
            Issue.record("expected confirmedAbsent before eviction")
            return
        }

        for index in 0..<uniqueKeyCount {
            cache.set(value: nil as Int?, for: makeKey("miss-\(index)"))
        }

        guard case .miss = lookup(cache, target) else {
            Issue.record("an evicted absence entry must report a miss")
            return
        }
        #expect(cache.has(valuesFor: target, at: now) == nil)
    }

    @Test("absence entries are evicted together with values in LRU order")
    func absenceEntriesShareTheLRU() {
        let cache = DepotMemoryCache(totalCostLimit: limit)
        let value = makeKey("value")
        cache.set(value: 1, for: value, cost: 64)
        for index in 0..<10 {
            cache.set(value: nil as Int?, for: makeKey("miss-\(index)"))
        }
        // Recently used value survives while older absence entries are evicted first.
        for index in 0..<uniqueKeyCount {
            guard case .hit(1) = lookup(cache, value) else {
                Issue.record("recently used value was evicted")
                return
            }
            cache.set(value: nil as Int?, for: makeKey("other-\(index)"))
        }
        expectBounded(cache)
        guard case .miss = lookup(cache, makeKey("miss-0")) else {
            Issue.record("least recently used absence entry should be evicted")
            return
        }
    }
}

// MARK: - File-backed

@Suite("Evicted cache knowledge consults the disk", .offCooperativePool)
struct CacheBookkeepingFileBackedTests {
    private static let cacheLimit = 4096

    private static func makeURL() -> URL {
        FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    }

    private static func cachedDepot(
        at url: URL,
        multiProcess: Bool = false,
        clock: any DepotClock = SystemClock(),
    ) -> Depot {
        Depot(
            configuration: .init(
                directoryURL: url,
                enableMultiProcessSupport: multiProcess,
                memoryCache: .init(byteCount: cacheLimit),
            ),
            overrides: .init(clock: clock),
        )
    }

    private static func uncachedDepot(at url: URL, multiProcess: Bool = false) -> Depot {
        Depot(configuration: .init(directoryURL: url, enableMultiProcessSupport: multiProcess, memoryCache: .disabled))
    }

    private static func item(_ name: String) -> TypedDistinctKey<Int> {
        Key.from("items" / name, as: Int.self)
    }

    private static func cache(of depot: Depot) throws -> DepotMemoryCache {
        try #require(depot.memoryCache)
    }

    private static func expectBounded(_ depot: Depot, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let cache = try cache(of: depot)
        // The smallest entry is a value file with a one-byte payload.
        let bound = cacheLimit / min(FileHeader.size + 1, DepotMemoryCache.entryOverheadCost) + 1
        #expect(cache.knowledgeEntryCount <= bound, sourceLocation: sourceLocation)
        #expect(cache.slotCount <= bound, sourceLocation: sourceLocation)
    }

    /// Produces misses for many unique keys so that older cache knowledge gets evicted.
    private static func missUniqueKeys(in depot: Depot, count: Int = 500) throws {
        for index in 0..<count {
            #expect(try depot.get(valueFor: item("missing-\(index)")) == nil)
        }
    }

    @Test("a miss recorded before an out-of-band write is re-read from disk after eviction")
    func evictedMissReadsDisk() throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = Self.cachedDepot(at: url)
        let writer = Self.uncachedDepot(at: url)
        _ = reader.register(key: Key.from("items" / .wildcard), coder: .json() as AnyCoder<Int>)
        _ = writer.register(key: Key.from("items" / .wildcard), coder: .json() as AnyCoder<Int>)
        let target = Self.item("target")

        #expect(try reader.get(valueFor: target) == nil)
        try writer.set(value: 42, for: target)
        // The reader still trusts its cached absence (no external-change check in single-process mode).
        #expect(try reader.get(valueFor: target) == nil)

        try Self.missUniqueKeys(in: reader)

        try Self.expectBounded(reader)
        #expect(try reader.get(valueFor: target) == 42)
    }

    @Test("a removal recorded before an out-of-band write is re-read from disk after eviction")
    func evictedRemovalReadsDisk() throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = Self.cachedDepot(at: url)
        let writer = Self.uncachedDepot(at: url)
        _ = reader.register(key: Key.from("items" / .wildcard), coder: .json() as AnyCoder<Int>)
        _ = writer.register(key: Key.from("items" / .wildcard), coder: .json() as AnyCoder<Int>)
        let target = Self.item("target")

        for index in 0..<300 {
            let key = Self.item("removed-\(index)")
            try reader.set(value: index, for: key)
            try reader.remove(valueFor: key)
        }
        try Self.expectBounded(reader)

        try reader.set(value: 1, for: target)
        try reader.remove(valueFor: target)
        try writer.set(value: 7, for: target)
        #expect(try reader.get(valueFor: target) == nil)

        try Self.missUniqueKeys(in: reader)

        try Self.expectBounded(reader)
        #expect(try reader.get(valueFor: target) == 7)
    }

    @Test("TTL expirations stay bounded and an evicted expiry is re-read from disk")
    func evictedExpiryReadsDisk() throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = MockClock()
        let reader = Self.cachedDepot(at: url, clock: clock)
        let writer = Self.uncachedDepot(at: url)
        let pattern = Key.from("items" / .wildcard)
        _ = reader.register(key: pattern, coder: .json() as AnyCoder<Int>, expiry: .seconds(10))
        _ = writer.register(key: pattern, coder: .json() as AnyCoder<Int>)
        let target = Self.item("target")

        try reader.set(value: 1, for: target)
        for index in 0..<300 {
            try reader.set(value: index, for: Self.item("expiring-\(index)"))
        }
        clock.advance(by: 20)
        for index in 0..<300 {
            #expect(try reader.get(valueFor: Self.item("expiring-\(index)")) == nil)
        }
        try Self.expectBounded(reader)

        #expect(try reader.get(valueFor: target) == nil)
        // The writer stores a value without expiry behind the reader's back.
        try writer.set(value: 9, for: target)
        #expect(try reader.get(valueFor: target) == nil)

        try Self.missUniqueKeys(in: reader)

        try Self.expectBounded(reader)
        #expect(try reader.get(valueFor: target) == 9)
    }

    @Test("external removals stay bounded and an evicted external removal is re-read from disk")
    func evictedExternalRemovalReadsDisk() throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = Self.cachedDepot(at: url, multiProcess: true)
        let writer = Self.uncachedDepot(at: url, multiProcess: true)
        let pattern = Key.from("items" / .wildcard)
        _ = reader.register(key: pattern, coder: .json() as AnyCoder<Int>)
        let writerPattern = writer.register(key: pattern, coder: .json() as AnyCoder<Int>)
        let target = Self.item("target")

        try writer.set(value: 1, for: target)
        for index in 0..<300 {
            try writer.set(value: index, for: Self.item("external-\(index)"))
        }
        try reader.checkForExternalChanges()
        try writer.remove(valuesFor: writerPattern)
        try reader.checkForExternalChanges()
        try Self.expectBounded(reader)

        #expect(try reader.get(valueFor: target) == nil)
        try writer.set(value: 5, for: target)
        // Without another external-change check the reader still trusts the recorded removal.
        #expect(try reader.get(valueFor: target) == nil)

        try Self.missUniqueKeys(in: reader)

        try Self.expectBounded(reader)
        #expect(try reader.get(valueFor: target) == 5)
    }
}
