// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if canImport(Combine)

import Combine
import DepotKit
import os

/// A Combine publisher that emits `Value?` whenever the depot value stored under a
/// single distinct key changes, using an ``ErrorHandlingDecision`` closure to recover
/// from errors instead of wrapping emissions in `Result`.
///
/// ## Overview
///
/// `SingleValuePublisherHandlingErrors` is the error-recovering counterpart of
/// ``SingleValuePublisher``. Instead of forwarding errors to the subscriber as
/// `Result.failure`, it passes each error through the `errorHandler` closure you provide
/// and applies the returned ``ErrorHandlingDecision``:
///
/// | Decision | Effect |
/// |---|---|
/// | ``ErrorHandlingDecision/skip`` | The error is swallowed; nothing is emitted. |
/// | ``ErrorHandlingDecision/replaceWith(_:)`` | The given fallback value is emitted. |
/// | ``ErrorHandlingDecision/complete(_:)`` | The publisher terminates with the specified completion. |
///
/// ## Creating a Publisher
///
/// Use the convenience method on ``Depot``:
///
/// ```swift
/// depot.published(valueFor: themeKey) { error, isInitial in
///     isInitial ? .replaceWith("light") : .skip
/// }
/// .receive(on: DispatchQueue.main)
/// .assign(to: &$theme)
/// ```
struct SingleValuePublisherHandlingErrors<Value>: Publisher where Value: Sendable {
    typealias Output = Value?
    typealias Failure = Error

    private weak var depot: Depot?
    private let key: TypedDistinctKey<Value>
    private let initialValue: Bool
    private let errorHandler: @Sendable (Failure, Bool) -> ErrorHandlingDecision<Output, Failure>

    init(
        depot: Depot,
        key: some TypedDistinctKeyProtocol<Value>,
        initialValue: Bool,
        errorHandler: @escaping @Sendable (Failure, Bool) -> ErrorHandlingDecision<Output, Failure>,
    ) {
        self.depot = depot
        self.key = TypedDistinctKey(key)
        self.initialValue = initialValue
        self.errorHandler = errorHandler
    }

    func receive<S>(subscriber: S) where S: Subscriber & Sendable, S.Input == Output, S.Failure == Failure {
        guard let depot else {
            subscriber.receive(subscription: Subscriptions.empty)
            subscriber.receive(completion: .finished)
            return
        }

        let subscription = SingleValueSubscriptionHandlingErrors<S, Value>(
            subscriber,
            depot: depot,
            key: key,
            initialValue: initialValue,
            errorHandler: errorHandler,
        )
        subscriber.receive(subscription: subscription)
    }
}

// MARK: - Private

private final class SingleValueSubscriptionHandlingErrors<S: Subscriber & Sendable, Value>: Subscription,
    @unchecked Sendable
where S.Input == SingleValuePublisherHandlingErrors<Value>.Output, S.Failure == Error, Value: Sendable {
    private struct State: Sendable {
        var subscriber: S?
        var task: Task<Void, Never>?
        var didReceiveInitialValue = false
        var didStartObserving = false
    }

    private nonisolated(unsafe) weak var depot: Depot?
    private let key: TypedDistinctKey<Value>
    private let initialValue: Bool
    private let errorHandler: @Sendable (S.Failure, Bool) -> ErrorHandlingDecision<S.Input, S.Failure>
    private let state: OSAllocatedUnfairLock<State>

    init(
        _ subscriber: S,
        depot: Depot,
        key: TypedDistinctKey<Value>,
        initialValue: Bool,
        errorHandler: @escaping @Sendable (S.Failure, Bool) -> ErrorHandlingDecision<S.Input, S.Failure>,
    ) {
        self.depot = depot
        state = OSAllocatedUnfairLock(uncheckedState: State(subscriber: subscriber))
        self.key = key
        self.initialValue = initialValue
        self.errorHandler = errorHandler
    }

    func request(_ demand: Subscribers.Demand) {
        guard demand > 0 else {
            return
        }
        let (subscriber, alreadyObserving) = state.withLock { state -> (S?, Bool) in
            let sub = state.subscriber
            let started = state.didStartObserving
            if !started { state.didStartObserving = true }
            return (sub, started)
        }
        guard let subscriber, !alreadyObserving else {
            return
        }
        observe(subscriber)
    }

    func cancel() {
        state.withLock { state in
            state.task?.cancel()
            state.subscriber = nil
            state.task = nil
        }
    }

    private func observe(_ subscriber: S) {
        guard let depot else {
            subscriber.receive(completion: .finished)
            return
        }

        let stream = depot.values(for: key, initialValue: initialValue)
        let task = Task { [weak self] in
            for await change in stream {
                guard let self else {
                    return
                }
                let (sub, didReceiveInitial) = state.withLock { ($0.subscriber, $0.didReceiveInitialValue) }
                guard let sub else {
                    return
                }

                switch change {
                case let .success(value):
                    _ = sub.receive(value)
                case let .failure(error):
                    switch errorHandler(error, initialValue && !didReceiveInitial) {
                    case .skip:
                        break
                    case let .replaceWith(value):
                        _ = sub.receive(value)
                    case let .complete(completion):
                        sub.receive(completion: completion)
                        return
                    }
                }

                state.withLock { $0.didReceiveInitialValue = true }
            }
        }
        state.withLock { $0.task = task }
    }
}

#endif
