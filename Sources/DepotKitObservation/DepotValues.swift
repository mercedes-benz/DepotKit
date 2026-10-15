// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if canImport(SwiftUI) && canImport(Observation)

import DepotKit
import Observation
import SwiftUI

// MARK: - DepotValues

/// A SwiftUI property wrapper that reads an array of values from a `Depot`.
///
/// `@DepotValues` observes a (possibly wildcard) key and delivers all matching
/// values as an array. It is the multi-value counterpart of ``DepotValue``.
/// The order of the values is unspecified; sort them if you need a stable order.
///
/// ### Reading values
///
/// ```swift
/// struct SettingsListView: View {
///     @DepotValues(key: allSettingsKey, depot: depot)
///     var settings: [Settings]
///
///     var body: some View {
///         List(settings.sorted { $0.name < $1.name }, id: \.self) { setting in
///             Text(setting.name)
///         }
///     }
/// }
/// ```
///
/// ### Using key definitions
///
/// You can also initialise from a `PatternKeyDefinition`, which registers the key
/// automatically when the observation starts:
///
/// ```swift
/// @DepotValues(definition: Keys.allSettings, depot: depot)
/// var settings: [Settings]
/// ```
///
/// ### Lifecycle
///
/// SwiftUI creates a new view value — and with it a new wrapper — every time a parent view
/// re-evaluates its `body`, but keeps the state of the view that is already on screen. Creating
/// the wrapper is therefore cheap and free of side effects: it only stores the depot, the key
/// (or definition) and the `initialValues` flag. It does not read from or register with the
/// depot.
///
/// The work starts when SwiftUI installs the view and calls `update()` before evaluating its
/// `body` for the first time: the wrapper registers the definition (for
/// ``init(definition:depot:initialValues:)``) and starts observing the key. Later
/// re-creations of the view with the same key and depot do not register again or start
/// another observation.
///
/// If the parent later passes a different key (path) or a different depot, the wrapper cancels
/// the previous observation and starts observing the new configuration before the next `body`
/// evaluation (registering the new definition first, if it was created from one). The values
/// are reset to an empty array and ``error`` to `nil` at that point, and the new key's values
/// arrive asynchronously like the initial values. Changing only `initialValues`, or passing a
/// different definition with the same path, does not restart the observation.
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
/// By default, the current depot values are read and delivered asynchronously
/// right after the observation starts; until they arrive, the wrapped value is
/// empty. Pass
/// `initialValues: false` to suppress this and only receive future changes:
///
/// ```swift
/// @DepotValues(key: allSettingsKey, depot: depot, initialValues: false)
/// var settings: [Settings]
/// ```
///
/// > Important: The key must be registered with the depot **before** the view is
/// > displayed, unless you use the ``init(definition:depot:initialValues:)`` convenience
/// > initialiser which registers the key for you.
@MainActor
@propertyWrapper
public struct DepotValues<Value: Sendable>: DynamicProperty {
    private enum Source {
        case key(TypedKey<Value>)
        case definition(PatternKeyDefinition<Value>)
    }

    @State
    private var storage = DepotValuesStorage<Value>()

    private let depot: Depot
    private let source: Source
    private let initialValues: Bool

    /// Creates a depot-backed property wrapper for multiple values.
    ///
    /// Creating the wrapper has no side effects; observation starts when SwiftUI first updates
    /// the view that owns it.
    ///
    /// - Parameters:
    ///   - key: A typed key identifying the values. May contain wildcards. Must be registered with the depot
    ///     before the view is displayed.
    ///   - depot: An observable depot to read from.
    ///   - initialValues: When `true` (the default), the current values are delivered (asynchronously) right
    ///     after the observation starts.
    public init(
        key: some TypedKeyProtocol<Value>,
        depot: Depot,
        initialValues: Bool = true,
    ) {
        self.depot = depot
        source = .key(TypedKey(key))
        self.initialValues = initialValues
    }

    /// Creates a depot-backed property wrapper from a `PatternKeyDefinition`.
    ///
    /// Creating the wrapper has no side effects. The definition's key and coder are registered with the
    /// depot right before the observation starts — when SwiftUI first updates the view that owns the
    /// wrapper, or when the definition's path or the depot changes.
    ///
    /// - Parameters:
    ///   - definition: A static pattern key definition containing the key path and coder.
    ///   - depot: An observable depot to read from.
    ///   - initialValues: When `true` (the default), the current values are delivered (asynchronously) right
    ///     after the observation starts.
    public init(
        definition: PatternKeyDefinition<Value>,
        depot: Depot,
        initialValues: Bool = true,
    ) {
        self.depot = depot
        source = .definition(definition)
        self.initialValues = initialValues
    }

    /// The current values stored in the depot matching the key, in unspecified order.
    public var wrappedValue: [Value] {
        storage.values
    }

    /// The last error encountered while observing, if any.
    public var error: Error? {
        storage.error
    }

    /// Starts observing the configured key, or restarts the observation when the key or depot changed.
    ///
    /// SwiftUI calls this on the main thread before each evaluation of the owning view's `body`.
    /// Calls with an unchanged key and depot do nothing.
    public nonisolated func update() {
        MainActor.assumeIsolated {
            switch source {
            case let .key(key):
                storage.observe(key: key, in: depot, initialValues: initialValues)
            case let .definition(definition):
                storage.observe(key: TypedKey(definition.key), in: depot, initialValues: initialValues) {
                    depot.register(definition)
                }
            }
        }
    }
}

// MARK: - DepotValuesStorage

/// Internal `@Observable` storage that bridges multi-value depot observation to SwiftUI.
///
/// A new storage is inert; `observe(key:in:initialValues:beforeStart:)` starts (or restarts) the
/// observation.
@MainActor
@Observable
final class DepotValuesStorage<Value: Sendable> {
    var values: [Value] = []
    private(set) var error: Error?

    @ObservationIgnored
    private var depot: Depot?

    @ObservationIgnored
    private var key: TypedKey<Value>?

    @ObservationIgnored
    private var task: Task<Void, Never>?

    init() {}

    deinit {
        task?.cancel()
    }

    /// Observes `key` in `depot`.
    ///
    /// Does nothing when the storage already observes the same key in the same depot. Otherwise
    /// cancels the current observation (if any), resets `values` and `error`, runs `beforeStart`
    /// (e.g. to register the key) and starts observing the new configuration.
    func observe(
        key: TypedKey<Value>,
        in depot: Depot,
        initialValues: Bool,
        beforeStart: () -> Void = {},
    ) {
        if let currentDepot = self.depot, currentDepot === depot, self.key == key {
            return
        }

        task?.cancel()
        if !values.isEmpty {
            values = []
        }
        if error != nil {
            error = nil
        }

        beforeStart()
        self.depot = depot
        self.key = key
        task = Task { [weak self] in
            for await result in depot.values(for: key, initialValues: initialValues) {
                // A restart cancels this task on the main actor; drop results of the old key.
                guard let self, !Task.isCancelled else {
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

#endif
