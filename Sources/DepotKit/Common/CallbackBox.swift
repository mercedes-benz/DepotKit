// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

/// An immutable reference to a callback, for keeping callbacks in lock-protected state.
///
/// Locks such as `OSAllocatedUnfairLock` keep their state generically. A function value stored
/// directly as (or in a tuple of) that state is wrapped in another reabstraction thunk on every
/// `withLock` access, even a read. Calls then get slower with every access, and releasing the
/// function after a few thousand accesses overflows the stack. Keep a reference to this box in the
/// lock instead: the function stored in it is never rewrapped.
///
/// Passing a function through other generic code, such as `Optional.map`, wraps it as well; box an
/// optional callback with the failable initializer instead.
final class CallbackBox: Sendable {
    let call: @Sendable () -> Void

    init(_ call: @escaping @Sendable () -> Void) {
        self.call = call
    }

    /// Boxes `call`, or returns `nil` when there is no callback.
    convenience init?(_ call: (@Sendable () -> Void)?) {
        guard let call else {
            return nil
        }
        self.init(call)
    }
}
