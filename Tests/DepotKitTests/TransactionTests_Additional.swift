// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

@Suite("Transaction additional coverage")
struct TransactionTests_Additional {
    @Test("empty transaction does not notify observers")
    func emptyTransactionDoesNotNotify() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "x", coder: .json() as AnyCoder<Int>)
        try await depot.set(value: 1, for: key)

        let notified = OSAllocatedUnfairLock(initialState: false)
        let stream: AsyncStream<Result<Int?, Error>> = depot.values(for: key, initialValue: false)
        let task = Task {
            for await _ in stream {
                notified.withLock { $0 = true }
            }
        }

        try await depot.transaction { _ in
            // no mutations
        }

        await depot.waitForPendingObservations()
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await task.value
        #expect(!notified.withLock { $0 })
    }

    @Test("transaction with only reads does not notify")
    func transactionWithOnlyReads() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "x", coder: .json() as AnyCoder<Int>)
        try await depot.set(value: 42, for: key)

        let notified = OSAllocatedUnfairLock(initialState: false)
        let stream: AsyncStream<Result<Int?, Error>> = depot.values(for: key, initialValue: false)
        let task = Task {
            for await _ in stream {
                notified.withLock { $0 = true }
            }
        }

        try await depot.transaction { transaction in
            _ = try transaction.get(valueFor: key)
        }

        await depot.waitForPendingObservations()
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await task.value
        #expect(!notified.withLock { $0 })
    }

    @Test("transaction mutations are discarded when closure throws")
    func transactionMutationsDiscardedOnThrow() async throws {
        let depot = Depot.temporary()
        let key = depot.register(keyPath: "persist", coder: .json() as AnyCoder<String>)

        struct Deliberate: Error {}

        do {
            try await depot.transaction { transaction in
                try transaction.set(value: "written", for: key)
                throw Deliberate()
            }
        } catch is Deliberate {}

        let value = try await depot.get(valueFor: key)
        #expect(value == nil)
    }

    @Test("removeAll then set notifies observers for removed keys")
    func removeAllThenSetNotifiesRemovedKeys() async throws {
        let depot = Depot.temporary()

        let keyA = depot.register(keyPath: "items" / "A", coder: .data(String.self))
        let keyB = depot.register(keyPath: "items" / "B", coder: .data(String.self))

        // Pre-populate both keys
        try await depot.set(value: "alpha", for: keyA)
        try await depot.set(value: "beta", for: keyB)

        // Observe keyB — it should be notified of removal even after a subsequent set on keyA
        let keyBNotified = OSAllocatedUnfairLock(initialState: false)
        let stream: AsyncStream<Result<String?, Error>> = depot.values(for: keyB, initialValue: false)
        let task = Task {
            for await _ in stream {
                keyBNotified.withLock { $0 = true }
            }
        }

        // Transaction: removeAll (clears both), then set keyA only
        try await depot.transaction { transaction in
            try transaction.remove(valuesFor: Key.all)
            try transaction.set(value: "new-alpha", for: keyA)
        }

        await depot.waitForPendingObservations()
        task.cancel()
        await task.value

        // keyB observer must have been notified (removeAll happened)
        #expect(
            keyBNotified.withLock { $0 },
            "Observer for keyB must be notified after removeAll, even if set was called afterward"
        )

        // keyA should have the new value, keyB should be gone
        let valueA = try await depot.get(valueFor: keyA)
        let valueB = try await depot.get(valueFor: keyB)
        #expect(valueA == "new-alpha")
        #expect(valueB == nil)
    }
}
