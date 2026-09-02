// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

@Suite
struct KeyTests {
    @Suite
    struct Components {
        @Test("has expected value")
        func hasExpectedValue() async throws {
            let components: [KeyComponent] = [
                .segment(identifier: "key"),
                .wildcard,
            ]

            let key = Key(components)
            #expect(key.components == components)
        }
    }

    @Suite
    struct FactoryMethods {
        @Test("work as expected")
        func works() async throws {
            #expect(Key.all == Key([.globstar]))
            #expect(Key.from("key" / .wildcard) == Key([.segment(identifier: "key"), .wildcard]))
            #expect(Key.from("key" / .globstar) == Key([.segment(identifier: "key"), .globstar]))
            #expect(
                Key.from("key").key
                    == Key([.segment(identifier: "key")]),
            )
        }
    }

    @Suite
    struct Distinct {
        @Test("works as expected")
        func works() async throws {
            #expect((Key.all).isDistinct == false)
            #expect((Key.from("key")).isDistinct == true)
            #expect((Key.from("key" / .wildcard)).isDistinct == false)
            #expect((Key.from("key" / .globstar)).isDistinct == false)
            #expect((Key.from("key" / "value")).isDistinct == true)
            #expect((Key.from("key" / .wildcard / "value")).isDistinct == false)
        }
    }

    @Suite
    struct KeyPath {
        @Test("works as expected")
        func works() async throws {
            #expect((Key.all).keyPath == "**")
            #expect((Key.from("key")).keyPath == "key")
            #expect((Key.from("key" / .wildcard)).keyPath == "key/*")
            #expect((Key.from("key" / .globstar)).keyPath == "key/**")
            #expect((Key.from("key" / "value")).keyPath == "key/value")
            #expect((Key.from("key" / .wildcard / "value")).keyPath == "key/*/value")
        }
    }

    @Suite
    struct KeyPathExpressionOperators {
        @Test("builds key paths via plus composition")
        func buildsKeyPathsViaPlusComposition() async throws {
            struct User {
                let id: String
            }

            let user = User(id: "abc-123")
            let key = Key.from("users" / user.id / "settings")
            #expect(
                key.components
                    == [
                        .segment(identifier: "users"),
                        .segment(identifier: user.id),
                        .segment(identifier: "settings"),
                    ],
            )
        }

        @Test("supports wildcard only via KeyComponent")
        func supportsWildcardOnlyViaKeyComponent() async throws {
            let wildcardKey = Key.from("users" / .wildcard / "settings")
            #expect(
                wildcardKey.components
                    == [
                        .segment(identifier: "users"),
                        .wildcard,
                        .segment(identifier: "settings"),
                    ],
            )

            let literalWildcardKey = Key.from("users" / "*" / "settings")
            #expect(
                literalWildcardKey.components
                    == [
                        .segment(identifier: "users"),
                        .segment(identifier: "*"),
                        .segment(identifier: "settings"),
                    ],
            )
            #expect(literalWildcardKey.isDistinct)
        }

        @Test("supports globstar via PatternKeyComponent")
        func supportsGlobstar() async throws {
            let globstarKey = Key.from("users" / .globstar)
            #expect(
                globstarKey.components
                    == [
                        .segment(identifier: "users"),
                        .globstar,
                    ],
            )
            #expect(!globstarKey.isDistinct)

            let literalGlobstar = Key.from("users" / "**")
            #expect(literalGlobstar.isDistinct)
        }

        @Test("preserves separators in slash-composed components")
        func preservesSeparatorsInPlusComposedComponents() async throws {
            let identifier = "id/with/slash"
            let key = Key.from("users" / identifier / "settings")
            #expect(
                key.components
                    == [
                        .segment(identifier: "users"),
                        .segment(identifier: identifier),
                        .segment(identifier: "settings"),
                    ],
            )
        }
    }

    @Suite
    struct Matches {
        // MARK: - Wildcard (* = single level)

        @Test("wildcard matches exactly one component")
        func wildcardSingleLevel() async throws {
            #expect(
                (Key.from("depot" / .wildcard / "entity")).matches(Key.from("depot" / "account" / "entity"))
                    == true,
            )
            #expect(
                (Key.from("depot" / "account" / "entity")).matches(Key.from("depot" / .wildcard / "entity"))
                    == false,
            )
        }

        @Test("trailing wildcard matches exactly one component — not deeper")
        func trailingWildcardSingleLevel() async throws {
            #expect(
                (Key.from("depot" / .wildcard)).matches(Key.from("depot" / "entity")) == true,
            )
            #expect(
                (Key.from("depot" / .wildcard)).matches(Key.from("depot" / "entity" / "account")) == false,
            )
        }

        @Test("wildcard does not match zero components")
        func wildcardDoesNotMatchZero() async throws {
            #expect(
                (Key.from("depot" / .wildcard / "account")).matches(Key.from("depot" / "account"))
                    == false,
            )
        }

        @Test("multiple wildcards match one each")
        func multipleWildcards() async throws {
            #expect(
                (Key.from("depot" / .wildcard / "account" / .wildcard)).matches(
                    Key.from("depot" / "status" / "account" / "active"),
                ) == true,
            )
            #expect(
                (Key.from("depot" / .wildcard / "account" / .wildcard)).matches(
                    Key.from("depot" / "status" / "account" / "active" / "extra"),
                ) == false,
            )
        }

        // MARK: - Globstar (** = zero or more)

        @Test("globstar matches zero components")
        func globstarMatchesZero() async throws {
            #expect(
                (Key.from("depot" / .globstar / "entity")).matches(Key.from("depot" / "entity"))
                    == true,
            )
        }

        @Test("globstar matches one component")
        func globstarMatchesOne() async throws {
            #expect(
                (Key.from("depot" / .globstar / "entity")).matches(Key.from("depot" / "x" / "entity"))
                    == true,
            )
        }

        @Test("globstar matches multiple components")
        func globstarMatchesMultiple() async throws {
            #expect(
                (Key.from("depot" / .globstar / "entity")).matches(Key.from("depot" / "a" / "b" / "c" / "entity"))
                    == true,
            )
        }

        @Test("trailing globstar matches any depth")
        func trailingGlobstar() async throws {
            #expect(
                (Key.from("depot" / .globstar)).matches(Key.from("depot" / "entity")) == true,
            )
            #expect(
                (Key.from("depot" / .globstar)).matches(Key.from("depot" / "entity" / "account")) == true,
            )
            #expect(
                (Key.from("depot" / .globstar)).matches(Key.from("depot" / "a" / "b" / "c")) == true,
            )
        }

        @Test("Key.all matches everything")
        func allMatchesEverything() async throws {
            #expect(Key.all.matches(Key.from("any")))
            #expect(Key.all.matches(Key.from("deep" / "nested" / "key")))
            #expect(Key.all.matches(Key([.wildcard])))
        }

        @Test("globstar alone matches any key")
        func globstarAlone() async throws {
            let glob = Key([.globstar])
            #expect(glob.matches(Key.from("a")))
            #expect(glob.matches(Key.from("a" / "b" / "c")))
        }

        // MARK: - Mixed wildcard + globstar

        @Test("wildcard followed by globstar")
        func wildcardThenGlobstar() async throws {
            let pattern = Key.from("users" / .wildcard / .globstar)
            #expect(pattern.matches(Key.from("users" / "alice")) == true)
            #expect(pattern.matches(Key.from("users" / "alice" / "settings")) == true)
            #expect(pattern.matches(Key.from("users" / "alice" / "a" / "b")) == true)
            #expect(pattern.matches(Key.from("users")) == false)
        }

        @Test("globstar followed by wildcard")
        func globstarThenWildcard() async throws {
            let pattern = Key.from(.globstar / .wildcard / "end")
            #expect(pattern.matches(Key.from("end")) == false)
            #expect(pattern.matches(Key.from("x" / "end")) == true)
            #expect(pattern.matches(Key.from("a" / "b" / "end")) == true)
        }

        // MARK: - Distinct keys

        @Test("distinct keys only match identical keys")
        func distinctOnly() async throws {
            #expect(
                (Key.from("depot" / "service" / "account")).matches(Key.from("depot" / "service"))
                    == false,
            )
            #expect(
                (Key.from("depot" / "service")).matches(Key.from("depot" / "service" / "account"))
                    == false,
            )
            #expect(
                (Key.from("depot" / "eins" / "zwei")).matches(Key.from("depot" / "eins" / "zwei"))
                    == true,
            )
        }

        @Test("non-pattern does not match pattern")
        func concreteDoesNotMatchPattern() async throws {
            #expect(
                (Key.from("depot" / "entity" / "account")).matches(Key.from("depot" / .wildcard))
                    == false,
            )
        }
    }

    @Suite
    struct Comparable {
        @Test("works as expected")
        func works() async throws {
            let k1 = Key.all
            let k2 = Key.from("key").key
            let k3 = Key.from("some" / .wildcard / "key")
            let k4 = Key.from("some" / "other" / .wildcard / "key")

            #expect((k1 < k1) == false)
            #expect((k1 < k2) == true)
            #expect((k2 < k1) == false)

            #expect((k3 < k4) == true)
            #expect((k4 < k3) == false)

            let globKey = Key.from("a" / .globstar)
            let wildKey = Key.from("a" / .wildcard)
            #expect(globKey < wildKey)
        }
    }

    @Suite
    struct Escaping {
        @Test("escapes wildcard")
        func wildcards() async throws {
            let identifier = "keywith*"
            let key = Key.from("test" / identifier)
            #expect(key.components == [.segment(identifier: "test"), .segment(identifier: identifier)])
        }

        @Test("escapes slash")
        func slash() async throws {
            let identifier = "keywith/"
            let key = Key.from("test" / identifier)
            #expect(key.components == [.segment(identifier: "test"), .segment(identifier: identifier)])
        }

        @Test("escaped wildcard and slash")
        func wildcardAndSlash() async throws {
            let identifier = "bad/identifier/*"
            let key = Key.from("objects" / identifier)
            #expect(key.components == [.segment(identifier: "objects"), .segment(identifier: "bad/identifier/*")])
        }

        @Test("keyPath is escaped")
        func isEscapted() async throws {
            let identifier = "key*with/characters"
            let key = Key.from("root" / identifier / "test")
            #expect(key.keyPath == "root/key\\*with\\/characters/test")
        }

        @Test("leaves regular keys unchanged")
        func regularKeysUnchanged() async throws {
            let identifier = "abc"
            let key = Key.from("some" / identifier / .wildcard)
            #expect(key.keyPath == "some/abc/*")
        }

        @Test("globstar keyPath renders as **")
        func globstarKeyPath() async throws {
            let key = Key.from("root" / .globstar)
            #expect(key.keyPath == "root/**")
        }
    }

    @Suite
    struct StringInterpolation {
        @Test("creates key from string interpolation")
        func stringInterpolation() {
            let userId = "abc123"
            let key = Key.from("\(userId).ext", as: String.self)
            #expect(key.key.components == [.segment(identifier: "abc123.ext")])
        }

        @Test("creates key from string interpolation with numeric value")
        func stringInterpolationNumeric() {
            let id = 42
            let key = Key.from("user_\(id)", as: Int.self)
            #expect(key.key.components == [.segment(identifier: "user_42")])
        }

        @Test("creates key from multi-segment interpolated path")
        func stringInterpolationMultiSegment() {
            let userId = "abc"
            let key = Key.from("\(userId)" / "settings")
            #expect(key.key.components == [.segment(identifier: "abc"), .segment(identifier: "settings")])
        }
    }
}
