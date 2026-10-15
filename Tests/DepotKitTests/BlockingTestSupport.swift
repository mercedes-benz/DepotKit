// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

// MARK: - Blocking work off the cooperative pool

/// Runs blocking `work` on a dedicated thread and suspends the calling task until it returns.
///
/// Swift Testing runs tests in parallel on the Swift concurrency cooperative pool, which has only
/// one thread per CPU core. Test code that blocks (semaphores, dispatch groups, `Thread.sleep`,
/// `DispatchQueue.concurrentPerform`, synchronous waits for other threads) must not run there:
/// every blocked pool thread is unavailable to all other tests, and GCD does not grant additional
/// worker threads while the pool is saturated, so a few such tests can stall the whole run for
/// seconds and make unrelated, time-bounded waits fail.
///
/// Prefer returning results and evaluating `#expect` in the calling test task.
func onDedicatedThread<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread {
            continuation.resume(with: Result { try work() })
        }
    }
}

/// Non-throwing variant of `onDedicatedThread(_:)`.
func onDedicatedThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread {
            continuation.resume(returning: work())
        }
    }
}

/// Calls `body` once for every index in `0..<iterations`, spread across `threadCount` dedicated
/// threads, and suspends until all calls returned.
///
/// Use it instead of a task group for concurrency stress whose operations block (locks, sleeps).
func concurrentlyOnDedicatedThreads(
    iterations: Int,
    threadCount: Int = ProcessInfo.processInfo.activeProcessorCount,
    _ body: @escaping @Sendable (Int) -> Void,
) async {
    let nextIndex = OSAllocatedUnfairLock(initialState: 0)
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<threadCount {
            group.addTask {
                await onDedicatedThread {
                    while let index = nextIndex.withLock({ next -> Int? in
                        guard next < iterations else {
                            return nil
                        }
                        defer { next += 1 }
                        return next
                    }) {
                        body(index)
                    }
                }
            }
        }
    }
}

// MARK: - Whole tests off the cooperative pool

/// Runs `operation` in the current task, preferring DepotKit's I/O executor (`DepotIOExecutor`)
/// for it and for the child tasks it creates, so that blocking work does not occupy the cooperative
/// pool.
///
/// Unlike `onDedicatedThread(_:)`, the operation stays in the test's task, so `#expect` and other
/// task-local state work as usual.
func offCooperativePool<T, Failure: Error>(
    _ operation: () async throws(Failure) -> T,
) async throws(Failure) -> T {
    if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
        return try await withTaskExecutorPreference(DepotIOExecutor.shared, operation: operation)
    }
    return try await operation()
}

/// A trait that runs each test case of a test or suite via `offCooperativePool(_:)`.
///
/// Apply it to tests and suites that block for a noticeable time: long synchronous file I/O,
/// file coordination, contended locks, semaphores, or sleeps. Swift Testing starts every test on
/// the cooperative pool at once, so while such tests occupy pool threads, the asynchronous steps of
/// all other tests (observer deliveries, `Task.sleep` wake-ups) wait behind them.
struct OffCooperativePoolTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for _: Test,
        testCase _: Test.Case?,
        performing function: @Sendable () async throws -> Void,
    ) async throws {
        try await DepotKitTests.offCooperativePool {
            try await function()
        }
    }
}

extension Trait where Self == OffCooperativePoolTrait {
    /// Runs the test (or every test in the suite) off the cooperative pool; see
    /// ``OffCooperativePoolTrait``.
    static var offCooperativePool: Self { Self() }
}
