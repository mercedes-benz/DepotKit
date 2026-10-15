// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if os(macOS)
import Foundation
import Testing
import os

@testable import DepotKit

/// `NSFileCoordinator` retains registered presenters, so a depot must unregister its presenter on teardown.
@Suite("File presenter teardown", .offCooperativePool)
struct FilePresenterLifecycleTests {
    private static func makeURL() -> URL {
        FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    }

    private static func makeDepot(at url: URL) -> Depot {
        Depot(configuration: .init(directoryURL: url, enableMultiProcessSupport: true, memoryCache: .disabled))
    }

    /// The process-wide registered presenters that present the lock file of the depot at `url`.
    private static func registeredPresenters(for url: URL) -> [any NSFilePresenter] {
        let lockPath = url.appending(component: "\(Depot.HiddenKeyPrefix)LOCK").path(percentEncoded: false)
        return NSFileCoordinator.filePresenters.filter {
            $0.presentedItemURL?.path(percentEncoded: false) == lockPath
        }
    }

    @Test("deallocating a depot unregisters its file presenter")
    func deallocationRemovesPresenter() throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var depot: Depot? = Self.makeDepot(at: url)
        try depot?.addFilePresenter()
        try depot?.addFilePresenter()
        #expect(!Self.registeredPresenters(for: url).isEmpty)

        weak let weakDepot = depot
        depot = nil

        #expect(weakDepot == nil)
        #expect(Self.registeredPresenters(for: url).isEmpty)
    }

    @Test("deallocating a depot with automatic external-change checks unregisters its file presenter")
    func automaticChecksDeallocationRemovesPresenter() throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var depot: Depot? = Self.makeDepot(at: url)
        try depot?.automaticallyCheckForExternalChanges(debounceInterval: 60)
        let presenters = Self.registeredPresenters(for: url)
        #expect(presenters.count == 1)

        weak let weakDepot = depot
        depot = nil

        #expect(weakDepot == nil, "the registered presenter must not keep the depot alive")
        #expect(Self.registeredPresenters(for: url).isEmpty)

        // A late callback on the detached presenter is harmless.
        presenters.first?.presentedItemDidChange?()
    }

    @Test("a depot released from a presenter callback unregisters without deadlocking")
    func releaseOnPresenterQueueDoesNotDeadlock() async throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var depot: Depot? = Self.makeDepot(at: url)
        let fileManager = try #require(depot?.fileManager)
        try await depot?.addFilePresenter()
        let holder = OSAllocatedUnfairLock<Depot?>(initialState: depot)
        depot = nil

        let released = OSAllocatedUnfairLock(initialState: false)
        // Drop the last reference inside the callback, so the depot deinitializes on the presenter's queue.
        fileManager.onExternalChangesDetected = {
            _ = holder.withLock { depot in
                defer { depot = nil }
                return depot
            }
            released.withLock { $0 = true }
        }
        let presenter = try #require(Self.registeredPresenters(for: url).first as? DepotFilePresenter)

        // Deliver the change notification on the presenter's queue, as Foundation does.
        presenter.presentedItemOperationQueue.addOperation {
            presenter.presentedItemDidChange()
        }

        // Generous timeout: the queue needs a worker thread, which a busy parallel test run can delay.
        #expect(await waitUntil(timeout: .seconds(120)) { released.withLock { $0 } })
        #expect(holder.withLock { $0 == nil })
        #expect(Self.registeredPresenters(for: url).isEmpty)
    }

    @Test("unregistered presenters released by Foundation do not trap")
    func releaseAfterUnregistrationDoesNotTrap() async throws {
        var urls = [URL]()
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }

        for index in 0..<20 {
            let url = Self.makeURL()
            urls.append(url)
            var depot: Depot? = Self.makeDepot(at: url)
            try await depot?.addFilePresenter()
            if index.isMultiple(of: 2) {
                try await depot?.removeFilePresenter()
            }
            depot = nil
            #expect(Self.registeredPresenters(for: url).isEmpty)
        }

        // Foundation drops its last references to unregistered presenters asynchronously, on its own queue.
        try await Task.sleep(for: .seconds(1))
    }
}
#endif
