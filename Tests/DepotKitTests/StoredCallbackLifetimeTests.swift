// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// Callbacks kept in lock-protected state must stay the same function value however often they are
/// read. A function stored directly as a lock's generic state is rewrapped in another reabstraction
/// thunk on every access, so invocations get slower with each one and releasing the callback after a
/// few thousand accesses overflows the stack.
@Suite("Stored callbacks survive many invocations")
struct StoredCallbackLifetimeTests {
    /// Well above the number of accesses after which releasing a rewrapped callback crashed.
    static let invocations = 5_000

    enum ObserverKind: String, CaseIterable, Sendable {
        case single
        case multi
        case available

        func makeObserver(
            key: TypedDistinctKey<Int>,
            onDelivery: @escaping @Sendable () -> Void,
        ) -> any ValueObserverProtocol {
            switch self {
            case .single:
                SingleValueObserver<Int>(key: key, update: { _ in onDelivery() })
            case .multi:
                MultiValueObserver<Int>(key: key, update: { _ in onDelivery() })
            case .available:
                AvailableValuesObserver<Int>(key: key, update: { _ in onDelivery() })
            }
        }
    }

    @Test("observers deliver many updates, then cancel and release cleanly", arguments: ObserverKind.allCases)
    func observerDeliveries(kind: ObserverKind) async throws {
        let depot = Depot()
        let key = depot.register(keyPath: "value", coder: .json(Int.self))
        let deliveries = OSAllocatedUnfairLock(initialState: 0)

        var observer: (any ValueObserverProtocol)? = kind.makeObserver(key: key) {
            deliveries.withLock { $0 += 1 }
        }
        for value in 0..<Self.invocations {
            await observer?.updated(value, in: depot)
        }
        #expect(deliveries.withLock { $0 } == Self.invocations)

        observer?.cancel()
        #expect(observer?.isCancelled == true)
        await observer?.updated(Self.invocations, in: depot)
        #expect(deliveries.withLock { $0 } == Self.invocations)
        observer = nil
    }

    @Test("an observer registered with the depot survives many writes and cancellation")
    func observerThroughDepot() async throws {
        let depot = Depot()
        let key = depot.register(keyPath: "value", coder: .json(Int.self))
        let deliveries = OSAllocatedUnfairLock(initialState: 0)
        let cancellable = depot.core.observe(
            valueFor: key,
            initialValue: false,
            update: { _ in deliveries.withLock { $0 += 1 } },
            in: depot,
        )

        for value in 0..<Self.invocations {
            try await depot.set(value: value, for: key)
        }
        await depot.waitForPendingObservations()
        #expect(deliveries.withLock { $0 } == Self.invocations)

        cancellable.cancel()
        try await depot.set(value: -1, for: key)
        await depot.waitForPendingObservations()
        #expect(deliveries.withLock { $0 } == Self.invocations)
    }

    @Test("file presenter callbacks survive many invocations and release cleanly")
    func filePresenterCallbacks() throws {
        let presenter = DepotFilePresenter(
            depotURL: FileManager.default.temporaryDirectory.appending(component: UUID().uuidString),
            enableMultiProcessSupport: true,
        )
        let calls = OSAllocatedUnfairLock(initialState: 0)
        presenter.onExternalChangesDetected = { calls.withLock { $0 += 1 } }
        presenter.willSynchronizeWithLock = { calls.withLock { $0 += 1 } }
        presenter.didAcquireLock = { calls.withLock { $0 += 1 } }

        for _ in 0..<Self.invocations {
            // Every file-presenter callback reads `onExternalChangesDetected`.
            presenter.presentedItemDidChange()
            presenter.willSynchronizeWithLock?()
            presenter.didAcquireLock?()
        }
        #expect(calls.withLock { $0 } == 3 * Self.invocations)

        presenter.onExternalChangesDetected = nil
        presenter.willSynchronizeWithLock = nil
        presenter.didAcquireLock = nil
        presenter.presentedItemDidChange()
        #expect(calls.withLock { $0 } == 3 * Self.invocations)
    }

    @Test("the after-commit hook survives many commits and releases cleanly")
    func afterCommitHook() throws {
        let depot = Depot()
        let key = depot.register(keyPath: "value", coder: .json(Int.self))
        let calls = OSAllocatedUnfairLock(initialState: 0)
        depot.core.setAfterCommitHook { calls.withLock { $0 += 1 } }

        for value in 0..<Self.invocations {
            try depot.set(value: value, for: key)
        }
        #expect(calls.withLock { $0 } == Self.invocations)

        depot.core.setAfterCommitHook(nil)
        try depot.set(value: -1, for: key)
        #expect(calls.withLock { $0 } == Self.invocations)
    }
}
