// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if canImport(Combine)

import Combine
import DepotKit
import os

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
///     .compactMap { try? $0.get() }
///     .receive(on: DispatchQueue.main)
///     .sink { names in
///         print("User names: \(names)")
///     }
///     .store(in: &cancellables)
/// ```
struct MultiValuePublisher<Value>: Publisher where Value: Sendable {
    typealias Output = Result<[Value], Error>
    typealias Failure = Error

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

        let subscription = MultiValueSubscription<S, Value>(
            subscriber,
            depot: depot,
            key: key,
            initialValues: initialValues,
        )
        subscriber.receive(subscription: subscription)
    }
}

// MARK: - Private

private final class MultiValueSubscription<S: Subscriber & Sendable, Value>: Subscription, @unchecked Sendable
where S.Input == MultiValuePublisher<Value>.Output, S.Failure == Error, Value: Sendable {
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

        let stream = depot.values(for: key, initialValues: initialValues)
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
