// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

// MARK: - Key Errors

/// Errors related to key operations.
///
/// These errors are thrown when a key operation cannot be completed because
/// of a structural constraint — for example, attempting to convert a pattern
/// key (one that contains wildcards) into a ``DistinctKey``.
public enum KeyError: Error, Equatable, Sendable {
    /// The key contains wildcard components and cannot be used as a distinct key.
    ///
    /// Thrown by ``KeyProtocol/distinct()`` and ``TypedKeyProtocol/distinct()``
    /// when the key contains at least one ``KeyComponent/wildcard``.
    case nonDistinctKey
}

extension KeyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .nonDistinctKey:
            "The key contains wildcards and cannot be used as a distinct key."
        }
    }
}

/// A single component of a key path.
///
/// Key paths are composed of an ordered list of components. Each component is
/// a concrete ``segment(identifier:)``, a ``wildcard``, or a ``globstar``.
///
/// - ``segment(identifier:)``: Matches only a component with the exact same
///   identifier string. When **all** components of a key are segments,
///   the key is *distinct* — it identifies exactly one value.
///
/// - ``wildcard``: Matches exactly **one** component at the same position.
///   When a key contains at least one wildcard or globstar, it is a *pattern*
///   and can match multiple values in a depot.
///
/// - ``globstar``: Matches **zero or more** components at the same position.
///   Use this for deep/recursive matching (e.g. remove all values at any depth).
///
/// You rarely create `KeyComponent` values directly. Instead, use the `/`
/// operator with ``KeyPathExpression`` and ``PatternKeyComponent/wildcard``
/// or ``PatternKeyComponent/globstar``:
///
/// ```swift
/// // Distinct — all segments:
/// let key = Key.from("user" / "settings")
///
/// // Pattern — single-level wildcard:
/// let pattern = Key.from("users" / .wildcard / "settings")
///
/// // Pattern — multi-level globstar:
/// let deep = Key.from("users" / .globstar)
/// ```
///
/// > Important: The strings `"*"` and `"**"` in a `/` expression create
/// > ``segment(identifier:)`` values with literal text. To create wildcards,
/// > always use `.wildcard` or `.globstar`.
public enum KeyComponent: Hashable, Sendable {
    /// A wildcard matches exactly one component at the same position.
    /// When a key has at least one wildcard or globstar in its components it's a **pattern**.
    case wildcard

    /// A globstar matches zero or more components at the same position.
    /// Use this for deep/recursive matching.
    case globstar

    /// A segment matches only an exact match.
    /// When all components of a key are segments it's **distinct**.
    case segment(identifier: String)
}

/// A key-component type restricted to wildcards and globstars.
///
/// Use ``PatternKeyComponent/wildcard`` (written as `.wildcard`) or
/// ``PatternKeyComponent/globstar`` (written as `.globstar`) in `/`
/// expressions to introduce a pattern and produce a ``PatternKeyPathExpression``:
///
/// ```swift
/// let key = Key.from("users" / .wildcard / "settings")
/// let deep = Key.from("users" / .globstar)
/// ```
///
/// > Important: The strings `"*"` and `"**"` in a `/` expression are **not**
/// > wildcards — they create segments with literal text.
/// > Always use `.wildcard` or `.globstar` for pattern components.
public enum PatternKeyComponent: Hashable, Sendable {
    /// A wildcard matches exactly one component.
    case wildcard

    /// A globstar matches zero or more components.
    case globstar

    /// The corresponding ``KeyComponent`` for this pattern component.
    @inlinable
    @inline(__always)
    public var keyComponent: KeyComponent {
        switch self {
        case .wildcard: .wildcard
        case .globstar: .globstar
        }
    }
}

// MARK: - Key Protocols

/// A type that can be used as a depot key.
///
/// `KeyProtocol` is the base protocol shared by all key types in *DepotKit*.
/// Conform to this protocol when you need generic code that works with any key,
/// regardless of whether it is typed or distinct.
///
/// ## Concrete conforming types
/// | Type | Typed | Distinct |
/// |---|---|---|
/// | ``Key`` | ❌ | maybe |
/// | ``DistinctKey`` | ❌ | ✅ |
/// | ``TypedKey`` | ✅ | maybe |
/// | ``TypedDistinctKey`` | ✅ | ✅ |
///
/// ## Protocols
/// Use the more specific sub-protocols to constrain generic parameters:
/// - ``DistinctKeyProtocol`` — guarantees no wildcards at the type level.
/// - ``TypedKeyProtocol`` — associates a `Value` type with the key.
/// - ``TypedDistinctKeyProtocol`` — combines both guarantees.
public protocol KeyProtocol: Hashable, Sendable {
    /// The path components that make up this key.
    var components: [KeyComponent] { get }

    /// Whether the key is distinct (contains no wildcard components).
    ///
    /// A distinct key references exactly one value in a depot.
    /// A pattern key contains at least one ``KeyComponent/wildcard``
    /// and can match multiple values.
    ///
    /// ```swift
    /// let distinctKey = Key.from("preferences" / "onboardingComplete")
    /// distinctKey.isDistinct  // true
    ///
    /// let patternKey = Key.from("preferences" / .wildcard)
    /// patternKey.isDistinct  // false
    /// ```
    var isDistinct: Bool { get }
}

/// A key that carries an associated `Value` type.
///
/// `TypedKeyProtocol` extends ``KeyProtocol`` with a `Value` associated type
/// so that depot read/write operations can be type-safe.
/// Both ``TypedKey`` and ``TypedDistinctKey`` conform to this protocol.
///
/// Use this protocol when you need to accept any typed key regardless of
/// whether it is distinct:
///
/// ```swift
/// func printValue<K: TypedKeyProtocol>(for key: K, in depot: some Depot) throws
///     where K.Value: CustomStringConvertible { … }
/// ```
public protocol TypedKeyProtocol<Value>: KeyProtocol {
    /// The type of value that this key references in a depot.
    associatedtype Value: Sendable
}

/// A key that is guaranteed — at the type level — to contain no wildcards.
///
/// Conforming types always have ``KeyProtocol/isDistinct`` equal to `true`.
/// Use this protocol to constrain generic parameters in APIs that require
/// a unique key path (e.g. single-value get/set operations).
///
/// Both ``DistinctKey`` and ``TypedDistinctKey`` conform to this protocol.
public protocol DistinctKeyProtocol: KeyProtocol {}

/// A typed key that is guaranteed — at the type level — to be distinct.
///
/// Combines the type association of ``TypedKeyProtocol`` with the
/// distinctness guarantee of ``DistinctKeyProtocol``.
/// ``TypedDistinctKey`` is the concrete conforming type.
public protocol TypedDistinctKeyProtocol<Value>: TypedKeyProtocol, DistinctKeyProtocol {}
