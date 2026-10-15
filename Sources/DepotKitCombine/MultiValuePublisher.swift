// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if canImport(Combine)

import Combine
import DepotKit

/// A Combine publisher that emits `Result<[Value], Error>` whenever **any** depot value
/// matching a (possibly wildcard) key changes.
///
/// ## Overview
///
/// `MultiValuePublisher` bridges ``Depot/values(for:initialValues:)``
/// into the Combine world.
///
/// The publisher **never completes** on its own — it stays active until cancelled or the
/// depot is deallocated.
///
/// ## Creating a Publisher
///
/// ```swift
/// let allUsersKey = Key.from("users" / .wildcard / "name", as: String.self)
///
/// depot.published(valuesFor: allUsersKey)
///     .receive(on: DispatchQueue.main)
///     .compactMap { try? $0.get() }
///     .sink { names in
///         print("User names: \(names)")
///     }
///     .store(in: &cancellables)
/// ```
struct MultiValuePublisher<Value>: Publisher where Value: Sendable {
    typealias Output = Result<[Value], Error>
    typealias Failure = Never

    private weak var depot: Depot?
    private let key: TypedKey<Value>
    private let initialValues: Bool

    init(depot: Depot, key: some TypedKeyProtocol<Value>, initialValues: Bool) {
        self.depot = depot
        self.key = TypedKey(key)
        self.initialValues = initialValues
    }

    func receive<S>(subscriber: S) where S: Subscriber & Sendable, S.Input == Output, S.Failure == Never {
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
        stream makeStream: @escaping @Sendable () -> AsyncStream<Output>?,
    ) -> DepotObservationSubscription<S, Output>
    where S: Subscriber & Sendable, S.Input == Output, S.Failure == Failure {
        DepotObservationSubscription(subscriber, makeStream: makeStream) { result, _ in
            .emit(result)
        }
    }
}

#endif
