// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import os

/// A cancellation token used internally by DepotKit.
protocol DepotCancellable: Sendable {
    func cancel()
}

extension DepotCancellable where Self == NoopDepotCancellable {
    /// A cancellable that does nothing on cancel.
    static var noop: NoopDepotCancellable { NoopDepotCancellable() }
}

/// A ``DepotCancellable`` that does nothing. Returned when no actual cancellation is needed.
struct NoopDepotCancellable: DepotCancellable {
    /// Does nothing. This cancellable has no associated work to stop.
    func cancel() {}
}

/// A ``DepotCancellable`` backed by a closure. Guarantees at-most-once execution.
struct ClosureDepotCancellable: DepotCancellable {
    private let state: OSAllocatedUnfairLock<CallbackBox?>

    init(_ cancel: @escaping @Sendable () -> Void) {
        state = OSAllocatedUnfairLock(initialState: CallbackBox(cancel))
    }

    func cancel() {
        let cancel = state.withLock { state in
            let cancel = state
            state = nil
            return cancel
        }

        cancel?.call()
    }
}
