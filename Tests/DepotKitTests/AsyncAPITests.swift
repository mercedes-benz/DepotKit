// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

@Suite
struct AsyncAPITests {
    @Test("async get returns nil for missing key")
    func asyncGetReturnsNil() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "value", coder: .json() as AnyCoder<String>)
        let result: String? = try await depot.get(valueFor: key)
        #expect(result == nil)
    }

    @Test("async set and get roundtrip")
    func asyncSetAndGet() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "name", coder: .json() as AnyCoder<String>)
        try await depot.set(value: "Alice", for: key)
        let result = try await depot.get(valueFor: key)
        #expect(result == "Alice")
    }

    @Test("async get with default returns default when nil")
    func asyncGetWithDefault() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "count", coder: .json() as AnyCoder<Int>)
        let result = try await depot.get(valueFor: key, default: 42)
        #expect(result == 42)
    }

    @Test("async get with default returns stored value when present")
    func asyncGetWithDefaultReturnsStored() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "count", coder: .json() as AnyCoder<Int>)
        try await depot.set(value: 7, for: key)
        let result = try await depot.get(valueFor: key, default: 42)
        #expect(result == 7)
    }

    @Test("async get valuesFor returns matching values")
    func asyncGetValuesFor() async throws {
        let depot = Depot.temporary()
        let pattern = depot.register(
            key: Key.from("items" / .wildcard),
            coder: .json() as AnyCoder<String>,
        )
        let keyA = Key.from("items" / "a", as: String.self)
        let keyB = Key.from("items" / "b", as: String.self)
        try await depot.set(value: "alpha", for: keyA)
        try await depot.set(value: "beta", for: keyB)
        let values = try await depot.get(valuesFor: pattern)
        #expect(Set(values) == ["alpha", "beta"])
    }

    @Test("async get availableValuesFor handles partial failures")
    func asyncGetAvailableValuesFor() async throws {
        let depot = Depot.temporary()
        let pattern = depot.register(
            key: Key.from("data" / .wildcard),
            coder: .json() as AnyCoder<Int>,
        )
        let keyGood = Key.from("data" / "good", as: Int.self)
        try await depot.set(value: 123, for: keyGood)

        // Write raw invalid data for another key
        let keyBad = DistinctKey(["data", "bad"].map { KeyComponent.segment(identifier: $0) })
        let fileURL = keyBad.getFileURL(from: depot.configuration.directoryURL!)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try Data("not json".utf8).write(to: fileURL, options: .atomic)

        let result = try await depot.get(availableValuesFor: pattern)
        #expect(result.values == [123])
        #expect(result.errors.count == 1)
    }

    @Test("async has returns true for existing key")
    func asyncHasValueFor() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "exists", coder: .json() as AnyCoder<Bool>)
        try await depot.set(value: true, for: key)
        let exists = try await depot.has(valueFor: key)
        #expect(exists == true)
    }

    @Test("async has returns false for missing key")
    func asyncHasMissing() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "missing", coder: .json() as AnyCoder<Bool>)
        let exists = try await depot.has(valueFor: key)
        #expect(exists == false)
    }

    @Test("async has valuesFor with pattern")
    func asyncHasValuesForPattern() async throws {
        let depot = Depot.temporary()
        _ = depot.register(key: Key.from("items" / .wildcard), coder: .json() as AnyCoder<String>)
        let key = Key.from("items" / "x", as: String.self)
        try await depot.set(value: "val", for: key)
        let has = try await depot.has(valuesFor: Key.from("items" / .wildcard))
        #expect(has == true)
    }

    @Test("async remove valueFor")
    func asyncRemoveValueFor() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "temp", coder: .json() as AnyCoder<String>)
        try await depot.set(value: "data", for: key)
        try await depot.remove(valueFor: key)
        let result: String? = try await depot.get(valueFor: key)
        #expect(result == nil)
    }

    @Test("async remove valuesFor with pattern")
    func asyncRemoveValuesFor() async throws {
        let depot = Depot.temporary()
        _ = depot.register(key: Key.from("cache" / .wildcard), coder: .json() as AnyCoder<String>)
        let keyA = Key.from("cache" / "a", as: String.self)
        let keyB = Key.from("cache" / "b", as: String.self)
        try await depot.set(value: "x", for: keyA)
        try await depot.set(value: "y", for: keyB)
        try await depot.remove(valuesFor: Key.from("cache" / .wildcard))
        let has = try await depot.has(valuesFor: Key.from("cache" / .wildcard))
        #expect(has == false)
    }

    @Test("async removeAll clears everything")
    func asyncRemoveAll() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "data", coder: .json() as AnyCoder<Int>)
        try await depot.set(value: 1, for: key)
        try await depot.removeAll()
        let result: Int? = try await depot.get(valueFor: key)
        #expect(result == nil)
    }

    @Test("async transaction roundtrip")
    func asyncTransaction() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "counter", coder: .json() as AnyCoder<Int>)
        try await depot.set(value: 0, for: key)

        let result = try await depot.transaction { transaction in
            let current = try transaction.get(valueFor: key) ?? 0
            try transaction.set(value: current + 1, for: key)
            return current + 1
        }

        #expect(result == 1)
        let stored = try await depot.get(valueFor: key)
        #expect(stored == 1)
    }

    @Test("async modify convenience")
    func asyncModify() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "counter", coder: .json() as AnyCoder<Int>)
        try await depot.set(value: 5, for: key)

        let newValue = try await depot.modify(valueFor: key) { .update(($0 ?? 0) + 10) }
        #expect(newValue == 15)
        let stored = try await depot.get(valueFor: key)
        #expect(stored == 15)
    }
}
