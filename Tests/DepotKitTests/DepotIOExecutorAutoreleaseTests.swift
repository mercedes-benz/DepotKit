// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// An object that reports its deallocation.
private final class DeallocationReporter: NSObject {
    private let onDeinit: @Sendable () -> Void

    init(onDeinit: @escaping @Sendable () -> Void) {
        self.onDeinit = onDeinit
    }

    deinit {
        onDeinit()
    }
}

/// The executor's threads are long-lived, so objects that Foundation autoreleases while a job runs
/// must be released when the job finishes rather than piling up until the thread exits. The Swift
/// runtime drains an autorelease pool around every job that `runSynchronously(on:)` runs.
///
/// These tests must not use the `.offCooperativePool` trait: it runs the test itself on the shared
/// executor.
@Suite("DepotIOExecutor autorelease pools")
struct DepotIOExecutorAutoreleaseTests {
    /// Runs `work` in a task that prefers `executor`, without awaiting the task (which would
    /// escalate its priority), and returns `work`'s result.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    private func run<T: Sendable>(on executor: DepotIOExecutor, _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Task(executorPreference: executor) {
                continuation.resume(returning: work())
            }
        }
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("objects autoreleased by a job are released when the job finishes, not when the thread exits")
    func autoreleasedObjectsAreReleasedAfterEachJob() async throws {
        // One long-lived thread runs all jobs, so a job only starts after the previous one returned.
        let executor = DepotIOExecutor(maximumThreadCount: 1, idleTimeout: 60)
        let released = OSAllocatedUnfairLock(initialState: 0)
        let iterations = 1000

        for iteration in 1...iterations {
            let releasedDuringJob = await run(on: executor) {
                // Foundation autoreleases objects like this one, for example in every file coordination.
                let reporter = DeallocationReporter { released.withLock { $0 += 1 } }
                _ = Unmanaged.passRetained(reporter).autorelease()
                return released.withLock { $0 }
            }
            let releasedCount = await run(on: executor) { released.withLock { $0 } }
            guard releasedDuringJob == iteration - 1, releasedCount == iteration else {
                Issue.record(
                    "job \(iteration): \(releasedDuringJob) objects released during the job, \(releasedCount) after it"
                )
                break
            }
        }

        #expect(executor.currentThreadCount == 1, "all jobs ran on the same thread")
    }
}
