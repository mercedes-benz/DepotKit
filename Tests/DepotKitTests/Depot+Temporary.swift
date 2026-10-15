// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import os

@testable import DepotKit

extension Depot {
    /// Creates a depot backed by a unique temporary directory (for testing).
    static func temporary(
        memoryCache: DepotConfiguration.MemoryCacheCapacity = .disabled,
    ) -> Depot {
        Depot(
            configuration: .init(
                directoryURL: FileManager.default.temporaryDirectory.appending(component: UUID().uuidString),
                memoryCache: memoryCache,
            ),
        )
    }

    /// Creates a depot backed by a unique temporary directory with a controllable clock (for testing).
    ///
    /// The automatic startup expiry sweep runs on the wall clock shortly after initialization. It is
    /// pushed far out so that it cannot remove (and notify about) values that a mock-clock test
    /// expired on purpose when that test runs longer under load. Tests of the sweep configure it
    /// explicitly.
    static func temporary(
        memoryCache: DepotConfiguration.MemoryCacheCapacity = .disabled,
        clock: any DepotClock,
    ) -> Depot {
        Depot(
            configuration: .init(
                directoryURL: FileManager.default.temporaryDirectory.appending(component: UUID().uuidString),
                memoryCache: memoryCache,
            ),
            overrides: .init(clock: clock, initSweepDelay: .seconds(3600)),
        )
    }
}

// MARK: - Polling Helper

/// The upper bound for waits in tests.
///
/// Waits return as soon as their condition holds, so the timeout is only reached when a test fails.
/// It is generous because asynchronous steps can be delayed for seconds in a loaded parallel run:
/// Swift Testing starts all tests on the cooperative pool at once, and a suspended test only
/// resumes after the test work queued before it.
let testWaitTimeout: Duration = .seconds(30)

/// Polls `predicate` until it returns `true` or `timeout` elapses.
func waitUntil(
    timeout: Duration = testWaitTimeout,
    pollInterval: Duration = .milliseconds(10),
    _ predicate: @escaping @Sendable () -> Bool,
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while clock.now < deadline {
        if predicate() {
            return true
        }
        try? await Task.sleep(for: pollInterval)
    }

    return predicate()
}

/// Wakes tasks that wait for a condition on state that other threads change, so that the waits
/// do not need to poll.
///
/// Call `signal()` after every change of the state that the predicates passed to
/// `wait(timeout:until:)` read.
final class ChangeSignal: Sendable {
    private let waiters = OSAllocatedUnfairLock<[UUID: AsyncStream<Void>.Continuation]>(initialState: [:])

    /// Wakes all current waiters to re-evaluate their predicates.
    func signal() {
        let continuations = waiters.withLock { Array($0.values) }
        for continuation in continuations {
            continuation.yield()
        }
    }

    /// Waits until `predicate` holds or `timeout` elapses, re-evaluating it after every `signal()`.
    func wait(timeout: Duration = testWaitTimeout, until predicate: () -> Bool) async -> Bool {
        let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        waiters.withLock { $0[id] = continuation }
        defer { waiters.withLock { _ = $0.removeValue(forKey: id) } }
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            continuation.finish()
        }
        defer { timeoutTask.cancel() }

        // Registered before the first check, so a change in between is not missed.
        if predicate() {
            return true
        }
        for await _ in changes {
            if predicate() {
                return true
            }
        }
        return predicate()
    }
}

/// A controllable clock for deterministic TTL testing.
final class MockClock: DepotClock, Sendable {
    private let _now: OSAllocatedUnfairLock<Date>

    init(now: Date = Date()) {
        _now = OSAllocatedUnfairLock(initialState: now)
    }

    func now() -> Date { _now.withLock { $0 } }

    func advance(by interval: TimeInterval) {
        _now.withLock { $0 = $0.addingTimeInterval(interval) }
    }

    func set(_ date: Date) {
        _now.withLock { $0 = date }
    }
}
