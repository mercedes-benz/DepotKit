// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if canImport(Combine)

import Combine
import DepotKit

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

        let key = key
        let initialValues = initialValues
        let subscription = makeSubscription(for: subscriber) { [weak depot] in
            depot?.values(for: key, initialValues: initialValues)
        }
        subscriber.receive(subscription: subscription)
    }

    /// Creates the demand-aware subscription for `subscriber`, reading elements from `makeStream`.
    func makeSubscription<S>(
        for subscriber: S,
        stream makeStream: @escaping @Sendable () -> AsyncStream<Result<[Value], Error>>?,
    ) -> DepotObservationSubscription<S, Result<[Value], Error>>
    where S: Subscriber & Sendable, S.Input == Output, S.Failure == Failure {
        let initialValues = initialValues
        let errorHandler = errorHandler
        return DepotObservationSubscription(subscriber, makeStream: makeStream) { result, isFirst in
            switch result {
            case let .success(values):
                .emit(values)
            case let .failure(error):
                ObservationEvent(errorHandler(error, initialValues && isFirst))
            }
        }
    }
}

#endif
