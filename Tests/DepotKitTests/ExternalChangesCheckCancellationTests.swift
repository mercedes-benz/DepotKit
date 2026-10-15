// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// An asynchronous external-change check waits for the depot's write lock. When its task is
/// canceled meanwhile, it must not scan the directory anymore — like a canceled debounced check,
/// which is superseded by a newer one.
@Suite("Cancellation of external-change checks", .offCooperativePool)
struct ExternalChangesCheckCancellationTests {
    @Test("a check canceled while waiting for the write lock does not scan")
    func canceledWhileWaitingForLock() async throws {
        let url = BulkRemovalSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        let cancelNextCheck = OSAllocatedUnfairLock(initialState: false)
        var hooks = Depot.TestHooks()
        hooks.willAcquireLockForExternalChangesCheck = {
            guard cancelNextCheck.withLock({ $0 }) else {
                return
            }
            cancelNextCheck.withLock { $0 = false }
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let depot = BulkRemovalSupport.makeDepot(at: url, hooks: hooks)
        let peer = BulkRemovalSupport.makeDepot(at: url)
        let key = depot.register(keyPath: "value", coder: .json(Int.self))
        let peerKey = peer.register(keyPath: "value", coder: .json(Int.self))
        let log = DeliveryLog<Int?>()
        let cancellable = depot.core.observe(
            valueFor: key,
            initialValue: false,
            update: { log.append(try? $0.get()) },
            in: depot,
        )
        defer { cancellable.cancel() }

        try await peer.set(value: 1, for: peerKey)

        cancelNextCheck.withLock { $0 = true }
        let check = Task { try await depot.checkForExternalChanges() }
        await #expect(throws: CancellationError.self) {
            try await check.value
        }
        #expect(!cancelNextCheck.withLock { $0 }, "the check reached the write lock")
        await depot.waitForPendingObservations()
        #expect(log.all.isEmpty)

        // The change is still pending and reported by the next check.
        try await depot.checkForExternalChanges()
        await depot.waitForPendingObservations()
        #expect(log.all == [1])
    }

    @Test("a synchronous check is not affected by the cancellation of the calling task")
    func synchronousCheckIgnoresCancellation() async throws {
        let url = BulkRemovalSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        let depot = BulkRemovalSupport.makeDepot(at: url)
        let peer = BulkRemovalSupport.makeDepot(at: url)
        let key = depot.register(keyPath: "value", coder: .json(Int.self))
        let peerKey = peer.register(keyPath: "value", coder: .json(Int.self))
        let log = DeliveryLog<Int?>()
        let cancellable = depot.core.observe(
            valueFor: key,
            initialValue: false,
            update: { log.append(try? $0.get()) },
            in: depot,
        )
        defer { cancellable.cancel() }

        try await peer.set(value: 1, for: peerKey)

        let check = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try depot.checkForExternalChanges()
        }
        try await check.value
        await depot.waitForPendingObservations()
        #expect(log.all == [1])
    }
}
