// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if canImport(SwiftUI) && canImport(Observation)

import DepotKit
import Observation
import SwiftUI

// MARK: - DepotValues

/// A SwiftUI property wrapper that reads an array of values from an ``Depot``.
///
/// `@DepotValues` observes a (possibly wildcard) key and delivers all matching
/// values as an array. It is the multi-value counterpart of ``DepotValue``.
///
/// ### Reading values
///
/// ```swift
/// struct SettingsListView: View {
///     @DepotValues(key: allSettingsKey, depot: depot)
///     var settings: [Settings]
///
///     var body: some View {
///         List(settings, id: \.self) { setting in
///             Text(setting.name)
///         }
///     }
/// }
/// ```
///
/// ### Using key definitions
///
/// You can also initialise from a ``KeyDefinition``, which registers the key
/// automatically:
///
/// ```swift
/// @DepotValues(definition: Keys.allSettings, depot: depot)
/// var settings: [Settings]
/// ```
///
/// ### Error handling
///
/// Access the ``error`` property to inspect the last observation error:
///
/// ```swift
/// if let error = _settings.error {
///     Text("Error: \(error.localizedDescription)")
/// }
/// ```
///
/// ### Controlling initial delivery
///
/// By default, the current depot values are delivered immediately. Pass
/// `initialValues: false` to suppress this and only receive future changes:
///
/// ```swift
/// @DepotValues(key: allSettingsKey, depot: depot, initialValues: false)
/// var settings: [Settings]
/// ```
///
/// > Important: The key must be registered with the depot **before** creating the
/// > view, unless you use the ``init(definition:depot:initialValues:)`` convenience
/// > initialiser which registers the key for you.
@MainActor
@propertyWrapper
public struct DepotValues<Value: Sendable>: DynamicProperty {
    @State
    private var storage: DepotValuesStorage<Value>

    /// Creates a depot-backed property wrapper for multiple values.
    ///
    /// - Parameters:
    ///   - key: A typed key identifying the values. May contain wildcards.
    ///   - depot: An observable depot to read from.
    ///   - initialValues: When `true` (the default), the current values are delivered immediately.
    public init(
        key: some TypedKeyProtocol<Value>,
        depot: Depot,
        initialValues: Bool = true,
    ) {
        _storage = State(
            initialValue: DepotValuesStorage(
                depot: depot,
                key: TypedKey(key),
                initialValues: initialValues,
            ),
        )
    }

    /// Creates a depot-backed property wrapper from a ``PatternKeyDefinition``.
    ///
    /// The definition's key and coder are registered with the depot automatically.
    ///
    /// - Parameters:
    ///   - definition: A static pattern key definition containing the key path and coder.
    ///   - depot: An observable depot to read from.
    ///   - initialValues: When `true` (the default), the current values are delivered immediately.
    public init(
        definition: PatternKeyDefinition<Value>,
        depot: Depot,
        initialValues: Bool = true,
    ) {
        let key = depot.register(definition)
        self.init(key: key, depot: depot, initialValues: initialValues)
    }

    /// The current values stored in the depot matching the key.
    public var wrappedValue: [Value] {
        storage.values
    }

    /// The last error encountered while observing, if any.
    public var error: Error? {
        storage.error
    }
}

// MARK: - DepotValuesStorage

/// Internal `@Observable` storage that bridges multi-value depot observation to SwiftUI.
@MainActor
@Observable
final class DepotValuesStorage<Value: Sendable> {
    var values: [Value] = []
    private(set) var error: Error?

    @ObservationIgnored
    private let depot: Depot

    @ObservationIgnored
    private let key: TypedKey<Value>

    @ObservationIgnored
    private var task: Task<Void, Never>?

    init(depot: Depot, key: TypedKey<Value>, initialValues: Bool) {
        self.depot = depot
        self.key = key
        startObserving(initialValues: initialValues)
    }

    deinit {
        task?.cancel()
    }

    private func startObserving(initialValues: Bool) {
        task = Task { [weak self, depot, key] in
            for await result in depot.values(for: key, initialValues: initialValues) {
                await MainActor.run {
                    guard let self else {
                        return
                    }
                    switch result {
                    case let .success(values):
                        self.values = values
                        self.error = nil
                    case let .failure(error):
                        self.error = error
                    }
                }
            }
        }
    }
}

#endif
