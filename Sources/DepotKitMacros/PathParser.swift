// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import SwiftDiagnostics
import SwiftSyntax

/// Parses a `/`-separated key path string into validated segments at compile time.
enum PathParser {

    /// The result of parsing a key path string: an array of literal, wildcard, or globstar segments.
    struct ParsedPath {
        let segments: [Segment]

        var hasWildcard: Bool {
            segments.contains { $0.isWildcard || $0.isGlobstar }
        }

        enum Segment {
            case literal(String)
            case wildcard
            case globstar

            var isWildcard: Bool {
                if case .wildcard = self {
                    return true
                }
                return false
            }

            var isGlobstar: Bool {
                if case .globstar = self {
                    return true
                }
                return false
            }
        }
    }

    private struct RawComponent {
        let resolved: String
        let hadEscape: Bool
    }

    static func parse(_ path: String) -> Result<ParsedPath, MacroDiagnostics.KeyExpression> {
        guard !path.isEmpty else {
            return .failure(.emptyPath)
        }

        switch splitComponents(path) {
        case .failure(let error):
            return .failure(error)
        case .success(let components):
            return resolveSegments(components)
        }
    }

    private static func splitComponents(_ path: String) -> Result<[RawComponent], MacroDiagnostics.KeyExpression> {
        var components: [RawComponent] = []
        var current = ""
        var escaped = false
        var currentHadEscape = false

        for char in path {
            if escaped {
                switch char {
                case "/", "*", "\\":
                    current.append(char)
                default:
                    return .failure(.invalidEscapeSequence)
                }
                escaped = false
                currentHadEscape = true
            } else if char == "\\" {
                escaped = true
            } else if char == "/" {
                components.append(RawComponent(resolved: current, hadEscape: currentHadEscape))
                current = ""
                currentHadEscape = false
            } else {
                current.append(char)
            }
        }

        if escaped {
            return .failure(.invalidEscapeSequence)
        }

        components.append(RawComponent(resolved: current, hadEscape: currentHadEscape))
        return .success(components)
    }

    private static func resolveSegments(
        _ components: [RawComponent]
    ) -> Result<ParsedPath, MacroDiagnostics.KeyExpression> {
        var segments: [ParsedPath.Segment] = []
        var previousSegment: ParsedPath.Segment?

        for component in components {
            if component.resolved.isEmpty {
                return .failure(.emptySegment)
            }

            let segment: ParsedPath.Segment
            if !component.hadEscape, component.resolved == "**" {
                if case .globstar = previousSegment {
                    return .failure(.consecutiveWildcards)
                }
                segment = .globstar
            } else if !component.hadEscape, component.resolved == "*" {
                if case .wildcard = previousSegment {
                    return .failure(.consecutiveWildcards)
                }
                segment = .wildcard
            } else {
                segment = .literal(component.resolved)
            }

            segments.append(segment)
            previousSegment = segment
        }

        return .success(ParsedPath(segments: segments))
    }

    /// Resolves and parses the path argument of `#key` / `#pattern`.
    ///
    /// - Throws: A `DiagnosticsError` anchored at `expression` when the argument is not a
    ///   plain string literal or the path is invalid.
    static func parse(argument expression: ExprSyntax) throws -> ParsedPath {
        switch PathLiteral.value(of: expression).flatMap(parse) {
        case .success(let parsed):
            return parsed
        case .failure(let diagnostic):
            throw diagnostic.error(at: expression)
        }
    }

    /// Builds a `[KeyComponent]` array literal for the parsed segments.
    ///
    /// The generated code deliberately avoids DepotKit's `/` operator: operators cannot be
    /// module-qualified, so a consumer's own `/` overloads could otherwise take part in
    /// overload resolution. The elements use implicit member syntax, which always resolves
    /// against the contextual `DepotKit.KeyComponent` type.
    static func buildComponentsExpression(from segments: [ParsedPath.Segment]) -> ExprSyntax {
        precondition(!segments.isEmpty)

        let elements = segments.enumerated().map { index, segment in
            ArrayElementSyntax(
                expression: componentExpression(for: segment),
                trailingComma: index < segments.count - 1 ? .commaToken(trailingTrivia: .space) : nil
            )
        }
        return ExprSyntax(ArrayExprSyntax(elements: ArrayElementListSyntax(elements)))
    }

    private static func componentExpression(for segment: ParsedPath.Segment) -> ExprSyntax {
        switch segment {
        case .literal(let value):
            ".segment(identifier: \(StringLiteralExprSyntax(content: value)))"
        case .wildcard:
            ".wildcard"
        case .globstar:
            ".globstar"
        }
    }

}
