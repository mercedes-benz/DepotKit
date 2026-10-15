// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

// These tests must not use the `.offCooperativePool` trait: it runs the test itself on the shared
// executor.

/// The name of the current thread.
private func currentThreadName() -> String {
    Thread.isMainThread ? "main" : (Thread.current.name ?? "")
}

/// A gate that blocks the threads that wait for it until it is opened.
private final class Gate: Sendable {
    private let condition = NSCondition()
    private let state = OSAllocatedUnfairLock(initialState: (isOpen: false, waiting: 0))

    /// The number of threads that are blocked in `wait()`.
    var waitingCount: Int { state.withLock { $0.waiting } }

    /// Blocks the calling thread until the gate is opened, or for at most `timeout`.
    func wait(timeout: TimeInterval = 30) {
        condition.lock()
        defer { condition.unlock() }
        state.withLock { $0.waiting += 1 }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !state.withLock({ $0.isOpen }), condition.wait(until: deadline) {}
        state.withLock { $0.waiting -= 1 }
    }

    func open() {
        condition.lock()
        state.withLock { $0.isOpen = true }
        condition.broadcast()
        condition.unlock()
    }
}

/// Starts a task that prefers `executor` and runs `work` on it, without awaiting the task (which
/// would escalate its priority), and returns `work`'s result.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private func run<T: Sendable>(
    on executor: DepotIOExecutor,
    priority: TaskPriority? = nil,
    _ work: @escaping @Sendable () -> T,
) async -> T {
    await withCheckedContinuation { continuation in
        Task(executorPreference: executor, priority: priority) {
            continuation.resume(returning: work())
        }
    }
}

@Suite("DepotIOExecutor")
struct DepotIOExecutorTests {
    @TaskLocal
    static var marker: String?

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("jobs run on DepotKit.io threads within the calling task")
    func jobsRunOnIOThreadsWithinTheTask() async throws {
        #expect(DepotIOExecutor.threadName == "DepotKit.io")
        let executor = DepotIOExecutor()

        let (name, marker, priority) = await Task(priority: .utility) {
            await Self.$marker.withValue("caller") {
                await withTaskExecutorPreference(executor) {
                    (currentThreadName(), Self.marker, Task.currentPriority)
                }
            }
        }.value

        #expect(name == "DepotKit.io")
        #expect(marker == "caller")
        // Awaiting the task may escalate its priority, but never lowers it.
        #expect(priority >= .utility)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("cancellation of the calling task is visible on the executor")
    func cancellationPropagates() async throws {
        let executor = DepotIOExecutor()

        let isCancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await withTaskExecutorPreference(executor) {
                Task.isCancelled
            }
        }.value

        #expect(isCancelled)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(
        "jobs run at the quality of service of their priority",
        arguments: [
            (TaskPriority.background, QOS_CLASS_BACKGROUND),
            (.utility, QOS_CLASS_UTILITY),
            (.medium, QOS_CLASS_DEFAULT),
            (.userInitiated, QOS_CLASS_USER_INITIATED),
        ],
    )
    func jobsRunAtTheirQoS(priority: TaskPriority, expected: qos_class_t) async throws {
        let executor = DepotIOExecutor()

        let qos = await run(on: executor, priority: priority) { qos_class_self() }

        #expect(qos == expected)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("job priorities map to quality-of-service classes")
    func qosMapping() {
        func qos(_ rawValue: UInt8) -> qos_class_t {
            DepotIOExecutor.qosClass(forPriority: rawValue)
        }
        #expect(qos(0) == QOS_CLASS_DEFAULT)
        #expect(qos(TaskPriority.background.rawValue) == QOS_CLASS_BACKGROUND)
        #expect(qos(TaskPriority.utility.rawValue) == QOS_CLASS_UTILITY)
        #expect(qos(TaskPriority.medium.rawValue) == QOS_CLASS_DEFAULT)
        #expect(qos(TaskPriority.userInitiated.rawValue) == QOS_CLASS_USER_INITIATED)
        #expect(qos(TaskPriority.userInitiated.rawValue + 1) == QOS_CLASS_USER_INTERACTIVE)
        #expect(qos(UInt8.max) == QOS_CLASS_USER_INTERACTIVE)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("a blocked job does not hold up other jobs")
    func blockedJobDoesNotHoldUpOthers() async throws {
        let executor = DepotIOExecutor()
        let gate = Gate()

        let blocked = Task(executorPreference: executor) {
            gate.wait()
        }
        #expect(await waitUntil { gate.waitingCount == 1 })

        // Runs on another thread that is started for it.
        let name = await run(on: executor) { currentThreadName() }
        let stillBlocked = gate.waitingCount == 1
        let threadCount = executor.currentThreadCount

        gate.open()
        await blocked.value

        #expect(name == "DepotKit.io")
        #expect(stillBlocked)
        #expect(threadCount == 2)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("jobs that arrive while an idle thread is being woken up do not queue behind it")
    func burstOnIdleThread() async throws {
        let executor = DepotIOExecutor()
        // Leaves one idle thread.
        _ = await run(on: executor) {}
        #expect(executor.currentThreadCount == 1)

        let gate = Gate()
        let secondRan = OSAllocatedUnfairLock(initialState: false)
        // Enqueued back to back, typically before the idle thread woke up for the first job.
        let first = Task(executorPreference: executor) { gate.wait() }
        let second = Task(executorPreference: executor) { secondRan.withLock { $0 = true } }

        let ranWhileFirstBlocked = await waitUntil(timeout: .seconds(10)) { secondRan.withLock { $0 } }
        gate.open()
        await first.value
        await second.value

        #expect(ranWhileFirstBlocked)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("idle threads exit, and later jobs start new threads")
    func idleThreadsExitAndRestart() async throws {
        let executor = DepotIOExecutor(idleTimeout: 0.05)

        #expect(await run(on: executor) { currentThreadName() } == "DepotKit.io")
        #expect(await waitUntil { executor.currentThreadCount == 0 })

        #expect(await run(on: executor) { currentThreadName() } == "DepotKit.io")
        #expect(await waitUntil { executor.currentThreadCount == 0 })
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("jobs enqueued while idle threads time out still run", .timeLimit(.minutes(1)))
    func enqueueRacingIdleExit() async throws {
        // Idle threads exit after about as long as the pauses between jobs, so enqueues keep
        // racing threads that are about to exit.
        let executor = DepotIOExecutor(idleTimeout: 0.0005)
        var completed = 0
        for iteration in 0..<500 {
            if iteration.isMultiple(of: 2) {
                try await Task.sleep(for: .microseconds(500))
            }
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<(iteration % 3 + 1) {
                    group.addTask(executorPreference: executor) {}
                }
            }
            completed += 1
        }

        #expect(completed == 500)
        #expect(await waitUntil { executor.currentThreadCount == 0 })
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("at most the maximum number of threads run; further jobs wait for a free thread")
    func threadCountIsCapped() async throws {
        let executor = DepotIOExecutor(maximumThreadCount: 2)
        let gate = Gate()
        let thirdRan = OSAllocatedUnfairLock(initialState: false)

        let blocked = (0..<2).map { _ in
            Task(executorPreference: executor) { gate.wait() }
        }
        #expect(await waitUntil { gate.waitingCount == 2 })
        let third = Task(executorPreference: executor) {
            thirdRan.withLock { $0 = true }
        }
        // The third job has no thread while both threads are blocked.
        try await Task.sleep(for: .milliseconds(50))
        let ranWhileBlocked = thirdRan.withLock { $0 }
        let threadCount = executor.currentThreadCount

        gate.open()
        await third.value
        for task in blocked {
            await task.value
        }

        #expect(!ranWhileBlocked)
        #expect(threadCount == 2)
        #expect(thirdRan.withLock { $0 })
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("many concurrent tasks all complete", .timeLimit(.minutes(1)))
    func stress() async throws {
        let executor = DepotIOExecutor(maximumThreadCount: 8, idleTimeout: 0.01)
        let names = OSAllocatedUnfairLock(initialState: Set<String>())
        let maximumThreadCount = OSAllocatedUnfairLock(initialState: 0)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<2000 {
                group.addTask(executorPreference: executor) {
                    names.withLock { _ = $0.insert(currentThreadName()) }
                    let count = executor.currentThreadCount
                    maximumThreadCount.withLock { $0 = max($0, count) }
                    if index.isMultiple(of: 50) {
                        // Block now and then, so that further threads are started.
                        usleep(2000)
                    }
                    await Task.yield()
                    names.withLock { _ = $0.insert(currentThreadName()) }
                }
            }
        }

        #expect(names.withLock { $0 } == ["DepotKit.io"])
        #expect(maximumThreadCount.withLock { $0 } <= 8)
    }
}
