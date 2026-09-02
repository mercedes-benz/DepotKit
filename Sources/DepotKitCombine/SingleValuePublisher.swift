// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if canImport(Combine)

import Combine
import DepotKit
import os

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
/// The internal subscription uses `OSAllocatedUnfairLock` to protect mutable state and
/// is safe to request / cancel from any thread. Emissions may arrive on **any thread**;
/// apply `.receive(on:)` if you need a specific scheduler.
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
///     .compactMap(\.success)
///     .receive(on: DispatchQueue.main)
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

        let subscription = SingleValueSubscription<S, Value>(
            subscriber,
            depot: depot,
            key: key,
            initialValue: initialValue,
        )
        subscriber.receive(subscription: subscription)
    }
}

// MARK: - Private

private final class SingleValueSubscription<S: Subscriber & Sendable, Value>: Subscription, @unchecked Sendable
where S.Input == SingleValuePublisher<Value>.Output, S.Failure == Never, Value: Sendable {
    private struct State: Sendable {
        var subscriber: S?
        var task: Task<Void, Never>?
        var didStartObserving = false
    }

    private nonisolated(unsafe) weak var depot: Depot?
    private let key: TypedDistinctKey<Value>
    private let initialValue: Bool
    private let state: OSAllocatedUnfairLock<State>

    init(_ subscriber: S, depot: Depot, key: TypedDistinctKey<Value>, initialValue: Bool) {
        self.depot = depot
        state = OSAllocatedUnfairLock(uncheckedState: State(subscriber: subscriber))
        self.key = key
        self.initialValue = initialValue
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

#endif
