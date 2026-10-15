// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

@Suite
struct ValueMetadataTests {
    @Test("metadata returns nil for absent key")
    func metadataAbsent() throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "missing", coder: .json() as AnyCoder<String>)
        let meta = try depot.metadata(for: key)
        #expect(meta == nil)
    }

    @Test("metadata returns correct modifiedAt and nil expiresAt for non-expiring key")
    func metadataNoExpiry() throws {
        let clock = MockClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let depot = Depot.temporary(clock: clock)
        let key = depot.register(keyPath: "stable", coder: .json() as AnyCoder<String>)

        try depot.set(value: "hello", for: key)

        let meta = try depot.metadata(for: key)
        #expect(meta != nil)
        #expect(meta!.modifiedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(meta!.expiresAt == nil)
    }

    @Test("metadata returns correct expiresAt for expiring key")
    func metadataWithExpiry() throws {
        let clock = MockClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let depot = Depot.temporary(clock: clock)
        let key = depot.register(keyPath: "temp", coder: .json() as AnyCoder<String>, expiry: .seconds(300))

        try depot.set(value: "ephemeral", for: key)

        let meta = try depot.metadata(for: key)
        #expect(meta != nil)
        #expect(meta!.expiresAt == Date(timeIntervalSince1970: 1_700_000_300))
    }

    @Test("metadata returns nil for expired key")
    func metadataExpired() throws {
        let clock = MockClock()
        let depot = Depot.temporary(clock: clock)
        let key = depot.register(keyPath: "ttl", coder: .json() as AnyCoder<Int>, expiry: .seconds(10))

        try depot.set(value: 42, for: key)
        clock.advance(by: 11)

        let meta = try depot.metadata(for: key)
        #expect(meta == nil)
    }

    @Test("metadata updates modifiedAt on overwrite")
    func metadataUpdatesOnWrite() throws {
        let clock = MockClock(now: Date(timeIntervalSince1970: 1_000_000))
        let depot = Depot.temporary(clock: clock)
        let key = depot.register(keyPath: "item", coder: .json() as AnyCoder<String>)

        try depot.set(value: "v1", for: key)
        let meta1 = try depot.metadata(for: key)!

        clock.advance(by: 100)
        try depot.set(value: "v2", for: key)
        let meta2 = try depot.metadata(for: key)!

        #expect(meta2.modifiedAt > meta1.modifiedAt)
    }

    @Test("metadata works in memory-only mode")
    func metadataMemoryOnly() throws {
        let clock = MockClock(now: Date(timeIntervalSince1970: 2_000_000))
        let depot = Depot(label: "test", configuration: .inMemory(), overrides: .init(clock: clock))
        let key = depot.register(keyPath: "mem", coder: .json() as AnyCoder<String>, expiry: .seconds(60))

        try depot.set(value: "val", for: key)

        let meta = try depot.metadata(for: key)
        #expect(meta != nil)
        #expect(meta!.modifiedAt == Date(timeIntervalSince1970: 2_000_000))
        #expect(meta!.expiresAt == Date(timeIntervalSince1970: 2_000_060))
    }
}
