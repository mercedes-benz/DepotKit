// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if canImport(SwiftUI) && canImport(Observation)

import DepotKit
import Observation
import SwiftUI

// MARK: - DepotValue

/// A SwiftUI property wrapper that reads and writes a single value from a `Depot`.
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
/// You can also initialise from a `KeyDefinition`, which registers the
/// key automatically when the observation starts:
///
/// ```swift
/// @DepotValue(definition: Keys.username, depot: depot)
/// var username: String?
/// ```
///
/// ### Lifecycle
///
/// SwiftUI creates a new view value — and with it a new wrapper — every time a parent view
/// re-evaluates its `body`, but keeps the state of the view that is already on screen. Creating
/// the wrapper is therefore cheap and free of side effects: it only stores the depot, the key
/// (or definition) and the `initialValue` flag. It does not read from or register with the
/// depot.
///
/// The work starts when SwiftUI installs the view and calls `update()` before evaluating its
/// `body` for the first time: the wrapper registers the definition (for
/// ``init(definition:depot:initialValue:)``) and starts observing the key. Later
/// re-creations of the view with the same key and depot do not register again or start
/// another observation.
///
/// If the parent later passes a different key (path) or a different depot, the wrapper cancels
/// the previous observation and starts observing the new configuration before the next `body`
/// evaluation (registering the new definition first, if it was created from one). The displayed
/// value and ``error`` are reset to `nil` at that point, and the new key's value arrives
/// asynchronously like the initial value. Writes already made through the binding still
/// complete for the key they were made for. Changing only `initialValue`, or passing a
/// different definition with the same path, does not restart the observation.
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
/// depot. The setter returns immediately (fire-and-forget) and writes are
/// applied in the order they are made; when a new write is made before an
/// earlier one has started, the earlier one is skipped. The displayed value
/// is not updated optimistically: ``wrappedValue`` and the binding keep
/// returning the previous value until the depot's observation delivers the
/// stored value. If the write fails, the displayed value stays unchanged and
/// the error is exposed through ``error`` until the next successful delivery.
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
/// By default, the current depot value is read and delivered asynchronously
/// right after the observation starts; until it arrives, the wrapped value is
/// `nil`. Pass
/// `initialValue: false` to suppress this and only receive future changes:
///
/// ```swift
/// @DepotValue(key: usernameKey, depot: depot, initialValue: false)
/// var username: String?
/// ```
///
/// > Important: The key must be registered with the depot **before** the view is
/// > displayed, unless you use the ``init(definition:depot:initialValue:)`` convenience
/// > initialiser which registers the key for you.
@MainActor
@propertyWrapper
public struct DepotValue<Value: Sendable>: DynamicProperty {
    private enum Source {
        case key(TypedDistinctKey<Value>)
        case definition(KeyDefinition<Value>)
    }

    @State
    private var storage = DepotValueStorage<Value>()

    private let depot: Depot
    private let source: Source
    private let initialValue: Bool

    /// Creates a depot-backed property wrapper.
    ///
    /// Creating the wrapper has no side effects; observation starts when SwiftUI first updates
    /// the view that owns it.
    ///
    /// - Parameters:
    ///   - key: A typed distinct key identifying the value. Must be registered with the depot before the view is
    ///     displayed.
    ///   - depot: An observable depot to read from and write to.
    ///   - initialValue: When `true` (the default), the current value is delivered (asynchronously) right after
    ///     the observation starts.
    public init(
        key: some TypedDistinctKeyProtocol<Value>,
        depot: Depot,
        initialValue: Bool = true,
    ) {
        self.depot = depot
        source = .key(TypedDistinctKey(key))
        self.initialValue = initialValue
    }

    /// Creates a depot-backed property wrapper from a `KeyDefinition`.
    ///
    /// Creating the wrapper has no side effects. The definition's key and coder are registered with the
    /// depot right before the observation starts — when SwiftUI first updates the view that owns the
    /// wrapper, or when the definition's path or the depot changes.
    ///
    /// - Parameters:
    ///   - definition: A static key definition containing the key path and coder.
    ///   - depot: An observable depot to read from and write to.
    ///   - initialValue: When `true` (the default), the current value is delivered (asynchronously) right after
    ///     the observation starts.
    public init(
        definition: KeyDefinition<Value>,
        depot: Depot,
        initialValue: Bool = true,
    ) {
        self.depot = depot
        source = .definition(definition)
        self.initialValue = initialValue
    }

    /// The current value stored in the depot, or `nil` if no value exists.
    public var wrappedValue: Value? {
        storage.value
    }

    /// A binding to the depot value, suitable for two-way SwiftUI bindings.
    ///
    /// Writing through this binding dispatches an asynchronous write to the depot.
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

    /// Starts observing the configured key, or restarts the observation when the key or depot changed.
    ///
    /// SwiftUI calls this on the main thread before each evaluation of the owning view's `body`.
    /// Calls with an unchanged key and depot do nothing.
    public nonisolated func update() {
        MainActor.assumeIsolated {
            switch source {
            case let .key(key):
                storage.observe(key: key, in: depot, initialValue: initialValue)
            case let .definition(definition):
                storage.observe(key: TypedDistinctKey(definition.key), in: depot, initialValue: initialValue) {
                    depot.register(definition)
                }
            }
        }
    }
}

// MARK: - DepotValueStorage

/// Internal `@Observable` storage that bridges depot observation to SwiftUI.
///
/// A new storage is inert; `observe(key:in:initialValue:beforeStart:)` starts (or restarts) the
/// observation.
@MainActor
@Observable
final class DepotValueStorage<Value: Sendable> {
    var value: Value?
    private(set) var error: Error?

    @ObservationIgnored
    private var depot: Depot?

    @ObservationIgnored
    private var key: TypedDistinctKey<Value>?

    @ObservationIgnored
    private var task: Task<Void, Never>?

    @ObservationIgnored
    private var writeTask: Task<Void, Never>?

    init() {}

    deinit {
        task?.cancel()
    }

    /// Observes `key` in `depot`.
    ///
    /// Does nothing when the storage already observes the same key in the same depot. Otherwise
    /// cancels the current observation (if any), detaches pending writes (they still complete for
    /// their key), resets `value` and `error`, runs `beforeStart`
    /// (e.g. to register the key) and starts observing the new configuration.
    func observe(
        key: TypedDistinctKey<Value>,
        in depot: Depot,
        initialValue: Bool,
        beforeStart: () -> Void = {},
    ) {
        if let currentDepot = self.depot, currentDepot === depot, self.key == key {
            return
        }

        task?.cancel()
        // Pending writes complete for the key they were made for; later writes target the new key
        // and neither wait for nor skip them.
        writeTask = nil
        if value != nil {
            value = nil
        }
        if error != nil {
            error = nil
        }

        beforeStart()
        self.depot = depot
        self.key = key
        task = Task { [weak self] in
            for await result in depot.values(for: key, initialValue: initialValue) {
                // A restart cancels this task on the main actor; drop results of the old key.
                guard let self, !Task.isCancelled else {
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

    /// Writes `newValue` to the observed key. Does nothing before the observation has started.
    func setValue(_ newValue: Value?) {
        guard let depot, let key else {
            return
        }
        let previousWrite = writeTask
        previousWrite?.cancel()
        writeTask = Task { [weak self] in
            // Apply writes in call order: an earlier write that is already running must not
            // complete after (and overwrite) this one.
            await previousWrite?.value
            do {
                try await depot.set(value: newValue, for: key)
            } catch is CancellationError {
                // Intentional: a new write cancelled this one — not a user-visible error.
            } catch {
                // Only expose the error while the storage still shows the key it was written to.
                guard let self, self.depot === depot, self.key == key else {
                    return
                }
                self.error = error
            }
        }
    }

    /// Waits until the latest write made through `setValue(_:)` has finished (for testing).
    ///
    /// Writes are chained, so this also waits for every earlier write made for the current key.
    /// A write that failed has exposed its error when this returns. Writes detached by a restart
    /// of the observation are not awaited.
    func waitForPendingWritesForTesting() async {
        await writeTask?.value
    }
}

#endif
