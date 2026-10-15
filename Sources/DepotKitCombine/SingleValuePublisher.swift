// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if canImport(Combine)

import Combine
import DepotKit

/// A Combine publisher that emits `Result<Value?, Error>` whenever the depot value
/// stored under a single distinct key changes.
///
/// ## Overview
///
/// `SingleValuePublisher` bridges the ``Depot/values(for:initialValue:)``
/// async sequence into the Combine world. Each emission is a `Result<Value?, Error>`:
///
/// | Result | Meaning |
/// |---|---|
/// | `.success(value)` | The value was read successfully (or `nil` if absent). |
/// | `.failure(error)` | The read failed (decoding error, unregistered key, etc.). |
///
/// The publisher **never completes** on its own — it stays active until cancelled or the
/// depot is deallocated.
///
/// ## Thread Safety
///
/// The subscription (``DepotObservationSubscription``) is safe to request / cancel from any
/// thread, including reentrantly from within `receive(_:)`. Emissions may arrive on
/// **any thread**; apply `.receive(on:)` if you need a specific scheduler.
///
/// ## Demand
///
/// Subscriber demand is honored; changes arriving while demand is zero are conflated to the
/// latest value (see ``DepotObservationSubscription``).
///
/// ## Creating a Publisher
///
/// You typically don't instantiate this type directly. Use the convenience method on
/// ``Depot``:
///
/// ```swift
/// let key = Key.from("settings" / "theme", as: String.self)
///
/// depot.published(valueFor: key)
///     .receive(on: DispatchQueue.main)
///     .compactMap { try? $0.get() }
///     .sink { theme in
///         print("Current theme: \(String(describing: theme))")
///     }
///     .store(in: &cancellables)
/// ```
struct SingleValuePublisher<Value>: Publisher where Value: Sendable {
    typealias Output = Result<Value?, Error>
    typealias Failure = Never

    private weak var depot: Depot?
    private let key: TypedDistinctKey<Value>
    private let initialValue: Bool

    init(depot: Depot, key: some TypedDistinctKeyProtocol<Value>, initialValue: Bool) {
        self.depot = depot
        self.key = TypedDistinctKey(key)
        self.initialValue = initialValue
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
        stream makeStream: @escaping @Sendable () -> AsyncStream<Output>?,
    ) -> DepotObservationSubscription<S, Output>
    where S: Subscriber & Sendable, S.Input == Output, S.Failure == Failure {
        DepotObservationSubscription(subscriber, makeStream: makeStream) { result, _ in
            .emit(result)
        }
    }
}

#endif
