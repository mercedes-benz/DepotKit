// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// Counts the debounced and immediate external-change checks of a depot.
private final class CheckProbe: Sendable {
    private let tasks = OSAllocatedUnfairLock(initialState: [Task<Void, Never>]())
    private let checks = OSAllocatedUnfairLock(initialState: 0)

    var scheduledTasks: [Task<Void, Never>] { tasks.withLock { $0 } }
    var checkCount: Int { checks.withLock { $0 } }

    var hooks: Depot.TestHooks {
        var hooks = Depot.TestHooks()
        // Debounce delays elapse immediately.
        hooks.debounceSleep = { _ in }
        hooks.didScheduleDebounceTask = { [tasks] task in tasks.withLock { $0.append(task) } }
        hooks.externalChangesCheck = { [checks] depot in
            checks.withLock { $0 += 1 }
            try await depot.checkForExternalChanges()
        }
        return hooks
    }
}

private func makeURL() -> URL {
    FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
}

private func multiProcessDepot(
    at url: URL,
    readOnly: Bool = false,
    cache: Bool = false,
    hooks: Depot.TestHooks = .init(),
) -> Depot {
    Depot(
        configuration: .init(
            directoryURL: url,
            enableMultiProcessSupport: true,
            readOnly: readOnly,
            memoryCache: cache ? .default : .disabled,
        ),
        overrides: .init(testHooks: hooks),
    )
}

/// The process-wide registered presenters of the depot at `url`: writable depots present the lock
/// file, read-only depots the depot directory.
private func registeredPresenters(for url: URL) -> [any NSFilePresenter] {
    let paths = [url, url.appending(component: "\(Depot.HiddenKeyPrefix)LOCK")].map {
        $0.path(percentEncoded: false)
    }
    return NSFileCoordinator.filePresenters.filter {
        paths.contains($0.presentedItemURL?.path(percentEncoded: false) ?? "")
    }
}

/// Every item below `url`, including hidden files, as relative paths.
private func directoryListing(at url: URL) -> Set<String> {
    guard let enumerator = FileManager.default.enumerator(atPath: url.path(percentEncoded: false)) else {
        return []
    }
    return Set(enumerator.compactMap { $0 as? String })
}

@Suite("Manually registered file presenters", .offCooperativePool)
struct ManualFilePresenterTests {
    @Test("presenter callbacks of a manually registered presenter schedule a debounced check")
    func manualPresenterSchedulesCheck() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = CheckProbe()
        let depot = multiProcessDepot(at: url, hooks: probe.hooks)
        defer { try? depot.removeFilePresenter() }

        try await depot.addFilePresenter()
        depot.fileManager?.presentedItemDidChange()

        let task = try #require(probe.scheduledTasks.first)
        await task.value
        #expect(probe.checkCount == 1)
    }

    @Test("a manually registered presenter picks up another instance's write")
    func manualPresenterPicksUpExternalWrite() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = multiProcessDepot(at: url)
        let reader = multiProcessDepot(at: url, cache: true)
        defer { try? reader.removeFilePresenter() }
        let writerKey = writer.register(keyPath: "value", coder: .json(String.self))
        let readerKey = reader.register(keyPath: "value", coder: .json(String.self))

        try await writer.set(value: "v1", for: writerKey)
        #expect(try await reader.get(valueFor: readerKey) == "v1")

        try await reader.addFilePresenter()
        try await writer.set(value: "v2", for: writerKey)

        // The presenter callback arrives asynchronously, followed by the default one-second debounce.
        #expect(await waitUntil(timeout: .seconds(60)) { (try? reader.get(valueFor: readerKey)) == "v2" })
    }
}

#if os(macOS)
@Suite("Automatic external-change checks on macOS", .offCooperativePool)
struct MacAutomaticExternalChangeTests {
    @Test("starting automatic checks catches up on changes made before registration")
    func initialCheckCatchesUp() throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = multiProcessDepot(at: url)
        let reader = multiProcessDepot(at: url, cache: true)
        defer { try? reader.removeFilePresenter() }
        let writerKey = writer.register(keyPath: "value", coder: .json(String.self))
        let readerKey = reader.register(keyPath: "value", coder: .json(String.self))

        try writer.set(value: "v1", for: writerKey)
        #expect(try reader.get(valueFor: readerKey) == "v1")
        try writer.set(value: "v2", for: writerKey)

        try reader.automaticallyCheckForExternalChanges(debounceInterval: 600)

        #expect(try reader.get(valueFor: readerKey) == "v2")
    }

    @Test("repeated calls register one presenter")
    func repeatedCallsRegisterOnePresenter() throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let depot = multiProcessDepot(at: url)
        defer { try? depot.removeFilePresenter() }

        try depot.automaticallyCheckForExternalChanges(debounceInterval: 600)
        try depot.automaticallyCheckForExternalChanges(debounceInterval: 600)
        try depot.addFilePresenter()

        #expect(registeredPresenters(for: url).count == 1)
    }
}
#endif

@Suite("File presenters of read-only depots")
struct ReadOnlyFilePresenterTests {
    @Test("a read-only depot registers its presenter and checks for changes without writing")
    func readOnlyPresenterDoesNotWrite() throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // A store written without multi-process support has no lock file.
        let writer = Depot(configuration: .init(directoryURL: url, memoryCache: .disabled))
        let writerKey = writer.register(keyPath: "value", coder: .json(String.self))
        try writer.set(value: "v1", for: writerKey)
        let listing = directoryListing(at: url)

        let reader = multiProcessDepot(at: url, readOnly: true)
        defer { try? reader.removeFilePresenter() }
        try reader.addFilePresenter()
        try reader.checkForExternalChanges()

        #expect(registeredPresenters(for: url).count == 1)
        #expect(directoryListing(at: url) == listing)
    }

    @Test("a read-only depot on a missing directory creates nothing")
    func readOnlyDepotOnMissingDirectory() throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = multiProcessDepot(at: url, readOnly: true)
        defer { try? reader.removeFilePresenter() }
        try reader.addFilePresenter()
        try reader.checkForExternalChanges()

        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test("a read-only depot's presenter is notified when a writer creates the lock file and writes")
    func readOnlyPresenterSeesWriterCreatingLock() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let plainWriter = Depot(configuration: .init(directoryURL: url, memoryCache: .disabled))
        let plainKey = plainWriter.register(keyPath: "value", coder: .json(String.self))
        try await plainWriter.set(value: "v1", for: plainKey)

        let reader = multiProcessDepot(at: url, readOnly: true, cache: true)
        defer { try? reader.removeFilePresenter() }
        let readerKey = reader.register(keyPath: "value", coder: .json(String.self))
        #expect(try await reader.get(valueFor: readerKey) == "v1")
        try await reader.addFilePresenter()

        let writer = multiProcessDepot(at: url)
        let writerKey = writer.register(keyPath: "value", coder: .json(String.self))
        try await writer.set(value: "v2", for: writerKey)

        #expect(await waitUntil(timeout: .seconds(60)) { (try? reader.get(valueFor: readerKey)) == "v2" })
    }
}

/// Simulates the lifecycle notifications of an app that is suspended in the background.
private final class TestApplicationLifecycle: Sendable {
    let didEnterBackground = Notification.Name("DepotKitTests.didEnterBackground.\(UUID().uuidString)")
    let willEnterForeground = Notification.Name("DepotKitTests.willEnterForeground.\(UUID().uuidString)")
    private let isInBackground: OSAllocatedUnfairLock<Bool>

    init(startsInBackground: Bool = false) {
        isInBackground = OSAllocatedUnfairLock(initialState: startsInBackground)
    }

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

private func lifecycleObserverCount(of depot: Depot) -> Int {
    depot.filePresenterState.withLockUnchecked { $0.lifecycleObservers.count }
}

/// Lets main-actor work enqueued before this call (lifecycle setup, notification observers) run.
private func drainMainActor() async {
    for _ in 0..<5 {
        await MainActor.run {}
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// Automatic checks on platforms whose apps are suspended (iOS, iPadOS, Mac Catalyst, tvOS,
/// visionOS, watchOS), driven by simulated lifecycle notifications.
@Suite("Automatic external-change checks following the app lifecycle")
struct LifecycleAutomaticExternalChangeTests {
    @Test("registers and checks while active, unregisters in the background, and catches up on return")
    func followsLifecycle() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let app = TestApplicationLifecycle()
        let probe = CheckProbe()
        var hooks = probe.hooks
        hooks.applicationLifecycle = app.lifecycle
        let depot = multiProcessDepot(at: url, hooks: hooks)
        defer { try? depot.removeFilePresenter() }

        try depot.automaticallyCheckForExternalChanges(debounceInterval: 600)
        #expect(
            await waitUntil(timeout: .seconds(60)) {
                registeredPresenters(for: url).count == 1 && probe.checkCount == 1
            }
        )

        app.enterBackground()
        #expect(await waitUntil(timeout: .seconds(60)) { registeredPresenters(for: url).isEmpty })

        app.enterForeground()
        #expect(
            await waitUntil(timeout: .seconds(60)) {
                registeredPresenters(for: url).count == 1 && probe.checkCount == 2
            }
        )
    }

    @Test("an app that starts in the background registers once it enters the foreground")
    func startsInBackground() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let app = TestApplicationLifecycle(startsInBackground: true)
        let probe = CheckProbe()
        var hooks = probe.hooks
        hooks.applicationLifecycle = app.lifecycle
        let depot = multiProcessDepot(at: url, hooks: hooks)
        defer { try? depot.removeFilePresenter() }

        try depot.automaticallyCheckForExternalChanges(debounceInterval: 600)
        #expect(await waitUntil(timeout: .seconds(60)) { lifecycleObserverCount(of: depot) == 2 })
        #expect(registeredPresenters(for: url).isEmpty)
        #expect(probe.checkCount == 0)

        app.enterForeground()
        #expect(
            await waitUntil(timeout: .seconds(60)) {
                registeredPresenters(for: url).count == 1 && probe.checkCount == 1
            }
        )
    }

    @Test("repeated calls observe the lifecycle once")
    func repeatedCallsObserveOnce() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let app = TestApplicationLifecycle()
        let probe = CheckProbe()
        var hooks = probe.hooks
        hooks.applicationLifecycle = app.lifecycle
        let depot = multiProcessDepot(at: url, hooks: hooks)
        defer { try? depot.removeFilePresenter() }

        try depot.automaticallyCheckForExternalChanges(debounceInterval: 600)
        try depot.automaticallyCheckForExternalChanges(debounceInterval: 600)
        try depot.automaticallyCheckForExternalChanges(debounceInterval: 600)
        #expect(await waitUntil(timeout: .seconds(60)) { probe.checkCount >= 1 })
        await drainMainActor()
        #expect(lifecycleObserverCount(of: depot) == 2)
        #expect(probe.checkCount == 1)

        app.enterForeground()
        #expect(await waitUntil(timeout: .seconds(60)) { probe.checkCount >= 2 })
        await drainMainActor()
        #expect(probe.checkCount == 2)
        #expect(registeredPresenters(for: url).count == 1)
    }

    @Test("a manually registered presenter does not prevent automatic lifecycle management")
    func manualRegistrationBeforeAutomaticChecks() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let app = TestApplicationLifecycle()
        let probe = CheckProbe()
        var hooks = probe.hooks
        hooks.applicationLifecycle = app.lifecycle
        let depot = multiProcessDepot(at: url, hooks: hooks)
        defer { try? depot.removeFilePresenter() }

        try await depot.addFilePresenter()
        try depot.automaticallyCheckForExternalChanges(debounceInterval: 600)
        #expect(await waitUntil(timeout: .seconds(60)) { lifecycleObserverCount(of: depot) == 2 })

        app.enterBackground()
        #expect(await waitUntil(timeout: .seconds(60)) { registeredPresenters(for: url).isEmpty })
    }

    @Test("without multi-process support, repeated calls observe nothing")
    func noMultiProcessSupportObservesNothing() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let app = TestApplicationLifecycle()
        let probe = CheckProbe()
        var hooks = probe.hooks
        hooks.applicationLifecycle = app.lifecycle
        let depot = Depot(configuration: .init(directoryURL: url), overrides: .init(testHooks: hooks))

        try depot.automaticallyCheckForExternalChanges()
        try depot.automaticallyCheckForExternalChanges()
        await drainMainActor()
        app.enterForeground()
        await drainMainActor()

        #expect(lifecycleObserverCount(of: depot) == 0)
        #expect(probe.checkCount == 0)
    }

    @Test("deallocating the depot removes its lifecycle observers")
    func deallocationRemovesObservers() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let app = TestApplicationLifecycle()
        let probe = CheckProbe()
        var hooks = probe.hooks
        hooks.applicationLifecycle = app.lifecycle
        var depot: Depot? = multiProcessDepot(at: url, hooks: hooks)

        try depot?.automaticallyCheckForExternalChanges(debounceInterval: 600)
        #expect(await waitUntil(timeout: .seconds(60)) { registeredPresenters(for: url).count == 1 })
        #expect(await waitUntil(timeout: .seconds(60)) { probe.checkCount == 1 })

        weak let weakDepot = depot
        depot = nil
        // The initial check may still hold the depot briefly.
        #expect(await waitUntil(timeout: .seconds(60)) { weakDepot == nil })
        #expect(registeredPresenters(for: url).isEmpty)

        app.enterForeground()
        await drainMainActor()
        #expect(registeredPresenters(for: url).isEmpty)
        #expect(probe.checkCount == 1)
    }
}
