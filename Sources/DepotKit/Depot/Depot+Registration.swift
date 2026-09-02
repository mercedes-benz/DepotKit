// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

// MARK: - Registration

extension Depot {
    /// Registers a key with a coder and returns the typed key handle.
    @discardableResult
    public func register<V: Sendable>(
        key: some KeyProtocol,
        coder: some Coder<V>,
        expiry: Duration? = nil
    ) -> TypedKey<V> {
        LOG(level: .debug, message: "Depot[\(label)] register '\(key)'")
        return core.register(key: key, coder: coder, expiry: expiry)
    }

    /// Registers a distinct key with a coder and returns a typed distinct key handle.
    @discardableResult
    public func register<V: Sendable>(
        key: some DistinctKeyProtocol,
        coder: some Coder<V>,
        expiry: Duration? = nil
    ) -> TypedDistinctKey<V> {
        let typedKey = register(key: Key(key.components), coder: coder, expiry: expiry)
        guard let distinctKey = try? typedKey.distinct() else {
            preconditionFailure("Expected a distinct key registration for \(key)")
        }
        return distinctKey
    }

    // MARK: AnyCoder Overloads

    // @_disfavoredOverload is intentional here: AnyCoder conforms to Coder, so
    // without disfavoring the concrete-AnyCoder overloads the compiler would
    // consider them ambiguous with the primary overloads that accept
    // `some Coder<V>`. By disfavoring these, callers get dot-syntax (`.json()`)
    // when the coder is already an AnyCoder, while generic Coder conformances
    // resolve to the primary overload without ambiguity.

    /// Registers a key with an ``AnyCoder``, enabling `.json()` / `.data()` / `.plist()` dot-syntax.
    @discardableResult
    @_disfavoredOverload
    public func register<V: Sendable>(key: some KeyProtocol, coder: AnyCoder<V>, expiry: Duration? = nil) -> TypedKey<V>
    {
        LOG(level: .debug, message: "Depot[\(label)] register '\(key)'")
        return core.register(key: key, coder: coder, expiry: expiry)
    }

    /// Registers a distinct key with an ``AnyCoder``, enabling dot-syntax factories.
    @discardableResult
    @_disfavoredOverload
    public func register<V: Sendable>(
        key: some DistinctKeyProtocol,
        coder: AnyCoder<V>,
        expiry: Duration? = nil
    ) -> TypedDistinctKey<V> {
        LOG(level: .debug, message: "Depot[\(label)] register '\(key)'")
        let typedKey: TypedKey<V> = core.register(key: key, coder: coder, expiry: expiry)
        guard let distinctKey = try? typedKey.distinct() else {
            preconditionFailure("Expected a distinct key registration for \(key)")
        }
        return distinctKey
    }

    /// Registers a pattern key-path expression (may contain wildcards).
    @discardableResult
    public func register<V: Sendable>(
        keyPath: PatternKeyPathExpression,
        coder: some Coder<V>,
        expiry: Duration? = nil
    ) -> TypedKey<V> {
        let key = Key.from(keyPath)
        return register(key: key, coder: coder, expiry: expiry)
    }

    /// Registers a distinct key-path expression (no wildcards).
    @discardableResult
    public func register<V: Sendable>(
        keyPath: KeyPathExpression,
        coder: some Coder<V>,
        expiry: Duration? = nil
    ) -> TypedDistinctKey<V> {
        let key: DistinctKey = Key.from(keyPath)
        return register(key: key, coder: coder, expiry: expiry)
    }

    // Same @_disfavoredOverload rationale as above.

    /// Registers a pattern key-path expression with an ``AnyCoder``.
    @discardableResult
    @_disfavoredOverload
    public func register<V: Sendable>(
        keyPath: PatternKeyPathExpression,
        coder: AnyCoder<V>,
        expiry: Duration? = nil
    ) -> TypedKey<V> {
        register(key: Key.from(keyPath), coder: coder, expiry: expiry)
    }

    /// Registers a distinct key-path expression with an ``AnyCoder``.
    @discardableResult
    @_disfavoredOverload
    public func register<V: Sendable>(
        keyPath: KeyPathExpression,
        coder: AnyCoder<V>,
        expiry: Duration? = nil
    ) -> TypedDistinctKey<V> {
        register(key: Key.from(keyPath) as DistinctKey, coder: coder, expiry: expiry)
    }
}
