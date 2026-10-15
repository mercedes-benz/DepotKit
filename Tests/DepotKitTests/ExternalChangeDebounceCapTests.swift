// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// Controls the clock and the debounce delays of automatic external-change checks.
private final class DebounceCapProbe: Sendable {
    private struct State {
        var elapsed: Duration = .zero
        var durations = [Duration]()
        var pending = [Int: CheckedContinuation<Void, any Error>]()
        var cancelled = Set<Int>()
        var checks = 0
        var tasks = [Task<Void, Never>]()
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let start = ContinuousClock.now

    let didEnterBackground = Notification.Name("DepotKitTests.debounceCap.didEnterBackground.\(UUID().uuidString)")
    let willEnterForeground = Notification.Name("DepotKitTests.debounceCap.willEnterForeground.\(UUID().uuidString)")
    private let isInBackground = OSAllocatedUnfairLock(initialState: false)

    var durations: [Duration] { state.withLock { $0.durations } }
    var checkCount: Int { state.withLock { $0.checks } }
    var pendingCount: Int { state.withLock { $0.pending.count } }
    var scheduledTasks: [Task<Void, Never>] { state.withLock { $0.tasks } }

    /// Emits a change signal at `elapsed` and waits until its debounce delay started.
    func signal(_ depot: Depot, at elapsed: Duration) async {
        advance(to: elapsed)
        let count = durations.count
        depot.externalChangesDetected?.emit()
        #expect(await waitUntil { self.durations.count == count + 1 })
    }

    func advance(to elapsed: Duration) {
        state.withLock { $0.elapsed = elapsed }
    }

    /// Ends the pending delays (cancelled delays already threw).
    func releaseAll() {
        let continuations = state.withLock { state in
            defer { state.pending.removeAll() }
            return Array(state.pending.values)
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    func enterBackground() {
        isInBackground.withLock { $0 = true }
        NotificationCenter.default.post(name: didEnterBackground, object: nil)
    }

    func enterForeground() {
        isInBackground.withLock { $0 = false }
        NotificationCenter.default.post(name: willEnterForeground, object: nil)
    }

    var hooks: Depot.TestHooks {
        var hooks = Depot.TestHooks()
        hooks.applicationLifecycle = ApplicationLifecycle(
            didEnterBackground: didEnterBackground,
            willEnterForeground: willEnterForeground,
            isInBackground: { [isInBackground] in isInBackground.withLock { $0 } },
        )
        hooks.debounceNow = { [state, start] in start.advanced(by: state.withLock { $0.elapsed }) }
        hooks.debounceSleep = { [state] duration in
            let id = state.withLock { state in
                state.durations.append(duration)
                return state.durations.count
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let cancelled = state.withLock { state in
                        if Task.isCancelled || state.cancelled.contains(id) {
                            return true
                        }
                        state.pending[id] = continuation
                        return false
                    }
                    if cancelled {
                        continuation.resume(throwing: CancellationError())
                    }
                }
            } onCancel: {
                let continuation = state.withLock { state in
                    state.cancelled.insert(id)
                    return state.pending.removeValue(forKey: id)
                }
                continuation?.resume(throwing: CancellationError())
            }
        }
        hooks.didScheduleDebounceTask = { [state] task in state.withLock { $0.tasks.append(task) } }
        hooks.externalChangesCheck = { [state] depot in
            state.withLock { $0.checks += 1 }
            try await depot.checkForExternalChanges()
        }
        return hooks
    }
}

@Suite("Maximum delay of debounced external-change checks", .offCooperativePool)
struct ExternalChangeDebounceCapTests {
    private func makeDepot(_ probe: DebounceCapProbe) -> (Depot, URL) {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let depot = Depot(
            configuration: .init(directoryURL: url, enableMultiProcessSupport: true, memoryCache: .disabled),
            overrides: .init(testHooks: probe.hooks),
        )
        return (depot, url)
    }

    /// Starts automatic checks and waits for the initial foreground check.
    private func startAutomaticChecks(_ depot: Depot, _ probe: DebounceCapProbe) async throws {
        try depot.automaticallyCheckForExternalChanges(debounceInterval: 5)
        #expect(await waitUntil { probe.checkCount == 1 })
    }

    @Test("signals that keep arriving postpone the check by at most three debounce intervals")
    func continuousSignalsAreCapped() async throws {
        let probe = DebounceCapProbe()
        let (depot, url) = makeDepot(probe)
        defer {
            try? depot.removeFilePresenter()
            try? FileManager.default.removeItem(at: url)
        }
        try await startAutomaticChecks(depot, probe)

        // The burst starts at 0 s, so the check runs at 15 s at the latest.
        for elapsed in [0, 4, 8, 12, 16] {
            await probe.signal(depot, at: .seconds(elapsed))
        }
        #expect(probe.durations == [.seconds(5), .seconds(5), .seconds(5), .seconds(3), .zero])

        let tasks = probe.scheduledTasks
        try #require(tasks.count == 5)
        for task in tasks.dropLast() {
            await task.value
        }
        #expect(await waitUntil { probe.pendingCount == 1 })
        probe.releaseAll()
        await tasks[4].value
        #expect(probe.checkCount == 2)

        // The check covered the burst; the next signal starts a new one.
        await probe.signal(depot, at: .seconds(17))
        #expect(probe.durations.last == .seconds(5))
        #expect(await waitUntil { probe.pendingCount == 1 })
        probe.releaseAll()
        await probe.scheduledTasks.last?.value
        #expect(probe.checkCount == 3)
    }

    @Test("entering the background cancels the pending check and ends the burst")
    func backgroundEndsBurst() async throws {
        let probe = DebounceCapProbe()
        let (depot, url) = makeDepot(probe)
        defer {
            try? depot.removeFilePresenter()
            try? FileManager.default.removeItem(at: url)
        }
        try await startAutomaticChecks(depot, probe)

        await probe.signal(depot, at: .zero)
        let pending = try #require(probe.scheduledTasks.last)

        probe.advance(to: .seconds(14))
        probe.enterBackground()
        await pending.value
        #expect(probe.checkCount == 1, "a cancelled delay runs no check")

        // A signal in the background schedules nothing.
        depot.externalChangesDetected?.emit()
        #expect(probe.scheduledTasks.count == 1)

        // Returning to the foreground runs a check; a later signal starts a new burst.
        probe.enterForeground()
        #expect(await waitUntil { probe.checkCount == 2 })
        await probe.signal(depot, at: .seconds(14))
        #expect(probe.durations == [.seconds(5), .seconds(5)])
        #expect(await waitUntil { probe.pendingCount == 1 })
        probe.releaseAll()
        await probe.scheduledTasks.last?.value
        #expect(probe.checkCount == 3)
    }
}
