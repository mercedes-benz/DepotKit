// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing

@testable import DepotKitMacros

let patternKeyMacros: [String: Macro.Type] = [
    "pattern": PatternKeyExpressionMacro.self
]

@Suite
struct PatternKeyExpressionMacroTests {

    @Test("expands wildcard path")
    func wildcardPath() {
        assertMacroExpansion(
            """
            let x = #pattern("users/*/settings", coder: .json(Settings.self))
            """,
            expandedSource: """
                let x = DepotKit.PatternKeyDefinition(key: DepotKit.Key([.segment(identifier: "users"), .wildcard, .segment(identifier: "settings")]), coder: .json(Settings.self))
                """,
            macros: patternKeyMacros
        )
    }

    @Test("expands single wildcard")
    func singleWildcard() {
        assertMacroExpansion(
            """
            let x = #pattern("*", coder: .json(String.self))
            """,
            expandedSource: """
                let x = DepotKit.PatternKeyDefinition(key: DepotKit.Key([.wildcard]), coder: .json(String.self))
                """,
            macros: patternKeyMacros
        )
    }

    @Test("expands single globstar")
    func singleGlobstar() {
        assertMacroExpansion(
            """
            let x = #pattern("**", coder: .json(String.self))
            """,
            expandedSource: """
                let x = DepotKit.PatternKeyDefinition(key: DepotKit.Key([.globstar]), coder: .json(String.self))
                """,
            macros: patternKeyMacros
        )
    }

    @Test("expands wildcard at end")
    func wildcardAtEnd() {
        assertMacroExpansion(
            """
            let x = #pattern("users/*", coder: .data(Data.self))
            """,
            expandedSource: """
                let x = DepotKit.PatternKeyDefinition(key: DepotKit.Key([.segment(identifier: "users"), .wildcard]), coder: .data(Data.self))
                """,
            macros: patternKeyMacros
        )
    }

    @Test("expands globstar path")
    func globstarPath() {
        assertMacroExpansion(
            """
            let x = #pattern("users/**", coder: .json(String.self))
            """,
            expandedSource: """
                let x = DepotKit.PatternKeyDefinition(key: DepotKit.Key([.segment(identifier: "users"), .globstar]), coder: .json(String.self))
                """,
            macros: patternKeyMacros
        )
    }

    @Test("expands globstar in middle")
    func globstarInMiddle() {
        assertMacroExpansion(
            """
            let x = #pattern("users/**/settings", coder: .json(Settings.self))
            """,
            expandedSource: """
                let x = DepotKit.PatternKeyDefinition(key: DepotKit.Key([.segment(identifier: "users"), .globstar, .segment(identifier: "settings")]), coder: .json(Settings.self))
                """,
            macros: patternKeyMacros
        )
    }

    @Test("expands mixed wildcard and globstar")
    func mixedWildcardAndGlobstar() {
        assertMacroExpansion(
            """
            let x = #pattern("users/*/data/**", coder: .json(String.self))
            """,
            expandedSource: """
                let x = DepotKit.PatternKeyDefinition(key: DepotKit.Key([.segment(identifier: "users"), .wildcard, .segment(identifier: "data"), .globstar]), coder: .json(String.self))
                """,
            macros: patternKeyMacros
        )
    }

    @Test("diagnoses no wildcard in #pattern")
    func noWildcard() {
        assertMacroExpansion(
            """
            let x = #pattern("users/settings", coder: .json(String.self))
            """,
            expandedSource: """
                let x = #pattern("users/settings", coder: .json(String.self))
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "#pattern requires at least one wildcard ('*' or '**') segment.",
                    line: 1,
                    column: 18
                )
            ],
            macros: patternKeyMacros
        )
    }

    @Test("diagnoses consecutive wildcards")
    func consecutiveWildcards() {
        assertMacroExpansion(
            """
            let x = #pattern("a/*/*/b", coder: .json(String.self))
            """,
            expandedSource: """
                let x = #pattern("a/*/*/b", coder: .json(String.self))
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Key path must not contain consecutive wildcards ('*/*' or '**/**').",
                    line: 1,
                    column: 18
                )
            ],
            macros: patternKeyMacros
        )
    }

    @Test("diagnoses consecutive globstars")
    func consecutiveGlobstars() {
        assertMacroExpansion(
            """
            let x = #pattern("a/**/**/b", coder: .json(String.self))
            """,
            expandedSource: """
                let x = #pattern("a/**/**/b", coder: .json(String.self))
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Key path must not contain consecutive wildcards ('*/*' or '**/**').",
                    line: 1,
                    column: 18
                )
            ],
            macros: patternKeyMacros
        )
    }

    @Test("allows wildcard followed by globstar")
    func wildcardThenGlobstar() {
        assertMacroExpansion(
            """
            let x = #pattern("a/*/**", coder: .json(String.self))
            """,
            expandedSource: """
                let x = DepotKit.PatternKeyDefinition(key: DepotKit.Key([.segment(identifier: "a"), .wildcard, .globstar]), coder: .json(String.self))
                """,
            macros: patternKeyMacros
        )
    }

    @Test("expands escaped wildcard alongside real wildcard")
    func escapedWildcardWithRealWildcard() {
        assertMacroExpansion(
            #"""
            let x = #pattern(#"users/*/with\*star"#, coder: .json(String.self))
            """#,
            expandedSource: #"""
                let x = DepotKit.PatternKeyDefinition(key: DepotKit.Key([.segment(identifier: "users"), .wildcard, .segment(identifier: "with*star")]), coder: .json(String.self))
                """#,
            macros: patternKeyMacros
        )
    }

    @Test("escaped wildcard alone is not a wildcard")
    func escapedWildcardAloneIsNotWildcard() {
        assertMacroExpansion(
            #"""
            let x = #pattern(#"users/\*/settings"#, coder: .json(String.self))
            """#,
            expandedSource: #"""
                let x = #pattern(#"users/\*/settings"#, coder: .json(String.self))
                """#,
            diagnostics: [
                DiagnosticSpec(
                    message: "#pattern requires at least one wildcard ('*' or '**') segment.",
                    line: 1,
                    column: 18
                )
            ],
            macros: patternKeyMacros
        )
    }
}
