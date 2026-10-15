// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import SwiftSyntax
import SwiftSyntaxMacros

/// Expands `#pattern("path", coder: ...)` into a `DepotKit.PatternKeyDefinition(key:coder:)` expression.
public struct PatternKeyExpressionMacro: ExpressionMacro {

    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        let arguments = Array(node.arguments)

        guard arguments.count >= 2 else {
            throw MacroDiagnostics.KeyExpression.missingArguments.error(at: node)
        }

        let pathArgument = arguments[0].expression
        let parsed = try PathParser.parse(argument: pathArgument)

        if !parsed.hasWildcard {
            throw MacroDiagnostics.KeyExpression.noWildcardInPatternKey.error(at: pathArgument)
        }

        let components = PathParser.buildComponentsExpression(from: parsed.segments)
        let coderExpr = arguments[1].expression

        return "DepotKit.PatternKeyDefinition(key: DepotKit.Key(\(components)), coder: \(coderExpr))"
    }
}
