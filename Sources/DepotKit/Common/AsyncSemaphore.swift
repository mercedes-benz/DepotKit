// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import os

/// A simple async semaphore for limiting concurrency.
///
/// This is intentionally implemented without actors to keep overhead low in hot paths.
final class AsyncSemaphore: Sendable {
    private final class Waiter: @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Error>?
        var isCancelled: Bool = false
    }

    private struct State: Sendable {
        var count: Int
        var waiters: [Waiter] = []
        var headIndex: Int = 0
    }

    private enum WaitAction {
        case resume
        case enqueue
        case cancel
    }

    private let state: OSAllocatedUnfairLock<State>

    init(value: Int) {
        state = OSAllocatedUnfairLock(initialState: State(count: value))
    }

    var waiterCount: Int {
        state.withLock { $0.waiters.count - $0.headIndex }
    }

    func wait() async throws {
        try Task.checkCancellation()

        let waiter = Waiter()
        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let action: WaitAction = state.withLock { state in
                        if state.count > 0 {
                            state.count -= 1
                            return .resume
                        }

                        waiter.continuation = continuation

                        // Cancellation may have happened between `checkCancellation()` and now.
                        if waiter.isCancelled {
                            waiter.continuation = nil
                            return .cancel
                        }

                        state.waiters.append(waiter)
                        return .enqueue
                    }

                    switch action {
                    case .resume:
                        continuation.resume()
                    case .cancel:
                        continuation.resume(throwing: CancellationError())
                    case .enqueue:
                        break
                    }
                }
            },
            onCancel: {
                let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
                    waiter.isCancelled = true

                    guard let continuation = waiter.continuation else {
                        return nil
                    }

                    waiter.continuation = nil

                    if let idx = state.waiters.firstIndex(where: { $0 === waiter }) {
                        state.waiters.remove(at: idx)
                        if idx < state.headIndex {
                            state.headIndex -= 1
                        }
                    }

                    return continuation
                }

                continuation?.resume(throwing: CancellationError())
            },
        )
    }

    func signal() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
            while state.headIndex < state.waiters.count {
                let waiter = state.waiters[state.headIndex]
                state.headIndex += 1

                if let continuation = waiter.continuation {
                    waiter.continuation = nil

                    // Avoid O(n) removeFirst() in hot paths while still keeping memory bounded.
                    if state.headIndex > 64, state.headIndex >= state.waiters.count / 2 {
                        state.waiters.removeFirst(state.headIndex)
                        state.headIndex = 0
                    }

                    return continuation
                }
            }

            // All waiters consumed — reclaim the array to avoid unbounded memory growth.
            if state.headIndex > 0 {
                state.waiters.removeAll(keepingCapacity: false)
                state.headIndex = 0
            }

            state.count += 1
            return nil
        }

        continuation?.resume()
    }
}
