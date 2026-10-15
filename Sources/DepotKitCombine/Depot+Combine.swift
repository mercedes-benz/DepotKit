// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if canImport(Combine)

import Combine
import DepotKit

/// Determines how a publisher should react when the depot observation produces an error.
///
/// Use this type with the error-handling publisher variants returned by the
/// `published(valueFor:initialValue:errorHandler:)` and
/// `published(valuesFor:initialValues:errorHandler:)` methods to decide per-error
/// whether to silently ignore it, substitute a fallback value, or terminate the stream.
///
/// ## Cases
///
/// | Case | Effect |
/// |---|---|
/// | ``skip`` | The error is swallowed; no value is emitted to downstream subscribers. |
/// | ``replaceWith(_:)`` | A replacement value is emitted in place of the failed one. |
/// | ``complete(_:)`` | The publisher completes (either normally via `.finished` or with a different error). |
///
/// ## Example
///
/// ```swift
/// depot.published(
///     valueFor: userKey,
///     errorHandler: { error, isInitial in
///         if isInitial {
///             // Provide a default for the very first read.
///             return .replaceWith(User.guest)
///         }
///         // Ignore transient errors during subsequent updates.
///         return .skip
///     }
/// )
/// ```
public enum ErrorHandlingDecision<Output, Failure>: Sendable where Output: Sendable, Failure: Error {
    /// Skip the errored value without emitting anything to downstream subscribers.
    case skip

    /// Emit the given replacement value to downstream subscribers instead of the error.
    case replaceWith(Output)

    /// Complete the publisher with the given `Subscribers.Completion` (`.finished` or `.failure`).
    case complete(Subscribers.Completion<Failure>)
}

// MARK: - Depot + Combine publishers

extension Depot {
    /// Creates a Combine publisher that emits whenever the value stored under `key` changes.
    ///
    /// Each emission is a `Result<V?, Error>`:
    /// - `.success(value)` when the value is read successfully (or `nil` if absent).
    /// - `.failure(error)` when the read fails (e.g. decoding error).
    ///
    /// The publisher does not complete while the depot exists; it stays active until the
    /// subscription is cancelled. When the depot is deallocated, the publisher completes
    /// with `.finished`.
    ///
    /// - Parameters:
    ///   - key: A typed distinct key identifying the value to observe.
    ///     The key must already be registered on the depot.
    ///   - initialValue: When `true` (the default), the publisher immediately emits the
    ///     current stored value upon subscription.
    ///
    /// - Returns: A publisher whose `Output` is `Result<V?, Error>` and `Failure` is `Never`.
    ///
    /// > Important: The publisher may emit on **any thread**. When driving UI or calling
    /// > main-actor code, put `.receive(on: DispatchQueue.main)` directly after the publisher,
    /// > before operators such as `map` or `compactMap`.
    ///
    /// ### Demand
    ///
    /// The publisher honors subscriber demand and never emits more values than requested.
    /// Observation starts with the first positive demand. Because emissions describe the
    /// current state, changes that occur while the outstanding demand is zero are
    /// **conflated**: only the latest one is kept and it is delivered as soon as more demand
    /// is requested.
    ///
    /// ### Observing a single value
    ///
    /// ```swift
    /// import Combine
    /// import DepotKit
    /// import DepotKitCombine
    ///
    /// let key = Key.from("settings" / "theme", as: String.self)
    /// var cancellables = Set<AnyCancellable>()
    ///
    /// depot.published(valueFor: key)
    ///     .receive(on: DispatchQueue.main)
    ///     .compactMap { try? $0.get() }
    ///     .sink { theme in
    ///         print("Current theme: \(String(describing: theme))")
    ///     }
    ///     .store(in: &cancellables)
    /// ```
    ///
    /// ### Feeding a `@Published` property for SwiftUI
    ///
    /// ```swift
    /// @MainActor
    /// final class SettingsViewModel: ObservableObject {
    ///     @Published var theme: String?
    ///
    ///     init(depot: Depot) {
    ///         let key = Key.from("settings" / "theme", as: String.self)
    ///         depot.published(valueFor: key)
    ///             .receive(on: DispatchQueue.main)
    ///             .map { result in try? result.get() }  // nil when missing or unreadable
    ///             .assign(to: &$theme)
    ///     }
    /// }
    /// ```
    ///
    /// `assign(to:)` requires a publisher that never fails, so the example maps the `Result`
    /// instead of using the error-handling variant.
    public func published<V>(
        valueFor key: some TypedDistinctKeyProtocol<V>,
        initialValue: Bool = true,
    ) -> some Publisher<Result<V?, Error>, Never> where V: Sendable {
        SingleValuePublisher(
            depot: self,
            key: key,
            initialValue: initialValue,
        )
    }

    /// Creates a Combine publisher that emits the *unwrapped* value whenever the value
    /// stored under `key` changes, using an ``ErrorHandlingDecision`` closure to recover
    /// from errors instead of surfacing them as `Result` values.
    ///
    /// Unlike ``published(valueFor:initialValue:)`` (which wraps every emission in
    /// a `Result`), this variant invokes `errorHandler` for each error and lets you
    /// decide whether to ``ErrorHandlingDecision/skip``, ``ErrorHandlingDecision/replaceWith(_:)``
    /// a fallback, or ``ErrorHandlingDecision/complete(_:)`` the stream.
    ///
    /// The default `errorHandler` replaces the initial-value error with `nil` and skips
    /// all subsequent errors, making it safe to drive UI without extra error mapping.
    ///
    /// - Parameters:
    ///   - key: A typed distinct key identifying the value to observe.
    ///   - initialValue: When `true` (the default), the publisher immediately emits the
    ///     current stored value upon subscription.
    ///   - errorHandler: A closure invoked whenever the observation produces an error.
    ///     - error: The error that occurred during the read.
    ///     - isInitialValue: `true` when the error belongs to the first element delivered to the
    ///       subscriber. That element already reflects changes made before it was delivered.
    ///       Always `false` when `initialValue` is `false`.
    ///
    /// - Returns: A publisher whose `Output` is `V?` and `Failure` is `Error`.
    ///
    /// > Important: The publisher may emit on **any thread**. When driving UI or calling
    /// > main-actor code, put `.receive(on: DispatchQueue.main)` directly after the publisher,
    /// > before operators such as `map` or `compactMap`.
    ///
    /// ### Demand
    ///
    /// The publisher honors subscriber demand and never emits more values than requested.
    /// Observation starts with the first positive demand. Because emissions describe the
    /// current state, changes that occur while the outstanding demand is zero are
    /// **conflated**: only the latest one is kept and it is delivered as soon as more demand
    /// is requested.
    ///
    /// `errorHandler` runs as soon as an error occurs, independent of demand. Replacement
    /// values are subject to demand and conflation like ordinary values. A
    /// ``ErrorHandlingDecision/complete(_:)`` decision completes the publisher without
    /// requiring demand; a value still waiting for demand at that moment is discarded.
    ///
    /// ### Basic usage with default error handling
    ///
    /// ```swift
    /// // Errors on the initial read become `nil`; later errors are silently skipped.
    /// depot.published(valueFor: themeKey, errorHandler: { _, isInitial in
    ///     isInitial ? .replaceWith(nil) : .skip
    /// })
    /// .receive(on: DispatchQueue.main)
    /// .assign(to: &$theme)
    /// ```
    ///
    /// ### Custom error handling
    ///
    /// ```swift
    /// depot.published(
    ///     valueFor: themeKey,
    ///     errorHandler: { error, isInitial in
    ///         if isInitial {
    ///             return .replaceWith("light")  // default theme
    ///         }
    ///         logger.error("Depot read failed: \(error)")
    ///         return .skip
    ///     }
    /// )
    /// .receive(on: DispatchQueue.main)
    /// .assign(to: &$theme)
    /// ```
    public func published<V>(
        valueFor key: some TypedDistinctKeyProtocol<V>,
        initialValue: Bool = true,
        errorHandler:
            @escaping @Sendable (_ error: Error, _ isInitialValue: Bool) -> ErrorHandlingDecision<V?, Error> = {
                _,
                initial in
                initial ? .replaceWith(nil) : .skip
            },
    ) -> some Publisher<V?, Error> where V: Sendable {
        SingleValuePublisherHandlingErrors(
            depot: self,
            key: key,
            initialValue: initialValue,
            errorHandler: errorHandler,
        )
    }

    /// Creates a Combine publisher that emits whenever **any** value matching `key` changes.
    ///
    /// The key may contain wildcards (e.g. `"users" / .wildcard / "name"`), so this
    /// publisher can track multiple depot entries at once. Each emission is a
    /// `Result<[V], Error>` containing the current array of all matching values.
    /// The order of the values is unspecified; sort them if you need a stable order.
    ///
    /// - Parameters:
    ///   - key: A typed key identifying the values to observe. May include wildcards.
    ///   - initialValues: When `true` (the default), the publisher immediately emits
    ///     the current set of matching values upon subscription.
    ///
    /// - Returns: A publisher whose `Output` is `Result<[V], Error>` and `Failure` is `Never`.
    ///
    /// > Important: The publisher may emit on **any thread**. When driving UI or calling
    /// > main-actor code, put `.receive(on: DispatchQueue.main)` directly after the publisher,
    /// > before operators such as `map` or `compactMap`.
    ///
    /// ### Demand
    ///
    /// The publisher honors subscriber demand and never emits more values than requested.
    /// Observation starts with the first positive demand. Because emissions describe the
    /// current state, changes that occur while the outstanding demand is zero are
    /// **conflated**: only the latest one is kept and it is delivered as soon as more demand
    /// is requested.
    ///
    /// ### Observing multiple values with a wildcard key
    ///
    /// ```swift
    /// let allUsersKey = Key.from("users" / .wildcard / "name", as: String.self)
    /// var cancellables = Set<AnyCancellable>()
    ///
    /// depot.published(valuesFor: allUsersKey)
    ///     .receive(on: DispatchQueue.main)
    ///     .compactMap { try? $0.get() }
    ///     .sink { names in
    ///         print("All user names: \(names)")
    ///     }
    ///     .store(in: &cancellables)
    /// ```
    public func published<V>(
        valuesFor key: some TypedKeyProtocol<V>,
        initialValues: Bool = true,
    ) -> some Publisher<Result<[V], Error>, Never> where V: Sendable {
        MultiValuePublisher(depot: self, key: key, initialValues: initialValues)
    }

    /// Creates a Combine publisher that emits *unwrapped* value arrays whenever **any**
    /// value matching `key` changes, using an ``ErrorHandlingDecision`` closure to
    /// recover from errors.
    ///
    /// This is the multi-value counterpart of
    /// ``published(valueFor:initialValue:errorHandler:)``.
    /// The default error handler replaces the initial-values error with an empty array
    /// and skips subsequent errors. The order of the values is unspecified; sort them if
    /// you need a stable order.
    ///
    /// - Parameters:
    ///   - key: A typed key identifying the values to observe. May include wildcards.
    ///   - initialValues: When `true` (the default), the publisher immediately emits
    ///     the current set of matching values upon subscription.
    ///   - errorHandler: A closure invoked whenever the observation produces an error.
    ///     - error: The error that occurred during the read.
    ///     - isInitialValues: `true` when the error belongs to the first element delivered to the
    ///       subscriber. That element already reflects changes made before it was delivered.
    ///       Always `false` when `initialValues` is `false`.
    ///
    /// - Returns: A publisher whose `Output` is `[V]` and `Failure` is `Error`.
    ///
    /// > Important: The publisher may emit on **any thread**.
    ///
    /// ### Demand
    ///
    /// The publisher honors subscriber demand and never emits more values than requested.
    /// Observation starts with the first positive demand. Because emissions describe the
    /// current state, changes that occur while the outstanding demand is zero are
    /// **conflated**: only the latest one is kept and it is delivered as soon as more demand
    /// is requested.
    ///
    /// `errorHandler` runs as soon as an error occurs, independent of demand. Replacement
    /// values are subject to demand and conflation like ordinary values. A
    /// ``ErrorHandlingDecision/complete(_:)`` decision completes the publisher without
    /// requiring demand; a value still waiting for demand at that moment is discarded.
    ///
    /// ### Usage
    ///
    /// ```swift
    /// depot.published(
    ///     valuesFor: allUsersKey,
    ///     errorHandler: { error, isInitial in
    ///         isInitial ? .replaceWith([]) : .skip
    ///     }
    /// )
    /// .receive(on: DispatchQueue.main)
    /// .assign(to: &$userNames)
    /// ```
    public func published<V>(
        valuesFor key: some TypedKeyProtocol<V>,
        initialValues: Bool = true,
        errorHandler:
            @escaping @Sendable (_ error: Error, _ isInitialValues: Bool) -> ErrorHandlingDecision<[V], Error> = {
                _,
                initial in
                initial ? .replaceWith([]) : .skip
            },
    ) -> some Publisher<[V], Error> where V: Sendable {
        MultiValuePublisherHandlingErrors(
            depot: self,
            key: key,
            initialValues: initialValues,
            errorHandler: errorHandler,
        )
    }

    /// Creates a Combine publisher that emits whenever **any** value matching `key`
    /// changes, returning successfully decoded values alongside a dictionary of
    /// per-key errors.
    ///
    /// Unlike ``published(valuesFor:initialValues:)`` which delivers raw
    /// `Result<[V], Error>`, this variant attempts all matching keys and partitions
    /// them into decoded values and per-key errors in a single read pass.
    ///
    /// For fatal I/O errors the original `Result.failure` is forwarded unchanged.
    ///
    /// - Parameters:
    ///   - key: A typed key identifying the values to observe. May include wildcards.
    ///   - initialValues: When `true` (the default), the publisher immediately emits
    ///     the current set of matching values upon subscription.
    ///
    /// - Returns: A publisher whose `Output` is `Result<AvailableValuesResult<V>, Error>`
    ///   and `Failure` is `Never`.
    ///
    /// > Important: The publisher may emit on **any thread**.
    ///
    /// ### Demand
    ///
    /// The publisher honors subscriber demand and never emits more values than requested.
    /// Observation starts with the first positive demand. Because emissions describe the
    /// current state, changes that occur while the outstanding demand is zero are
    /// **conflated**: only the latest one is kept and it is delivered as soon as more demand
    /// is requested.
    ///
    /// ### Handling decode failures gracefully
    ///
    /// ```swift
    /// depot.published(availableValuesFor: allUsersKey)
    ///     .receive(on: DispatchQueue.main)
    ///     .sink { completion in
    ///         print("Completed: \(completion)")
    ///     } receiveValue: { result in
    ///         switch result {
    ///         case .success(let result):
    ///             print("Decoded \(result.values.count) values")
    ///             for (key, error) in result.keyedErrors {
    ///                 print("Failed to decode \(key): \(error)")
    ///             }
    ///         case .failure(let error):
    ///             print("Total failure: \(error)")
    ///         }
    ///     }
    ///     .store(in: &cancellables)
    /// ```
    public func published<V>(
        availableValuesFor key: some TypedKeyProtocol<V>,
        initialValues: Bool = true,
    ) -> some Publisher<Result<AvailableValuesResult<V>, Error>, Never>
    where V: Sendable {
        AvailableValuesPublisher(depot: self, key: key, initialValues: initialValues)
    }

    /// Creates a Combine publisher that emits *unwrapped* value arrays whenever **any**
    /// value matching `key` changes, recovering from decode errors by emitting the
    /// successfully decoded subset.
    ///
    /// The default error handler emits the successfully decoded values from each
    /// observation and discards the errors. On fatal I/O errors during the initial
    /// read it emits an empty array; subsequent fatal errors are skipped. The order of
    /// the values is unspecified; sort them if you need a stable order.
    ///
    /// - Parameters:
    ///   - key: A typed key identifying the values to observe. May include wildcards.
    ///   - initialValues: When `true` (the default), the publisher immediately emits
    ///     the current set of matching values upon subscription.
    ///   - errorHandler: A closure invoked whenever a fatal I/O error occurs (not
    ///     per-key decode errors, which are collected in the tuple).
    ///     - error: The error that occurred during the read.
    ///     - isInitialValues: `true` when the error belongs to the first element delivered to the
    ///       subscriber. That element already reflects changes made before it was delivered.
    ///       Always `false` when `initialValues` is `false`.
    ///
    /// - Returns: A publisher whose `Output` is `[V]` and `Failure` is `Error`.
    ///
    /// > Important: The publisher may emit on **any thread**.
    ///
    /// ### Demand
    ///
    /// The publisher honors subscriber demand and never emits more values than requested.
    /// Observation starts with the first positive demand. Because emissions describe the
    /// current state, changes that occur while the outstanding demand is zero are
    /// **conflated**: only the latest one is kept and it is delivered as soon as more demand
    /// is requested.
    ///
    /// `errorHandler` runs as soon as an error occurs, independent of demand. Replacement
    /// values are subject to demand and conflation like ordinary values. A
    /// ``ErrorHandlingDecision/complete(_:)`` decision completes the publisher without
    /// requiring demand; a value still waiting for demand at that moment is discarded.
    ///
    /// ### Gracefully degrading on decode failures
    ///
    /// ```swift
    /// depot.published(availableValuesFor: allUsersKey) { error, isInitial in
    ///     logger.warning("Depot read error: \(error)")
    ///     return isInitial ? .replaceWith([]) : .skip
    /// }
    /// .receive(on: DispatchQueue.main)
    /// .assign(to: &$userNames)
    /// ```
    public func published<V>(
        availableValuesFor key: some TypedKeyProtocol<V>,
        initialValues: Bool = true,
        errorHandler:
            @escaping @Sendable (_ error: Error, _ isInitialValues: Bool) -> ErrorHandlingDecision<[V], Error> = {
                _,
                initial in
                initial ? .replaceWith([]) : .skip
            },
    ) -> some Publisher<[V], Error> where V: Sendable {
        AvailableValuesPublisherHandlingErrors(
            depot: self,
            key: key,
            initialValues: initialValues,
            errorHandler: errorHandler,
        )
    }
}

#endif
