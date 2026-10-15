// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if canImport(Combine)

import Combine
import DepotKit

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

        let key = key
        let initialValues = initialValues
        let subscription = makeSubscription(for: subscriber) { [weak depot] in
            depot?.availableValues(for: key, initialValues: initialValues)
        }
        subscriber.receive(subscription: subscription)
    }

    /// Creates the demand-aware subscription for `subscriber`, reading elements from `makeStream`.
    func makeSubscription<S>(
        for subscriber: S,
        stream makeStream: @escaping @Sendable () -> AsyncStream<Output>?,
    ) -> DepotObservationSubscription<S, Output>
    where S: Subscriber & Sendable, S.Input == Output, S.Failure == Failure {
        DepotObservationSubscription(subscriber, makeStream: makeStream) { result, _ in
            .emit(result)
        }
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

        let key = key
        let initialValues = initialValues
        let subscription = makeSubscription(for: subscriber) { [weak depot] in
            depot?.availableValues(for: key, initialValues: initialValues)
        }
        subscriber.receive(subscription: subscription)
    }

    /// Creates the demand-aware subscription for `subscriber`, reading elements from `makeStream`.
    ///
    /// Successful observations emit their decoded values (per-key decode errors are dropped);
    /// top-level failures go through `errorHandler`. The `isInitial` flag is gated by
    /// `initialValues`, so with `initialValues: false` every failure is classified as an update.
    func makeSubscription<S>(
        for subscriber: S,
        stream makeStream: @escaping @Sendable () -> AsyncStream<Result<AvailableValuesResult<Value>, Error>>?,
    ) -> DepotObservationSubscription<S, Result<AvailableValuesResult<Value>, Error>>
    where S: Subscriber & Sendable, S.Input == Output, S.Failure == Failure {
        let initialValues = initialValues
        let errorHandler = errorHandler
        return DepotObservationSubscription(subscriber, makeStream: makeStream) { result, isFirst in
            switch result {
            case let .success(available):
                .emit(available.values)
            case let .failure(error):
                ObservationEvent(errorHandler(error, initialValues && isFirst))
            }
        }
    }
}

#endif
