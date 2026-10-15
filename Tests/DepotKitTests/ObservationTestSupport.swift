// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if OBSERVATION_ENABLED && canImport(SwiftUI) && canImport(Observation)

import Observation

/// The upper bound for the waits in the Observation adapter tests.
///
/// The waits return as soon as their condition holds, so the timeout is only reached when a test
/// fails. It is generous so that the tests also pass on heavily loaded machines.
let observationTestTimeout: Duration = testWaitTimeout

/// Waits on the main actor until `predicate` holds, re-evaluating it whenever an `@Observable`
/// property that it read changes.
///
/// Use this for conditions on `@Observable` state, such as the `value` or `error` of an adapter
/// storage. Changes to state that is not observable do not wake the wait; use
/// `waitOnMain(timeout:pollInterval:pump:_:)` for conditions on such state.
///
/// - Returns: Whether `predicate` held before `timeout` elapsed.
@MainActor
func waitUntilObserved(
    timeout: Duration = observationTestTimeout,
    _ predicate: () -> Bool,
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while true {
        let (changes, continuation) = AsyncStream<Void>.makeStream()
        let holds = withObservationTracking {
            predicate()
        } onChange: {
            continuation.finish()
        }
        // Check again now that the tracking is installed, in case a change happened in between.
        if holds || predicate() {
            return true
        }
        if clock.now >= deadline || Task.isCancelled {
            return false
        }
        let timeoutTask = Task {
            try? await Task.sleep(until: deadline, clock: clock)
            continuation.finish()
        }
        for await _ in changes {}
        timeoutTask.cancel()
    }
}

/// Polls `predicate` on the main actor until it holds or `timeout` elapses, running `pump` before
/// every check (e.g. to let a hosting view lay out and re-render).
///
/// Use this for conditions on state that is not `@Observable`, such as what a hosted view
/// rendered, the depot's active stream count, or released references.
///
/// - Returns: Whether `predicate` held before `timeout` elapsed.
@MainActor
func waitOnMain(
    timeout: Duration = observationTestTimeout,
    pollInterval: Duration = .milliseconds(5),
    pump: () -> Void = {},
    _ predicate: () -> Bool,
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline, !Task.isCancelled {
        pump()
        if predicate() {
            return true
        }
        try? await Task.sleep(for: pollInterval)
    }
    pump()
    return predicate()
}

#endif
