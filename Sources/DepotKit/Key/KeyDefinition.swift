// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

// MARK: - KeyDefinition

/// A static definition of a depot key, combining a key path with its coder.
///
/// Use `KeyDefinition` to define keys as static properties on a namespace
/// enum, then register them with a depot. This keeps key declarations centralised
/// and eliminates scattered string literals.
///
/// ```swift
/// enum Keys {
///     static let username = KeyDefinition<String>(
///         path: "user" / "username",
///         coder: .json()
///     )
///     static let preferences = KeyDefinition<Preferences>(
///         path: "user" / "preferences",
///         coder: .json()
///     )
/// }
///
/// // Register and use:
/// let key = depot.register(Keys.username)
/// try depot.set(value: "Alice", for: key)
/// ```
public struct KeyDefinition<Value: Sendable>: Sendable {
    /// The distinct key for this definition.
    public let key: DistinctKey

    /// The type-erased coder for encoding and decoding values.
    public let coder: AnyCoder<Value>

    /// The expiry duration for values written under this key, or `nil` for no expiry.
    public let expiry: Duration?

    /// Creates a key definition from a distinct key path expression and a coder.
    ///
    /// - Parameters:
    ///   - path: A distinct key path expression (no wildcards).
    ///   - coder: An ``AnyCoder`` capable of encoding and decoding values of type `Value`.
    ///   - expiry: Optional duration after which the value expires.
    public init(path: KeyPathExpression, coder: AnyCoder<Value>, expiry: Duration? = nil) {
        key = Key.from(path)
        self.coder = coder
        self.expiry = expiry
    }

    /// Creates a key definition from an existing distinct key and a coder.
    ///
    /// - Parameters:
    ///   - key: A distinct key (no wildcards).
    ///   - coder: An ``AnyCoder`` capable of encoding and decoding values of type `Value`.
    ///   - expiry: Optional duration after which the value expires.
    public init(key: DistinctKey, coder: AnyCoder<Value>, expiry: Duration? = nil) {
        self.key = key
        self.coder = coder
        self.expiry = expiry
    }
}

// MARK: - PatternKeyDefinition

/// A static definition of a wildcard depot key, combining a key path with its coder.
///
/// Use `PatternKeyDefinition` for keys that contain wildcards and match
/// multiple values:
///
/// ```swift
/// enum Keys {
///     static let allSettings = PatternKeyDefinition<Settings>(
///         path: "users" / .wildcard / "settings",
///         coder: .json()
///     )
/// }
///
/// let key = depot.register(Keys.allSettings)
/// let settings = try depot.get(valuesFor: key)
/// ```
public struct PatternKeyDefinition<Value: Sendable>: Sendable {
    /// The (possibly wildcard) key for this definition.
    public let key: Key

    /// The type-erased coder for encoding and decoding values.
    public let coder: AnyCoder<Value>

    /// The expiry duration for values written under this pattern, or `nil` for no expiry.
    public let expiry: Duration?

    /// Creates a pattern key definition from a key path expression and a coder.
    ///
    /// - Parameters:
    ///   - path: A pattern key path expression (contains at least one wildcard).
    ///   - coder: An ``AnyCoder`` capable of encoding and decoding values of type `Value`.
    ///   - expiry: Optional duration after which values expire.
    public init(path: PatternKeyPathExpression, coder: AnyCoder<Value>, expiry: Duration? = nil) {
        key = Key.from(path)
        self.coder = coder
        self.expiry = expiry
    }

    /// Creates a pattern key definition from an existing key and a coder.
    ///
    /// - Parameters:
    ///   - key: A key (may contain wildcards).
    ///   - coder: An ``AnyCoder`` capable of encoding and decoding values of type `Value`.
    ///   - expiry: Optional duration after which values expire.
    public init(key: Key, coder: AnyCoder<Value>, expiry: Duration? = nil) {
        self.key = key
        self.coder = coder
        self.expiry = expiry
    }
}

// MARK: - Depot + KeyDefinition

extension Depot {
    /// Registers a key from a static ``KeyDefinition`` and returns the typed distinct key.
    ///
    /// This convenience method lets you register pre-defined key definitions in a
    /// single call:
    ///
    /// ```swift
    /// let key = depot.register(Keys.username)
    /// try depot.set(value: "Alice", for: key)
    /// ```
    ///
    /// - Parameter definition: A static key definition containing the key path and coder.
    /// - Returns: A ``TypedDistinctKey`` for single-value read and write operations.
    @discardableResult
    public func register<V: Sendable>(_ definition: KeyDefinition<V>) -> TypedDistinctKey<V> {
        register(key: definition.key, coder: definition.coder, expiry: definition.expiry)
    }

    /// Registers a wildcard key from a static ``PatternKeyDefinition`` and returns the typed key.
    ///
    /// ```swift
    /// let key = depot.register(Keys.allSettings)
    /// let settings = try depot.get(valuesFor: key)
    /// ```
    ///
    /// - Parameter definition: A static wildcard key definition containing the key path and coder.
    /// - Returns: A ``TypedKey`` for multi-value read operations.
    @discardableResult
    public func register<V: Sendable>(_ definition: PatternKeyDefinition<V>) -> TypedKey<V> {
        register(key: definition.key, coder: definition.coder, expiry: definition.expiry)
    }
}
