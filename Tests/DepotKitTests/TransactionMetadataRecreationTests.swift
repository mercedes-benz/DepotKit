// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// A transactional `removeAll()` whose metadata recreation fails must still apply the rest of the
/// commit, like ``Depot/reset()`` keeps the deletions: the metadata creation stays pending and is
/// retried by the transaction's own writes.
@Suite("Transactional removeAll with a failing metadata recreation", .offCooperativePool)
struct TransactionMetadataRecreationTests {
    typealias Support = BulkRemovalSupport

    private static func makeDepot(at url: URL, multiProcess: Bool, failure: InjectedFailure) -> Depot {
        var hooks = Depot.TestHooks()
        hooks.willRecreateMetadata = { throw failure }
        let depot = Support.makeDepot(at: url, multiProcess: multiProcess, hooks: hooks)
        depot.register(key: Key.all, coder: .json(String.self))
        return depot
    }

    private static func metadataExists(in depot: Depot) throws -> Bool {
        Support.fileExists(try #require(depot.metadataFileURL))
    }

    @Test("the buffered writes are applied, observed, and persisted", arguments: [false, true])
    func writesAfterRemoveAllAreApplied(multiProcess: Bool) async throws {
        let url = Support.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        let depot = Self.makeDepot(at: url, multiProcess: multiProcess, failure: InjectedFailure())

        let a = Key.from("items" / "a", as: String.self)
        let b = Key.from("items" / "b", as: String.self)
        let old = Key.from("items" / "old", as: String.self)
        try await depot.set(value: "old", for: old)
        try await depot.set(value: "previous a", for: a)

        var logs = [DeliveryLog<String?>]()
        var cancellables = [any DepotCancellable]()
        for key in [a, b, old] {
            let log = DeliveryLog<String?>()
            logs.append(log)
            cancellables.append(
                depot.core.observe(
                    valueFor: key,
                    initialValue: false,
                    update: { log.append(DeliveryLog.value(of: $0)) },
                    in: depot,
                )
            )
        }
        let patternLog = DeliveryLog<[String]>()
        cancellables.append(
            depot.core.observe(
                valuesFor: Key.from("items" / .wildcard, as: String.self),
                initialValues: false,
                update: { result in patternLog.append((try? result.get())?.sorted() ?? ["<error>"]) },
                in: depot,
            )
        )
        defer {
            for cancellable in cancellables {
                cancellable.cancel()
            }
        }

        try await depot.transaction { transaction in
            try transaction.removeAll()
            try transaction.set(value: "a", for: a)
            try transaction.set(value: "b", for: b)
        }

        #expect(try await depot.get(valueFor: a) == "a")
        #expect(try await depot.get(valueFor: b) == "b")
        #expect(try await depot.get(valueFor: old) == nil)

        await depot.waitForPendingObservations()
        #expect(logs.map(\.all) == [["a"], ["b"], [nil]], "one notification per observer with the committed state")
        #expect(patternLog.all == [["a", "b"]])

        // The transaction's writes created the pending metadata.
        #expect(try Self.metadataExists(in: depot))
        #expect(!depot.metadataCreationPending.withLock { $0 })
        try await depot.verifyIntegrity()

        let reopened = Support.makeDepot(at: url, multiProcess: multiProcess)
        reopened.register(key: Key.all, coder: .json(String.self))
        try await reopened.verifyIntegrity()
        #expect(try await reopened.get(valueFor: a) == "a")
        #expect(try await reopened.get(valueFor: b) == "b")
        #expect(try await reopened.get(valueFor: old) == nil)
    }

    @Test("a removeAll-only transaction succeeds and leaves the metadata creation pending")
    func removeAllOnlyLeavesCreationPending() async throws {
        let url = Support.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        let depot = Self.makeDepot(at: url, multiProcess: true, failure: InjectedFailure())
        let key = Key.from("items" / "a", as: String.self)
        try await depot.set(value: "a", for: key)

        try await depot.transaction { try $0.removeAll() }

        #expect(try await depot.get(valueFor: key) == nil)
        #expect(try !Self.metadataExists(in: depot))
        #expect(depot.metadataCreationPending.withLock { $0 })

        // Retried like after a reset: verifying creates the metadata of the empty store.
        try await depot.verifyIntegrity()
        #expect(try Self.metadataExists(in: depot))
    }
}
