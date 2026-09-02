// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

/// A key-path expression composed entirely of segment (non-wildcard) components.
///
/// `KeyPathExpression` is the building block for creating ``DistinctKey``
/// and ``TypedDistinctKey`` values through the ``Key/from(_:)-4n7iq`` and
/// ``Key/from(_:as:)-4wgoc`` factory methods.
///
/// ## Usage
///
/// Create a single-component expression from a string literal, then chain
/// additional components with `/`:
///
/// ```swift
/// let key = Key.from("users" / "alice" / "settings")        // DistinctKey
/// let typed = Key.from("users" / "alice" / "name", as: String.self) // TypedDistinctKey<String>
/// ```
///
/// ## Converting to Patterns
///
/// To introduce a wildcard and obtain a ``PatternKeyPathExpression``,
/// append `.wildcard` with `/`:
///
/// ```swift
/// let key = Key.from("users" / .wildcard / "settings")      // Key (pattern)
/// ```
///
/// ## Dynamic Components
///
/// For a dynamic first component, use ``component(_:)``:
///
/// ```swift
/// let key = Key.from(.component(userId) / "settings")
/// ```
///
/// Subsequent components can use any `CustomStringConvertible` directly,
/// because the `/` operator accepts `some CustomStringConvertible` on the
/// right-hand side:
///
/// ```swift
/// let key = Key.from("users" / userId / "settings")
/// ```
///
/// > Important: The string `"*"` in a `/` expression creates a concrete
/// > component with the literal text `*`, not a wildcard. Always use
/// > `.wildcard` for wildcard components.
public struct KeyPathExpression: ExpressibleByStringLiteral {
    @usableFromInline
    let components: [KeyComponent]

    /// Creates a single-component expression from a string literal.
    ///
    /// Each string literal represents exactly one path component.
    /// Use `/` to compose multiple components: `"users" / "alice" / "settings"`.
    ///
    /// For dynamic values, use ``init(_:)`` or the `/` operator with any `CustomStringConvertible`.
    ///
    /// - Precondition: `value` must not be empty.
    public init(stringLiteral value: String) {
        precondition(!value.isEmpty, "A key component must not be empty.")
        components = [.segment(identifier: value)]
    }

    /// Creates a single-component expression from any `CustomStringConvertible` value.
    ///
    /// Use this when the first path component is a dynamic value rather than
    /// a string literal:
    ///
    /// ```swift
    /// let key = Key.from(KeyPathExpression(userID) / "settings")
    /// ```
    ///
    /// - Parameter value: A value whose `description` becomes the component identifier.
    /// - Precondition: `value.description` must not be empty.
    public init(_ value: some CustomStringConvertible) {
        let identifier = value.description
        precondition(!identifier.isEmpty, "A key component must not be empty.")
        components = [.segment(identifier: identifier)]
    }

    /// Creates a single-component expression from a dynamic value.
    ///
    /// Use this as a shorter alternative to ``init(_:)`` when the first path
    /// component is a runtime value. The dot-syntax resolves naturally inside
    /// ``Key/from(_:)-4n7iq``:
    ///
    /// ```swift
    /// let key = Key.from(.component(userId) / "settings")
    /// ```
    ///
    /// - Parameter value: A value whose `description` becomes the component identifier.
    /// - Precondition: `value.description` must not be empty.
    /// - Returns: A ``KeyPathExpression`` with a single segment component.
    public static func component(_ value: some CustomStringConvertible) -> KeyPathExpression {
        KeyPathExpression(value)
    }

    @usableFromInline
    init(components: [KeyComponent]) {
        self.components = components
    }
}

// MARK: - KeyPathExpression + ExpressibleByStringInterpolation

extension KeyPathExpression: ExpressibleByStringInterpolation {
    public struct StringInterpolation: StringInterpolationProtocol {
        @usableFromInline
        var result: String = ""

        @inlinable
        @inline(__always)
        public init(literalCapacity: Int, interpolationCount _: Int) {
            result.reserveCapacity(literalCapacity)
        }

        @inlinable
        @inline(__always)
        public mutating func appendLiteral(_ literal: String) {
            result.append(literal)
        }

        @inlinable
        @inline(__always)
        public mutating func appendInterpolation(_ value: some CustomStringConvertible) {
            result.append(value.description)
        }
    }

    public init(stringInterpolation: StringInterpolation) {
        precondition(!stringInterpolation.result.isEmpty, "A key component must not be empty.")
        components = [.segment(identifier: stringInterpolation.result)]
    }
}

// MARK: - PatternKeyPathExpression

/// A key-path expression that contains at least one wildcard component.
///
/// You cannot create a `PatternKeyPathExpression` from a string literal
/// directly. Instead, include `.wildcard` in a `/` expression:
///
/// ```swift
/// let key = Key.from("users" / .wildcard / "settings")
/// let typed = Key.from("entities" / .wildcard / "status", as: String.self)
/// ```
///
/// The `/` operator returns a `PatternKeyPathExpression` whenever
/// `.wildcard` (of type ``PatternKeyComponent``) or a ``KeyComponent``
/// appears as an operand in a combination that includes at least one wildcard.
///
/// ## How Wildcard Expressions Are Formed
///
/// The type system enforces the distinction at compile time:
///
/// | Left | `/` | Right | Result |
/// |---|---|---|---|
/// | `KeyPathExpression` | / | `String` / `CustomStringConvertible` | ``KeyPathExpression`` |
/// | `KeyPathExpression` | / | `.wildcard` (`KeyComponent`) | **`PatternKeyPathExpression`** |
/// | `PatternKeyPathExpression` | / | any | **`PatternKeyPathExpression`** |
/// | `.wildcard` (`PatternKeyComponent`) | / | any | **`PatternKeyPathExpression`** |
///
/// This means once a wildcard is introduced, the expression stays a pattern.
public struct PatternKeyPathExpression {
    @usableFromInline
    let components: [KeyComponent]

    @usableFromInline
    init(components: [KeyComponent]) {
        self.components = components
    }
}

// MARK: - KeyPathExpression Operators

// The `/` operator overloads form a type-safe DSL for building key path
// expressions. The compiler picks the correct overload based on the operand
// types, which determines at compile time whether the resulting expression
// is distinct or a pattern.
//
// Summary of overloads:
//
//   PatternKeyComponent / KeyComponent           → PatternKeyPathExpression
//   PatternKeyComponent / CustomStringConvertible → PatternKeyPathExpression
//   KeyPathExpression / KeyComponent          → PatternKeyPathExpression
//   KeyPathExpression / CustomStringConvertible → KeyPathExpression
//   PatternKeyPathExpression / KeyComponent       → PatternKeyPathExpression
//   PatternKeyPathExpression / CustomStringConvertible → PatternKeyPathExpression

/// Combines a pattern component with any key component, producing a pattern expression.
///
/// This overload handles expressions that start with `.wildcard` or `.globstar`:
///
/// ```swift
/// let expr = .wildcard / .segment(identifier: "settings")
/// let deep = .globstar / .segment(identifier: "name")
/// ```
///
/// - Parameters:
///   - lhs: A ``PatternKeyComponent/wildcard`` or ``PatternKeyComponent/globstar``.
///   - rhs: The key component to append.
/// - Returns: A ``PatternKeyPathExpression`` with the pattern component followed by `rhs`.
@inlinable
@inline(__always)
public func / (lhs: PatternKeyComponent, rhs: KeyComponent) -> PatternKeyPathExpression {
    PatternKeyPathExpression(components: [lhs.keyComponent, rhs])
}

/// Combines a pattern component with a string-convertible value, producing a pattern expression.
///
/// ```swift
/// let expr = .wildcard / "settings"
/// let deep = .globstar / "settings"
/// ```
///
/// - Parameters:
///   - lhs: A ``PatternKeyComponent/wildcard`` or ``PatternKeyComponent/globstar``.
///   - rhs: A value whose `description` becomes a ``KeyComponent/segment(identifier:)``.
/// - Returns: A ``PatternKeyPathExpression`` with the pattern component followed by a segment.
@inlinable
@inline(__always)
public func / (lhs: PatternKeyComponent, rhs: some CustomStringConvertible) -> PatternKeyPathExpression {
    PatternKeyPathExpression(components: [lhs.keyComponent, .segment(identifier: rhs.description)])
}

/// Appends any key component to a distinct expression.
///
/// Because ``KeyComponent`` can be a ``KeyComponent/wildcard``, this overload
/// produces a ``PatternKeyPathExpression``:
///
/// ```swift
/// let expr: PatternKeyPathExpression = "users" / .wildcard
/// ```
///
/// - Parameters:
///   - lhs: A distinct key path expression.
///   - rhs: The key component to append (often `.wildcard`).
/// - Returns: A ``PatternKeyPathExpression``.
@inlinable
@inline(__always)
public func / (lhs: KeyPathExpression, rhs: KeyComponent) -> PatternKeyPathExpression {
    PatternKeyPathExpression(components: lhs.components + [rhs])
}

/// Appends a string-convertible value to a distinct expression, preserving distinctness.
///
/// This is the primary operator for chaining string components:
///
/// ```swift
/// let expr: KeyPathExpression = "users" / "alice" / "settings"
/// ```
///
/// - Parameters:
///   - lhs: A distinct key path expression.
///   - rhs: A value whose `description` becomes a ``KeyComponent/segment(identifier:)``.
/// - Returns: A ``KeyPathExpression`` with the segment appended.
@inlinable
@inline(__always)
public func / (lhs: KeyPathExpression, rhs: some CustomStringConvertible) -> KeyPathExpression {
    KeyPathExpression(components: lhs.components + [.segment(identifier: rhs.description)])
}

/// Appends any key component to a pattern expression.
///
/// The result remains a pattern regardless of what is appended.
///
/// ```swift
/// let expr = ("users" / .wildcard) / .segment(identifier: "name")
/// ```
///
/// - Parameters:
///   - lhs: A pattern key path expression.
///   - rhs: The key component to append.
/// - Returns: A ``PatternKeyPathExpression`` with `rhs` appended.
@inlinable
@inline(__always)
public func / (lhs: PatternKeyPathExpression, rhs: KeyComponent) -> PatternKeyPathExpression {
    PatternKeyPathExpression(components: lhs.components + [rhs])
}

/// Appends a string-convertible value to a pattern expression.
///
/// The result remains a pattern:
///
/// ```swift
/// let expr = ("users" / .wildcard) / "settings"
/// // equivalent to: "users" / .wildcard / "settings"
/// ```
///
/// - Parameters:
///   - lhs: A pattern key path expression.
///   - rhs: A value whose `description` becomes a ``KeyComponent/segment(identifier:)``.
/// - Returns: A ``PatternKeyPathExpression`` with the segment appended.
@inlinable
@inline(__always)
public func / (lhs: PatternKeyPathExpression, rhs: some CustomStringConvertible) -> PatternKeyPathExpression {
    PatternKeyPathExpression(components: lhs.components + [.segment(identifier: rhs.description)])
}
