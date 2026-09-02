// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import SwiftDiagnostics

/// Compile-time diagnostics emitted by DepotKit's expression macros.
enum MacroDiagnostics {

    // MARK: - #key / #pattern

    enum KeyExpression: String, DiagnosticMessage, Error {
        case pathMustBeStringLiteral
        case emptyPath
        case emptySegment
        case consecutiveWildcards
        case wildcardInDistinctKey
        case noWildcardInPatternKey
        case invalidEscapeSequence

        var severity: DiagnosticSeverity { .error }

        var message: String {
            switch self {
            case .pathMustBeStringLiteral:
                "Path argument must be a string literal."
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
    }

}
