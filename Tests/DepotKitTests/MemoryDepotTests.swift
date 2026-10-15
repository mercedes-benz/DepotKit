// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

private struct CrashingCoder: Coder {
    typealias Value = String
    func encode(_ value: String) throws -> Data {
        fatalError("Coder should not be invoked in memory-only mode")
    }

    func decode(_ data: Data) throws -> String {
        fatalError("Coder should not be invoked in memory-only mode")
    }
}

@Suite("Memory-only Depot")
struct MemoryDepotTests {
    private func makeDepot(label: String = "Test") -> Depot {
        Depot(label: label)
    }

    @Test
    func storesAndRetrievesValues() throws {
        let depot = makeDepot()
        let key = depot.register(keyPath: "greeting", coder: .json() as AnyCoder<String>)

        try depot.set(value: "hello", for: key)
        let result = try depot.get(valueFor: key)

        #expect(result == "hello")
    }

    @Test
    func returnsNilForMissingKey() throws {
        let depot = makeDepot()
        let key = depot.register(keyPath: "missing", coder: .json() as AnyCoder<Int>)

        let result = try depot.get(valueFor: key)

        #expect(result == nil)
    }

    @Test
    func overwritesExistingValue() throws {
        let depot = makeDepot()
        let key = depot.register(keyPath: "counter", coder: .json() as AnyCoder<Int>)

        try depot.set(value: 1, for: key)
        try depot.set(value: 2, for: key)
        let result = try depot.get(valueFor: key)

        #expect(result == 2)
    }

    @Test
    func removesValueBySettingNil() throws {
        let depot = makeDepot()
        let key = depot.register(keyPath: "temp", coder: .json() as AnyCoder<String>)

        try depot.set(value: "exists", for: key)
        try depot.set(value: nil, for: key)
        let result = try depot.get(valueFor: key)

        #expect(result == nil)
    }

    @Test
    func removesValuesForKey() throws {
        let depot = makeDepot()
        let key = depot.register(keyPath: "item", coder: .json() as AnyCoder<String>)

        try depot.set(value: "value", for: key)
        try depot.remove(valuesFor: key)
        let result = try depot.get(valueFor: key)

        #expect(result == nil)
    }

    @Test
    func hasValuesReturnsCorrectly() throws {
        let depot = makeDepot()
        let key = depot.register(keyPath: "check", coder: .json() as AnyCoder<Bool>)

        #expect(try depot.has(valuesFor: key) == false)

        try depot.set(value: true, for: key)

        #expect(try depot.has(valuesFor: key) == true)
    }

    @Test
    func getValuesForPatternKey() throws {
        let depot = makeDepot()
        let pattern = depot.register(
            key: Key.from("users" / .wildcard / "name"),
            coder: .json() as AnyCoder<String>,
        )
        let key1 = depot.register(keyPath: "users" / "alice" / "name", coder: .json() as AnyCoder<String>)
        let key2 = depot.register(keyPath: "users" / "bob" / "name", coder: .json() as AnyCoder<String>)

        try depot.set(value: "Alice", for: key1)
        try depot.set(value: "Bob", for: key2)

        let values = try depot.get(valuesFor: pattern)

        #expect(values.count == 2)
        #expect(values.contains("Alice"))
        #expect(values.contains("Bob"))
    }

    @Test
    func removeAll() throws {
        let depot = makeDepot()
        let key1 = depot.register(keyPath: "a", coder: .json() as AnyCoder<Int>)
        let key2 = depot.register(keyPath: "b", coder: .json() as AnyCoder<Int>)

        try depot.set(value: 1, for: key1)
        try depot.set(value: 2, for: key2)
        try depot.removeAll()

        #expect(try depot.get(valueFor: key1) == nil)
        #expect(try depot.get(valueFor: key2) == nil)
    }

    @Test
    func resetClearsAllEntries() throws {
        let depot = makeDepot()
        let key = depot.register(keyPath: "data", coder: .json() as AnyCoder<String>)

        try depot.set(value: "stored", for: key)
        try depot.reset()

        #expect(try depot.get(valueFor: key) == nil)
    }

    @Test
    func readOnlyThrowsOnWrite() throws {
        let config = DepotConfiguration(directoryURL: nil, readOnly: true)
        let depot = Depot(label: "ReadOnly", configuration: config)
        let key = depot.register(keyPath: "locked", coder: .json() as AnyCoder<String>)

        #expect(throws: DepotError.self) {
            try depot.set(value: "nope", for: key)
        }
    }

    @Test
    func mismatchedTypeThrows() throws {
        let depot = makeDepot()
        let stringKey = depot.register(keyPath: "typed", coder: .json() as AnyCoder<String>)
        try depot.set(value: "hello", for: stringKey)

        let intKey = depot.register(keyPath: "typed", coder: .json() as AnyCoder<Int>)

        #expect(throws: DepotError.self) {
            _ = try depot.get(valueFor: intKey)
        }
    }

    @Test
    func codersAreNotInvoked() throws {
        let depot = makeDepot()
        let key = depot.register(keyPath: "custom", coder: CrashingCoder())

        try depot.set(value: "hello", for: key)
        let retrieved = try depot.get(valueFor: key)

        #expect(retrieved == "hello")
    }

    @Test
    func verifyIntegrityIsNoOp() throws {
        let depot = makeDepot()
        try depot.verifyIntegrity()
    }

    @Test
    func addFilePresenterIsNoOp() throws {
        let depot = makeDepot()
        try depot.addFilePresenter()
    }

    @Test
    func checkForExternalChangesIsNoOp() throws {
        let depot = makeDepot()
        try depot.checkForExternalChanges()
    }

    @Test
    func diskUsageReturnsZero() throws {
        let depot = makeDepot()
        let key = depot.register(keyPath: "data", coder: .json() as AnyCoder<String>)
        try depot.set(value: "something", for: key)

        let usage = try depot.diskUsage()

        #expect(usage.fileCount == 0)
        #expect(usage.totalBytes == 0)
    }

    @Test
    func configurationReportsMemoryOnly() {
        let config = DepotConfiguration.inMemory()

        #expect(config.isFileBacked == false)
        #expect(config.cacheInMemory == false)
        #expect(config.directoryURL == nil)
    }

    @Test
    func transactionWorksInMemoryMode() throws {
        let depot = makeDepot()
        let key = depot.register(keyPath: "counter", coder: .json() as AnyCoder<Int>)

        try depot.set(value: 0, for: key)

        try depot.transaction { transaction in
            let current = try transaction.get(valueFor: key) ?? 0
            try transaction.set(value: current + 1, for: key)
        }

        #expect(try depot.get(valueFor: key) == 1)
    }

    @Test
    func transactionRemoveAllInMemoryMode() throws {
        let depot = makeDepot()
        let key1 = depot.register(keyPath: "x", coder: .json() as AnyCoder<Int>)
        let key2 = depot.register(keyPath: "y", coder: .json() as AnyCoder<Int>)

        try depot.set(value: 1, for: key1)
        try depot.set(value: 2, for: key2)

        try depot.transaction { transaction in
            try transaction.removeAll()
        }

        #expect(try depot.get(valueFor: key1) == nil)
        #expect(try depot.get(valueFor: key2) == nil)
    }

    @Test
    func asyncOperations() async throws {
        let depot = makeDepot()
        let key = depot.register(keyPath: "async", coder: .json() as AnyCoder<String>)

        try await depot.set(value: "world", for: key)
        let result = try await depot.get(valueFor: key)

        #expect(result == "world")
    }

    @Test
    func observationDeliversUpdates() async throws {
        let depot = makeDepot()
        let key = depot.register(keyPath: "observed", coder: .json() as AnyCoder<Int>)

        try await depot.set(value: 0, for: key)

        let stream = depot.values(for: key, initialValue: true)
        var iterator = stream.makeAsyncIterator()

        let initial = await iterator.next()
        #expect(try initial?.get() == 0)

        try await depot.set(value: 42, for: key)

        let updated = await iterator.next()
        #expect(try updated?.get() == 42)
    }

    @Test
    func availableValuesForPattern() throws {
        let depot = makeDepot()
        let pattern = depot.register(
            key: Key.from("items" / .wildcard),
            coder: .json() as AnyCoder<Int>,
        )
        let key1 = depot.register(keyPath: "items" / "a", coder: .json() as AnyCoder<Int>)
        let key2 = depot.register(keyPath: "items" / "b", coder: .json() as AnyCoder<Int>)

        try depot.set(value: 10, for: key1)
        try depot.set(value: 20, for: key2)

        let result = try depot.get(availableValuesFor: pattern)

        #expect(result.values.count == 2)
        #expect(result.errors.isEmpty)
    }

    @Test
    func modifyInMemoryMode() async throws {
        let depot = makeDepot()
        let key = depot.register(keyPath: "count", coder: .json() as AnyCoder<Int>)

        try await depot.set(value: 5, for: key)

        let newValue = try await depot.modify(valueFor: key) { .update(($0 ?? 0) + 10) }

        #expect(newValue == 15)
    }

    @Test
    func encryptionConfigurationIsIgnored() throws {
        let encryption = try EncryptionConfiguration(
            cipher: .chaChaPoly,
            hashFunction: .sha256,
            key: EncryptionConfiguration.generateKey(),
        )

        let depot = Depot(
            label: "EncryptedMemory",
            configuration: DepotConfiguration(directoryURL: nil, encryption: encryption)
        )
        let key = depot.register(keyPath: "secret", coder: .json() as AnyCoder<String>)

        try depot.set(value: "plaintext", for: key)
        let result = try depot.get(valueFor: key)

        #expect(result == "plaintext")
    }

    @Test("transaction isolates from concurrent writes")
    func transactionIsolation() async throws {
        let depot = makeDepot()
        let key = depot.register(keyPath: "counter", coder: .json() as AnyCoder<Int>)
        try await depot.set(value: 0, for: key)

        let iterations = 100

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    do {
                        try depot.transaction { tx in
                            let current = try tx.get(valueFor: key) ?? 0
                            try tx.set(value: current + 1, for: key)
                        }
                    } catch {
                        Issue.record("Transaction failed: \(error)")
                    }
                }
            }
        }

        let final = try await depot.get(valueFor: key)
        #expect(final == iterations)
    }
}
