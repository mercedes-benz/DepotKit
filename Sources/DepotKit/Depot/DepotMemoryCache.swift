// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import os

/// LRU memory cache with cost-based eviction for decoded depot values.
///
/// Besides decoded values, the cache remembers keys that are known to be absent
/// (misses, removals, expirations). Both kinds of entries share one LRU list and
/// one cost budget, so the cache's bookkeeping is bounded by its capacity. An
/// evicted entry of either kind turns into "unknown", which makes the caller
/// consult the disk; eviction never produces a false "absent" answer.
///
/// Every entry is charged its payload cost (the file size for values), the
/// UTF-8 bytes of its key, and ``entryOverheadCost``. An entry whose charge
/// exceeds the capacity is not cached at all.
///
/// Note: Only to be used by ``Depot``!
final class DepotMemoryCache: Sendable {
    /// The fixed cost charged for every entry in addition to its key and payload.
    ///
    /// Approximates the bookkeeping of an entry (dictionary entry, LRU slot, and
    /// entry record), so entries with tiny or free payloads are bounded by the budget.
    static let entryOverheadCost = 128

    /// The cost charged for an entry of `key` with the given payload cost.
    static func cost(of key: DistinctKey, payloadCost: Int) -> Int {
        var cost = entryOverheadCost + max(0, payloadCost)
        for component in key.components {
            if case let .segment(identifier) = component {
                cost += identifier.utf8.count
            }
        }
        return cost
    }

    /// A slot in the contiguous LRU array. Uses integer indices for
    /// prev/next links instead of heap-allocated node objects.
    private struct LRUSlot {
        /// `nil` while the slot is free, so that free slots do not keep keys alive.
        var key: DistinctKey?
        var prev: Int  // -1 = none
        var next: Int  // -1 = none
    }

    private struct CacheEntry {
        /// The decoded value, or `nil` when the key is known to be absent.
        let value: (any Sendable)?
        let cost: Int
        let slotIndex: Int
        let expiresAt: Date?
    }

    private struct State {
        /// Every entry (value or known absence) owns exactly one LRU slot.
        var cache = [DistinctKey: CacheEntry]()
        var currentCost = 0
        var slots = [LRUSlot]()
        var freeSlots = [Int]()
        var lruHead: Int = -1  // most recently used
        var lruTail: Int = -1  // least recently used
        let totalCostLimit: Int

        mutating func allocateSlot(for key: DistinctKey) -> Int {
            if let index = freeSlots.popLast() {
                slots[index] = LRUSlot(key: key, prev: -1, next: -1)
                return index
            }
            let index = slots.count
            slots.append(LRUSlot(key: key, prev: -1, next: -1))
            return index
        }

        mutating func moveToHead(_ index: Int) {
            guard index != lruHead else {
                return
            }
            unlinkSlot(index)
            prependSlot(index)
        }

        mutating func prependSlot(_ index: Int) {
            slots[index].prev = -1
            slots[index].next = lruHead
            if lruHead >= 0 {
                slots[lruHead].prev = index
            }
            lruHead = index
            if lruTail < 0 {
                lruTail = index
            }
        }

        mutating func unlinkSlot(_ index: Int) {
            let prev = slots[index].prev
            let next = slots[index].next
            if prev >= 0 {
                slots[prev].next = next
            }
            if next >= 0 {
                slots[next].prev = prev
            }
            if index == lruHead {
                lruHead = next
            }
            if index == lruTail {
                lruTail = prev
            }
            slots[index].prev = -1
            slots[index].next = -1
        }

        mutating func removeSlot(_ index: Int) {
            unlinkSlot(index)
            slots[index].key = nil
            freeSlots.append(index)
        }

        /// Forgets everything about `key`; subsequent lookups report a miss.
        mutating func removeEntry(for key: DistinctKey) {
            if let existing = cache.removeValue(forKey: key) {
                currentCost -= existing.cost
                removeSlot(existing.slotIndex)
            }
        }

        /// Stores `value` for `key`, or records the key as absent when `value` is `nil`.
        mutating func insert(value: (any Sendable)?, for key: DistinctKey, cost: Int, expiresAt: Date?) {
            removeEntry(for: key)

            let entryCost = DepotMemoryCache.cost(of: key, payloadCost: value == nil ? 0 : cost)
            guard totalCostLimit == 0 || entryCost <= totalCostLimit else {
                // Caching it would evict everything else; the key stays unknown instead.
                return
            }

            let slotIndex = allocateSlot(for: key)
            cache[key] = CacheEntry(
                value: value,
                cost: entryCost,
                slotIndex: slotIndex,
                expiresAt: value == nil ? nil : expiresAt
            )
            prependSlot(slotIndex)
            currentCost += entryCost
            evictIfNeeded(excluding: key)
        }

        mutating func evictIfNeeded(excluding protectedKey: DistinctKey) {
            guard totalCostLimit > 0, currentCost > totalCostLimit else {
                return
            }

            let evictionTarget = Int(Double(totalCostLimit) * 0.6)
            let costBefore = currentCost
            var evictedCount = 0
            var current = lruTail
            while current >= 0, currentCost > evictionTarget {
                let prev = slots[current].prev
                if let key = slots[current].key, key != protectedKey {
                    removeEntry(for: key)
                    evictedCount += 1
                }
                current = prev
            }

            LOG(
                level: .debug,
                message: "DepotMemoryCache: evicted \(evictedCount) entries, freed \(costBefore - currentCost) bytes",
            )
        }
    }

    // MARK: - Properties

    private let state: OSAllocatedUnfairLock<State>

    // MARK: - Init

    init(totalCostLimit: Int) {
        state = OSAllocatedUnfairLock(uncheckedState: State(totalCostLimit: totalCostLimit))
    }

    // MARK: - Types

    enum CacheLookupResult<V: Sendable>: Sendable {
        case hit(V)
        case confirmedAbsent
        case expired
        case miss
    }

    // MARK: - Internal

    func lookup<V>(valueFor key: DistinctKey, at now: Date) -> CacheLookupResult<V> where V: Sendable {
        state.withLock { state in
            guard let entry = state.cache[key] else {
                return .miss
            }
            guard let value = entry.value else {
                state.moveToHead(entry.slotIndex)
                return .confirmedAbsent
            }
            if let expiresAt = entry.expiresAt, now >= expiresAt {
                return .expired
            }
            state.moveToHead(entry.slotIndex)
            if let value = value as? V {
                return .hit(value)
            }
            return .miss
        }
    }

    func set(value: (some Sendable)?, for key: DistinctKey, cost: Int? = nil, expiresAt: Date? = nil) {
        state.withLock { state in
            state.insert(value: value, for: key, cost: cost ?? 0, expiresAt: expiresAt)
        }
    }

    func markExpired(for key: DistinctKey) {
        state.withLock { state in
            state.insert(value: nil, for: key, cost: 0, expiresAt: nil)
        }
    }

    func has(valuesFor key: some KeyProtocol, at now: Date) -> Bool? {
        state.withLock { state in
            if let distinctKey = try? key.distinct() {
                guard let entry = state.cache[distinctKey] else {
                    return nil
                }
                guard entry.value != nil else {
                    return false
                }
                if let expiresAt = entry.expiresAt, now >= expiresAt {
                    return false
                }
                return true
            }

            // Pattern keys can match multiple entries; only a cached, unexpired value proves existence.
            if state.cache.contains(where: { entryKey, entry in
                guard entry.value != nil, key.matches(entryKey.key) else {
                    return false
                }
                if let expiresAt = entry.expiresAt, now >= expiresAt {
                    return false
                }
                return true
            }) {
                return true
            }

            return nil
        }
    }

    func remove(valuesFor key: some KeyProtocol) {
        state.withLock { state in
            if let distinctKey = try? key.distinct() {
                state.insert(value: nil, for: distinctKey, cost: 0, expiresAt: nil)
                return
            }

            // Keys without a cached value are unknown already; they stay unknown.
            let keysToRemove = state.cache.compactMap { entryKey, entry in
                entry.value != nil && key.matches(entryKey.key) ? entryKey : nil
            }

            for entryKey in keysToRemove {
                state.insert(value: nil, for: entryKey, cost: 0, expiresAt: nil)
            }
        }
    }

    func invalidate(modified: Set<some DistinctKeyProtocol>, removed: Set<some DistinctKeyProtocol>) {
        state.withLock { state in
            for key in modified {
                state.removeEntry(for: DistinctKey(key))
            }

            for key in removed {
                state.insert(value: nil, for: DistinctKey(key), cost: 0, expiresAt: nil)
            }
        }
    }

    struct DeferredUpdate {
        let key: DistinctKey
        let value: (any Sendable)?
        let cost: Int
        let expiresAt: Date?
    }

    func applyBatch(writes: [DeferredUpdate], removals: [DistinctKey]) {
        state.withLock { state in
            for key in removals {
                state.insert(value: nil, for: key, cost: 0, expiresAt: nil)
            }

            for update in writes {
                state.insert(value: update.value, for: update.key, cost: update.cost, expiresAt: update.expiresAt)
            }
        }
    }

    func removeAll() {
        state.withLock { state in
            state.cache.removeAll()
            state.currentCost = 0
            state.slots.removeAll()
            state.freeSlots.removeAll()
            state.lruHead = -1
            state.lruTail = -1
        }
    }

    // MARK: - Testing

    /// The number of keys the cache holds knowledge about (values and known absences).
    var knowledgeEntryCount: Int {
        state.withLock { $0.cache.count }
    }

    /// The number of allocated LRU slots, including free ones.
    var slotCount: Int {
        state.withLock { $0.slots.count }
    }

    /// The total cost currently charged against the capacity.
    var totalCost: Int {
        state.withLock { $0.currentCost }
    }

    /// The number of LRU slots that still reference a key.
    var retainedSlotKeyCount: Int {
        state.withLock { $0.slots.count { $0.key != nil } }
    }
}
