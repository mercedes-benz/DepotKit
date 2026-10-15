// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

// These tests must not use the `.offCooperativePool` trait: they check where DepotKit itself runs
// blocking work, and the trait would move the depot calls off the cooperative pool by itself.

/// Holds a coordinated write on a file from a dedicated thread, like another process that holds a
/// depot's shared lock file during a long commit.
private final class CoordinatedLockHolder: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (acquired: false, released: false))
    private let condition = NSCondition()

    /// Acquires the coordinated write and returns once it is held. The holder releases it by itself
    /// after `timeout`, so that a failing test cannot hang.
    init(url: URL, timeout: TimeInterval = 15) {
        Thread.detachNewThread { [self] in
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &error) { _ in
                condition.lock()
                state.withLock { $0.acquired = true }
                condition.broadcast()
                let deadline = Date(timeIntervalSinceNow: timeout)
                while !state.withLock({ $0.released }), condition.wait(until: deadline) {}
                state.withLock { $0.released = true }
                condition.unlock()
            }
        }
        condition.lock()
        while !state.withLock({ $0.acquired }) {
            condition.wait()
        }
        condition.unlock()
    }

    /// Whether the coordinated write is still held.
    var isHolding: Bool {
        state.withLock { $0.acquired && !$0.released }
    }

    func release() {
        condition.lock()
        state.withLock { $0.released = true }
        condition.broadcast()
        condition.unlock()
    }
}

/// A JSON coder that records the names of the threads it runs on.
private struct ThreadRecordingCoder: Coder {
    let threadNames: OSAllocatedUnfairLock<[String]>
    let marker: OSAllocatedUnfairLock<[String?]>

    func encode(_ value: String) throws -> Data {
        record()
        return try JSONEncoder().encode(value)
    }

    func decode(_ data: Data) throws -> String {
        record()
        return try JSONDecoder().decode(String.self, from: data)
    }

    private func record() {
        let name = currentThreadName()
        threadNames.withLock { $0.append(name) }
        marker.withLock { $0.append(CooperativePoolBlockingTests.marker) }
    }
}

private func makeURL() -> URL {
    FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
}

private func multiProcessDepot(at url: URL, maximumConcurrentTasks: Int = 4, hooks: Depot.TestHooks = .init()) -> Depot
{
    Depot(
        configuration: .init(directoryURL: url, enableMultiProcessSupport: true, memoryCache: .disabled),
        maximumConcurrentTasks: maximumConcurrentTasks,
        overrides: .init(initSweepDelay: .seconds(3600), testHooks: hooks),
    )
}

/// Whether `name` is the name of a ``DepotIOExecutor`` thread.
private func isIOThread(_ name: String) -> Bool {
    name == "DepotKit.io"
}

/// The name of the current thread (`"main"` for the main thread).
private func currentThreadName() -> String {
    Thread.isMainThread ? "main" : (Thread.current.name ?? "")
}

// DepotKit runs storage work on its own threads only where task executors are available, so the
// tests of this suite are marked available from those systems on.
@Suite("Blocking storage work stays off the cooperative pool")
struct CooperativePoolBlockingTests {
    @TaskLocal
    static var marker: String?

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("async writes waiting for the shared lock file do not occupy cooperative threads")
    func asyncWritesWaitingForLockFile() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // More waiting writes than the cooperative pool has threads.
        let writerCount = ProcessInfo.processInfo.activeProcessorCount + 2
        let depots = (0..<writerCount).map { _ in multiProcessDepot(at: url) }
        let keys = depots.enumerated().map { index, depot in
            depot.register(keyPath: "value-\(index)", coder: .json(Int.self))
        }
        let waitingWriters = OSAllocatedUnfairLock(initialState: 0)
        for depot in depots {
            depot.fileManager?.willSynchronizeWithLock = { waitingWriters.withLock { $0 += 1 } }
        }

        let holder = CoordinatedLockHolder(url: url.appending(component: "\(Depot.HiddenKeyPrefix)LOCK"))
        defer { holder.release() }

        let writes = Task {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (index, (depot, key)) in zip(depots, keys).enumerated() {
                    group.addTask { try await depot.set(value: index, for: key) }
                }
                try await group.waitForAll()
            }
        }

        let allWaiting = await waitUntil(timeout: .seconds(10)) { waitingWriters.withLock { $0 } >= writerCount }
        let heldWhileAllWaiting = holder.isHolding
        // Unrelated tasks still run, and sleeping tasks still wake up.
        await Task.detached {}.value
        try await Task.sleep(for: .milliseconds(10))
        let heldAfterUnrelatedWork = holder.isHolding

        holder.release()
        try await writes.value

        #expect(allWaiting)
        #expect(heldWhileAllWaiting, "the writes waited on cooperative threads until the lock was released")
        #expect(heldAfterUnrelatedWork)
        for (index, (depot, key)) in zip(depots, keys).enumerated() {
            #expect(try await depot.get(valueFor: key) == index)
        }
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("async APIs run storage work on DepotKit's I/O threads within the calling task")
    func asyncAPIsRunOnWorkerThreads() async throws {
        let threadNames = OSAllocatedUnfairLock(initialState: [String]())
        let markers = OSAllocatedUnfairLock(initialState: [String?]())
        let depot = Depot.temporary()
        let key = depot.register(
            keyPath: "value",
            coder: AnyCoder(ThreadRecordingCoder(threadNames: threadNames, marker: markers)),
        )

        try await Self.$marker.withValue("caller") {
            try await depot.set(value: "a", for: key)
            #expect(try await depot.get(valueFor: key) == "a")
            try await depot.transaction { transaction in
                // Async transaction closures run on the I/O threads as well.
                threadNames.withLock { $0.append(currentThreadName()) }
                markers.withLock { $0.append(Self.marker) }
                try transaction.set(value: "b", for: key)
            }
        }

        let names = threadNames.withLock { $0 }
        #expect(!names.isEmpty)
        #expect(names.allSatisfy(isIOThread), "\(names)")
        // The work runs in the calling task, so its task-local values are visible.
        #expect(markers.withLock { $0 }.allSatisfy { $0 == "caller" })
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("async APIs called on the main actor run storage work on DepotKit's I/O threads")
    @MainActor
    func mainActorCallersRunOnIOThreads() async throws {
        let threadNames = OSAllocatedUnfairLock(initialState: [String]())
        let depot = Depot.temporary()
        let key = depot.register(
            keyPath: "value",
            coder: AnyCoder(ThreadRecordingCoder(threadNames: threadNames, marker: .init(initialState: []))),
        )

        try await depot.set(value: "a", for: key)
        #expect(try await depot.get(valueFor: key) == "a")
        let transactionThread = try await depot.transaction { _ in currentThreadName() }

        let names = threadNames.withLock { $0 } + [transactionThread]
        #expect(names.allSatisfy(isIOThread), "\(names)")
    }

    @Test("async APIs of memory-only depots called on the main actor leave the main actor")
    @MainActor
    func memoryOnlyMainActorCallersLeaveTheMainActor() async throws {
        let depot = Depot()
        let key = depot.register(keyPath: "value", coder: .json(Int.self))

        let name = try await depot.transaction { transaction in
            try transaction.set(value: 1, for: key)
            return currentThreadName()
        }

        #expect(name != "main")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("memory-only depots run async work inline")
    func memoryOnlyDepotsRunInline() async throws {
        let depot = Depot()
        let key = depot.register(keyPath: "value", coder: .json(Int.self))

        let name = try await depot.transaction { transaction in
            try transaction.set(value: 1, for: key)
            return currentThreadName()
        }

        #expect(!isIOThread(name))
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("memory-cache hits of async reads are answered without switching to the I/O threads")
    func cacheHitsAreAnsweredInline() async throws {
        let threadNames = OSAllocatedUnfairLock(initialState: [String]())
        let depot = Depot.temporary(memoryCache: .default)
        let key = depot.register(
            keyPath: "value",
            coder: AnyCoder(ThreadRecordingCoder(threadNames: threadNames, marker: .init(initialState: []))),
        )
        try await depot.set(value: "a", for: key)
        let recordedAfterWrite = threadNames.withLock { $0.count }

        #expect(try await depot.get(valueFor: key) == "a")
        #expect(threadNames.withLock { $0.count } == recordedAfterWrite, "the cached value was decoded again")

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await depot.get(valueFor: key)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("observer re-reads run on DepotKit's I/O threads")
    func observerReadsRunOnWorkerThreads() async throws {
        let threadNames = OSAllocatedUnfairLock(initialState: [String]())
        let depot = Depot.temporary()
        let pattern = depot.register(
            key: Key.from("items" / .wildcard),
            coder: AnyCoder(ThreadRecordingCoder(threadNames: threadNames, marker: .init(initialState: []))),
        )
        let item = Key.from("items" / "a", as: String.self)

        let stream = depot.values(for: pattern)
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next()?.get() == [])

        // Updates of a pattern observation re-read every matching value.
        try await depot.set(value: "a", for: item)
        #expect(try await iterator.next()?.get() == ["a"])

        let names = threadNames.withLock { $0 }
        #expect(!names.isEmpty)
        #expect(names.allSatisfy(isIOThread), "\(names)")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("the startup expiry sweep runs on a DepotKit I/O thread")
    func startupSweepRunsOnWorkerThread() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let start = Date()
        let writer = Depot(
            configuration: .init(directoryURL: url),
            overrides: .init(clock: MockClock(now: start), initSweepDelay: .seconds(3600)),
        )
        let writerKey = writer.register(keyPath: "token", coder: .json(String.self), expiry: .seconds(1))
        try await writer.set(value: "expired", for: writerKey)

        let sweepThreads = OSAllocatedUnfairLock(initialState: [String]())
        var hooks = Depot.TestHooks()
        hooks.willRemoveExpiredFile = { _ in
            sweepThreads.withLock { $0.append(Thread.current.name ?? "") }
        }
        let depot = Depot(
            configuration: .init(directoryURL: url),
            overrides: .init(
                clock: MockClock(now: start.addingTimeInterval(10)),
                initSweepDelay: .zero,
                testHooks: hooks
            ),
        )
        await depot.waitForInitSweep()

        let names = sweepThreads.withLock { $0 }
        #expect(names.count == 1)
        #expect(names.allSatisfy(isIOThread), "\(names)")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("debounced external-change checks run on a DepotKit I/O thread")
    func debouncedChecksRunOnIOThread() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let checkThreads = OSAllocatedUnfairLock(initialState: [String]())
        let tasks = OSAllocatedUnfairLock(initialState: [Task<Void, Never>]())
        var hooks = Depot.TestHooks()
        hooks.debounceSleep = { _ in }
        hooks.didScheduleDebounceTask = { task in tasks.withLock { $0.append(task) } }
        hooks.externalChangesCheck = { _ in
            checkThreads.withLock { $0.append(currentThreadName()) }
        }
        let depot = multiProcessDepot(at: url, hooks: hooks)
        defer { try? depot.removeFilePresenter() }

        try await depot.addFilePresenter()
        depot.externalChangesDetected?.emit()
        let task = try #require(tasks.withLock { $0.first })
        await task.value

        let names = checkThreads.withLock { $0 }
        #expect(names.count == 1)
        #expect(names.allSatisfy(isIOThread), "\(names)")
    }
}

/// Simulates the lifecycle notifications of an app that is suspended in the background.
private final class SimulatedApplicationLifecycle: Sendable {
    let didEnterBackground = Notification.Name("DepotKitTests.blocking.didEnterBackground.\(UUID().uuidString)")
    let willEnterForeground = Notification.Name("DepotKitTests.blocking.willEnterForeground.\(UUID().uuidString)")
    private let isInBackground = OSAllocatedUnfairLock(initialState: false)

    var lifecycle: ApplicationLifecycle {
        ApplicationLifecycle(
            didEnterBackground: didEnterBackground,
            willEnterForeground: willEnterForeground,
            isInBackground: { [isInBackground] in isInBackground.withLock { $0 } },
        )
    }

    @MainActor
    func enterBackground() {
        isInBackground.withLock { $0 = true }
        NotificationCenter.default.post(name: didEnterBackground, object: nil)
    }

    @MainActor
    func enterForeground() {
        isInBackground.withLock { $0 = false }
        NotificationCenter.default.post(name: willEnterForeground, object: nil)
    }
}

private func registeredPresenterCount(for url: URL) -> Int {
    let path = url.appending(component: "\(Depot.HiddenKeyPrefix)LOCK").path(percentEncoded: false)
    return NSFileCoordinator.filePresenters.filter {
        $0.presentedItemURL?.path(percentEncoded: false) == path
    }.count
}

@Suite("Automatic external-change checks do not block the main actor")
struct LifecycleMainActorBlockingTests {
    @Test("registering the presenter while another process holds the lock file leaves the main actor free")
    func registrationDoesNotBlockMainActor() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let app = SimulatedApplicationLifecycle()
        let checks = OSAllocatedUnfairLock(initialState: 0)
        var hooks = Depot.TestHooks()
        hooks.applicationLifecycle = app.lifecycle
        hooks.externalChangesCheck = { _ in checks.withLock { $0 += 1 } }
        let depot = multiProcessDepot(at: url, hooks: hooks)
        defer { try? depot.removeFilePresenter() }

        // The lock file has to exist for the registration to coordinate on it.
        try depot.fileManager?.touchLock()
        let holder = CoordinatedLockHolder(url: url.appending(component: "\(Depot.HiddenKeyPrefix)LOCK"))
        defer { holder.release() }

        try depot.automaticallyCheckForExternalChanges(debounceInterval: 600)
        // Several main-actor round trips: the lifecycle setup and the registration are enqueued first.
        for _ in 0..<5 {
            await MainActor.run {}
        }
        let heldAfterMainActorWork = holder.isHolding
        holder.release()

        #expect(heldAfterMainActorWork, "the main actor waited for the coordinated write")
        #expect(
            await waitUntil(timeout: .seconds(30)) {
                registeredPresenterCount(for: url) == 1 && checks.withLock { $0 } == 1
            }
        )
    }

    @Test("entering the background while the registration waits for the lock file skips the registration and the check")
    func backgroundDuringRegistrationSkipsIt() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let app = SimulatedApplicationLifecycle()
        let checks = OSAllocatedUnfairLock(initialState: 0)
        let registrations = OSAllocatedUnfairLock(initialState: [Task<Void, Never>]())
        var hooks = Depot.TestHooks()
        hooks.applicationLifecycle = app.lifecycle
        hooks.externalChangesCheck = { _ in checks.withLock { $0 += 1 } }
        hooks.didStartForegroundRegistration = { task in registrations.withLock { $0.append(task) } }
        let depot = multiProcessDepot(at: url, hooks: hooks)
        defer { try? depot.removeFilePresenter() }

        try depot.fileManager?.touchLock()
        let holder = CoordinatedLockHolder(url: url.appending(component: "\(Depot.HiddenKeyPrefix)LOCK"))
        defer { holder.release() }

        try depot.automaticallyCheckForExternalChanges(debounceInterval: 600)
        #expect(await waitUntil(timeout: .seconds(30)) { registrations.withLock { $0.count } == 1 })
        await app.enterBackground()
        #expect(await waitUntil(timeout: .seconds(30)) { !depot.filePresenterState.withLock { $0.isInForeground } })
        holder.release()

        let registration = try #require(registrations.withLock { $0.first })
        await registration.value
        #expect(checks.withLock { $0 } == 0)
        #expect(registeredPresenterCount(for: url) == 0)

        // Returning to the foreground registers and catches up.
        await app.enterForeground()
        #expect(
            await waitUntil(timeout: .seconds(30)) {
                registeredPresenterCount(for: url) == 1 && checks.withLock { $0 } == 1
            }
        )
    }
}
