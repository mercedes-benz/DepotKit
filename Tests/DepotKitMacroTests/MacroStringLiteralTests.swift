// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing

@testable import DepotKitMacros

/// A macro path argument as written in Swift source, paired with the path
/// `[KeyComponent]` array elements the macro is expected to generate for it.
struct MacroPathLiteralCase: CustomTestStringConvertible, Sendable {
    let source: String
    let expectedComponents: String

    var testDescription: String { source }
}

/// Verifies that `#key` / `#pattern` first resolve the Swift string literal to its
/// value and only then apply DepotKit's path-escape rules.
@Suite
struct MacroStringLiteralTests {

    // MARK: - Ordinary and raw literals produce identical keys

    static let keyCases: [MacroPathLiteralCase] = [
        // Escaped separator: Depot escape `\/` spelled as `\\/` or raw `\/`.
        .init(
            source: #""users/fraud\\/name""#,
            expectedComponents: #".segment(identifier: "users"), .segment(identifier: "fraud/name")"#
        ),
        .init(
            source: ##"#"users/fraud\/name"#"##,
            expectedComponents: #".segment(identifier: "users"), .segment(identifier: "fraud/name")"#
        ),
        // Literal backslash: Depot escape `\\` spelled as `\\\\` or raw `\\`.
        .init(
            source: #""users/back\\\\slash""#,
            expectedComponents: ##".segment(identifier: "users"), .segment(identifier: #"back\slash"#)"##
        ),
        .init(
            source: ##"#"users/back\\slash"#"##,
            expectedComponents: ##".segment(identifier: "users"), .segment(identifier: #"back\slash"#)"##
        ),
        // Literal asterisk: Depot escape `\*` spelled as `\\*` or raw `\*`.
        .init(
            source: #""users/with\\*star""#,
            expectedComponents: #".segment(identifier: "users"), .segment(identifier: "with*star")"#
        ),
        .init(
            source: ##"#"users/with\*star"#"##,
            expectedComponents: #".segment(identifier: "users"), .segment(identifier: "with*star")"#
        ),
        // Swift Unicode escapes resolve before path parsing.
        .init(
            source: #""users/\u{61}lice""#,
            expectedComponents: #".segment(identifier: "users"), .segment(identifier: "alice")"#
        ),
        .init(
            source: ##"#"users/\#u{61}lice"#"##,
            expectedComponents: #".segment(identifier: "users"), .segment(identifier: "alice")"#
        ),
        .init(source: #""\u{61}""#, expectedComponents: #".segment(identifier: "a")"#),
        .init(
            source: #""users/\u{5C}/name""#,
            expectedComponents: #".segment(identifier: "users"), .segment(identifier: "/name")"#
        ),
        // Other Swift escapes become part of the component value.
        .init(
            source: #""users/line\nbreak""#,
            expectedComponents: #".segment(identifier: "users"), .segment(identifier: "line\nbreak")"#
        ),
        .init(
            source: ##"#"users/line\#nbreak"#"##,
            expectedComponents: #".segment(identifier: "users"), .segment(identifier: "line\nbreak")"#
        ),
        .init(
            source: #""users/say \"hi\"""#,
            expectedComponents: ##".segment(identifier: "users"), .segment(identifier: #"say "hi""#)"##
        ),
        // Mixed escapes.
        .init(
            source: #""users/fraud\\\\name\\/with\\*/settings""#,
            expectedComponents:
                ##".segment(identifier: "users"), .segment(identifier: #"fraud\name/with*"#), .segment(identifier: "settings")"##
        ),
        .init(
            source: ##"#"users/fraud\\name\/with\*/settings"#"##,
            expectedComponents:
                ##".segment(identifier: "users"), .segment(identifier: #"fraud\name/with*"#), .segment(identifier: "settings")"##
        ),
        // Multi-line literals are combined into their represented value.
        .init(
            source: "\"\"\"\n    users/name\n    \"\"\"",
            expectedComponents: #".segment(identifier: "users"), .segment(identifier: "name")"#
        ),
    ]

    @Test("#key uses the represented Swift string value", arguments: keyCases)
    func keyUsesRepresentedValue(_ testCase: MacroPathLiteralCase) {
        assertMacroExpansion(
            "let x = #key(\(testCase.source), coder: .json(String.self))",
            expandedSource:
                "let x = DepotKit.KeyDefinition(key: DepotKit.DistinctKey([\(testCase.expectedComponents)]), coder: .json(String.self))",
            macros: keyMacros
        )
    }

    static let patternCases: [MacroPathLiteralCase] = [
        .init(
            source: #""users/*/with\\*star""#,
            expectedComponents: #".segment(identifier: "users"), .wildcard, .segment(identifier: "with*star")"#
        ),
        .init(
            source: ##"#"users/*/with\*star"#"##,
            expectedComponents: #".segment(identifier: "users"), .wildcard, .segment(identifier: "with*star")"#
        ),
        .init(
            source: #""users/*/fraud\\/name""#,
            expectedComponents: #".segment(identifier: "users"), .wildcard, .segment(identifier: "fraud/name")"#
        ),
        .init(
            source: ##"#"users/*/fraud\/name"#"##,
            expectedComponents: #".segment(identifier: "users"), .wildcard, .segment(identifier: "fraud/name")"#
        ),
        .init(
            source: #""users/**/back\\\\slash""#,
            expectedComponents: ##".segment(identifier: "users"), .globstar, .segment(identifier: #"back\slash"#)"##
        ),
        .init(
            source: ##"#"users/**/back\\slash"#"##,
            expectedComponents: ##".segment(identifier: "users"), .globstar, .segment(identifier: #"back\slash"#)"##
        ),
        // `\u{2A}` is `*` in Swift, so it denotes a wildcard just like a plain `*`.
        .init(
            source: #""users/\u{2A}/name""#,
            expectedComponents: #".segment(identifier: "users"), .wildcard, .segment(identifier: "name")"#
        ),
        .init(source: #""\u{61}/*""#, expectedComponents: #".segment(identifier: "a"), .wildcard"#),
    ]

    @Test("#pattern uses the represented Swift string value", arguments: patternCases)
    func patternUsesRepresentedValue(_ testCase: MacroPathLiteralCase) {
        assertMacroExpansion(
            "let x = #pattern(\(testCase.source), coder: .json(String.self))",
            expandedSource:
                "let x = DepotKit.PatternKeyDefinition(key: DepotKit.Key([\(testCase.expectedComponents)]), coder: .json(String.self))",
            macros: patternKeyMacros
        )
    }

    // MARK: - Invalid input

    static let invalidEscapeMessage =
        #"Invalid escape sequence. Use '\/' for literal '/', '\*' for literal '*', or '\\' for literal '\'."#

    static let invalidEscapeSources: [String] = [
        #""users/\\n""#,
        ##"#"users/\n"#"##,
        #""users/name\\""#,
        ##"#"users/name\"#"##,
    ]

    @Test("diagnoses invalid DepotKit escapes in the represented value", arguments: invalidEscapeSources)
    func invalidDepotEscape(_ source: String) {
        assertMacroExpansion(
            "let x = #key(\(source), coder: .json(String.self))",
            expandedSource: "let x = #key(\(source), coder: .json(String.self))",
            diagnostics: [
                DiagnosticSpec(message: Self.invalidEscapeMessage, line: 1, column: 14)
            ],
            macros: keyMacros
        )
    }

    static let interpolationSources: [String] = [
        #""users/\(name)""#,
        ##"#"users/\#(name)"#"##,
    ]

    @Test("diagnoses string interpolation", arguments: interpolationSources)
    func interpolation(_ source: String) {
        assertMacroExpansion(
            "let x = #key(\(source), coder: .json(String.self))",
            expandedSource: "let x = #key(\(source), coder: .json(String.self))",
            diagnostics: [
                DiagnosticSpec(message: "Path string literal must not contain interpolation.", line: 1, column: 14)
            ],
            macros: keyMacros
        )
    }

    @Test("diagnoses malformed Swift string literal")
    func malformedSwiftLiteral() throws {
        // The source itself fails to lex, and a failed expansion leaves it in place, so the
        // expansion harness (which rejects syntax errors in its output) cannot be used here.
        let source = #"let x = #key("users/fraud\/name", coder: .json(String.self))"#
        let file = Parser.parse(source: source)
        let macro = try #require(
            file.statements.first?.item.as(VariableDeclSyntax.self)?
                .bindings.first?.initializer?.value.as(MacroExpansionExprSyntax.self)
        )

        let error = try #require(throws: DiagnosticsError.self) {
            try KeyExpressionMacro.expansion(of: macro, in: BasicMacroExpansionContext())
        }

        try #require(error.diagnostics.count == 1)
        let diagnostic = error.diagnostics[0]
        let location = diagnostic.location(converter: SourceLocationConverter(fileName: "test.swift", tree: file))
        #expect(diagnostic.message == "Path argument is not a valid string literal.")
        #expect(location.line == 1)
        #expect(location.column == 14)
    }

    @Test("Unicode-escaped asterisk is a wildcard in #key")
    func unicodeEscapedWildcardInKey() {
        assertMacroExpansion(
            #"let x = #key("users/\u{2A}", coder: .json(String.self))"#,
            expandedSource: #"let x = #key("users/\u{2A}", coder: .json(String.self))"#,
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

    @Test("ordinary-literal escaped wildcard alone is not a wildcard")
    func ordinaryEscapedWildcardIsNotWildcard() {
        assertMacroExpansion(
            #"let x = #pattern("users/\\*/settings", coder: .json(String.self))"#,
            expandedSource: #"let x = #pattern("users/\\*/settings", coder: .json(String.self))"#,
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

    @Test("Unicode escape producing an empty segment is diagnosed")
    func unicodeEscapedSeparatorProducesEmptySegment() {
        assertMacroExpansion(
            #"let x = #key("users/\u{2F}/name", coder: .json(String.self))"#,
            expandedSource: #"let x = #key("users/\u{2F}/name", coder: .json(String.self))"#,
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
}
