// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import SwiftParser
import SwiftSyntax

/// Resolves the path argument of `#key` / `#pattern` to the string value it represents in Swift.
///
/// This is the first of two explicit stages: Swift's own literal escaping (`\\`, `\u{61}`,
/// raw-string delimiters, multi-line literals, …) is resolved here, exactly as the compiler
/// would. Only the resulting value is passed to ``PathParser``, which applies DepotKit's
/// path escapes (`\/`, `\*`, `\\`) as the second stage.
enum PathLiteral {

    static func value(of expression: ExprSyntax) -> Result<String, MacroDiagnostics.KeyExpression> {
        guard let literal = expression.as(StringLiteralExprSyntax.self) else {
            return .failure(.pathMustBeStringLiteral)
        }

        if literal.segments.contains(where: { $0.is(ExpressionSegmentSyntax.self) }) {
            return .failure(.pathMustNotContainInterpolation)
        }

        guard let value = literal.representedLiteralValue else {
            return .failure(.invalidStringLiteral)
        }

        return .success(value)
    }
}
