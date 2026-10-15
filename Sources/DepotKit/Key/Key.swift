// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

// MARK: - Key Types

/// A key references one or multiple values in a depot.
///
/// You are familiar with *keys* when working with `Dictionary` or `UserDefaults`. Similarly, they are essential when you want to reference values in a depot.
/// Whereas with `Dictionary` the only requirement for the keys is that they must conform to `Hashable`, keys in *DepotKit* are slightly more advanced.
///
/// ## Creating Keys
///
/// ``Key`` is constructed from a **key path expression**, using the `/` operator
/// to compose components. Key paths let you organize values in your depot
/// similar to files in directories.
///
/// ```swift
/// let plainKey = Key.from("isLoggedIn")
/// let structuredKey = Key.from("user" / "preferences" / "analytics")
/// ```
///
/// Key paths without wildcards produce a ``DistinctKey`` (via ``KeyPathExpression``).
/// Adding a `.wildcard` component produces a pattern ``Key``
/// (via ``PatternKeyPathExpression``):
///
/// ```swift
/// // Remove all data for all entities in the depot
/// let allEntitiesKey = Key.from("entities" / .wildcard)
/// try depot.remove(valuesFor: allEntitiesKey)
/// ```
///
/// ## Dynamic Key Components
///
/// When the first component of a key is a runtime value rather than a literal,
/// use ``KeyPathExpression/component(_:)``:
///
/// ```swift
/// let userKey = Key.from(.component(userId) / "settings")
/// ```
///
/// Subsequent components can use any `CustomStringConvertible` value directly:
///
/// ```swift
/// let key = Key.from("users" / userId / "settings")
/// ```
///
/// ## Typed Keys
///
/// Pass an `as:` parameter to ``Key/from(_:as:)->TypedDistinctKey<V>`` to associate a
/// value type and get a ``TypedDistinctKey``:
///
/// ```swift
/// let nameKey = Key.from("user" / "name", as: String.self)
/// // nameKey is TypedDistinctKey<String>
/// ```
///
/// ## Key Hierarchy
///
/// The key type hierarchy mirrors the two independent properties a key can have
/// — *typed* and *distinct*:
///
/// | Type | Typed | Distinct |
/// |---|---|---|
/// | ``Key`` | ❌ | maybe |
/// | ``DistinctKey`` | ❌ | ✅ |
/// | ``TypedKey`` | ✅ | maybe |
/// | ``TypedDistinctKey`` | ✅ | ✅ |
///
/// ## Wildcard Matching
///
/// Use ``matches(_:)`` to check if a pattern key matches a concrete key.
/// DepotKit uses glob semantics with the `**` rules of `.gitignore`:
///
/// - `.wildcard` (`*`) matches exactly **one** component.
/// - A trailing `.globstar` (`**`) matches **one or more** components — everything
///   inside the prefix, but not the prefix itself.
/// - A leading or middle `.globstar` matches **zero or more** components.
///
/// ```swift
/// let single = Key.from("users" / .wildcard / "settings")
/// single.matches(Key.from("users" / "alice" / "settings"))   // true
/// single.matches(Key.from("users" / "a" / "b" / "settings")) // false — * is one level
///
/// let deep = Key.from("users" / .globstar)
/// deep.matches(Key.from("users" / "alice"))                  // true
/// deep.matches(Key.from("users" / "alice" / "settings"))     // true — ** is recursive
/// deep.matches(Key.from("users"))                            // false — trailing ** needs ≥ 1
///
/// let anywhere = Key.from(.globstar / "settings")
/// anywhere.matches(Key.from("settings"))                     // true — leading ** may be empty
/// ```
///
/// > Important: The strings `"*"` and `"**"` in a `/` expression are treated
/// > as literal components, not wildcards. Always use `.wildcard` or `.globstar`.
public struct Key: KeyProtocol, CustomStringConvertible {
    /// The path components that make up this key.
    public let components: [KeyComponent]

    /// Whether this key is distinct (contains no wildcard components).
    public let isDistinct: Bool

    /// Pre-computed hash value for fast dictionary lookups.
    let cachedHashValue: Int

    /// Computes a hash value from the given components.
    @inline(__always)
    private static func computeHash(of components: [KeyComponent]) -> Int {
        var hasher = Hasher()
        hasher.combine(components)
        return hasher.finalize()
    }

    /// Creates a key from any other key-conforming value.
    ///
    /// Segment identifiers are normalized to Unicode Normalization Form C.
    public init(_ other: some KeyProtocol) {
        if let other = other as? any CanonicalKeyConvertible {
            self = other.canonicalKey
        } else {
            self.init(other.components)
        }
    }

    /// Creates a key from an array of components.
    ///
    /// Prefer ``Key/from(_:)->DistinctKey`` or ``Key/from(_:)->Key`` for
    /// constructing keys from key path expressions.
    ///
    /// Segment identifiers are normalized to Unicode Normalization Form C
    /// (without case folding), so canonically equivalent spellings produce
    /// identical keys, key paths and file names.
    ///
    /// - Parameter components: The components of the key. Must not be empty.
    ///
    /// - Precondition: `components` must not be empty.
    /// - Precondition: Components must not contain consecutive wildcards.
    public init(_ components: [KeyComponent]) {
        components.assertValidKeyComponents()
        let components = components.canonicalized()
        self.components = components
        isDistinct = !components.containsPattern()
        cachedHashValue = Self.computeHash(of: components)
    }

    /// Creates a key from pre-validated components. No validation is performed,
    /// but identifiers are normalized to Unicode Normalization Form C.
    @usableFromInline
    init(unchecked components: [KeyComponent], isDistinct: Bool) {
        let components = components.canonicalized()
        self.components = components
        self.isDistinct = isDistinct
        cachedHashValue = Self.computeHash(of: components)
    }

    /// A textual representation of the key, e.g. `Key<"users/depotkit">`.
    public var description: String {
        "Key<\"\(keyPath)\">"
    }

    // MARK: - Hashable / Equatable (exclude derived isDistinct)

    public static func == (lhs: Key, rhs: Key) -> Bool {
        lhs.cachedHashValue == rhs.cachedHashValue && lhs.components == rhs.components
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(cachedHashValue)
    }
}

/// A key that is guaranteed to be distinct (no wildcard components).
///
/// Distinct keys reference exactly one value in a depot and can be used with
/// operations like ``Depot/get(valueFor:)-5hm8k`` and ``Depot/set(value:for:)-6afwr``
/// that require a unique key path.
///
/// ## Creating Distinct Keys
///
/// Create a `DistinctKey` using the factory method — the compiler selects
/// this return type automatically when the expression contains no wildcards:
///
/// ```swift
/// let key = Key.from("user" / "settings")               // DistinctKey
/// let key = Key.from(KeyPathExpression(id) / "settings")  // dynamic first component
/// ```
///
/// You can also convert from a ``Key``: `key.distinct()` (throws when the key has wildcards).
///
/// ## Accessing the Underlying Key
///
/// Use the ``key`` property to obtain the underlying ``Key`` when passing
/// to APIs that accept ``KeyProtocol`` constraints:
///
/// ```swift
/// let distinct = Key.from("user" / "name")
/// let untyped: Key = distinct.key
/// ```
public struct DistinctKey: DistinctKeyProtocol, CustomStringConvertible {
    /// The underlying untyped key.
    public let key: Key

    /// The path components that make up this key.
    public var components: [KeyComponent] {
        key.components
    }

    /// Always `true` for a distinct key.
    public let isDistinct = true

    /// Creates a distinct key from any key-conforming value.
    public init(_ other: some DistinctKeyProtocol) {
        if let other = other as? DistinctKey {
            self = other
        } else if let other = other as? any CanonicalKeyConvertible {
            self.init(uncheckedKey: other.canonicalKey)
        } else {
            self.init(other.components)
        }
    }

    /// Creates a distinct key from an array of components.
    ///
    /// - Parameter components: The components of the key. Must not contain wildcards.
    /// - Precondition: No component may be ``KeyComponent/wildcard``.
    public init(_ components: [KeyComponent]) {
        key = Key(components)
        precondition(key.isDistinct, "DistinctKey requires a distinct key (no wildcards).")
    }

    /// Creates a distinct key from a pre-validated key. No validation is performed.
    @usableFromInline
    init(uncheckedKey key: Key) {
        self.key = key
    }

    /// A textual representation of the key, e.g. `DistinctKey<"user/settings">`.
    public var description: String {
        "DistinctKey<\"\(keyPath)\">"
    }

    // MARK: - Hashable / Equatable (exclude constant isDistinct)

    public static func == (lhs: DistinctKey, rhs: DistinctKey) -> Bool {
        lhs.key == rhs.key
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }
}

/// A key with an associated `Value` type.
///
/// Typed keys are required for all read and write operations on a depot.
/// You obtain a typed key in one of three ways:
/// 1. Register an untyped key with a depot — ``Depot/register(key:coder:expiry:)-(KeyProtocol,AnyCoder<V>,_)`` returns a `TypedKey`.
/// 2. Use the factory method with `as:`: `Key.from("users" / .wildcard, as: String.self)`.
/// 3. Convert from an existing key using ``KeyProtocol/typed(as:)``.
///
/// A `TypedKey` may or may not be distinct. If you need a compile-time
/// distinctness guarantee, use ``TypedDistinctKey`` instead.
///
/// ## Typed Keys and Wildcards
///
/// When you use a wildcard in a typed key, you get a ``TypedKey`` rather
/// than a ``TypedDistinctKey``:
///
/// ```swift
/// // TypedKey<String> — pattern, for observation / enumeration
/// let allStatuses = Key.from("entities" / .wildcard / "status", as: String.self)
///
/// // TypedDistinctKey<String> — distinct, for get / set
/// let aliceStatus = Key.from("entities" / "alice" / "status", as: String.self)
/// ```
///
/// ## Accessing the Underlying Key
///
/// Use the ``key`` property when passing to APIs that accept ``KeyProtocol``
/// constraints:
///
/// ```swift
/// let typed: TypedKey<String> = Key.from("users" / .wildcard, as: String.self)
/// let untyped: Key = typed.key
/// ```
public struct TypedKey<Value: Sendable>: TypedKeyProtocol, CustomStringConvertible {
    /// The underlying untyped key.
    public let key: Key

    /// The path components that make up this key.
    public var components: [KeyComponent] {
        key.components
    }

    /// Whether this key is distinct (contains no wildcard components).
    public var isDistinct: Bool {
        key.isDistinct
    }

    /// Creates a typed key from any key-conforming value.
    public init(_ other: some KeyProtocol) {
        if let other = other as? TypedKey<Value> {
            self = other
        } else if let other = other as? any CanonicalKeyConvertible {
            self.init(uncheckedKey: other.canonicalKey)
        } else {
            self.init(other.components)
        }
    }

    /// Creates a typed key from an array of components.
    ///
    /// Prefer ``Key/from(_:as:)->TypedDistinctKey<V>`` or ``Key/from(_:as:)->TypedKey<V>``
    /// for constructing typed keys from key path expressions.
    ///
    /// - Parameter components: The components of the key. Must not be empty.
    ///
    /// - Precondition: `components` must not be empty.
    /// - Precondition: Components must not contain consecutive wildcards.
    public init(_ components: [KeyComponent]) {
        key = Key(components)
    }

    /// Creates a typed key from a pre-validated key. No validation is performed.
    @usableFromInline
    init(uncheckedKey key: Key) {
        self.key = key
    }

    /// A textual representation of the key, e.g. `TypedKey<User, "users/depotkit">`.
    public var description: String {
        "TypedKey<\(Value.self), \"\(keyPath)\">"
    }
}

/// A typed key that is guaranteed to be distinct (no wildcard components).
///
/// `TypedDistinctKey` combines the type association of ``TypedKey`` with the
/// distinctness guarantee of ``DistinctKey``. Methods like ``Depot/get(valueFor:)-5hm8k``
/// and ``Depot/set(value:for:)-6afwr`` accept `TypedDistinctKey` directly without
/// needing runtime distinctness checks.
///
/// ## Creating Typed Distinct Keys
///
/// Create a `TypedDistinctKey` using the factory method with `as:` —
/// the compiler selects this return type automatically when the expression
/// contains no wildcards:
///
/// ```swift
/// let key = Key.from("user" / "name", as: String.self)  // TypedDistinctKey<String>
/// ```
///
/// You can also obtain one by registering a ``DistinctKey`` with a depot:
///
/// ```swift
/// let key = depot.register(key: Key.from("user" / "name"), coder: .json())
/// ```
///
/// Or by calling ``DistinctKeyProtocol/typed(as:)`` on any distinct key:
///
/// ```swift
/// let untyped = Key.from("user" / "name")       // DistinctKey
/// let typed = untyped.typed(as: String.self)     // TypedDistinctKey<String>
/// ```
///
/// ## Using with Depot Operations
///
/// ```swift
/// let nameKey = Key.from("user" / "name", as: String.self)
/// try depot.set(value: "Alice", for: nameKey)
/// let name = try depot.get(valueFor: nameKey)  // "Alice"
/// ```
///
/// ## Accessing the Underlying Key
///
/// Use the ``key`` property when passing to APIs that accept ``KeyProtocol``
/// constraints:
///
/// ```swift
/// let typed = Key.from("user" / "name", as: String.self)
/// let untyped: Key = typed.key
/// ```
///
/// Both `TypedDistinctKey` and ``TypedKey`` conform to ``TypedKeyProtocol``,
/// so APIs using generic constraints can accept either type transparently.
public struct TypedDistinctKey<Value: Sendable>: TypedDistinctKeyProtocol, CustomStringConvertible {
    /// The underlying untyped key.
    ///
    /// Use this when you need the ``Key`` directly, for example
    /// to pass to APIs that accept ``KeyProtocol`` constraints.
    public let key: Key

    /// The path components that make up this key.
    public var components: [KeyComponent] {
        key.components
    }

    /// Always `true` for a typed distinct key.
    public let isDistinct = true

    /// Creates a distinct key from any key-conforming value.
    public init(_ other: some DistinctKeyProtocol) {
        if let other = other as? TypedDistinctKey<Value> {
            self = other
        } else if let other = other as? any CanonicalKeyConvertible {
            self.init(uncheckedKey: other.canonicalKey)
        } else {
            self.init(other.components)
        }
    }

    /// Creates a typed distinct key from an array of components.
    ///
    /// - Parameter components: The components of the key. Must not contain wildcards.
    /// - Precondition: No component may be ``KeyComponent/wildcard``.
    public init(_ components: [KeyComponent]) {
        key = Key(components)
        precondition(key.isDistinct, "TypedDistinctKey requires a distinct key (no wildcards).")
    }

    /// Creates a typed distinct key from a pre-validated key. No validation is performed.
    @usableFromInline
    init(uncheckedKey key: Key) {
        self.key = key
    }

    /// A textual representation of the key, e.g. `TypedDistinctKey<User, "users/depotkit">`.
    public var description: String {
        "TypedDistinctKey<\(Value.self), \"\(keyPath)\">"
    }

    // MARK: - Hashable / Equatable (exclude constant isDistinct)

    public static func == (lhs: TypedDistinctKey, rhs: TypedDistinctKey) -> Bool {
        lhs.key == rhs.key
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }
}

// MARK: - Key Extensions

extension KeyProtocol {
    /// The key path as a slash-separated `String`, e.g. `"users/alice"`.
    ///
    /// Wildcard components are rendered as `*`. Special characters (`/`, `*`, `\`)
    /// in segment identifiers are backslash-escaped. Segment identifiers are rendered
    /// in Unicode Normalization Form C, the form the depot stores, also for custom
    /// key types whose components are not normalized.
    ///
    /// ```swift
    /// Key.from("users" / "alice").keyPath           // "users/alice"
    /// Key.from("users" / .wildcard).keyPath         // "users/*"
    /// ```
    public var keyPath: String {
        if let key = self as? any CanonicalKeyConvertible {
            return String(key: key.canonicalKey)
        }
        return String(key: Key(unchecked: components, isDistinct: isDistinct))
    }

    /// Returns `true` if the receiver (the **pattern**) matches the `other` key (the **candidate**).
    ///
    /// The receiver is the pattern side — its wildcards expand to cover candidates.
    /// Calling this on a distinct key is an exact-equality check (fast path).
    ///
    /// Key matching uses glob-like semantics:
    /// - `.wildcard` (`*`) matches exactly **one** component.
    /// - A trailing `.globstar` (`**`) matches **one or more** components:
    ///   `users/**` matches `users/alice` and `users/alice/settings`, but not `users`.
    /// - A leading or middle `.globstar` matches **zero or more** components:
    ///   `**/settings` matches `settings` and `users/alice/settings`;
    ///   `users/**/settings` matches `users/settings` and `users/alice/settings`.
    /// - A segment matches only the identical segment.
    ///
    /// This follows the `**` rules of `.gitignore` files: like `dir/**`, a trailing
    /// globstar matches everything *inside* the prefix but not the prefix itself.
    /// A value stored at `users` (for example a list) can therefore have a different
    /// type than the values registered for `users/**`.
    ///
    /// Matching is **directional**: `pattern.matches(candidate)` is not the same as
    /// `candidate.matches(pattern)`. A pattern can match a concrete key, but a
    /// concrete key cannot match a pattern.
    ///
    /// - Parameter other: The candidate key to test against the receiver's pattern.
    ///
    /// - Returns: `true` if the receiver's pattern covers `other`.
    ///
    /// ```swift
    /// // Pattern matches candidate:
    /// Key.from("users" / .wildcard).matches(Key.from("users" / "alice"))   // true
    /// Key.from("users" / .globstar).matches(Key.from("users" / "a" / "b")) // true
    /// Key.from("users" / .globstar).matches(Key.from("users"))             // false — trailing ** needs ≥ 1
    ///
    /// // Candidate does NOT match pattern (wrong direction):
    /// Key.from("users" / "alice").matches(Key.from("users" / .wildcard))   // false
    /// ```
    public func matches(_ other: some KeyProtocol) -> Bool {
        if isDistinct {
            return components == other.components
        }

        let pattern = components
        let target = other.components

        return Self.globMatch(pattern: pattern[...], target: target[...])
    }

    private static func globMatch(pattern: ArraySlice<KeyComponent>, target: ArraySlice<KeyComponent>) -> Bool {
        var pIdx = pattern.startIndex
        var tIdx = target.startIndex

        var lastGlobstarP = pattern.endIndex
        var lastGlobstarT = target.endIndex

        while tIdx < target.endIndex {
            if pIdx < pattern.endIndex {
                switch pattern[pIdx] {
                case .globstar:
                    if pattern.index(after: pIdx) == pattern.endIndex {
                        // A trailing globstar matches the one or more remaining components.
                        return true
                    }
                    lastGlobstarP = pIdx
                    lastGlobstarT = tIdx
                    pIdx = pattern.index(after: pIdx)
                    continue
                case .wildcard:
                    pIdx = pattern.index(after: pIdx)
                    tIdx = target.index(after: tIdx)
                    continue
                case .segment(let id):
                    if case .segment(let otherId) = target[tIdx], id == otherId {
                        pIdx = pattern.index(after: pIdx)
                        tIdx = target.index(after: tIdx)
                        continue
                    }
                }
            }

            if lastGlobstarP < pattern.endIndex {
                pIdx = pattern.index(after: lastGlobstarP)
                lastGlobstarT = target.index(after: lastGlobstarT)
                tIdx = lastGlobstarT
                continue
            }

            return false
        }

        // The pattern must be fully consumed: a trailing globstar needs at least one component.
        return pIdx == pattern.endIndex
    }
}

extension KeyProtocol {
    /// The components rewritten so that every globstar matches zero or more components.
    ///
    /// A trailing globstar matches one or more components, which is the same as a
    /// wildcard followed by a zero-or-more globstar (`users/**` → `users/*/**`). Matchers
    /// that treat every globstar as zero-or-more use this form to apply the
    /// semantics of ``matches(_:)``.
    var zeroOrMoreGlobstarComponents: [KeyComponent] {
        guard components.last == .globstar else {
            return components
        }
        return Array(components.dropLast()) + [.wildcard, .globstar]
    }
}

// MARK: - Key Operations

extension KeyProtocol {
    /// Converts this key to a ``TypedKey`` with the specified `Value` type.
    ///
    /// - Parameter type: The value type to associate with this key.
    /// - Returns: A ``TypedKey`` wrapping this key.
    @inlinable
    @inline(__always)
    public func typed<V>(as _: V.Type = V.self) -> TypedKey<V> where V: Sendable {
        TypedKey<V>(self)
    }

    /// Attempts to convert this key to a ``DistinctKey``.
    ///
    /// - Returns: A ``DistinctKey`` if this key contains no wildcards.
    /// - Throws: ``KeyError/nonDistinctKey`` if this key contains wildcards.
    @inlinable
    @inline(__always)
    public func distinct() throws(KeyError) -> DistinctKey {
        if let distinct = self as? DistinctKey {
            distinct
        } else if isDistinct {
            DistinctKey(components)
        } else {
            throw .nonDistinctKey
        }
    }

    /// Returns a new key by appending the given component.
    ///
    /// If `component` is ``KeyComponent/wildcard``, the resulting key will be a pattern.
    ///
    /// - Parameter component: The component to append.
    /// - Returns: A new ``Key`` with the component appended.
    @inlinable
    @inline(__always)
    public func appending(_ component: KeyComponent) -> Key {
        if case .wildcard = component {
            precondition(components.last != .wildcard, "A key must not contain consecutive wildcards.")
        } else if case .globstar = component {
            precondition(components.last != .globstar, "A key must not contain consecutive globstars.")
        } else if case let .segment(identifier) = component {
            precondition(!identifier.isEmpty, "A key component must not be empty.")
        }

        return Key(unchecked: components + [component], isDistinct: isDistinct && !component.isPattern)
    }

    /// Returns a new key by appending a segment with the given identifier.
    ///
    /// - Parameter identifier: The identifier to use as the segment.
    /// - Returns: A new ``Key`` with the segment appended.
    @inlinable
    @inline(__always)
    public func appending(_ identifier: String) -> Key {
        precondition(!identifier.isEmpty, "A key component must not be empty.")
        return Key(unchecked: components + [.segment(identifier: identifier)], isDistinct: isDistinct)
    }
}

extension DistinctKeyProtocol {
    /// Converts this distinct key to a ``TypedDistinctKey`` with the specified `Value` type.
    ///
    /// This is a zero-cost wrapper — no runtime validation is needed.
    ///
    /// - Parameter type: The value type to associate with this key.
    /// - Returns: A ``TypedDistinctKey`` wrapping this key.
    @inlinable
    @inline(__always)
    public func typed<V>(as _: V.Type = V.self) -> TypedDistinctKey<V> where V: Sendable {
        TypedDistinctKey<V>(self)
    }

    /// Returns a new distinct key by appending a segment with the given identifier.
    ///
    /// To append a ``KeyComponent/wildcard`` and receive a pattern ``Key``,
    /// use ``KeyProtocol/appending(_:)-(KeyComponent)`` instead.
    ///
    /// - Parameter identifier: The identifier to use as the segment.
    /// - Returns: A new ``DistinctKey`` with the segment appended.
    @inlinable
    @inline(__always)
    public func appending(_ identifier: String) -> DistinctKey {
        precondition(!identifier.isEmpty, "A key component must not be empty.")
        let newKey = Key(unchecked: components + [.segment(identifier: identifier)], isDistinct: true)
        return DistinctKey(uncheckedKey: newKey)
    }
}

extension TypedKeyProtocol {
    /// Attempts to convert this key to a ``TypedDistinctKey``.
    ///
    /// - Returns: A ``TypedDistinctKey`` if this key contains no wildcards.
    /// - Throws: ``KeyError/nonDistinctKey`` if this key contains wildcards.
    @inlinable
    @inline(__always)
    public func distinct() throws(KeyError) -> TypedDistinctKey<Value> {
        if let distinct = self as? TypedDistinctKey<Value> {
            distinct
        } else if isDistinct {
            TypedDistinctKey(components)
        } else {
            throw .nonDistinctKey
        }
    }

    /// Returns a new typed key by appending the given component.
    ///
    /// If `component` is ``KeyComponent/wildcard`` or ``KeyComponent/globstar``,
    /// the resulting key will be a pattern.
    ///
    /// - Parameter component: The component to append.
    /// - Returns: A new ``TypedKey`` with the component appended.
    @inlinable
    @inline(__always)
    public func appending(_ component: KeyComponent) -> TypedKey<Value> {
        if case .wildcard = component {
            precondition(components.last != .wildcard, "A key must not contain consecutive wildcards.")
        } else if case .globstar = component {
            precondition(components.last != .globstar, "A key must not contain consecutive globstars.")
        } else if case let .segment(identifier) = component {
            precondition(!identifier.isEmpty, "A key component must not be empty.")
        }

        return TypedKey<Value>(
            uncheckedKey: Key(unchecked: components + [component], isDistinct: isDistinct && !component.isPattern),
        )
    }

    /// Returns a new typed key by appending a segment with the given identifier.
    ///
    /// - Parameter identifier: The identifier to use as the segment.
    /// - Returns: A new ``TypedKey`` with the segment appended.
    @inlinable
    @inline(__always)
    public func appending(_ identifier: String) -> TypedKey<Value> {
        precondition(!identifier.isEmpty, "A key component must not be empty.")
        return TypedKey<Value>(
            uncheckedKey: Key(unchecked: components + [.segment(identifier: identifier)], isDistinct: isDistinct),
        )
    }
}

extension TypedDistinctKeyProtocol {
    /// Returns a new typed distinct key by appending a segment with the given identifier.
    ///
    /// To append a ``KeyComponent/wildcard`` and receive a pattern ``TypedKey``,
    /// use ``TypedKeyProtocol/appending(_:)-(KeyComponent)`` instead.
    ///
    /// - Parameter identifier: The identifier to use as the segment.
    /// - Returns: A new ``TypedDistinctKey`` with the segment appended.
    @inlinable
    @inline(__always)
    public func appending(_ identifier: String) -> TypedDistinctKey<Value> {
        precondition(!identifier.isEmpty, "A key component must not be empty.")
        let newKey = Key(unchecked: components + [.segment(identifier: identifier)], isDistinct: true)
        return TypedDistinctKey<Value>(uncheckedKey: newKey)
    }
}

// MARK: - Key Mutation

extension Key {
    /// Appends the given component to this key in place.
    ///
    /// - Parameter component: The component to append.
    @inlinable
    @inline(__always)
    public mutating func append(_ component: KeyComponent) {
        self = appending(component)
    }

    /// Appends a segment with the given identifier to this key in place.
    ///
    /// - Parameter identifier: The identifier to use as the segment.
    @inlinable
    @inline(__always)
    public mutating func append(_ identifier: String) {
        self = appending(identifier)
    }
}

extension DistinctKey {
    /// Appends a segment with the given identifier to this key in place.
    ///
    /// - Parameter identifier: The identifier to use as the segment.
    @inlinable
    @inline(__always)
    public mutating func append(_ identifier: String) {
        self = appending(identifier)
    }
}

extension TypedKey {
    /// Appends the given component to this key in place.
    ///
    /// - Parameter component: The component to append.
    @inlinable
    @inline(__always)
    public mutating func append(_ component: KeyComponent) {
        self = appending(component)
    }

    /// Appends a segment with the given identifier to this key in place.
    ///
    /// - Parameter identifier: The identifier to use as the segment.
    @inlinable
    @inline(__always)
    public mutating func append(_ identifier: String) {
        self = appending(identifier)
    }
}

extension TypedDistinctKey {
    /// Appends a segment with the given identifier to this key in place.
    ///
    /// - Parameter identifier: The identifier to use as the segment.
    @inlinable
    @inline(__always)
    public mutating func append(_ identifier: String) {
        self = appending(identifier)
    }
}

// MARK: - Factory Methods

extension Key {
    /// A key that matches all keys/values at any depth.
    /// This is equivalent to a single-component globstar key (`"**"`).
    /// Calling ``matches(_:)`` on this key will always return `true`.
    ///
    /// Use this to enumerate or remove every value in a depot:
    ///
    /// ```swift
    /// try depot.remove(valuesFor: Key.all)
    /// ```
    ///
    /// - Returns: A key that matches all keys/values.
    public static let all = Key([.globstar])

    /// Construct a distinct key from a distinct key path expression.
    ///
    /// The return type is ``DistinctKey`` — no type annotation or cast is needed:
    ///
    /// ```swift
    /// let key = Key.from("users" / "alice" / "settings")
    /// let dynamic = Key.from(KeyPathExpression(userId) / "settings")
    /// ```
    ///
    /// This method does not throw. Invalid states (wildcards in distinct
    /// expressions) are prevented at the type level by
    /// ``KeyPathExpression``.
    ///
    /// - Parameter expression: A distinct key path expression (no wildcards).
    /// - Returns: A ``DistinctKey``.
    public static func from(_ expression: KeyPathExpression) -> DistinctKey {
        expression.components.assertValidIdentifiers()
        return DistinctKey(uncheckedKey: Key(unchecked: expression.components, isDistinct: true))
    }

    /// Construct a typed distinct key from a distinct key path expression.
    ///
    /// Pass the value type via the `as:` parameter:
    ///
    /// ```swift
    /// let key = Key.from("users" / "alice" / "name", as: String.self)
    /// ```
    ///
    /// This method does not throw.
    ///
    /// - Parameters:
    ///   - expression: A distinct key path expression (no wildcards).
    ///   - type: The type of the value associated with this key.
    /// - Returns: A ``TypedDistinctKey``.
    public static func from<V>(_ expression: KeyPathExpression, as _: V.Type = V.self) -> TypedDistinctKey<V>
    where V: Sendable {
        expression.components.assertValidIdentifiers()
        return TypedDistinctKey(uncheckedKey: Key(unchecked: expression.components, isDistinct: true))
    }

    /// Construct a pattern key from a pattern key path expression.
    ///
    /// Pattern expressions are created by including `.wildcard`
    /// in a `/` expression:
    ///
    /// ```swift
    /// let key = Key.from("users" / .wildcard / "settings")
    /// ```
    ///
    /// - Parameter expression: A pattern key path expression (may contain wildcards).
    /// - Returns: A ``Key`` whose ``isDistinct`` reflects whether wildcards are present.
    public static func from(_ expression: PatternKeyPathExpression) -> Key {
        expression.components.assertValidKeyComponents()
        return Key(unchecked: expression.components, isDistinct: !expression.components.containsPattern())
    }

    /// Construct a typed pattern key from a pattern key path expression.
    ///
    /// Pass the value type via the `as:` parameter:
    ///
    /// ```swift
    /// let key = Key.from("users" / .wildcard / "name", as: String.self)
    /// // TypedKey<String> — useful for observing multiple values
    /// ```
    ///
    /// - Parameters:
    ///   - expression: A pattern key path expression (may contain wildcards).
    ///   - type: The type of the value associated with this key.
    /// - Returns: A ``TypedKey`` whose ``Key/isDistinct`` reflects whether wildcards are present.
    public static func from<V>(_ expression: PatternKeyPathExpression, as _: V.Type = V.self) -> TypedKey<V>
    where V: Sendable {
        expression.components.assertValidKeyComponents()
        return TypedKey(
            uncheckedKey: Key(unchecked: expression.components, isDistinct: !expression.components.containsPattern())
        )
    }
}

// MARK: - Private

extension KeyComponent {
    @inlinable
    @inline(__always)
    func matches(_ other: KeyComponent) -> Bool {
        switch (self, other) {
        case (.wildcard, _), (.globstar, _):
            true
        case let (.segment(left), .segment(right)):
            left == right
        default:
            false
        }
    }
}
