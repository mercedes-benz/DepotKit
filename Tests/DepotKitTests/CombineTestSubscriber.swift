// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if COMBINE_ENABLED && canImport(Combine)

import Combine
import os

/// A `Subscriber` with explicit, scriptable demand used to verify Combine back-pressure.
///
/// - `initialDemand` is requested from inside `receive(subscription:)` (nothing if `.none`).
/// - `onReceive` decides the demand returned from `receive(_:)` and may call back into the
///   subscription (reentrant `request` / `cancel`).
/// - Overlapping `receive` calls are recorded as serialization violations.
final class DemandTestSubscriber<Input, Failure: Error>: Subscriber, @unchecked Sendable {
    typealias ReceiveHandler = @Sendable (_ subscriber: DemandTestSubscriber, _ input: Input) -> Subscribers.Demand

    private struct State {
        var subscription: (any Subscription)?
        var values: [Input] = []
        var completions: [Subscribers.Completion<Failure>] = []
        var isInsideReceive = false
        var overlappingCalls = 0
    }

    let combineIdentifier = CombineIdentifier()
    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())
    private let changes = ChangeSignal()
    private let initialDemand: Subscribers.Demand
    private let onReceive: ReceiveHandler

    init(
        initialDemand: Subscribers.Demand,
        onReceive: @escaping ReceiveHandler = { _, _ in .none },
    ) {
        self.initialDemand = initialDemand
        self.onReceive = onReceive
    }

    // MARK: Subscriber

    func receive(subscription: any Subscription) {
        state.withLockUnchecked { $0.subscription = subscription }
        if initialDemand > 0 {
            subscription.request(initialDemand)
        }
    }

    func receive(_ input: Input) -> Subscribers.Demand {
        state.withLockUnchecked { state in
            if state.isInsideReceive {
                state.overlappingCalls += 1
            }
            state.isInsideReceive = true
            state.values.append(input)
        }
        changes.signal()
        let demand = onReceive(self, input)
        state.withLockUnchecked { $0.isInsideReceive = false }
        return demand
    }

    func receive(completion: Subscribers.Completion<Failure>) {
        state.withLockUnchecked { $0.completions.append(completion) }
        changes.signal()
    }

    // MARK: Driving the subscription

    var subscription: (any Subscription)? {
        state.withLockUnchecked { $0.subscription }
    }

    func request(_ demand: Subscribers.Demand) {
        subscription?.request(demand)
    }

    func cancel() {
        subscription?.cancel()
    }

    // MARK: Inspection

    var values: [Input] {
        state.withLockUnchecked { $0.values }
    }

    var completions: [Subscribers.Completion<Failure>] {
        state.withLockUnchecked { $0.completions }
    }

    var overlappingCalls: Int {
        state.withLockUnchecked { $0.overlappingCalls }
    }

    /// Waits until at least `count` values have been received.
    func waitForValues(count: Int, timeout: Duration = testWaitTimeout) async -> Bool {
        await changes.wait(timeout: timeout) { values.count >= count }
    }

    /// Waits until a completion has been received.
    func waitForCompletion(timeout: Duration = testWaitTimeout) async -> Bool {
        await changes.wait(timeout: timeout) { !completions.isEmpty }
    }
}

#endif
