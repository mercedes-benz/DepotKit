// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Expands `#pattern("path", coder: ...)` into a `PatternKeyDefinition(path:coder:)` expression.
public struct PatternKeyExpressionMacro: ExpressionMacro {

    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) -> ExprSyntax {
        let arguments = Array(node.arguments)

        guard arguments.count >= 2 else {
            return ExprSyntax(StringLiteralExprSyntax(content: ""))
        }

        guard let pathLiteral = arguments[0].expression.as(StringLiteralExprSyntax.self),
            pathLiteral.segments.count == 1,
            let segment = pathLiteral.segments.first?.as(StringSegmentSyntax.self)
        else {
            context.diagnose(
                Diagnostic(
                    node: arguments[0].expression,
                    message: MacroDiagnostics.KeyExpression.pathMustBeStringLiteral
                )
            )
            return ExprSyntax(StringLiteralExprSyntax(content: ""))
        }

        let pathString = segment.content.text

        switch PathParser.parse(pathString) {
        case .failure(let diagnostic):
            context.diagnose(
                Diagnostic(
                    node: arguments[0].expression,
                    message: diagnostic
                )
            )
            return ExprSyntax(StringLiteralExprSyntax(content: ""))

        case .success(let parsed):
            if !parsed.hasWildcard {
                context.diagnose(
                    Diagnostic(
                        node: arguments[0].expression,
                        message: MacroDiagnostics.KeyExpression.noWildcardInPatternKey
                    )
                )
                return ExprSyntax(StringLiteralExprSyntax(content: ""))
            }

            let pathExpr = PathParser.buildPathExpression(from: parsed.segments)
            let coderExpr = arguments[1].expression

            return "PatternKeyDefinition(path: \(pathExpr), coder: \(coderExpr))"
        }
    }
}
