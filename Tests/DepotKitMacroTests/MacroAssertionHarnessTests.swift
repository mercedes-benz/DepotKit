// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing

@testable import DepotKitMacros

/// Verifies that macro assertion failures surface as Swift Testing issues.
///
/// Each test deliberately states a wrong expectation inside `withKnownIssue`.
/// If the assertion helper stopped reporting failures through Swift Testing,
/// no issue would be recorded and `withKnownIssue` would fail the test.
@Suite
struct MacroAssertionHarnessTests {

    @Test("wrong expanded source records an issue")
    func wrongExpansionRecordsIssue() {
        withKnownIssue {
            assertMacroExpansion(
                """
                let x = #key("username", coder: .json(String.self))
                """,
                expandedSource: """
                    let x = DepotKit.KeyDefinition(key: DepotKit.DistinctKey([.segment(identifier: "not-the-expansion")]), coder: .json(String.self))
                    """,
                macros: keyMacros
            )
        }
    }

    @Test("wrong diagnostic message records an issue")
    func wrongDiagnosticRecordsIssue() {
        withKnownIssue {
            assertMacroExpansion(
                """
                let x = #pattern("users/settings", coder: .json(String.self))
                """,
                expandedSource: """
                    let x = #pattern("users/settings", coder: .json(String.self))
                    """,
                diagnostics: [
                    DiagnosticSpec(message: "Not the emitted diagnostic.", line: 1, column: 18)
                ],
                macros: patternKeyMacros
            )
        }
    }

    @Test("missing diagnostic records an issue")
    func missingDiagnosticRecordsIssue() {
        withKnownIssue {
            assertMacroExpansion(
                """
                let x = #key("users/*", coder: .json(String.self))
                """,
                expandedSource: """
                    let x = #key("users/*", coder: .json(String.self))
                    """,
                macros: keyMacros
            )
        }
    }
}
