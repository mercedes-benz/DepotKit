// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// The internal metadata file is excluded from modification-date snapshots, so recreating it
/// (after `reset()` or a transaction's `removeAll()`) must not make it appear as a removed key.
@Suite("External-change checks ignore internal metadata", .offCooperativePool)
struct ChangeTrackerInternalFilesTests {
    private static func makeDepot() -> Depot {
        Depot(
            configuration: .init(
                directoryURL: FileManager.default.temporaryDirectory.appending(component: UUID().uuidString),
                enableMultiProcessSupport: true,
            )
        )
    }

    private final class UpdateCounter: Sendable {
        private let count = OSAllocatedUnfairLock(initialState: 0)
        var value: Int { count.withLock { $0 } }
        func increment() { count.withLock { $0 += 1 } }
    }

    /// Pending tracker changes, as the next external-change check would see them.
    private static func pendingChanges(
        in depot: Depot
    ) throws -> (modified: Set<DistinctKey>, removed: Set<DistinctKey>) {
        let tracker = try #require(depot.changeTracker)
        let fileManager = try #require(depot.fileManager)
        return tracker.setModificationDates(try fileManager.takeSnapshotOfModificationDates())
    }

    @Test("reset does not leave the metadata key pending as a removed key")
    func resetLeavesNoPendingChanges() throws {
        let depot = Self.makeDepot()
        let key = depot.register(keyPath: "value", coder: .json() as AnyCoder<Int>)
        try depot.set(value: 1, for: key)

        try depot.reset()

        let changes = try Self.pendingChanges(in: depot)
        #expect(changes.modified.isEmpty)
        #expect(changes.removed.isEmpty)
    }

    @Test("a transaction's removeAll does not leave the metadata key pending as a removed key")
    func transactionRemoveAllLeavesNoPendingChanges() throws {
        let depot = Self.makeDepot()
        let key = depot.register(keyPath: "value", coder: .json() as AnyCoder<Int>)
        try depot.set(value: 1, for: key)

        try depot.transaction { tx in
            try tx.removeAll()
        }

        let changes = try Self.pendingChanges(in: depot)
        #expect(changes.modified.isEmpty)
        #expect(changes.removed.isEmpty)
    }

    @Test("an external-change check after reset does not notify observers")
    func checkAfterResetDoesNotNotify() async throws {
        let depot = Self.makeDepot()
        let pattern = depot.register(key: Key([.wildcard]), coder: .json() as AnyCoder<Int>)
        try await depot.set(value: 1, for: Key.from("value", as: Int.self))

        let counter = UpdateCounter()
        let cancellable = depot.core.observe(
            valuesFor: pattern,
            initialValues: false,
            update: { _ in
                counter.increment()
            },
            in: depot
        )
        defer { cancellable.cancel() }

        try await depot.reset()
        await depot.core.waitForPendingObservations()
        let updatesAfterReset = counter.value

        try await depot.checkForExternalChanges()
        await depot.core.waitForPendingObservations()

        #expect(counter.value == updatesAfterReset, "the recreated metadata file is not an external change")
    }

    @Test("the change tracker ignores its internal keys")
    func trackerIgnoresInternalKeys() {
        let internalKey = DistinctKey([.segment(identifier: "\(Depot.HiddenKeyPrefix)META")])
        let userKey = DistinctKey([.segment(identifier: "user")])
        let tracker = DepotChangeTracker(ignoredKeys: [internalKey])
        let date = Date()

        tracker.modified(key: internalKey, at: date)
        tracker.modified(key: userKey, at: date)
        let unchanged = tracker.setModificationDates([userKey: date])
        #expect(unchanged.modified.isEmpty)
        #expect(unchanged.removed.isEmpty)

        let changes = tracker.setModificationDates([userKey: date, internalKey: date])
        #expect(changes.modified.isEmpty)
        #expect(changes.removed.isEmpty)
    }
}
