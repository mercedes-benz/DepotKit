// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if canImport(Combine)

import Combine
import DepotKit
import os

/// A Combine publisher that emits `Result<AvailableValuesResult<Value>, Error>` whenever
/// **any** depot value matching a (possibly wildcard) key changes.
///
/// Unlike ``MultiValuePublisher`` which wraps all values in a single `Result`,
/// this publisher partitions results into successfully decoded values and per-key errors.
///
/// The publisher **never completes** on its own — it stays active until cancelled or the
/// depot is deallocated.
struct AvailableValuesPublisher<Value>: Publisher where Value: Sendable {
    typealias Output = Result<AvailableValuesResult<Value>, Error>
    typealias Failure = Never

    private weak var depot: Depot?
    private let key: TypedKey<Value>
    private let initialValues: Bool

    init(depot: Depot, key: some TypedKeyProtocol<Value>, initialValues: Bool) {
        self.depot = depot
        self.key = TypedKey(key)
        self.initialValues = initialValues
    }

    func receive<S>(subscriber: S) where S: Subscriber & Sendable, S.Input == Output, S.Failure == Failure {
        guard let depot else {
            subscriber.receive(subscription: Subscriptions.empty)
            subscriber.receive(completion: .finished)
            return
        }

        let subscription = AvailableValuesSubscription<S, Value>(
            subscriber,
            depot: depot,
            key: key,
            initialValues: initialValues,
        )
        subscriber.receive(subscription: subscription)
    }
}

/// A Combine publisher that emits unwrapped `[Value]` arrays whenever **any** depot value
/// matching a key changes, using an ``ErrorHandlingDecision`` closure to recover from errors.
struct AvailableValuesPublisherHandlingErrors<Value>: Publisher where Value: Sendable {
    typealias Output = [Value]
    typealias Failure = Error

    private weak var depot: Depot?
    private let key: TypedKey<Value>
    private let initialValues: Bool
    private let errorHandler: @Sendable (Error, Bool) -> ErrorHandlingDecision<[Value], Error>

    init(
        depot: Depot,
        key: some TypedKeyProtocol<Value>,
        initialValues: Bool,
        errorHandler: @escaping @Sendable (Error, Bool) -> ErrorHandlingDecision<[Value], Error>,
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

        let subscription = AvailableValuesErrorHandlingSubscription<S, Value>(
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

private final class AvailableValuesSubscription<S: Subscriber & Sendable, Value>: Subscription, @unchecked Sendable
where S.Input == AvailableValuesPublisher<Value>.Output, S.Failure == Never, Value: Sendable {
    private struct State: Sendable {
        var subscriber: S?
        var task: Task<Void, Never>?
        var didStartObserving = false
    }

    private nonisolated(unsafe) weak var depot: Depot?
    private let key: TypedKey<Value>
    private let initialValues: Bool
    private let state: OSAllocatedUnfairLock<State>

    init(_ subscriber: S, depot: Depot, key: TypedKey<Value>, initialValues: Bool) {
        self.depot = depot
        state = OSAllocatedUnfairLock(uncheckedState: State(subscriber: subscriber))
        self.key = key
        self.initialValues = initialValues
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

        let stream = depot.availableValues(for: key, initialValues: initialValues)
        let task = Task { [weak self] in
            for await result in stream {
                guard let self else {
                    return
                }
                let sub = state.withLock { $0.subscriber }
                guard let sub else {
                    return
                }
                _ = sub.receive(result)
            }
        }
        state.withLock { $0.task = task }
    }
}

private final class AvailableValuesErrorHandlingSubscription<S: Subscriber & Sendable, Value>: Subscription,
    @unchecked Sendable
where S.Input == [Value], S.Failure == Error, Value: Sendable {
    private struct State: Sendable {
        var subscriber: S?
        var task: Task<Void, Never>?
        var didStartObserving = false
        var isInitial = true
    }

    private nonisolated(unsafe) weak var depot: Depot?
    private let key: TypedKey<Value>
    private let initialValues: Bool
    private let errorHandler: @Sendable (Error, Bool) -> ErrorHandlingDecision<[Value], Error>
    private let state: OSAllocatedUnfairLock<State>

    init(
        _ subscriber: S,
        depot: Depot,
        key: TypedKey<Value>,
        initialValues: Bool,
        errorHandler: @escaping @Sendable (Error, Bool) -> ErrorHandlingDecision<[Value], Error>,
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

        let stream = depot.availableValues(for: key, initialValues: initialValues)
        let task = Task { [weak self] in
            for await result in stream {
                guard let self else {
                    return
                }
                handle(result)
            }
        }
        state.withLock { $0.task = task }
    }

    private func handle(_ result: Result<AvailableValuesResult<Value>, Error>) {
        let (sub, currentIsInitial) = state.withLock { state -> (S?, Bool) in
            let isInit = state.isInitial
            state.isInitial = false
            return (state.subscriber, isInit)
        }
        guard let sub else {
            return
        }

        switch result {
        case let .success(available):
            _ = sub.receive(available.values)
        case let .failure(error):
            switch errorHandler(error, currentIsInitial) {
            case .skip:
                break
            case let .replaceWith(replacement):
                _ = sub.receive(replacement)
            case let .complete(completion):
                switch completion {
                case .finished:
                    sub.receive(completion: .finished)
                case let .failure(error):
                    sub.receive(completion: .failure(error))
                }
            }
        }
    }
}

#endif
