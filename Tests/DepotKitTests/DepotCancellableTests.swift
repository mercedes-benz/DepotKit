// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

@Suite
struct DepotCancellableTests {
    // MARK: - ClosureDepotCancellable

    @Test("cancel executes the closure")
    func cancelExecutesClosure() {
        let executed = OSAllocatedUnfairLock(initialState: false)

        let cancellable = ClosureDepotCancellable {
            executed.withLock { $0 = true }
        }

        cancellable.cancel()

        #expect(executed.withLock { $0 } == true)
    }

    @Test("cancel executes at most once")
    func cancelExecutesAtMostOnce() {
        let count = OSAllocatedUnfairLock(initialState: 0)

        let cancellable = ClosureDepotCancellable {
            count.withLock { $0 += 1 }
        }

        cancellable.cancel()
        cancellable.cancel()
        cancellable.cancel()

        #expect(count.withLock { $0 } == 1)
    }

    @Test("concurrent cancel calls execute closure exactly once")
    func concurrentCancelExecutesOnce() async {
        let count = OSAllocatedUnfairLock(initialState: 0)

        let cancellable = ClosureDepotCancellable {
            count.withLock { $0 += 1 }
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    cancellable.cancel()
                }
            }
        }

        #expect(count.withLock { $0 } == 1)
    }

    // MARK: - NoopDepotCancellable

    @Test("noop cancellable does nothing")
    func noopCancellableDoesNothing() {
        let cancellable: any DepotCancellable = .noop
        cancellable.cancel()
    }

    @Test("noop static factory returns NoopDepotCancellable")
    func noopStaticFactory() {
        let cancellable: any DepotCancellable = .noop
        #expect(cancellable is NoopDepotCancellable)
    }
}
