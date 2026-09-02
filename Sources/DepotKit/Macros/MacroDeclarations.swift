// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

// MARK: - Expression Macros

/// Creates a ``KeyDefinition`` for a concrete (distinct) key path.
///
/// The path string is split by `/` at compile time. Each segment becomes a
/// ``KeyPathExpression`` component. Wildcards (`*`) and globstars (`**`) are
/// **not allowed** — use ``pattern(_:_:)`` instead.
///
/// The coder argument uses a shorthand syntax:
/// - `.json(String.self)` → `JSONCoder<String>.json()`
/// - `.plist(Int.self)` → `PLISTCoder<Int>.plist()`
/// - `.data(Data.self)` → `DataCoder<Data>.data()`
///
/// ```swift
/// let username = #key("user/username", coder: .json(String.self))
/// ```
///
/// - Parameters:
///   - path: A `/`-separated key path string. Must not contain `*` or `**` segments.
///   - coder: A coder shorthand expression (e.g. `.json(String.self)`).
/// - Returns: A ``KeyDefinition`` for the specified path and coder.
@freestanding(expression)
public macro key<V: Sendable>(
    _ path: String,
    coder: AnyCoder<V>
) -> KeyDefinition<V> =
    #externalMacro(
        module: "DepotKitMacros",
        type: "KeyExpressionMacro"
    )

/// Creates a ``PatternKeyDefinition`` for a wildcard key path.
///
/// The path string is split by `/` at compile time. Segments equal to `*`
/// become `.wildcard` components (single-level match), and segments equal to
/// `**` become `.globstar` components (zero-or-more levels). At least one
/// `*` or `**` is **required** — use ``key(_:_:)`` for distinct paths.
///
/// ```swift
/// let allSettings = #pattern("users/*/settings", coder: .json(Settings.self))
/// let allDeep = #pattern("users/**", coder: .json(String.self))
/// ```
///
/// - Parameters:
///   - path: A `/`-separated key path string. Must contain at least one `*` or `**`.
///   - coder: A coder shorthand expression (e.g. `.json(Settings.self)`).
/// - Returns: A ``PatternKeyDefinition`` for the specified path and coder.
@freestanding(expression)
public macro pattern<V: Sendable>(
    _ path: String,
    coder: AnyCoder<V>
) -> PatternKeyDefinition<V> =
    #externalMacro(
        module: "DepotKitMacros",
        type: "PatternKeyExpressionMacro"
    )
