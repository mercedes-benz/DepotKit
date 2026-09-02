// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

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

    static func buildPathExpression(from segments: [ParsedPath.Segment]) -> ExprSyntax {
        precondition(!segments.isEmpty)

        var result: ExprSyntax

        switch segments[0] {
        case .literal(let value):
            result = ExprSyntax(StringLiteralExprSyntax(content: value))
        case .wildcard:
            result = ExprSyntax(MemberAccessExprSyntax(name: "wildcard"))
        case .globstar:
            result = ExprSyntax(MemberAccessExprSyntax(name: "globstar"))
        }

        for segment in segments.dropFirst() {
            let rhs: ExprSyntax
            switch segment {
            case .literal(let value):
                rhs = ExprSyntax(StringLiteralExprSyntax(content: value))
            case .wildcard:
                rhs = ExprSyntax(MemberAccessExprSyntax(name: "wildcard"))
            case .globstar:
                rhs = ExprSyntax(MemberAccessExprSyntax(name: "globstar"))
            }
            result = ExprSyntax(
                InfixOperatorExprSyntax(
                    leftOperand: result,
                    operator: BinaryOperatorExprSyntax(
                        leadingTrivia: .space,
                        operator: .binaryOperator("/"),
                        trailingTrivia: .space
                    ),
                    rightOperand: rhs
                )
            )
        }

        return result
    }

}
