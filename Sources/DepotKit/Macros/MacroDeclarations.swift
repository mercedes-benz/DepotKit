// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if DEPOTKIT_MACROS

// MARK: - Expression Macros

/// Creates a ``KeyDefinition`` for a concrete (distinct) key path.
///
/// The path string is split by `/` at compile time. Each segment becomes a
/// ``KeyComponent/segment(identifier:)``. Wildcards (`*`) and globstars (`**`) are
/// **not allowed** — use ``pattern(_:coder:)`` instead.
///
/// The coder argument is passed through unchanged; any ``AnyCoder`` expression works,
/// for example `.json(String.self)`, `.plist(Int.self)`, or `.data(Data.self)`.
///
/// ```swift
/// let username = #key("user/username", coder: .json(String.self))
/// ```
///
/// ## Escaping
///
/// The path argument must be a single string literal without interpolation
/// (`"\(id)/name"` is rejected at compile time). It is interpreted in two stages:
///
/// 1. **Swift string literal.** The literal is first resolved exactly as the compiler
///    would resolve it, including escapes such as `\\` or `\u{E9}`, raw strings
///    (`#"..."#`), and multi-line literals.
/// 2. **Key path escapes.** The resulting value is split at `/`. Within it, `\/` stands for
///    a literal `/`, `\*` for a literal `*`, and `\\` for a literal backslash. Any other
///    backslash sequence is a compile-time error.
///
/// A key path escape therefore needs a doubled backslash in an ordinary string literal,
/// but only a single one in a raw string literal:
///
/// ```swift
/// // Two components: "files" and "a/b"
/// let escapedSlash = #key("files/a\\/b", coder: .data(Data.self))
/// let sameKey = #key(#"files/a\/b"#, coder: .data(Data.self))
///
/// // Two components: "files" and a component consisting of "a", one backslash, and "b"
/// let backslash = #key("files/a\\\\b", coder: .data(Data.self))
/// let sameBackslash = #key(#"files/a\\b"#, coder: .data(Data.self))
/// ```
///
/// - Parameters:
///   - path: A `/`-separated key path string literal. Must not contain `*` or `**` segments.
///   - coder: A coder expression (e.g. `.json(String.self)`).
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
/// `**` become `.globstar` components (one or more levels at the end of the path,
/// zero or more elsewhere — see ``KeyProtocol/matches(_:)``). At least one
/// `*` or `**` is **required** — use ``key(_:coder:)`` for distinct paths.
///
/// Only a whole, unescaped segment is a wildcard: `a*b` and an escaped `\*` are literal
/// components. The path argument follows the same two-stage escaping rules as
/// ``key(_:coder:)``: Swift string-literal escapes are resolved first, then the key path
/// escapes `\/`, `\*`, and `\\`. Interpolation is not allowed.
///
/// ```swift
/// let allSettings = #pattern("users/*/settings", coder: .json(Settings.self))
/// // Matches users/alice and users/alice/name, but not users
/// let allDeep = #pattern("users/**", coder: .json(String.self))
/// // Components: "ratings", a literal "*", and a wildcard
/// let literalStar = #pattern(#"ratings/\*/*"#, coder: .json(Int.self))
/// ```
///
/// - Parameters:
///   - path: A `/`-separated key path string literal. Must contain at least one `*` or `**`.
///   - coder: A coder expression (e.g. `.json(Settings.self)`).
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

#endif
