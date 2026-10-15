// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

private final class TransactionTestConfiguration {
    let depotURL: URL

    init() {
        depotURL = try! DepotConfiguration.directoryURL(
            in: .caches,
            name: "TransactionTests-\(UUID().uuidString)",
        )
    }

    deinit {
        let depotURL = depotURL

        Task { @concurrent in
            do {
                try FileManager.default.removeItem(at: depotURL)
            } catch {
                // ignore
            }
        }
    }
}

@Suite
struct TransactionTests {
    @Test("coalesces observer updates (sync)")
    func coalescesObserverUpdatesSyncDepot() async throws {
        let depot = Depot.temporary()

        let itemsKey = depot.register(
            key: Key.from("items" / .wildcard),
            coder: .data(String.self),
        )

        let keyA = Key.from("items" / "A", as: String.self)
        let keyB = Key.from("items" / "B", as: String.self)

        let receivedValues = OSAllocatedUnfairLock<[[String]]>(initialState: [])

        let stream = depot.values(for: itemsKey, initialValues: false)
        let task = Task {
            for await result in stream {
                switch result {
                case let .success(values):
                    receivedValues.withLock { $0.append(values.sorted()) }
                case .failure:
                    Issue.record()
                }
            }
        }

        try await depot.transaction { transaction in
            try transaction.set(value: "a", for: keyA)
            try transaction.set(value: "b", for: keyB)
        }

        await depot.waitForPendingObservations()
        #expect(await waitUntil { receivedValues.withLock { !$0.isEmpty } })
        task.cancel()
        await task.value

        #expect(receivedValues.withLock { $0 } == [["a", "b"]])
    }

    @Test("notifies on removing a missing distinct key (sync)")
    func notifiesOnRemovingMissingKeySyncDepot() async throws {
        let depot = Depot.temporary()

        let statusKey = depot.register(
            key: Key.from("entity" / .wildcard / "status"),
            coder: .data(String.self),
        )

        let existingKey = Key.from("entity" / "B" / "status", as: String.self)
        let missingKey = Key.from("entity" / "A" / "status", as: String.self)

        let receivedValues = OSAllocatedUnfairLock<[[String]]>(initialState: [])

        let stream = depot.values(for: statusKey, initialValues: false)
        let task = Task {
            for await result in stream {
                switch result {
                case let .success(values):
                    receivedValues.withLock { $0.append(values.sorted()) }
                case .failure:
                    Issue.record()
                }
            }
        }

        try await depot.set(value: "2", for: existingKey)
        await depot.waitForPendingObservations()
        #expect(await waitUntil { receivedValues.withLock { !$0.isEmpty } })
        receivedValues.withLock { $0.removeAll() }

        try await depot.transaction { transaction in
            try transaction.remove(valuesFor: missingKey)
        }

        await depot.waitForPendingObservations()
        #expect(await waitUntil { receivedValues.withLock { !$0.isEmpty } })
        task.cancel()
        await task.value

        #expect(receivedValues.withLock { $0 } == [["2"]])
    }

    @Test("coalesces observer updates (async Depot transaction)")
    func coalescesObserverUpdatesInAsyncDepot() async throws {
        let testConfiguration = TransactionTestConfiguration()

        let depot = Depot(configuration: .init(directoryURL: testConfiguration.depotURL, memoryCache: .disabled))

        let itemsKey = depot.register(
            key: Key.from("items" / .wildcard),
            coder: .data(String.self),
        )

        let keyA = Key.from("items" / "A", as: String.self)
        let keyB = Key.from("items" / "B", as: String.self)

        let receivedValues = OSAllocatedUnfairLock<[[String]]>(initialState: [])

        let stream = depot.values(for: itemsKey, initialValues: false)
        let task = Task {
            for await result in stream {
                switch result {
                case let .success(values):
                    receivedValues.withLock { $0.append(values.sorted()) }
                case .failure:
                    Issue.record()
                }
            }
        }

        try await depot.transaction { transaction in
            try transaction.set(value: "a", for: keyA)
            try transaction.set(value: "b", for: keyB)
        }

        await depot.waitForPendingObservations()
        #expect(await waitUntil { receivedValues.withLock { !$0.isEmpty } })
        task.cancel()
        await task.value

        #expect(receivedValues.withLock { $0 } == [["a", "b"]])
    }

    // MARK: - Rollback on throw

    @Test("mutations before throw are rolled back (sync)")
    func mutationsBeforeThrowAreRolledBackSyncDepot() throws {
        let depot = Depot.temporary()

        let keyA = depot.register(key: Key.from("a"), coder: .data(String.self))
        let keyB = depot.register(key: Key.from("b"), coder: .data(String.self))

        struct ExpectedError: Error {}

        // The transaction sets "a" then throws before setting "b".
        // The transaction rolls back: "a" must not be persisted.
        #expect(throws: ExpectedError.self) {
            try depot.transaction { transaction in
                try transaction.set(value: "committed", for: keyA)
                throw ExpectedError()
            }
        }

        #expect(try depot.get(valueFor: keyA) == nil, "Mutations before throw must be rolled back")
        #expect(try depot.get(valueFor: keyB) == nil, "Keys not touched in transaction must remain nil")
    }

    @Test("mutations before throw are rolled back (Depot)")
    func mutationsBeforeThrowAreRolledBackInDepot() throws {
        let testConfiguration = TransactionTestConfiguration()
        let depot = Depot(configuration: .init(directoryURL: testConfiguration.depotURL, memoryCache: .disabled))

        let keyA = depot.register(key: Key.from("x"), coder: .data(String.self))
        let keyB = depot.register(key: Key.from("y"), coder: .data(String.self))

        struct ExpectedError: Error {}

        #expect(throws: ExpectedError.self) {
            try depot.transaction { transaction in
                try transaction.set(value: "persisted", for: keyA)
                throw ExpectedError()
            }
        }

        #expect(try depot.get(valueFor: keyA) == nil, "Mutations before throw must be rolled back")
        #expect(try depot.get(valueFor: keyB) == nil, "Keys not touched in transaction must remain nil")
    }
}
