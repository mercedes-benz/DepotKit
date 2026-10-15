// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

@Suite("count(for:)")
struct CountTests {
    // MARK: - Basic Count

    @Test("Returns 0 when no values match the pattern")
    func countReturnsZeroWhenEmpty() throws {
        let depot = Depot.temporary()
        let pattern = depot.register(
            key: Key.from("users" / .wildcard / "name"),
            coder: .json() as AnyCoder<String>,
        )

        let count = try depot.count(for: pattern)
        #expect(count == 0)
    }

    @Test("Counts values after setting them")
    func countAfterSets() throws {
        let depot = Depot.temporary()
        let pattern = depot.register(
            key: Key.from("users" / .wildcard / "name"),
            coder: .json() as AnyCoder<String>,
        )

        let key1 = depot.register(key: Key.from("users" / "alice" / "name"), coder: .json() as AnyCoder<String>)
        let key2 = depot.register(key: Key.from("users" / "bob" / "name"), coder: .json() as AnyCoder<String>)
        let key3 = depot.register(key: Key.from("users" / "charlie" / "name"), coder: .json() as AnyCoder<String>)

        try depot.set(value: "Alice", for: key1)
        try depot.set(value: "Bob", for: key2)
        try depot.set(value: "Charlie", for: key3)

        let count = try depot.count(for: pattern)
        #expect(count == 3)
    }

    @Test("Wildcard matches single component")
    func countWithWildcard() throws {
        let depot = Depot.temporary()
        let pattern = depot.register(
            key: Key.from("items" / .wildcard),
            coder: .json() as AnyCoder<Int>,
        )

        let key1 = depot.register(key: Key.from("items" / "a"), coder: .json() as AnyCoder<Int>)
        let key2 = depot.register(key: Key.from("items" / "b"), coder: .json() as AnyCoder<Int>)
        // This should NOT match the wildcard (nested too deep)
        let keyDeep = depot.register(key: Key.from("items" / "c" / "nested"), coder: .json() as AnyCoder<Int>)

        try depot.set(value: 1, for: key1)
        try depot.set(value: 2, for: key2)
        try depot.set(value: 3, for: keyDeep)

        let count = try depot.count(for: pattern)
        #expect(count == 2)
    }

    @Test("Globstar matches zero or more components")
    func countWithGlobstar() throws {
        let depot = Depot.temporary()
        let pattern = depot.register(
            key: Key.from("cache" / .globstar),
            coder: .json() as AnyCoder<String>,
        )

        let key1 = depot.register(key: Key.from("cache" / "a"), coder: .json() as AnyCoder<String>)
        let key2 = depot.register(key: Key.from("cache" / "b" / "c"), coder: .json() as AnyCoder<String>)
        let key3 = depot.register(key: Key.from("cache" / "d" / "e" / "f"), coder: .json() as AnyCoder<String>)
        // This should NOT match (different prefix)
        let keyOther = depot.register(key: Key.from("other" / "x"), coder: .json() as AnyCoder<String>)

        try depot.set(value: "1", for: key1)
        try depot.set(value: "2", for: key2)
        try depot.set(value: "3", for: key3)
        try depot.set(value: "4", for: keyOther)

        let count = try depot.count(for: pattern)
        #expect(count == 3)
    }

    @Test("Count decreases after removing values")
    func countAfterRemoval() throws {
        let depot = Depot.temporary()
        let pattern = depot.register(
            key: Key.from("data" / .wildcard),
            coder: .json() as AnyCoder<String>,
        )

        let key1 = depot.register(key: Key.from("data" / "one"), coder: .json() as AnyCoder<String>)
        let key2 = depot.register(key: Key.from("data" / "two"), coder: .json() as AnyCoder<String>)
        let key3 = depot.register(key: Key.from("data" / "three"), coder: .json() as AnyCoder<String>)

        try depot.set(value: "1", for: key1)
        try depot.set(value: "2", for: key2)
        try depot.set(value: "3", for: key3)

        #expect(try depot.count(for: pattern) == 3)

        try depot.remove(valueFor: key2)
        #expect(try depot.count(for: pattern) == 2)

        try depot.remove(valuesFor: pattern)
        #expect(try depot.count(for: pattern) == 0)
    }

    // MARK: - Async

    @Test("Async count works through semaphore")
    func asyncCount() async throws {
        let depot = Depot.temporary()
        let pattern = depot.register(
            key: Key.from("async" / .wildcard),
            coder: .json() as AnyCoder<Int>,
        )

        let key1 = depot.register(key: Key.from("async" / "a"), coder: .json() as AnyCoder<Int>)
        let key2 = depot.register(key: Key.from("async" / "b"), coder: .json() as AnyCoder<Int>)

        try await depot.set(value: 1, for: key1)
        try await depot.set(value: 2, for: key2)

        let count = try await depot.count(for: pattern)
        #expect(count == 2)
    }

    // MARK: - Transaction

    @Test("Transaction count includes buffered writes")
    func transactionCountIncludesBufferedWrites() throws {
        let depot = Depot.temporary()
        let pattern = depot.register(
            key: Key.from("tx" / .wildcard),
            coder: .json() as AnyCoder<String>,
        )

        let key1 = depot.register(key: Key.from("tx" / "a"), coder: .json() as AnyCoder<String>)
        let key2 = depot.register(key: Key.from("tx" / "b"), coder: .json() as AnyCoder<String>)
        let key3 = depot.register(key: Key.from("tx" / "c"), coder: .json() as AnyCoder<String>)

        try depot.set(value: "committed", for: key1)

        try depot.transaction { tx in
            // 1 committed value
            #expect(try tx.count(for: pattern) == 1)

            // Add buffered writes
            try tx.set(value: "buffered1", for: key2)
            #expect(try tx.count(for: pattern) == 2)

            try tx.set(value: "buffered2", for: key3)
            #expect(try tx.count(for: pattern) == 3)
        }
    }

    @Test("Transaction count excludes buffered removes")
    func transactionCountExcludesBufferedRemoves() throws {
        let depot = Depot.temporary()
        let pattern = depot.register(
            key: Key.from("txr" / .wildcard),
            coder: .json() as AnyCoder<String>,
        )

        let key1 = depot.register(key: Key.from("txr" / "a"), coder: .json() as AnyCoder<String>)
        let key2 = depot.register(key: Key.from("txr" / "b"), coder: .json() as AnyCoder<String>)

        try depot.set(value: "a", for: key1)
        try depot.set(value: "b", for: key2)

        try depot.transaction { tx in
            #expect(try tx.count(for: pattern) == 2)

            try tx.set(value: nil, for: key1)
            #expect(try tx.count(for: pattern) == 1)

            try tx.set(value: nil, for: key2)
            #expect(try tx.count(for: pattern) == 0)
        }
    }

    // MARK: - Memory-only Depot

    @Test("Count works with memory-only depot")
    func memoryOnlyCount() throws {
        let depot = Depot(configuration: .inMemory())
        let pattern = depot.register(
            key: Key.from("mem" / .wildcard),
            coder: .json() as AnyCoder<String>,
        )

        let key1 = depot.register(key: Key.from("mem" / "x"), coder: .json() as AnyCoder<String>)
        let key2 = depot.register(key: Key.from("mem" / "y"), coder: .json() as AnyCoder<String>)

        #expect(try depot.count(for: pattern) == 0)

        try depot.set(value: "x", for: key1)
        try depot.set(value: "y", for: key2)

        #expect(try depot.count(for: pattern) == 2)

        try depot.remove(valueFor: key1)
        #expect(try depot.count(for: pattern) == 1)
    }
}
