// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

@Suite
struct AsyncSemaphoreTests {
    @Test("wait acquires immediately when count > 0")
    func waitAcquiresImmediately() async throws {
        let sem = AsyncSemaphore(value: 2)
        try await sem.wait()
        try await sem.wait()
        // Both acquired without blocking
        sem.signal()
        sem.signal()
    }

    @Test("wait blocks when count == 0 and resumes on signal")
    func waitBlocksAndResumes() async throws {
        let sem = AsyncSemaphore(value: 1)
        try await sem.wait()  // count = 0

        let resumed = OSAllocatedUnfairLock(initialState: false)

        let task = Task {
            try await sem.wait()  // should block
            resumed.withLock { $0 = true }
        }

        // Give task time to enqueue
        try await Task.sleep(for: .milliseconds(50))
        #expect(resumed.withLock { $0 } == false)

        sem.signal()  // should wake the waiter

        try await Task.sleep(for: .milliseconds(50))
        #expect(resumed.withLock { $0 } == true)

        sem.signal()
        _ = await task.result
    }

    @Test("multiple waiters are served FIFO")
    func multipleWaitersFIFO() async throws {
        let sem = AsyncSemaphore(value: 0)
        let order = OSAllocatedUnfairLock<[Int]>(initialState: [])

        // Spawn tasks one at a time, polling waiterCount to confirm each is
        // actually enqueued before spawning the next.
        let task1 = Task {
            try await sem.wait()
            order.withLock { $0.append(1) }
        }
        while sem.waiterCount < 1 { await Task.yield() }

        let task2 = Task {
            try await sem.wait()
            order.withLock { $0.append(2) }
        }
        while sem.waiterCount < 2 { await Task.yield() }

        let task3 = Task {
            try await sem.wait()
            order.withLock { $0.append(3) }
        }
        while sem.waiterCount < 3 { await Task.yield() }

        // Signal and await one at a time to verify the correct waiter is served.
        sem.signal()
        _ = await task1.result
        #expect(order.withLock { $0 } == [1])

        sem.signal()
        _ = await task2.result
        #expect(order.withLock { $0 } == [1, 2])

        sem.signal()
        _ = await task3.result
        #expect(order.withLock { $0 } == [1, 2, 3])
    }

    @Test("cancelled task while waiting throws CancellationError")
    func cancelledWhileWaiting() async throws {
        let sem = AsyncSemaphore(value: 0)  // will block

        let task = Task {
            try await sem.wait()
        }

        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        let result = await task.result
        switch result {
        case .success:
            Issue.record("Expected cancellation error")
        case let .failure(error):
            #expect(error is CancellationError)
        }
    }

    @Test("already-cancelled task throws immediately")
    func alreadyCancelledThrows() async throws {
        let sem = AsyncSemaphore(value: 1)

        let task = Task {
            // Cancel before wait
            try await Task.sleep(for: .milliseconds(10))
            try Task.checkCancellation()
            try await sem.wait()
        }

        task.cancel()

        let result = await task.result
        switch result {
        case .success:
            Issue.record("Expected cancellation error")
        case let .failure(error):
            #expect(error is CancellationError)
        }
    }

    @Test("signal without waiters increments count")
    func signalWithoutWaiters() async throws {
        let sem = AsyncSemaphore(value: 0)
        sem.signal()
        sem.signal()
        // Now count = 2, two waits should succeed immediately
        try await sem.wait()
        try await sem.wait()
    }

    @Test("many waiters and signals exercise compaction")
    func compactionPath() async throws {
        let sem = AsyncSemaphore(value: 0)
        let completed = OSAllocatedUnfairLock(initialState: 0)

        // Enqueue 100 waiters to trigger the >64 compaction path
        var tasks = [Task<Void, Error>]()
        for _ in 0..<100 {
            let task = Task {
                try await sem.wait()
                completed.withLock { $0 += 1 }
            }
            tasks.append(task)
        }

        try await Task.sleep(for: .milliseconds(50))

        // Signal all
        for _ in 0..<100 {
            sem.signal()
        }

        for task in tasks {
            _ = await task.result
        }

        #expect(completed.withLock { $0 } == 100)
    }

    @Test("concurrent wait and signal stress test")
    func concurrentStress() async throws {
        let sem = AsyncSemaphore(value: 4)
        let active = OSAllocatedUnfairLock(initialState: 0)
        let maxActive = OSAllocatedUnfairLock(initialState: 0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try? await sem.wait()
                    let current = active.withLock { val -> Int in
                        val += 1
                        return val
                    }
                    maxActive.withLock { $0 = max($0, current) }
                    try? await Task.sleep(for: .milliseconds(5))
                    active.withLock { $0 -= 1 }
                    sem.signal()
                }
            }
        }

        #expect(maxActive.withLock { $0 } <= 4)
    }
}
