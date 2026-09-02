// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct DepotKitMacroPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        KeyExpressionMacro.self,
        PatternKeyExpressionMacro.self,
    ]
}
