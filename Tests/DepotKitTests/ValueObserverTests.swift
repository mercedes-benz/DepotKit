// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

@Suite
struct ValueObserverTests {
    // MARK: - Single Value

    @Test("single value observer delivers initial value")
    func singleValueInitial() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "name", coder: .json() as AnyCoder<String>)
        try await depot.set(value: "Alice", for: key)

        let stream = depot.values(for: key, initialValue: true)
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()

        guard case .success(let value) = first else {
            Issue.record("Expected .success")
            return
        }
        #expect(value == "Alice")
    }

    @Test("single value observer delivers updates")
    func singleValueUpdate() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "name", coder: .json() as AnyCoder<String>)

        let stream = depot.values(for: key, initialValue: false)
        let task = Task {
            var values = [String]()
            for await case .success(let v?) in stream {
                values.append(v)
                if values.count >= 2 { break }
            }
            return values
        }

        try await depot.set(value: "Bob", for: key)
        await depot.waitForPendingObservations()
        try await depot.set(value: "Charlie", for: key)
        await depot.waitForPendingObservations()

        let values = await task.value
        #expect(values == ["Bob", "Charlie"])
    }

    @Test("single value observer delivers absent on removal")
    func singleValueRemoval() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "val", coder: .json() as AnyCoder<String>)
        try await depot.set(value: "exists", for: key)

        let stream = depot.values(for: key, initialValue: false)
        let task = Task {
            for await result in stream {
                return result
            }
            return Result<String?, Error>.success(nil)
        }

        try await depot.remove(valueFor: key)
        await depot.waitForPendingObservations()

        let result = await task.value
        #expect(try result.get() == nil)
    }

    @Test("single value observer can be cancelled")
    func singleValueCancellation() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "val", coder: .json() as AnyCoder<Int>)

        let stream = depot.values(for: key, initialValue: false)
        let task = Task {
            var count = 0
            for await _ in stream {
                count += 1
            }
            return count
        }

        task.cancel()
        let count = await task.value
        #expect(count == 0)
    }

    // MARK: - Multi Value

    @Test("multi value observer delivers initial values")
    func multiValueInitial() async throws {
        let depot = Depot.temporary()
        let pattern = depot.register(
            key: Key.from("items" / .wildcard),
            coder: .json() as AnyCoder<String>,
        )
        let keyA = Key.from("items" / "a", as: String.self)
        let keyB = Key.from("items" / "b", as: String.self)
        try await depot.set(value: "alpha", for: keyA)
        try await depot.set(value: "beta", for: keyB)

        let stream = depot.values(for: pattern, initialValues: true)
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()

        guard case .success(let values) = first else {
            Issue.record("Expected success")
            return
        }
        #expect(Set(values) == ["alpha", "beta"])
    }

    @Test("multi value observer delivers on add")
    func multiValueOnAdd() async throws {
        let depot = Depot.temporary()
        let pattern = depot.register(
            key: Key.from("items" / .wildcard),
            coder: .json() as AnyCoder<String>,
        )

        let stream = depot.values(for: pattern, initialValues: false)
        let task = Task {
            for await case .success(let values) in stream {
                return values
            }
            return [String]()
        }

        let keyA = Key.from("items" / "a", as: String.self)
        try await depot.set(value: "new", for: keyA)
        await depot.waitForPendingObservations()

        let values = await task.value
        #expect(values == ["new"])
    }

    // MARK: - Available Values

    @Test("available values observer includes errors for bad entries")
    func availableValuesWithErrors() async throws {
        let depot = Depot.temporary()
        let pattern = depot.register(
            key: Key.from("data" / .wildcard),
            coder: .json() as AnyCoder<Int>,
        )
        let keyGood = Key.from("data" / "good", as: Int.self)
        try await depot.set(value: 42, for: keyGood)

        // Write invalid data
        let keyBad = DistinctKey(["data", "bad"].map { KeyComponent.segment(identifier: $0) })
        let fileURL = try depot.fileURL(for: keyBad)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try Data("broken".utf8).write(to: fileURL, options: .atomic)

        let stream = depot.availableValues(for: pattern, initialValues: true)
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()

        guard case .success(let result) = first else {
            Issue.record("Expected success")
            return
        }
        #expect(result.values == [42])
        #expect(result.errors.count == 1)
    }

    // MARK: - Transaction Coalescing

    @Test("transaction coalesces notifications for observers")
    func transactionCoalesces() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "counter", coder: .json() as AnyCoder<Int>)
        try await depot.set(value: 0, for: key)

        let received = OSAllocatedUnfairLock<[Int]>(initialState: [])
        let stream = depot.values(for: key, initialValue: false)
        let task = Task {
            for await case .success(let v?) in stream {
                received.withLock { $0.append(v) }
            }
        }

        try await depot.transaction { transaction in
            try transaction.set(value: 1, for: key)
            try transaction.set(value: 2, for: key)
            try transaction.set(value: 3, for: key)
        }

        await depot.waitForPendingObservations()
        #expect(await waitUntil { received.withLock { !$0.isEmpty } })
        task.cancel()
        await task.value

        let values = received.withLock { $0 }
        // Transaction should coalesce: observer only notified once (reads final value)
        #expect(values.count == 1)
        #expect(values.first == 3)
    }

    // MARK: - Observer Cleanup

    @Test("cancelled observers are cleaned up")
    func observerCleanup() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "val", coder: .json() as AnyCoder<String>)

        let stream = depot.values(for: key, initialValue: false)
        let task = Task {
            for await _ in stream { break }
        }
        task.cancel()
        await task.value

        // Trigger observer pruning by writing
        try await depot.set(value: "trigger", for: key)
        await depot.waitForPendingObservations()
        // No crash = observers were cleaned up
    }
}
