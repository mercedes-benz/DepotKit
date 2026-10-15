// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import SwiftDiagnostics
import SwiftSyntax

/// Compile-time diagnostics emitted by DepotKit's expression macros.
enum MacroDiagnostics {

    // MARK: - #key / #pattern

    enum KeyExpression: String, DiagnosticMessage, Error {
        case missingArguments
        case pathMustBeStringLiteral
        case pathMustNotContainInterpolation
        case invalidStringLiteral
        case emptyPath
        case emptySegment
        case consecutiveWildcards
        case wildcardInDistinctKey
        case noWildcardInPatternKey
        case invalidEscapeSequence

        var severity: DiagnosticSeverity { .error }

        var message: String {
            switch self {
            case .missingArguments:
                "Expected a path string literal and a coder argument."
            case .pathMustBeStringLiteral:
                "Path argument must be a string literal."
            case .pathMustNotContainInterpolation:
                "Path string literal must not contain interpolation."
            case .invalidStringLiteral:
                "Path argument is not a valid string literal."
            case .emptyPath:
                "Key path must not be empty."
            case .emptySegment:
                "Key path must not contain empty segments (e.g. '//')."
            case .consecutiveWildcards:
                "Key path must not contain consecutive wildcards ('*/*' or '**/**')."
            case .wildcardInDistinctKey:
                "#key does not allow wildcards ('*' or '**'). Use #pattern for wildcard paths."
            case .noWildcardInPatternKey:
                "#pattern requires at least one wildcard ('*' or '**') segment."
            case .invalidEscapeSequence:
                "Invalid escape sequence. Use '\\/' for literal '/', '\\*' for literal '*', or '\\\\' for literal '\\'."
            }
        }

        var diagnosticID: MessageID {
            MessageID(domain: "DepotKitMacros", id: rawValue)
        }

        /// Wraps this message in an error anchored at `node`, so a throwing expansion
        /// reports it at the offending argument instead of the whole macro expression.
        func error(at node: some SyntaxProtocol) -> DiagnosticsError {
            DiagnosticsError(diagnostics: [Diagnostic(node: node, message: self)])
        }
    }

}
