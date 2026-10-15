// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if DEPOTKIT_MACROS

// Consumer-compilation coverage for `#key` / `#pattern`.
//
// This target intentionally uses only an ordinary `import DepotKit` (no
// `@testable`), so every macro expansion below must compile against DepotKit's
// public API exactly as it would in a client app.

import DepotKit
import Testing

enum ConsumerKeys {
    // MARK: Distinct keys

    static let username = #key("user/name", coder: .json(String.self))
    static let topLevel = #key("settings", coder: .json(Int.self))

    static let escapedSeparator = #key("users/fraud\\/name", coder: .json(String.self))
    static let escapedSeparatorRaw = #key(#"users/fraud\/name"#, coder: .json(String.self))

    static let literalBackslash = #key("files/back\\\\slash", coder: .json(String.self))
    static let literalBackslashRaw = #key(#"files/back\\slash"#, coder: .json(String.self))

    static let literalStar = #key("files/with\\*star", coder: .json(String.self))
    static let literalStarRaw = #key(#"files/with\*star"#, coder: .json(String.self))

    static let unicodeEscape = #key("people/\u{61}lice", coder: .json(String.self))
    static let unicodeEscapeRaw = #key(#"people/\#u{61}lice"#, coder: .json(String.self))
    static let unicodePlain = #key("people/alice", coder: .json(String.self))

    // MARK: Pattern keys

    static let anyTopLevel = #pattern("*", coder: .json(Int.self))
    static let everything = #pattern("**", coder: .json(Int.self))
    static let userName = #pattern("users/*/name", coder: .json(String.self))
    static let userNameUnicode = #pattern("users/\u{2A}/name", coder: .json(String.self))
    static let userData = #pattern("users/*/data/**", coder: .json(String.self))
    static let deepName = #pattern("users/**/name", coder: .json(String.self))
    static let trailingWildcard = #pattern("users/*", coder: .json(String.self))
    static let leadingGlobstar = #pattern("**/name", coder: .json(String.self))
    static let escapedInPattern = #pattern("users/*/fraud\\/name", coder: .json(String.self))
    static let escapedInPatternRaw = #pattern(#"users/*/fraud\/name"#, coder: .json(String.self))
}

@Suite
struct MacroConsumerTests {

    // MARK: - Standalone wildcards

    @Test("#pattern(\"*\") compiles and matches every single-component key")
    func standaloneWildcard() throws {
        #expect(ConsumerKeys.anyTopLevel.key.components == [.wildcard])
        #expect(ConsumerKeys.anyTopLevel.key == Key.from(PatternKeyPathExpression(.wildcard)))

        let depot = Depot()
        let pattern = depot.register(ConsumerKeys.anyTopLevel)
        try depot.set(value: 1, for: Key.from("alpha", as: Int.self))
        try depot.set(value: 2, for: Key.from("beta", as: Int.self))

        #expect(try depot.get(valuesFor: pattern).sorted() == [1, 2])
        #expect(try depot.get(valueFor: Key.from("alpha", as: Int.self)) == 1)
    }

    @Test("#pattern(\"**\") compiles and matches keys at any depth")
    func standaloneGlobstar() throws {
        #expect(ConsumerKeys.everything.key.components == [.globstar])
        #expect(ConsumerKeys.everything.key == Key.all)
        #expect(ConsumerKeys.everything.key == Key.from(PatternKeyPathExpression(.globstar)))

        let depot = Depot()
        let pattern = depot.register(ConsumerKeys.everything)
        try depot.set(value: 1, for: Key.from("a", as: Int.self))
        try depot.set(value: 2, for: Key.from("a" / "b", as: Int.self))
        try depot.set(value: 3, for: Key.from("a" / "b" / "c", as: Int.self))

        #expect(try depot.get(valuesFor: pattern).sorted() == [1, 2, 3])
    }

    // MARK: - Mixed patterns

    @Test("mixed wildcard and globstar patterns compile and match")
    func mixedPatterns() throws {
        #expect(ConsumerKeys.userName.key == Key.from("users" / .wildcard / "name"))
        #expect(ConsumerKeys.userData.key == Key.from("users" / .wildcard / "data" / .globstar))
        #expect(ConsumerKeys.deepName.key == Key.from("users" / .globstar / "name"))
        #expect(ConsumerKeys.trailingWildcard.key == Key.from("users" / .wildcard))
        #expect(ConsumerKeys.leadingGlobstar.key == Key.from(.globstar / "name"))

        let depot = Depot()
        let data = depot.register(ConsumerKeys.userData)
        try depot.set(value: "x", for: Key.from("users" / "alice" / "data" / "x", as: String.self))
        try depot.set(value: "y", for: Key.from("users" / "bob" / "data" / "deep" / "y", as: String.self))

        #expect(try depot.get(valuesFor: data).sorted() == ["x", "y"])
    }

    // MARK: - Swift literal decoding

    @Test("escaped separator yields one component containing '/'")
    func escapedSeparator() throws {
        let expected = Key.from("users" / "fraud/name", as: String.self)
        #expect(ConsumerKeys.escapedSeparator.key == DistinctKey(expected))
        #expect(ConsumerKeys.escapedSeparatorRaw.key == ConsumerKeys.escapedSeparator.key)
        #expect(ConsumerKeys.escapedInPattern.key == Key.from("users" / .wildcard / "fraud/name"))
        #expect(ConsumerKeys.escapedInPatternRaw.key == ConsumerKeys.escapedInPattern.key)

        let depot = Depot()
        let key = depot.register(ConsumerKeys.escapedSeparator)
        let pattern = depot.register(ConsumerKeys.escapedInPattern)
        try depot.set(value: "fraud", for: key)

        #expect(try depot.get(valueFor: expected) == "fraud")
        #expect(try depot.get(valueFor: depot.register(ConsumerKeys.escapedSeparatorRaw)) == "fraud")
        #expect(try depot.get(valuesFor: pattern).isEmpty)
        try depot.set(value: "bob", for: Key.from("users" / "bob" / "fraud/name", as: String.self))
        #expect(try depot.get(valuesFor: pattern) == ["bob"])
    }

    @Test("escaped backslash and asterisk yield literal characters")
    func literalBackslashAndAsterisk() throws {
        #expect(ConsumerKeys.literalBackslash.key == Key.from("files" / #"back\slash"#))
        #expect(ConsumerKeys.literalBackslashRaw.key == ConsumerKeys.literalBackslash.key)
        #expect(ConsumerKeys.literalStar.key == Key.from("files" / "with*star"))
        #expect(ConsumerKeys.literalStarRaw.key == ConsumerKeys.literalStar.key)

        let depot = Depot()
        let backslash = depot.register(ConsumerKeys.literalBackslash)
        let star = depot.register(ConsumerKeys.literalStar)
        try depot.set(value: "b", for: backslash)
        try depot.set(value: "s", for: star)

        #expect(try depot.get(valueFor: depot.register(ConsumerKeys.literalBackslashRaw)) == "b")
        #expect(try depot.get(valueFor: depot.register(ConsumerKeys.literalStarRaw)) == "s")
    }

    @Test("Unicode escapes resolve to the represented characters")
    func unicodeEscapes() throws {
        #expect(ConsumerKeys.unicodeEscape.key == ConsumerKeys.unicodePlain.key)
        #expect(ConsumerKeys.unicodeEscapeRaw.key == ConsumerKeys.unicodePlain.key)
        #expect(ConsumerKeys.userNameUnicode.key == ConsumerKeys.userName.key)

        let depot = Depot()
        let escaped = depot.register(ConsumerKeys.unicodeEscape)
        let plain = depot.register(ConsumerKeys.unicodePlain)
        try depot.set(value: "Alice", for: escaped)

        #expect(try depot.get(valueFor: plain) == "Alice")
    }

    @Test("plain #key definitions register, write and read")
    func plainKeys() throws {
        #expect(ConsumerKeys.username.key == Key.from("user" / "name"))
        #expect(ConsumerKeys.topLevel.key == Key.from("settings"))

        let depot = Depot()
        let username = depot.register(ConsumerKeys.username)
        let topLevel = depot.register(ConsumerKeys.topLevel)
        try depot.set(value: "alice", for: username)
        try depot.set(value: 42, for: topLevel)

        #expect(try depot.get(valueFor: username) == "alice")
        #expect(try depot.get(valueFor: topLevel) == 42)
    }
}

#endif
