// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if canImport(Combine)

import Combine
import DepotKit
import os

/// A Combine publisher that emits `[Value]` whenever **any** depot value matching a
/// (possibly wildcard) key changes, using an ``ErrorHandlingDecision`` closure to
/// recover from errors instead of wrapping emissions in `Result`.
///
/// ## Creating a Publisher
///
/// ```swift
/// depot.published(valuesFor: allUsersKey) { error, isInitial in
///     isInitial ? .replaceWith([]) : .skip
/// }
/// .receive(on: DispatchQueue.main)
/// .assign(to: &$userNames)
/// ```
struct MultiValuePublisherHandlingErrors<Value>: Publisher where Value: Sendable {
    typealias Output = [Value]
    typealias Failure = Error

    private weak var depot: Depot?
    private let key: TypedKey<Value>
    private let initialValues: Bool
    private let errorHandler: @Sendable (Failure, Bool) -> ErrorHandlingDecision<Output, Failure>

    init(
        depot: Depot,
        key: some TypedKeyProtocol<Value>,
        initialValues: Bool,
        errorHandler: @escaping @Sendable (Failure, Bool) -> ErrorHandlingDecision<Output, Failure>,
    ) {
        self.depot = depot
        self.key = TypedKey(key)
        self.initialValues = initialValues
        self.errorHandler = errorHandler
    }

    func receive<S>(subscriber: S) where S: Subscriber & Sendable, S.Input == Output, S.Failure == Failure {
        guard let depot else {
            subscriber.receive(subscription: Subscriptions.empty)
            subscriber.receive(completion: .finished)
            return
        }

        let subscription = MultiValueSubscriptionHandlingErrors<S, Value>(
            subscriber,
            depot: depot,
            key: key,
            initialValues: initialValues,
            errorHandler: errorHandler,
        )
        subscriber.receive(subscription: subscription)
    }
}

// MARK: - Private

private final class MultiValueSubscriptionHandlingErrors<S: Subscriber & Sendable, Value>: Subscription,
    @unchecked Sendable
where S.Input == MultiValuePublisherHandlingErrors<Value>.Output, S.Failure == Error, Value: Sendable {
    private struct State: Sendable {
        var subscriber: S?
        var task: Task<Void, Never>?
        var didReceiveInitialValues = false
        var didStartObserving = false
    }

    private nonisolated(unsafe) weak var depot: Depot?
    private let key: TypedKey<Value>
    private let initialValues: Bool
    private let errorHandler: @Sendable (S.Failure, Bool) -> ErrorHandlingDecision<S.Input, S.Failure>
    private let state: OSAllocatedUnfairLock<State>

    init(
        _ subscriber: S,
        depot: Depot,
        key: TypedKey<Value>,
        initialValues: Bool,
        errorHandler: @escaping @Sendable (S.Failure, Bool) -> ErrorHandlingDecision<S.Input, S.Failure>,
    ) {
        self.depot = depot
        state = OSAllocatedUnfairLock(uncheckedState: State(subscriber: subscriber))
        self.key = key
        self.initialValues = initialValues
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

        let stream = depot.values(for: key, initialValues: initialValues)
        let task = Task { [weak self] in
            for await result in stream {
                guard let self else {
                    return
                }
                let (sub, didReceiveInitial) = state.withLock {
                    ($0.subscriber, $0.didReceiveInitialValues)
                }
                guard let sub else {
                    return
                }

                switch result {
                case let .success(values):
                    _ = sub.receive(values)
                case let .failure(error):
                    switch errorHandler(error, initialValues && !didReceiveInitial) {
                    case .skip:
                        break
                    case let .replaceWith(values):
                        _ = sub.receive(values)
                    case let .complete(completion):
                        sub.receive(completion: completion)
                        return
                    }
                }

                state.withLock { $0.didReceiveInitialValues = true }
            }
        }
        state.withLock { $0.task = task }
    }
}

#endif
