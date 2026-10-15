// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if canImport(Combine)

import Combine
import DepotKit

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

        let key = key
        let initialValue = initialValue
        let subscription = makeSubscription(for: subscriber) { [weak depot] in
            depot?.values(for: key, initialValue: initialValue)
        }
        subscriber.receive(subscription: subscription)
    }

    /// Creates the demand-aware subscription for `subscriber`, reading elements from `makeStream`.
    func makeSubscription<S>(
        for subscriber: S,
        stream makeStream: @escaping @Sendable () -> AsyncStream<Result<Value?, Error>>?,
    ) -> DepotObservationSubscription<S, Result<Value?, Error>>
    where S: Subscriber & Sendable, S.Input == Output, S.Failure == Failure {
        let initialValue = initialValue
        let errorHandler = errorHandler
        return DepotObservationSubscription(subscriber, makeStream: makeStream) { result, isFirst in
            switch result {
            case let .success(value):
                .emit(value)
            case let .failure(error):
                ObservationEvent(errorHandler(error, initialValue && isFirst))
            }
        }
    }
}

#endif
