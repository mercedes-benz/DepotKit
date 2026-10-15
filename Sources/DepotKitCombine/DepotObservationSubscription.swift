// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if canImport(Combine)

import Combine
import os

/// What a depot subscription does with one element produced by the underlying observation stream.
enum ObservationEvent<Input, Failure: Error> {
    /// Offer the value to the subscriber (subject to demand; see ``DepotObservationSubscription``).
    case emit(Input)
    /// Drop the element without emitting anything.
    case skip
    /// Terminate the subscription with the given completion.
    case complete(Subscribers.Completion<Failure>)
}

extension ObservationEvent where Input: Sendable {
    /// Maps a user-provided ``ErrorHandlingDecision`` onto an observation event.
    init(_ decision: ErrorHandlingDecision<Input, Failure>) {
        switch decision {
        case .skip:
            self = .skip
        case let .replaceWith(value):
            self = .emit(value)
        case let .complete(completion):
            self = .complete(completion)
        }
    }
}

/// Test-only view onto a ``DepotObservationSubscription`` (accessible via `@testable import`).
protocol DepotObservationSubscriptionProbe: AnyObject, Sendable {
    /// The number of stream elements the subscription has fully processed: transformed, and
    /// delivered if demand allowed (or left pending, skipped, or turned into a completion).
    var processedElementCount: Int { get }
}

/// The demand-aware Combine subscription shared by all DepotKit publishers.
///
/// ## Demand
///
/// The subscription honors the Combine back-pressure contract:
///
/// - Outstanding demand is accumulated from `request(_:)` calls and from the demand returned by
///   the subscriber's `receive(_:)`; it is decremented for every delivered value. The subscriber
///   never receives more values than it requested.
/// - Observation of the depot starts lazily, on the first positive demand.
/// - **Conflation policy:** depot publishers describe *state*, so values that arrive while the
///   outstanding demand is zero are not queued. Only the most recent pending value is kept
///   (replacing any older pending value) and it is delivered as soon as demand becomes
///   available. Intermediate states are dropped.
/// - A completion (from an ``ErrorHandlingDecision/complete(_:)`` decision, or because the depot
///   is gone) does not require demand. A pending value is delivered before the completion if
///   demand allows; otherwise it is discarded.
///
/// ## Concurrency
///
/// All state is protected by a lock that is **never** held while calling into the subscriber.
/// Calls into the subscriber are serialized: if another thread (or a reentrant call from inside
/// `receive(_:)`) adds demand or produces a value while a delivery is in progress, the delivering
/// thread picks it up after `receive(_:)` returns. `request(_:)` and `cancel()` are therefore
/// safe to call from any thread, including reentrantly from within `receive(_:)`.
final class DepotObservationSubscription<S: Subscriber & Sendable, Element: Sendable>: Subscription,
    DepotObservationSubscriptionProbe, @unchecked Sendable
{
    /// Maps one stream element to an event. `isFirst` is `true` for the first element only.
    typealias Transform = @Sendable (_ element: Element, _ isFirst: Bool) -> ObservationEvent<S.Input, S.Failure>

    /// Creates the stream to observe, or returns `nil` when the depot is no longer available.
    typealias StreamFactory = @Sendable () -> AsyncStream<Element>?

    private struct State {
        var subscriber: S?
        var demand: Subscribers.Demand = .none
        var pendingValue: S.Input?
        var pendingCompletion: Subscribers.Completion<S.Failure>?
        var isDelivering = false
        var didStartObserving = false
        var isFirstElement = true
        var task: Task<Void, Never>?
        var processedElementCount = 0
    }

    private enum Action {
        case idle
        case deliver(S, S.Input)
        case complete(S, Subscribers.Completion<S.Failure>, Task<Void, Never>?)
    }

    private let state: OSAllocatedUnfairLock<State>
    private let makeStream: StreamFactory
    private let transform: Transform

    init(_ subscriber: S, makeStream: @escaping StreamFactory, transform: @escaping Transform) {
        state = OSAllocatedUnfairLock(uncheckedState: State(subscriber: subscriber))
        self.makeStream = makeStream
        self.transform = transform
    }

    /// Ends the observation when the subscriber releases the subscription without cancelling it.
    ///
    /// The observation task holds the subscription only weakly, so without this it would keep the
    /// depot's stream registered until the next element arrives or the depot is deallocated.
    deinit {
        state.withLockUnchecked { $0.task }?.cancel()
    }

    var processedElementCount: Int {
        state.withLockUnchecked { $0.processedElementCount }
    }

    // MARK: Subscription

    func request(_ demand: Subscribers.Demand) {
        guard demand > 0 else {
            return
        }
        let shouldStart = state.withLockUnchecked { state -> Bool in
            guard state.subscriber != nil else {
                return false
            }
            state.demand += demand
            guard !state.didStartObserving else {
                return false
            }
            state.didStartObserving = true
            return true
        }
        if shouldStart {
            startObserving()
        }
        drain()
    }

    func cancel() {
        let task = state.withLockUnchecked { state -> Task<Void, Never>? in
            state.subscriber = nil
            state.pendingValue = nil
            state.pendingCompletion = nil
            state.demand = .none
            defer { state.task = nil }
            return state.task
        }
        task?.cancel()
    }

    // MARK: Producer side

    /// Processes one element of the observation stream.
    ///
    /// - Returns: `true` when the subscription is finished and observation should stop.
    @discardableResult
    func process(_ element: Element) -> Bool {
        let isFirst = state.withLockUnchecked { state -> Bool? in
            guard state.subscriber != nil, state.pendingCompletion == nil else {
                state.processedElementCount += 1
                return nil
            }
            defer { state.isFirstElement = false }
            return state.isFirstElement
        }
        guard let isFirst else {
            return true
        }

        let event = transform(element, isFirst)

        let isFinished = state.withLockUnchecked { state -> Bool in
            guard state.subscriber != nil, state.pendingCompletion == nil else {
                return true
            }
            switch event {
            case .skip:
                return false
            case let .emit(value):
                state.pendingValue = value
                return false
            case let .complete(completion):
                state.pendingCompletion = completion
                return true
            }
        }
        drain()
        state.withLockUnchecked { $0.processedElementCount += 1 }
        return isFinished
    }

    private func startObserving() {
        guard let stream = makeStream() else {
            state.withLockUnchecked { state in
                if state.subscriber != nil, state.pendingCompletion == nil {
                    state.pendingCompletion = .finished
                }
            }
            return
        }

        let task = Task { [weak self] in
            for await element in stream {
                guard let self, !process(element) else {
                    return
                }
            }
            // The depot finishes its observation streams when it is deallocated.
            guard !Task.isCancelled else {
                return
            }
            self?.observationDidFinish()
        }
        let isAlreadyFinished = state.withLockUnchecked { state -> Bool in
            guard state.subscriber != nil, state.pendingCompletion == nil else {
                return true
            }
            state.task = task
            return false
        }
        if isAlreadyFinished {
            task.cancel()
        }
    }

    /// Completes the subscription with `.finished` because the observation stream ended (the
    /// depot is gone). Does nothing if the subscription is already cancelled or completing.
    private func observationDidFinish() {
        state.withLockUnchecked { state in
            if state.subscriber != nil, state.pendingCompletion == nil {
                state.pendingCompletion = .finished
            }
        }
        drain()
    }

    // MARK: Delivery

    /// Delivers pending values (and finally a pending completion) while demand allows.
    ///
    /// Only one thread delivers at a time; concurrent and reentrant callers return immediately
    /// and leave the remaining work to the delivering thread.
    private func drain() {
        var returnedDemand: Subscribers.Demand?
        while true {
            let action = state.withLockUnchecked { state -> Action in
                if let additional = returnedDemand {
                    state.isDelivering = false
                    if state.subscriber != nil {
                        state.demand += additional
                    }
                } else if state.isDelivering {
                    return .idle
                }

                guard let subscriber = state.subscriber else {
                    return .idle
                }
                if state.demand > 0, let value = state.pendingValue {
                    state.pendingValue = nil
                    state.demand -= 1
                    state.isDelivering = true
                    return .deliver(subscriber, value)
                }
                if let completion = state.pendingCompletion {
                    state.subscriber = nil
                    state.pendingValue = nil
                    state.pendingCompletion = nil
                    state.demand = .none
                    defer { state.task = nil }
                    return .complete(subscriber, completion, state.task)
                }
                return .idle
            }

            switch action {
            case .idle:
                return
            case let .deliver(subscriber, value):
                returnedDemand = subscriber.receive(value)
            case let .complete(subscriber, completion, task):
                task?.cancel()
                subscriber.receive(completion: completion)
                return
            }
        }
    }
}

#endif
