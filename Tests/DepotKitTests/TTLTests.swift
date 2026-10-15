// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

@Suite
struct TTLTests {
    // MARK: - Basic Expiry

    @Test("expired value returns nil on get")
    func expiredReturnsNil() throws {
        let clock = MockClock()
        let depot = Depot.temporary(clock: clock)
        let key = depot.register(keyPath: "token", coder: .json() as AnyCoder<String>, expiry: .seconds(60))

        try depot.set(value: "abc", for: key)
        #expect(try depot.get(valueFor: key) == "abc")

        clock.advance(by: 61)
        #expect(try depot.get(valueFor: key) == nil)
    }

    @Test("non-expired value returns normally")
    func nonExpiredReturns() throws {
        let clock = MockClock()
        let depot = Depot.temporary(clock: clock)
        let key = depot.register(keyPath: "token", coder: .json() as AnyCoder<String>, expiry: .seconds(60))

        try depot.set(value: "abc", for: key)
        clock.advance(by: 30)
        #expect(try depot.get(valueFor: key) == "abc")
    }

    @Test("value expires exactly at boundary")
    func expiresAtBoundary() throws {
        let clock = MockClock(now: Date(timeIntervalSince1970: 1_000_000))
        let depot = Depot.temporary(clock: clock)
        let key = depot.register(keyPath: "x", coder: .json() as AnyCoder<Int>, expiry: .seconds(10))

        try depot.set(value: 42, for: key)
        clock.advance(by: 10)
        #expect(try depot.get(valueFor: key) == nil)
    }

    @Test("key without expiry never expires")
    func noExpiryNeverExpires() throws {
        let clock = MockClock()
        let depot = Depot.temporary(clock: clock)
        let key = depot.register(keyPath: "forever", coder: .json() as AnyCoder<String>)

        try depot.set(value: "persist", for: key)
        clock.advance(by: 999_999)
        #expect(try depot.get(valueFor: key) == "persist")
    }

    // MARK: - has() checks expiry

    @Test("has returns false for expired value")
    func hasChecksTTL() throws {
        let clock = MockClock()
        let depot = Depot.temporary(clock: clock)
        let key = depot.register(keyPath: "ephemeral", coder: .json() as AnyCoder<String>, expiry: .seconds(5))

        try depot.set(value: "x", for: key)
        #expect(try depot.has(valueFor: key) == true)

        clock.advance(by: 6)
        #expect(try depot.has(valueFor: key) == false)
    }

    // MARK: - Pattern key reads filter expired

    @Test("get(valuesFor:) excludes expired values")
    func multiValueFiltersExpired() throws {
        let clock = MockClock()
        let depot = Depot.temporary(clock: clock)
        let pattern = depot.register(
            keyPath: "items" / .wildcard,
            coder: .json() as AnyCoder<String>,
            expiry: .seconds(30)
        )
        let key1 = depot.register(keyPath: "items" / "a", coder: .json() as AnyCoder<String>, expiry: .seconds(10))
        let key2 = depot.register(keyPath: "items" / "b", coder: .json() as AnyCoder<String>, expiry: .seconds(60))

        try depot.set(value: "first", for: key1)
        try depot.set(value: "second", for: key2)

        clock.advance(by: 15)

        let values = try depot.get(valuesFor: pattern)
        #expect(values == ["second"])
    }

    // MARK: - removeExpired()

    @Test("removeExpired removes only expired entries")
    func removeExpiredSelectivity() throws {
        let clock = MockClock()
        let depot = Depot.temporary(clock: clock)
        let shortKey = depot.register(keyPath: "short", coder: .json() as AnyCoder<String>, expiry: .seconds(10))
        let longKey = depot.register(keyPath: "long", coder: .json() as AnyCoder<String>, expiry: .seconds(100))

        try depot.set(value: "a", for: shortKey)
        try depot.set(value: "b", for: longKey)

        clock.advance(by: 15)

        let removed = try depot.removeExpired()
        #expect(removed == 1)

        #expect(try depot.get(valueFor: longKey) == "b")
    }

    @Test("removeExpired returns 0 when nothing is expired")
    func removeExpiredNothingToRemove() throws {
        let clock = MockClock()
        let depot = Depot.temporary(clock: clock)
        let key = depot.register(keyPath: "fresh", coder: .json() as AnyCoder<String>, expiry: .seconds(60))

        try depot.set(value: "hi", for: key)
        let removed = try depot.removeExpired()
        #expect(removed == 0)
    }

    // MARK: - Memory-only depot

    @Test("TTL works in memory-only mode")
    func memoryOnlyTTL() throws {
        let clock = MockClock()
        let depot = Depot(label: "test", configuration: .inMemory(), overrides: .init(clock: clock))
        let key = depot.register(keyPath: "mem", coder: .json() as AnyCoder<Int>, expiry: .seconds(5))

        try depot.set(value: 99, for: key)
        #expect(try depot.get(valueFor: key) == 99)

        clock.advance(by: 6)
        #expect(try depot.get(valueFor: key) == nil)
    }

    @Test("removeExpired works in memory-only mode")
    func memoryOnlyRemoveExpired() throws {
        let clock = MockClock()
        let depot = Depot(label: "test", configuration: .inMemory(), overrides: .init(clock: clock))
        let key = depot.register(keyPath: "mem", coder: .json() as AnyCoder<Int>, expiry: .seconds(5))

        try depot.set(value: 1, for: key)
        clock.advance(by: 10)

        let removed = try depot.removeExpired()
        #expect(removed == 1)
    }

    // MARK: - Modify resets expiry

    @Test("modify recomputes expiresAt from registration duration")
    func modifyResetsExpiry() throws {
        let clock = MockClock()
        let depot = Depot.temporary(clock: clock)
        let key = depot.register(keyPath: "counter", coder: .json() as AnyCoder<Int>, expiry: .seconds(60))

        try depot.set(value: 1, for: key)
        clock.advance(by: 50)

        try depot.modify(valueFor: key) { _ in .update(2) }

        // Should now expire 60s from the modify, not 10s from now
        clock.advance(by: 30)
        #expect(try depot.get(valueFor: key) == 2)

        clock.advance(by: 31)
        #expect(try depot.get(valueFor: key) == nil)
    }

    // MARK: - KeyDefinition carries expiry

    @Test("KeyDefinition expiry flows through to registration")
    func keyDefinitionExpiry() throws {
        let clock = MockClock()
        let depot = Depot.temporary(clock: clock)

        let definition = KeyDefinition<String>(path: "auth" / "token", coder: .json(), expiry: .seconds(30))
        let key = depot.register(definition)

        try depot.set(value: "session", for: key)
        clock.advance(by: 31)
        #expect(try depot.get(valueFor: key) == nil)
    }

    // MARK: - Observer notifications

    @Test("removeExpired fires observer notifications for each removed key")
    func removeExpiredNotifiesObservers() async throws {
        let clock = MockClock(now: Date(timeIntervalSince1970: 1_000_000))
        let depot = Depot.temporary(clock: clock)
        let key = depot.register(keyPath: "expiring", coder: .json() as AnyCoder<String>, expiry: .seconds(10))

        try await depot.set(value: "val", for: key)

        let stream = depot.values(for: key, initialValue: false)
        var iterator = stream.makeAsyncIterator()

        clock.advance(by: 11)
        _ = try await depot.removeExpired()
        await depot.waitForPendingObservations()

        let change = await iterator.next()
        switch change {
        case .some(.success(let value)):
            #expect(value == nil)
        default:
            Issue.record("Expected .success(nil), got \(String(describing: change))")
        }
    }

    @Test("lazy expiry via get does NOT fire observer (silent)")
    func lazyExpiryIsSilent() async throws {
        let clock = MockClock(now: Date(timeIntervalSince1970: 1_000_000))
        let depot = Depot.temporary(clock: clock)
        let key = depot.register(keyPath: "token", coder: .json() as AnyCoder<String>, expiry: .seconds(10))

        try await depot.set(value: "secret", for: key)
        await depot.waitForPendingObservations()

        let stream = depot.values(for: key, initialValue: false)

        clock.advance(by: 11)

        let value: String? = try await depot.get(valueFor: key)
        #expect(value == nil)

        await depot.waitForPendingObservations()

        let task = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }

        await Task.yield()
        task.cancel()
        let result = await task.value
        #expect(result == nil, "Lazy expiry must NOT fire observer — only removeExpired() should")
    }

    // MARK: - Init sweep

    @Test("init sweep removes pre-existing expired entries")
    func initSweepRemovesExpired() async throws {
        let clock = MockClock(now: Date(timeIntervalSince1970: 1_000_000))
        let dir = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)

        // Write an expired entry with the first depot instance
        let depot1 = Depot(
            configuration: .init(directoryURL: dir),
            overrides: .init(clock: clock),
        )
        let key = depot1.register(keyPath: "temp", coder: .json() as AnyCoder<String>, expiry: .seconds(5))
        try await depot1.set(value: "will-expire", for: key)

        // Advance past expiry
        clock.advance(by: 6)

        // Create a new depot pointing at the same directory — init sweep should fire
        let depot2 = Depot(
            configuration: .init(directoryURL: dir),
            overrides: .init(clock: clock, initSweepDelay: .milliseconds(10)),
        )
        _ = depot2.register(keyPath: "temp", coder: .json() as AnyCoder<String>, expiry: .seconds(5))

        await depot2.waitForInitSweep()

        let exists = try await depot2.has(valueFor: key)
        #expect(exists == false)
    }

    // MARK: - Read-only depot

    @Test("removeExpired throws on read-only depot")
    func removeExpiredReadOnly() throws {
        let config = DepotConfiguration(
            directoryURL: FileManager.default.temporaryDirectory.appending(component: UUID().uuidString),
            readOnly: true
        )
        let depot = Depot(configuration: config)
        let _ = depot.register(keyPath: "x", coder: .json() as AnyCoder<String>, expiry: .seconds(5))

        #expect(throws: DepotError.self) {
            _ = try depot.removeExpired()
        }
    }

    // MARK: - Pattern-only expiry resolution

    @Test("expiry resolves from pattern when distinct key has no direct registration")
    func expiryFromPatternOnly() throws {
        let clock = MockClock()
        let depot = Depot.temporary(clock: clock)
        _ = depot.register(keyPath: "cache" / .wildcard, coder: .json() as AnyCoder<String>, expiry: .seconds(20))

        // Construct a typed distinct key without a direct registration — coder and expiry resolve via pattern
        let concreteKey: TypedDistinctKey<String> = Key.from("cache" / "entry1").typed()

        try depot.set(value: "data", for: concreteKey)
        #expect(try depot.get(valueFor: concreteKey) == "data")

        clock.advance(by: 21)
        #expect(try depot.get(valueFor: concreteKey) == nil)
    }

    @Test("direct registration expiry takes precedence over pattern expiry")
    func directExpiryOverridesPattern() throws {
        let clock = MockClock()
        let depot = Depot.temporary(clock: clock)
        _ = depot.register(keyPath: "cache" / .wildcard, coder: .json() as AnyCoder<String>, expiry: .seconds(20))
        let key = depot.register(keyPath: "cache" / "pinned", coder: .json() as AnyCoder<String>, expiry: .seconds(100))

        try depot.set(value: "long-lived", for: key)
        clock.advance(by: 25)
        // Pattern would have expired at 20s, but direct registration says 100s
        #expect(try depot.get(valueFor: key) == "long-lived")

        clock.advance(by: 76)
        #expect(try depot.get(valueFor: key) == nil)
    }

    // MARK: - Memory cache integration

    // MARK: - TTL in transactions

    @Test("expired value returns nil inside transaction")
    func transactionExpiredGet() throws {
        let clock = MockClock()
        let depot = Depot.temporary(clock: clock)
        let key = depot.register(keyPath: "session", coder: .json() as AnyCoder<String>, expiry: .seconds(30))

        try depot.set(value: "active", for: key)
        clock.advance(by: 31)

        try depot.transaction { tx in
            let value = try tx.get(valueFor: key)
            let exists = try tx.has(valueFor: key)
            #expect(value == nil)
            #expect(exists == false)
        }
    }

    @Test("write inside transaction resets TTL for buffered value")
    func transactionWriteResetsTTL() throws {
        let clock = MockClock()
        let depot = Depot.temporary(clock: clock)
        let key = depot.register(keyPath: "token", coder: .json() as AnyCoder<String>, expiry: .seconds(60))

        try depot.set(value: "old", for: key)
        clock.advance(by: 61)

        try depot.transaction { tx in
            #expect(try tx.get(valueFor: key) == nil)
            try tx.set(value: "refreshed", for: key)
            #expect(try tx.get(valueFor: key) == "refreshed")
        }

        #expect(try depot.get(valueFor: key) == "refreshed")
    }

    // MARK: - Memory cache integration

    @Test("TTL works through memory cache path")
    func ttlWithMemoryCache() throws {
        let clock = MockClock(now: Date(timeIntervalSince1970: 1_000_000))
        let depot = Depot.temporary(memoryCache: .default, clock: clock)
        let key = depot.register(keyPath: "cached", coder: .json() as AnyCoder<String>, expiry: .seconds(30))

        try depot.set(value: "hello", for: key)

        // First get populates cache
        #expect(try depot.get(valueFor: key) == "hello")

        // Second get serves from cache
        #expect(try depot.get(valueFor: key) == "hello")

        // Advance past expiry — cache should return expired
        clock.advance(by: 31)
        #expect(try depot.get(valueFor: key) == nil)

        // has() should also reflect expiry
        #expect(try depot.has(valueFor: key) == false)
    }
}
