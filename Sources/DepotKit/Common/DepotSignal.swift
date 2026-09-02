// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import os

/// A tiny, dependency-free signal type (similar to a `PassthroughSubject`) used for internal event bridging.
///
/// `DepotSignal` exists instead of `AsyncStream` because depot observations are **synchronous** and
/// **multi-listener**: every registered observer is invoked inline on the calling thread when `emit`
/// is called. `AsyncStream` is single-consumer, requires an async context to iterate, and introduces
/// buffering/back-pressure semantics that don't match the depot's transaction notification model
/// (coalesced notifications at the end of a transaction, delivered synchronously under the depot's lock).
/// Unlike Combine's `PassthroughSubject`, `DepotSignal` has zero framework dependencies and works on
/// all Apple platforms including watchOS without pulling in the Combine framework.
final class DepotSignal<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var nextID: UInt64 = 0
        var observers: [UInt64: @Sendable (Value) -> Void] = [:]
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    /// Creates a signal with no observers.
    init() {}

    /// Adds an observer and returns a cancellable to remove it.
    @discardableResult
    func observe(_ observer: @escaping @Sendable (Value) -> Void) -> any DepotCancellable {
        let id = state.withLock { state -> UInt64 in
            let id = state.nextID
            state.nextID += 1
            state.observers[id] = observer
            return id
        }

        return ClosureDepotCancellable { [state] in
            state.withLock { state in
                state.observers[id] = nil
            }
        }
    }

    /// Sends `value` to every registered observer synchronously.
    func emit(_ value: Value) {
        let observers: [@Sendable (Value) -> Void] = state.withLock { state in
            guard !state.observers.isEmpty else {
                return []
            }
            return Array(state.observers.values)
        }

        for observer in observers {
            observer(value)
        }
    }
}

extension DepotSignal where Value == Void {
    /// Convenience overload that sends `Void` to every registered observer.
    func emit() {
        emit(())
    }
}
