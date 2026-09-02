// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if canImport(SwiftUI) && canImport(Observation)

import DepotKit
import Observation
import SwiftUI

// MARK: - DepotValue

/// A SwiftUI property wrapper that reads and writes a single value from an ``Depot``.
///
/// `@DepotValue` provides `@AppStorage`-like ergonomics for DepotKit depots.
/// It observes the depot for changes and automatically triggers SwiftUI view updates.
///
/// ### Reading values
///
/// Declare a `@DepotValue` property with a typed key and depot reference:
///
/// ```swift
/// struct ProfileView: View {
///     @DepotValue(key: usernameKey, depot: depot)
///     var username: String?
///
///     var body: some View {
///         Text(username ?? "Guest")
///     }
/// }
/// ```
///
/// ### Using key definitions
///
/// You can also initialise from a ``KeyDefinition``, which registers the
/// key automatically:
///
/// ```swift
/// @DepotValue(definition: Keys.username, depot: depot)
/// var username: String?
/// ```
///
/// ### Writing values
///
/// Use the `$` projected binding for two-way SwiftUI bindings:
///
/// ```swift
/// Toggle("Notifications", isOn: Binding(
///     get: { $notificationsEnabled.wrappedValue ?? false },
///     set: { $notificationsEnabled.wrappedValue = $0 }
/// ))
/// ```
///
/// Writing through the binding dispatches an **asynchronous** write to the
/// depot. The setter returns immediately (fire-and-forget); if the write
/// fails, the error is captured in ``error`` and the next observation
/// cycle will restore the previous value. This matches the behavior of
/// `@AppStorage`.
///
/// ### Error handling
///
/// Access the ``error`` property to inspect the last observation or write error:
///
/// ```swift
/// if let error = _username.error {
///     Text("Error: \(error.localizedDescription)")
/// }
/// ```
///
/// ### Controlling initial delivery
///
/// By default, the current depot value is delivered immediately. Pass
/// `initialValue: false` to suppress this and only receive future changes:
///
/// ```swift
/// @DepotValue(key: usernameKey, depot: depot, initialValue: false)
/// var username: String?
/// ```
///
/// > Important: The key must be registered with the depot **before** creating the
/// > view, unless you use the ``init(definition:depot:initialValue:)`` convenience
/// > initialiser which registers the key for you.
@MainActor
@propertyWrapper
public struct DepotValue<Value: Sendable>: DynamicProperty {
    @State
    private var storage: DepotValueStorage<Value>

    /// Creates a depot-backed property wrapper.
    ///
    /// - Parameters:
    ///   - key: A typed distinct key identifying the value. Must already be registered with the depot.
    ///   - depot: An observable depot to read from and write to.
    ///   - initialValue: When `true` (the default), the current value is delivered immediately.
    public init(
        key: some TypedDistinctKeyProtocol<Value>,
        depot: Depot,
        initialValue: Bool = true,
    ) {
        _storage = State(
            initialValue: DepotValueStorage(
                depot: depot,
                key: TypedDistinctKey(key),
                initialValue: initialValue,
            ),
        )
    }

    /// Creates a depot-backed property wrapper from a ``KeyDefinition``.
    ///
    /// The definition's key and coder are registered with the depot automatically.
    ///
    /// - Parameters:
    ///   - definition: A static key definition containing the key path and coder.
    ///   - depot: An observable depot to read from and write to.
    ///   - initialValue: When `true` (the default), the current value is delivered immediately.
    public init(
        definition: KeyDefinition<Value>,
        depot: Depot,
        initialValue: Bool = true,
    ) {
        let key = depot.register(definition)
        self.init(key: key, depot: depot, initialValue: initialValue)
    }

    /// The current value stored in the depot, or `nil` if no value exists.
    public var wrappedValue: Value? {
        storage.value
    }

    /// A binding to the depot value, suitable for two-way SwiftUI bindings.
    ///
    /// Writing through this binding calls ``Depot/set(value:for:)`` synchronously.
    public var projectedValue: Binding<Value?> {
        Binding(
            get: { storage.value },
            set: { newValue in storage.setValue(newValue) },
        )
    }

    /// The last error encountered while observing or writing, if any.
    public var error: Error? {
        storage.error
    }
}

// MARK: - DepotValueStorage

/// Internal `@Observable` storage that bridges depot observation to SwiftUI.
@MainActor
@Observable
final class DepotValueStorage<Value: Sendable> {
    var value: Value?
    private(set) var error: Error?

    @ObservationIgnored
    private let depot: Depot

    @ObservationIgnored
    private let key: TypedDistinctKey<Value>

    @ObservationIgnored
    private var task: Task<Void, Never>?

    init(depot: Depot, key: TypedDistinctKey<Value>, initialValue: Bool) {
        self.depot = depot
        self.key = key
        startObserving(initialValue: initialValue)
    }

    deinit {
        task?.cancel()
    }

    func setValue(_ newValue: Value?) {
        let depot = self.depot
        let key = self.key
        Task {
            do {
                try await depot.set(value: newValue, for: key)
            } catch {
                self.error = error
            }
        }
    }

    private func startObserving(initialValue: Bool) {
        task = Task { [weak self, depot, key] in
            for await result in depot.values(for: key, initialValue: initialValue) {
                await MainActor.run {
                    guard let self else {
                        return
                    }
                    switch result {
                    case let .success(value):
                        self.value = value
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
