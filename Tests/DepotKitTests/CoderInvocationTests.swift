// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// Rejected writes fail before any value is encoded, and memory-only depots
/// never invoke coders at all.
@Suite
struct CoderInvocationTests {
    private struct CountingCoder: Coder {
        let calls: OSAllocatedUnfairLock<Int>

        func encode(_ value: Int) throws -> Data {
            calls.withLock { $0 += 1 }
            return try JSONEncoder().encode(value)
        }

        func decode(_ data: Data) throws -> Int {
            calls.withLock { $0 += 1 }
            return try JSONDecoder().decode(Int.self, from: data)
        }
    }

    struct Variant: Sendable, CustomTestStringConvertible {
        let memoryOnly: Bool
        let pattern: Bool
        let asynchronous: Bool
        let nilValue: Bool

        static let all = [false, true].flatMap { memoryOnly in
            [false, true].flatMap { pattern in
                [false, true].flatMap { asynchronous in
                    [false, true].map { nilValue in
                        Variant(
                            memoryOnly: memoryOnly,
                            pattern: pattern,
                            asynchronous: asynchronous,
                            nilValue: nilValue
                        )
                    }
                }
            }
        }

        var testDescription: String {
            [
                memoryOnly ? "memory-only" : "file-backed",
                pattern ? "pattern registration" : "distinct registration",
                asynchronous ? "async" : "sync",
                nilValue ? "nil" : "value",
            ]
            .joined(separator: ", ")
        }

        func makeDepot() -> Depot {
            memoryOnly ? Depot() : Depot.temporary(memoryCache: .default)
        }
    }

    private static func removeDirectory(of depot: Depot) {
        if let url = depot.configuration.directoryURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test("a wrong-type write fails without encoding, mutating or notifying", arguments: Variant.all)
    func wrongTypeWriteSkipsCoder(variant: Variant) async throws {
        let depot = variant.makeDepot()
        defer { Self.removeDirectory(of: depot) }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let key = Key.from("items" / "entry", as: Int.self)
        if variant.pattern {
            depot.register(key: Key.from("items" / .wildcard), coder: CountingCoder(calls: calls))
        } else {
            depot.register(key: key, coder: CountingCoder(calls: calls))
        }
        try await depot.set(value: 42, for: key)
        await depot.waitForPendingObservations()
        let callsBefore = calls.withLock { $0 }

        let updates = OSAllocatedUnfairLock(initialState: 0)
        let observer = depot.core.observe(
            valueFor: key,
            initialValue: false,
            update: { _ in updates.withLock { $0 += 1 } },
            in: depot,
        )
        defer { observer.cancel() }

        let wrongKey = Key.from("items" / "entry", as: String.self)
        let wrongValue: String? = variant.nilValue ? nil : "wrong"
        let expected = DepotError.mismatchedTypes(keyPath: key.keyPath, expected: "String", actual: "Int")
        if variant.asynchronous {
            await #expect(throws: expected) { try await depot.set(value: wrongValue, for: wrongKey) }
        } else {
            #expect(throws: expected) { try depot.set(value: wrongValue, for: wrongKey) }
        }

        await depot.waitForPendingObservations()
        #expect(updates.withLock { $0 } == 0)
        #expect(calls.withLock { $0 } == callsBefore)
        #expect(try await depot.get(valueFor: key) == 42)
        if variant.memoryOnly {
            #expect(calls.withLock { $0 } == 0)
        }
    }

    @Test(
        "a rejected transaction write rolls back earlier buffered writes without encoding",
        arguments: Variant.all,
        [false, true],
    )
    func rejectedTransactionWriteSkipsCoder(variant: Variant, unregistered: Bool) async throws {
        let depot = variant.makeDepot()
        defer { Self.removeDirectory(of: depot) }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let coder = CountingCoder(calls: calls)
        let validKey = depot.register(keyPath: "valid", coder: coder)
        let target = Key.from("items" / "entry", as: Int.self)
        if variant.pattern {
            depot.register(key: Key.from("items" / .wildcard), coder: coder)
        } else {
            depot.register(key: target, coder: coder)
        }
        try await depot.set(value: 7, for: validKey)
        try await depot.set(value: 42, for: target)
        await depot.waitForPendingObservations()

        let updates = OSAllocatedUnfairLock(initialState: 0)
        let observer = depot.core.observe(
            valuesFor: Key.all.typed(as: Int.self),
            initialValues: false,
            update: { _ in updates.withLock { $0 += 1 } },
            in: depot,
        )
        defer { observer.cancel() }

        let expected =
            unregistered
            ? DepotError.unregisteredKey(keyPath: "unknown")
            : DepotError.mismatchedTypes(keyPath: target.keyPath, expected: "String", actual: "Int")
        let nilValue = variant.nilValue
        let work: @Sendable (inout DepotTransaction) throws -> Void = { transaction in
            try transaction.set(value: 99, for: validKey)
            let callsBeforeRejectedWrite = calls.withLock { $0 }
            defer { #expect(calls.withLock { $0 } == callsBeforeRejectedWrite) }
            if unregistered {
                try transaction.set(value: nilValue ? nil : 3, for: Key.from("unknown", as: Int.self))
            } else {
                try transaction.set(value: nilValue ? nil : "wrong", for: Key.from("items" / "entry", as: String.self))
            }
        }
        if variant.asynchronous {
            await #expect(throws: expected) { try await depot.transaction(work) }
        } else {
            #expect(throws: expected) { try depot.transaction(work) }
        }

        await depot.waitForPendingObservations()
        #expect(updates.withLock { $0 } == 0)
        #expect(try await depot.get(valueFor: validKey) == 7)
        #expect(try await depot.get(valueFor: target) == 42)
        if variant.memoryOnly {
            #expect(calls.withLock { $0 } == 0)
        }
    }

    @Test("memory-only transactions on pattern-covered keys skip coders and honor expiry")
    func memoryOnlyPatternTransaction() async throws {
        let clock = MockClock()
        let depot = Depot(configuration: .inMemory(), overrides: .init(clock: clock))
        let calls = OSAllocatedUnfairLock(initialState: 0)
        depot.register(key: Key.from("items" / .wildcard), coder: CountingCoder(calls: calls), expiry: .seconds(5))
        let key = Key.from("items" / "entry", as: Int.self)

        try await depot.transaction { transaction in
            try transaction.set(value: 42, for: key)
            #expect(try transaction.get(valueFor: key) == 42)
        }
        #expect(try await depot.get(valueFor: key) == 42)

        clock.advance(by: 5)
        #expect(try await depot.get(valueFor: key) == nil)

        try await depot.transaction { transaction in
            try transaction.set(value: nil, for: key)
        }
        #expect(calls.withLock { $0 } == 0)
    }
}
