// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// Simulates the lifecycle notifications of an app that is suspended in the background.
private final class SuspendingApplicationLifecycle: Sendable {
    let didEnterBackground = Notification.Name("DepotKitTests.suspending.didEnterBackground.\(UUID().uuidString)")
    let willEnterForeground = Notification.Name("DepotKitTests.suspending.willEnterForeground.\(UUID().uuidString)")
    private let isInBackground = OSAllocatedUnfairLock(initialState: false)

    var lifecycle: ApplicationLifecycle {
        ApplicationLifecycle(
            didEnterBackground: didEnterBackground,
            willEnterForeground: willEnterForeground,
            isInBackground: { [isInBackground] in isInBackground.withLock { $0 } },
        )
    }

    func enterBackground() {
        isInBackground.withLock { $0 = true }
        NotificationCenter.default.post(name: didEnterBackground, object: nil)
    }

    func enterForeground() {
        isInBackground.withLock { $0 = false }
        NotificationCenter.default.post(name: willEnterForeground, object: nil)
    }
}

/// Records the debounced checks of a depot whose debounce delays last until the test opens a gate.
private final class GatedCheckProbe: Sendable {
    private let isOpen = OSAllocatedUnfairLock(initialState: false)
    private let tasks = OSAllocatedUnfairLock(initialState: [Task<Void, Never>]())
    private let checks = OSAllocatedUnfairLock(initialState: 0)
    private let finishedChecks = OSAllocatedUnfairLock(initialState: 0)

    var scheduledTasks: [Task<Void, Never>] { tasks.withLock { $0 } }
    /// The number of checks that started.
    var checkCount: Int { checks.withLock { $0 } }
    /// The number of checks that returned or threw.
    var finishedCheckCount: Int { finishedChecks.withLock { $0 } }

    func openGate() {
        isOpen.withLock { $0 = true }
    }

    func hooks(lifecycle: ApplicationLifecycle) -> Depot.TestHooks {
        var hooks = Depot.TestHooks()
        hooks.applicationLifecycle = lifecycle
        // A cancelled delay throws from `Task.sleep`, like the real debounce delay.
        hooks.debounceSleep = { [isOpen] _ in
            while !isOpen.withLock({ $0 }) {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        hooks.didScheduleDebounceTask = { [tasks] task in tasks.withLock { $0.append(task) } }
        hooks.externalChangesCheck = { [checks, finishedChecks] depot in
            checks.withLock { $0 += 1 }
            defer { finishedChecks.withLock { $0 += 1 } }
            try await depot.checkForExternalChanges()
        }
        return hooks
    }
}

private func registeredPresenterCount(for url: URL) -> Int {
    let path = url.appending(component: "\(Depot.HiddenKeyPrefix)LOCK").path(percentEncoded: false)
    return NSFileCoordinator.filePresenters.filter {
        $0.presentedItemURL?.path(percentEncoded: false) == path
    }.count
}

private func multiProcessDepot(at url: URL, cache: Bool = false, hooks: Depot.TestHooks = .init()) -> Depot {
    Depot(
        configuration: .init(
            directoryURL: url,
            enableMultiProcessSupport: true,
            memoryCache: cache ? .default : .disabled,
        ),
        overrides: .init(testHooks: hooks),
    )
}

@Suite("External-change checks while the app is in the background", .offCooperativePool)
struct BackgroundExternalChangeCheckTests {
    /// A presenter callback shortly before entering the background schedules a debounced check that
    /// is still pending then; one shortly after (the presenter was removed) arrives late.
    @Test(
        "a presenter callback around entering the background runs no check until the app returns",
        arguments: [false, true],
    )
    func noCheckInBackground(callbackAfterEnteringBackground: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let app = SuspendingApplicationLifecycle()
        let probe = GatedCheckProbe()
        let writer = multiProcessDepot(at: url)
        let writerKey = writer.register(keyPath: "value", coder: .json(String.self))
        try await writer.set(value: "v1", for: writerKey)

        let reader = multiProcessDepot(at: url, cache: true, hooks: probe.hooks(lifecycle: app.lifecycle))
        defer { try? reader.removeFilePresenter() }
        let readerKey = reader.register(keyPath: "value", coder: .json(String.self))
        #expect(try await reader.get(valueFor: readerKey) == "v1")

        let notifications = OSAllocatedUnfairLock(initialState: [String?]())
        let observation = reader.core.observe(
            valueFor: readerKey,
            initialValue: false,
            update: { result in notifications.withLock { $0.append(try? result.get()) } },
            in: reader,
        )
        defer { observation.cancel() }

        try reader.automaticallyCheckForExternalChanges(debounceInterval: 600)
        // The initial check must be over before the other process writes, or it picks up the write.
        #expect(await waitUntil { registeredPresenterCount(for: url) == 1 && probe.finishedCheckCount == 1 })

        if !callbackAfterEnteringBackground {
            reader.fileManager?.presentedItemDidChange()
            #expect(!probe.scheduledTasks.isEmpty)
        }

        app.enterBackground()
        #expect(await waitUntil { registeredPresenterCount(for: url) == 0 })

        // Another process writes while the app is in the background.
        try await writer.set(value: "v2", for: writerKey)
        if callbackAfterEnteringBackground {
            reader.fileManager?.presentedItemDidChange()
        }

        probe.openGate()
        for task in probe.scheduledTasks {
            await task.value
        }
        await reader.waitForPendingObservations()

        #expect(probe.checkCount == 1)
        #expect(notifications.withLock { $0 }.isEmpty)
        // No check invalidated the cached value.
        #expect(try await reader.get(valueFor: readerKey) == "v1")

        // Returning to the foreground catches up on the change.
        app.enterForeground()
        #expect(await waitUntil { registeredPresenterCount(for: url) == 1 && probe.checkCount == 2 })
        #expect(await waitUntil { notifications.withLock { $0 } == ["v2"] })
        #expect(try await reader.get(valueFor: readerKey) == "v2")
    }
}
