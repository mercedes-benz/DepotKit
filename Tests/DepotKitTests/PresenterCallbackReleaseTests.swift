// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if os(macOS)
import Foundation
import Testing
import os

@testable import DepotKit

/// File-presenter callbacks run on the presenter's operation queue. They must not retain the depot,
/// so that dropping the last reference elsewhere never deinitializes it on that queue.
@Suite("Presenter callbacks and depot release", .offCooperativePool)
struct PresenterCallbackReleaseTests {
    private static let presenterQueueName = "DepotFilePresenter.presented-item-operation-queue"

    private static func makeURL() -> URL {
        FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    }

    private static func registeredPresenters(for url: URL) -> [any NSFilePresenter] {
        let lockPath = url.appending(component: "\(Depot.HiddenKeyPrefix)LOCK").path(percentEncoded: false)
        return NSFileCoordinator.filePresenters.filter {
            $0.presentedItemURL?.path(percentEncoded: false) == lockPath
        }
    }

    /// What the debounce hook observed while it ran inside the presenter callback.
    private struct CallbackObservation: Sendable {
        var onPresenterQueue: Bool
        var releasedInCallback: Bool
    }

    @Test("a depot released during a presenter callback deinitializes right away and unregisters")
    func releaseDuringCallback() async throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let holder = OSAllocatedUnfairLock<Depot?>(initialState: nil)
        let reference = OSAllocatedUnfairLock<WeakReference<Depot>?>(initialState: nil)
        let observation = OSAllocatedUnfairLock<CallbackObservation?>(initialState: nil)

        var hooks = Depot.TestHooks()
        hooks.didScheduleDebounceTask = { _ in
            // Runs inside the presenter callback: drop the test's last reference to the depot.
            let didRelease = holder.withLock { depot in
                defer { depot = nil }
                return depot != nil
            }
            guard didRelease else {
                return
            }
            let isReleased = reference.withLock { $0 }?.isReleased ?? false
            observation.withLock {
                $0 = CallbackObservation(
                    onPresenterQueue: OperationQueue.current?.name == Self.presenterQueueName,
                    releasedInCallback: isReleased,
                )
            }
        }

        do {
            let depot = Depot(
                configuration: .init(directoryURL: url, enableMultiProcessSupport: true, memoryCache: .disabled),
                overrides: .init(initSweepDelay: .seconds(3600), testHooks: hooks),
            )
            try await depot.addFilePresenter()
            reference.withLock { $0 = WeakReference(depot) }
            holder.withLock { $0 = depot }
        }
        #expect(Self.registeredPresenters(for: url).count == 1)

        // Another depot instance touches the lock file, so Foundation notifies the registered presenter.
        let writer = Depot(
            configuration: .init(directoryURL: url, enableMultiProcessSupport: true, memoryCache: .disabled),
            overrides: .init(initSweepDelay: .seconds(3600)),
        )
        try writer.fileManager?.touchLock()

        // Generous timeout: the presenter queue needs a worker thread, which a busy parallel run can delay.
        #expect(await waitUntil(timeout: .seconds(120)) { observation.withLock { $0 } != nil })
        let observed = try #require(observation.withLock { $0 })
        #expect(observed.onPresenterQueue)
        #expect(observed.releasedInCallback, "the presenter callback must not keep the depot alive")
        #expect(reference.withLock { $0 }?.isReleased == true)
        #expect(Self.registeredPresenters(for: url).isEmpty)
    }

    @Test("depots released while presenter callbacks fire unregister their presenters")
    func releaseWhileCallbacksFire() async throws {
        for _ in 0..<3 {
            let url = Self.makeURL()
            defer { try? FileManager.default.removeItem(at: url) }

            let reference: WeakReference<Depot>
            do {
                let depot = Depot(
                    configuration: .init(directoryURL: url, enableMultiProcessSupport: true, memoryCache: .disabled),
                    overrides: .init(initSweepDelay: .seconds(3600)),
                )
                try depot.automaticallyCheckForExternalChanges(debounceInterval: 0.001)
                reference = WeakReference(depot)

                // Foundation delivers the change callback asynchronously, racing the release below.
                let writer = Depot(
                    configuration: .init(directoryURL: url, enableMultiProcessSupport: true, memoryCache: .disabled),
                    overrides: .init(initSweepDelay: .seconds(3600)),
                )
                try writer.fileManager?.touchLock()
            }

            #expect(await waitUntil { reference.isReleased })
            #expect(await waitUntil { Self.registeredPresenters(for: url).isEmpty })
        }
    }
}
#endif
