// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import os

/// LRU memory cache with cost-based eviction for decoded depot values.
///
/// Note: Only to be used by ``Depot``!
final class DepotMemoryCache: Sendable {
    /// A slot in the contiguous LRU array. Uses integer indices for
    /// prev/next links instead of heap-allocated node objects.
    private struct LRUSlot {
        var key: DistinctKey
        var prev: Int  // -1 = none
        var next: Int  // -1 = none
    }

    private struct CacheEntry {
        let value: any Sendable
        let cost: Int
        let slotIndex: Int
        let expiresAt: Date?
    }

    private struct State {
        var cache = [DistinctKey: CacheEntry]()
        /// Tracks key presence independently of `cache` — allows "confirmed absent" answers after LRU eviction.
        var entries = [DistinctKey: Bool]()
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
            freeSlots.append(index)
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
                if slots[current].key != protectedKey {
                    if let entry = cache.removeValue(forKey: slots[current].key) {
                        currentCost -= entry.cost
                        evictedCount += 1
                    }
                    entries.removeValue(forKey: slots[current].key)
                    removeSlot(current)
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
            if let entry = state.cache[key] {
                // Check expiry
                if let expiresAt = entry.expiresAt, now >= expiresAt {
                    return .expired
                }
                state.moveToHead(entry.slotIndex)
                if let value = entry.value as? V {
                    return .hit(value)
                }
            }

            if let hasValue = state.entries[key] {
                return hasValue ? .miss : .confirmedAbsent
            }

            return .miss
        }
    }

    func set(value: (some Sendable)?, for key: DistinctKey, cost: Int? = nil, expiresAt: Date? = nil) {
        state.withLock { state in
            if let existing = state.cache.removeValue(forKey: key) {
                state.currentCost -= existing.cost
                state.removeSlot(existing.slotIndex)
            }

            if let value {
                let entryCost = cost ?? 0
                let slotIndex = state.allocateSlot(for: key)
                state.cache[key] = CacheEntry(
                    value: value,
                    cost: entryCost,
                    slotIndex: slotIndex,
                    expiresAt: expiresAt
                )
                state.prependSlot(slotIndex)
                state.currentCost += entryCost
                state.evictIfNeeded(excluding: key)
            }

            state.entries[key] = value != nil
        }
    }

    func markExpired(for key: DistinctKey) {
        state.withLock { state in
            if let existing = state.cache.removeValue(forKey: key) {
                state.currentCost -= existing.cost
                state.removeSlot(existing.slotIndex)
            }
            state.entries[key] = false
        }
    }

    func has(valuesFor key: some KeyProtocol, at now: Date) -> Bool? {
        state.withLock { state in
            if let distinctKey = try? key.distinct() {
                if let entry = state.cache[distinctKey] {
                    if let expiresAt = entry.expiresAt, now >= expiresAt {
                        return false
                    }
                    return true
                }
                if let hasValue = state.entries[distinctKey] {
                    if !hasValue {
                        return false
                    }
                    // LRU-evicted: can't verify expiry — force disk check
                    return nil
                }
                return nil
            }

            // Pattern keys can match multiple entries
            if state.entries.contains(where: { entryKey, hasValue in
                guard hasValue, key.matches(entryKey.key) else {
                    return false
                }
                guard let entry = state.cache[entryKey] else {
                    // LRU-evicted — can't verify expiry
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
                if let removed = state.cache.removeValue(forKey: distinctKey) {
                    state.currentCost -= removed.cost
                    state.removeSlot(removed.slotIndex)
                }

                state.entries[distinctKey] = false
                return
            }

            var keysToRemove = [DistinctKey]()
            for (entryKey, hasValue) in state.entries where hasValue && key.matches(entryKey.key) {
                keysToRemove.append(entryKey)
            }

            for entryKey in keysToRemove {
                if let removed = state.cache.removeValue(forKey: entryKey) {
                    state.currentCost -= removed.cost
                    state.removeSlot(removed.slotIndex)
                }

                state.entries[entryKey] = false
            }
        }
    }

    func invalidate(modified: Set<some DistinctKeyProtocol>, removed: Set<some DistinctKeyProtocol>) {
        state.withLock { state in
            for key in modified {
                let distinctKey = DistinctKey(key)
                if let removed = state.cache.removeValue(forKey: distinctKey) {
                    state.currentCost -= removed.cost
                    state.removeSlot(removed.slotIndex)
                }

                state.entries[distinctKey] = true
            }

            for key in removed {
                let distinctKey = DistinctKey(key)
                if let removed = state.cache.removeValue(forKey: distinctKey) {
                    state.currentCost -= removed.cost
                    state.removeSlot(removed.slotIndex)
                }

                state.entries[distinctKey] = false
            }
        }
    }

    func removeAll() {
        state.withLock { state in
            state.cache.removeAll()
            state.entries.removeAll()
            state.currentCost = 0
            state.slots.removeAll()
            state.freeSlots.removeAll()
            state.lruHead = -1
            state.lruTail = -1
        }
    }

}
