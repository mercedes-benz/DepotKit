// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

@Suite
struct TransactionFileBackedTests {
    @Test("file-backed transaction read-modify-write")
    func readModifyWrite() throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "counter", coder: .json() as AnyCoder<Int>)
        try depot.set(value: 10, for: key)

        try depot.transaction { transaction in
            let current = try transaction.get(valueFor: key) ?? 0
            try transaction.set(value: current + 5, for: key)
        }

        let result = try depot.get(valueFor: key)
        #expect(result == 15)
    }

    @Test("file-backed transaction multiple sets and removes")
    func multipleOps() throws {
        let depot = Depot.temporary()
        let keyA = depot.register(keyPath: "a", coder: .json() as AnyCoder<String>)
        let keyB = depot.register(keyPath: "b", coder: .json() as AnyCoder<String>)
        let keyC = depot.register(keyPath: "c", coder: .json() as AnyCoder<String>)

        try depot.set(value: "old-a", for: keyA)
        try depot.set(value: "old-b", for: keyB)
        try depot.set(value: "old-c", for: keyC)

        try depot.transaction { transaction in
            try transaction.set(value: "new-a", for: keyA)
            try transaction.remove(valueFor: keyB)
            try transaction.set(value: "new-c", for: keyC)
        }

        #expect(try depot.get(valueFor: keyA) == "new-a")
        #expect(try depot.get(valueFor: keyB) == nil)
        #expect(try depot.get(valueFor: keyC) == "new-c")
    }

    @Test("file-backed transaction remove with pattern key")
    func removeWithPattern() throws {
        let depot = Depot.temporary()
        let pattern = depot.register(
            key: Key.from("items" / .wildcard),
            coder: .json() as AnyCoder<String>,
        )
        let keyA = Key.from("items" / "a", as: String.self)
        let keyB = Key.from("items" / "b", as: String.self)
        try depot.set(value: "x", for: keyA)
        try depot.set(value: "y", for: keyB)

        try depot.transaction { transaction in
            try transaction.remove(valuesFor: Key.from("items" / .wildcard))
        }

        let remaining = try depot.get(valuesFor: pattern)
        #expect(remaining.isEmpty)
    }

    @Test("file-backed transaction removeAll")
    func removeAll() throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "val", coder: .json() as AnyCoder<Int>)
        try depot.set(value: 1, for: key)

        try depot.transaction { transaction in
            try transaction.removeAll()
        }

        #expect(try depot.get(valueFor: key) == nil)
    }

    @Test("file-backed transaction on read-only depot throws")
    func readOnlyThrows() throws {
        let depot = Depot(
            configuration: .init(
                directoryURL: FileManager.default.temporaryDirectory.appending(component: UUID().uuidString),
                readOnly: true
            )
        )
        let key = depot.register(keyPath: "val", coder: .json() as AnyCoder<Int>)

        #expect(throws: DepotError.self) {
            try depot.transaction { transaction in
                try transaction.set(value: 1, for: key)
            }
        }
    }

    @Test("file-backed transaction with reserved key throws")
    func reservedKeyThrows() throws {
        let depot = Depot.temporary()
        let reservedKey = TypedDistinctKey<String>(
            DistinctKey([KeyComponent.segment(identifier: "\(Depot.HiddenKeyPrefix)META")])
        )

        #expect(throws: DepotError.self) {
            try depot.transaction { transaction in
                try transaction.set(value: "x", for: reservedKey)
            }
        }
    }

    @Test("file-backed transaction where closure throws rolls back all mutations")
    func rollbackOnThrow() throws {
        let depot = Depot.temporary()
        let keyA = depot.register(keyPath: "a", coder: .json() as AnyCoder<String>)
        let keyB = depot.register(keyPath: "b", coder: .json() as AnyCoder<String>)

        do {
            try depot.transaction { transaction in
                try transaction.set(value: "written", for: keyA)
                throw TestTransactionError.forced
            }
        } catch is TestTransactionError {
            // expected
        }

        // Nothing persisted — the transaction rolled back
        #expect(try depot.get(valueFor: keyA) == nil)
        #expect(try depot.get(valueFor: keyB) == nil)
    }

    @Test("file-backed transaction returns closure value")
    func returnsClosureValue() throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "val", coder: .json() as AnyCoder<Int>)
        try depot.set(value: 5, for: key)

        let result = try depot.transaction { transaction in
            let v = try transaction.get(valueFor: key) ?? 0
            try transaction.set(value: v * 2, for: key)
            return v * 2
        }

        #expect(result == 10)
    }

    @Test("file-backed transaction get valuesFor")
    func transactionGetValuesFor() throws {
        let depot = Depot.temporary()
        let pattern = depot.register(
            key: Key.from("nums" / .wildcard),
            coder: .json() as AnyCoder<Int>,
        )
        let key1 = Key.from("nums" / "1", as: Int.self)
        let key2 = Key.from("nums" / "2", as: Int.self)
        try depot.set(value: 10, for: key1)
        try depot.set(value: 20, for: key2)

        try depot.transaction { transaction in
            let values = try transaction.get(valuesFor: pattern)
            #expect(Set(values) == [10, 20])
        }
    }

    @Test("file-backed transaction has valuesFor")
    func transactionHas() throws {
        let depot = Depot.temporary()
        _ = depot.register(key: Key.from("x" / .wildcard), coder: .json() as AnyCoder<String>)
        let key = Key.from("x" / "a", as: String.self)
        try depot.set(value: "v", for: key)

        try depot.transaction { transaction in
            let has = try transaction.has(valuesFor: Key.from("x" / .wildcard))
            #expect(has == true)
            let hasMissing = try transaction.has(valuesFor: Key.from("y" / .wildcard))
            #expect(hasMissing == false)
        }
    }

    @Test("file-backed transaction remove distinct key")
    func removeDistinctKey() throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "item", coder: .json() as AnyCoder<String>)
        try depot.set(value: "val", for: key)

        try depot.transaction { transaction in
            try transaction.remove(valueFor: key)
        }

        #expect(try depot.get(valueFor: key) == nil)
    }

    @Test("file-backed transaction set nil removes value")
    func setNilRemoves() throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "val", coder: .json() as AnyCoder<String>)
        try depot.set(value: "exists", for: key)

        try depot.transaction { transaction in
            try transaction.set(value: nil, for: key)
        }

        #expect(try depot.get(valueFor: key) == nil)
    }

    @Test("async transaction roundtrip")
    func asyncTransaction() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "counter", coder: .json() as AnyCoder<Int>)
        try await depot.set(value: 0, for: key)

        let result = try await depot.transaction { transaction in
            let v = try transaction.get(valueFor: key) ?? 0
            try transaction.set(value: v + 1, for: key)
            return v + 1
        }

        #expect(result == 1)
    }

    @Test("async modify convenience")
    func asyncModify() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "counter", coder: .json() as AnyCoder<Int>)
        try await depot.set(value: 3, for: key)

        let result = try await depot.modify(valueFor: key) { .update(($0 ?? 0) * 2) }
        #expect(result == 6)
    }

    @Test("transaction with memory cache populated")
    func transactionWithCache() throws {
        let depot = Depot.temporary(memoryCache: .default)
        let key = depot.register(keyPath: "cached", coder: .json() as AnyCoder<Int>)
        try depot.set(value: 1, for: key)
        // Populate cache
        _ = try depot.get(valueFor: key)

        try depot.transaction { transaction in
            let v = try transaction.get(valueFor: key)
            #expect(v == 1)
            try transaction.set(value: 2, for: key)
        }

        #expect(try depot.get(valueFor: key) == 2)
    }
}

private enum TestTransactionError: Error {
    case forced
}
