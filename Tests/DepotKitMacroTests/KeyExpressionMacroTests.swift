// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

@testable import DepotKitMacros

let keyMacros: [String: Macro.Type] = [
    "key": KeyExpressionMacro.self
]

@Suite
struct KeyExpressionMacroTests {

    @Test("expands single-segment path")
    func singleSegment() {
        assertMacroExpansion(
            """
            let x = #key("username", coder: .json(String.self))
            """,
            expandedSource: """
                let x = KeyDefinition(path: "username", coder: .json(String.self))
                """,
            macros: keyMacros
        )
    }

    @Test("expands multi-segment path")
    func multiSegment() {
        assertMacroExpansion(
            """
            let x = #key("user/settings/theme", coder: .json(String.self))
            """,
            expandedSource: """
                let x = KeyDefinition(path: "user" / "settings" / "theme", coder: .json(String.self))
                """,
            macros: keyMacros
        )
    }

    @Test("expands data coder shorthand")
    func dataCoder() {
        assertMacroExpansion(
            """
            let x = #key("user/avatar", coder: .data(Data.self))
            """,
            expandedSource: """
                let x = KeyDefinition(path: "user" / "avatar", coder: .data(Data.self))
                """,
            macros: keyMacros
        )
    }

    @Test("expands plist coder shorthand")
    func plistCoder() {
        assertMacroExpansion(
            """
            let x = #key("prefs", coder: .plist(Settings.self))
            """,
            expandedSource: """
                let x = KeyDefinition(path: "prefs", coder: .plist(Settings.self))
                """,
            macros: keyMacros
        )
    }

    @Test("diagnoses wildcard in #key")
    func wildcardInKey() {
        assertMacroExpansion(
            """
            let x = #key("users/*/name", coder: .json(String.self))
            """,
            expandedSource: """
                let x = ""
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "#key does not allow wildcards ('*' or '**'). Use #pattern for wildcard paths.",
                    line: 1,
                    column: 14
                )
            ],
            macros: keyMacros
        )
    }

    @Test("diagnoses globstar in #key")
    func globstarInKey() {
        assertMacroExpansion(
            """
            let x = #key("users/**/name", coder: .json(String.self))
            """,
            expandedSource: """
                let x = ""
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "#key does not allow wildcards ('*' or '**'). Use #pattern for wildcard paths.",
                    line: 1,
                    column: 14
                )
            ],
            macros: keyMacros
        )
    }

    @Test("diagnoses empty path")
    func emptyPath() {
        assertMacroExpansion(
            """
            let x = #key("", coder: .json(String.self))
            """,
            expandedSource: """
                let x = ""
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Key path must not be empty.",
                    line: 1,
                    column: 14
                )
            ],
            macros: keyMacros
        )
    }

    @Test("diagnoses empty segment")
    func emptySegment() {
        assertMacroExpansion(
            """
            let x = #key("user//name", coder: .json(String.self))
            """,
            expandedSource: """
                let x = ""
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Key path must not contain empty segments (e.g. '//').",
                    line: 1,
                    column: 14
                )
            ],
            macros: keyMacros
        )
    }

    @Test("diagnoses consecutive wildcards")
    func consecutiveWildcards() {
        assertMacroExpansion(
            """
            let x = #key("a/*/*/b", coder: .json(String.self))
            """,
            expandedSource: """
                let x = ""
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Key path must not contain consecutive wildcards ('*/*' or '**/**').",
                    line: 1,
                    column: 14
                )
            ],
            macros: keyMacros
        )
    }

    @Test("expands escaped slash as literal")
    func escapedSlash() {
        assertMacroExpansion(
            #"""
            let x = #key("users/fraud\/name", coder: .json(String.self))
            """#,
            expandedSource: #"""
                let x = KeyDefinition(path: "users" / #"fraud/name"#, coder: .json(String.self))
                """#,
            macros: keyMacros
        )
    }

    @Test("expands escaped wildcard as literal")
    func escapedWildcard() {
        assertMacroExpansion(
            #"""
            let x = #key("users/with\*star", coder: .json(String.self))
            """#,
            expandedSource: #"""
                let x = KeyDefinition(path: "users" / "with*star", coder: .json(String.self))
                """#,
            macros: keyMacros
        )
    }

    @Test("expands escaped backslash as literal")
    func escapedBackslash() {
        assertMacroExpansion(
            #"""
            let x = #key("users/back\\slash", coder: .json(String.self))
            """#,
            expandedSource: #"""
                let x = KeyDefinition(path: "users" / #"back\slash"#, coder: .json(String.self))
                """#,
            macros: keyMacros
        )
    }

    @Test("expands mixed escapes")
    func mixedEscapes() {
        assertMacroExpansion(
            #"""
            let x = #key("users/fraud\\name\/with\*/settings", coder: .json(String.self))
            """#,
            expandedSource: #"""
                let x = KeyDefinition(path: "users" / #"fraud\name/with*"# / "settings", coder: .json(String.self))
                """#,
            macros: keyMacros
        )
    }

    @Test("diagnoses invalid escape sequence")
    func invalidEscape() {
        assertMacroExpansion(
            #"""
            let x = #key("users/\n", coder: .json(String.self))
            """#,
            expandedSource: #"""
                let x = ""
                """#,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        #"Invalid escape sequence. Use '\/' for literal '/', '\*' for literal '*', or '\\' for literal '\'."#,
                    line: 1,
                    column: 14
                )
            ],
            macros: keyMacros
        )
    }
}
