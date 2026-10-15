// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if DEPOTKIT_MACROS

// Consumer code may declare types and operators with the same names DepotKit uses.
// `#key` / `#pattern` expansions must keep resolving to DepotKit's declarations.

import DepotKit
import Testing

/// A consumer-defined path-joining operator on strings.
private func / (lhs: String, rhs: String) -> String {
    lhs + "|" + rhs
}

/// A consumer-defined operator with exactly the signature of a DepotKit overload.
private func / (lhs: KeyPathExpression, rhs: some CustomStringConvertible) -> KeyPathExpression {
    Issue.record("A macro expansion used the consumer's `/` operator.")
    return lhs
}

private enum ShadowingKeys {
    struct KeyDefinition {}
    struct PatternKeyDefinition {}
    struct Key {}
    struct DistinctKey {}
    struct KeyComponent {}

    static let username = #key("user/name", coder: .json(String.self))
    static let topLevel = #key("settings", coder: .json(Int.self))
    static let userName = #pattern("users/*/name", coder: .json(String.self))
    static let userData = #pattern("users/**", coder: .json(String.self))
}

@Suite
struct MacroShadowingConsumerTests {

    @Test("#key ignores consumer types and operators with DepotKit names")
    func keyIgnoresShadowingDeclarations() throws {
        let username: DepotKit.KeyDefinition<String> = ShadowingKeys.username
        #expect(username.key.keyPath == "user/name")
        #expect(username.key.components == [.segment(identifier: "user"), .segment(identifier: "name")])
        #expect(ShadowingKeys.topLevel.key.keyPath == "settings")

        let depot = Depot()
        let key = depot.register(username)
        try depot.set(value: "alice", for: key)
        #expect(try depot.get(valueFor: key) == "alice")
    }

    @Test("#pattern ignores consumer types and operators with DepotKit names")
    func patternIgnoresShadowingDeclarations() throws {
        let userName: DepotKit.PatternKeyDefinition<String> = ShadowingKeys.userName
        #expect(userName.key.components == [.segment(identifier: "users"), .wildcard, .segment(identifier: "name")])
        #expect(ShadowingKeys.userData.key.components == [.segment(identifier: "users"), .globstar])

        let depot = Depot()
        let pattern = depot.register(userName)
        let alice = TypedDistinctKey<String>([
            .segment(identifier: "users"), .segment(identifier: "alice"), .segment(identifier: "name"),
        ])
        try depot.set(value: "alice", for: alice)
        #expect(try depot.get(valuesFor: pattern) == ["alice"])
    }
}

#endif
