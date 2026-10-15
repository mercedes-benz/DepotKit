// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

@Suite
struct KeyMatchingTests {
    // MARK: - Pattern Matching Edge Cases

    @Suite
    struct PatternMatching {
        @Test("globstar at start matches any prefix")
        func globstarAtStart() {
            let pattern = Key.from(.globstar / "end")
            #expect(pattern.matches(Key.from("end")))
            #expect(pattern.matches(Key.from("a" / "end")))
            #expect(pattern.matches(Key.from("a" / "b" / "c" / "end")))
            #expect(!pattern.matches(Key.from("end" / "extra")))
            #expect(!pattern.matches(Key.from("notend")))
        }

        @Test("globstar in middle matches zero or more")
        func globstarInMiddle() {
            let pattern = Key.from("start" / .globstar / "end")
            #expect(pattern.matches(Key.from("start" / "end")))
            #expect(pattern.matches(Key.from("start" / "x" / "end")))
            #expect(pattern.matches(Key.from("start" / "a" / "b" / "c" / "end")))
            #expect(!pattern.matches(Key.from("start" / "end" / "extra")))
            #expect(!pattern.matches(Key.from("wrong" / "end")))
        }

        @Test("multiple globstars in pattern")
        func multipleGlobstars() {
            let pattern = Key.from(.globstar / "mid" / .globstar / "end")
            #expect(pattern.matches(Key.from("mid" / "end")))
            #expect(pattern.matches(Key.from("a" / "mid" / "end")))
            #expect(pattern.matches(Key.from("mid" / "x" / "end")))
            #expect(pattern.matches(Key.from("a" / "b" / "mid" / "x" / "y" / "end")))
            #expect(!pattern.matches(Key.from("mid" / "end" / "extra")))
        }

        @Test("wildcard + globstar combinations")
        func wildcardPlusGlobstar() {
            let pattern = Key.from(.wildcard / .globstar / "end")
            #expect(pattern.matches(Key.from("x" / "end")))
            #expect(pattern.matches(Key.from("x" / "a" / "b" / "end")))
            #expect(!pattern.matches(Key.from("end")))
        }

        @Test("Key.all matches single component keys")
        func allMatchesSingle() {
            #expect(Key.all.matches(Key.from("x")))
        }

        @Test("Key.all matches deeply nested keys")
        func allMatchesDeep() {
            #expect(Key.all.matches(Key.from("a" / "b" / "c" / "d" / "e")))
        }

        @Test("pattern does not match shorter key")
        func patternDoesNotMatchShorter() {
            let pattern = Key.from("a" / .wildcard / "b" / .wildcard)
            #expect(!pattern.matches(Key.from("a" / "x" / "b")))
        }

        @Test("pattern does not match longer key without globstar")
        func patternDoesNotMatchLonger() {
            let pattern = Key.from("a" / .wildcard)
            #expect(!pattern.matches(Key.from("a" / "x" / "y")))
        }

        @Test("segment mismatch in pattern")
        func segmentMismatch() {
            let pattern = Key.from("users" / .wildcard / "name")
            #expect(!pattern.matches(Key.from("users" / "alice" / "age")))
        }

        @Test("globstar before segment followed by wildcard")
        func globstarSegmentWildcard() {
            let pattern = Key.from(.globstar / "users" / .wildcard)
            #expect(pattern.matches(Key.from("users" / "alice")))
            #expect(pattern.matches(Key.from("app" / "users" / "bob")))
            #expect(!pattern.matches(Key.from("users")))
        }
    }

    // MARK: - DistinctKey.from(fileURL:relativeTo:)

    @Suite
    struct FileURLConstruction {
        @Test("constructs key from file URL")
        func constructsFromFileURL() throws {
            let depotURL = URL(fileURLWithPath: "/tmp/depot")
            let key = Key.from("hello")
            let fileURL = try key.getFileURL(from: depotURL, codec: .base64URL)

            let reconstructed = DistinctKey.from(fileURL: fileURL, relativeTo: depotURL, codec: .base64URL)
            #expect(reconstructed?.components == key.components)
        }

        @Test("constructs multi-segment key from file URL")
        func multiSegment() throws {
            let depotURL = URL(fileURLWithPath: "/tmp/depot")
            let key = Key.from("users" / "alice" / "settings")
            let fileURL = try key.getFileURL(from: depotURL, codec: .base64URL)

            let reconstructed = DistinctKey.from(fileURL: fileURL, relativeTo: depotURL, codec: .base64URL)
            #expect(reconstructed?.components == key.components)
        }

        @Test("returns nil for non-bin extension")
        func returnsNilForWrongExtension() throws {
            let depotURL = URL(fileURLWithPath: "/tmp/depot")
            let fileURL = depotURL.appendingPathComponent("file.txt")

            let result = DistinctKey.from(fileURL: fileURL, relativeTo: depotURL, codec: .base64URL)
            #expect(result == nil)
        }

        @Test("returns nil when depot path not found in file path")
        func returnsNilForUnrelatedPath() throws {
            let depotURL = URL(fileURLWithPath: "/tmp/depot")
            let fileURL = URL(fileURLWithPath: "/other/path/file.bin")

            let result = DistinctKey.from(fileURL: fileURL, relativeTo: depotURL, codec: .base64URL)
            #expect(result == nil)
        }

        @Test("handles special characters in key")
        func specialCharacters() throws {
            let depotURL = URL(fileURLWithPath: "/tmp/depot")
            let key = Key.from("path/with/slash")
            let fileURL = try key.getFileURL(from: depotURL, codec: .base64URL)

            let reconstructed = DistinctKey.from(fileURL: fileURL, relativeTo: depotURL, codec: .base64URL)
            #expect(reconstructed?.components == key.components)
        }
    }

    // MARK: - Key Component Encoding/Decoding

    @Suite
    struct ComponentEncoding {
        @Test("pathComponent encodes identifiers as base64")
        func encodesAsBase64() {
            let component = KeyComponent.segment(identifier: "hello")
            let encoded = component.pathComponent(using: .base64URL)
            #expect(encoded == "aGVsbG8=")
            #expect(!encoded.contains("/"))
        }

        @Test("pathComponent encodes identifiers with the hidden key prefix", arguments: DepotFileNameCodec.allCases)
        func encodesHiddenPrefix(codec: DepotFileNameCodec) {
            for identifier in [".FS_META", ".FS_/../../outside", "..", "."] {
                let encoded = KeyComponent.segment(identifier: identifier).pathComponent(using: codec)
                #expect(!encoded.hasPrefix("."))
                #expect(!encoded.contains("/"))
                #expect(codec.decode(encoded) == identifier)
            }
        }

        @Test("decoding a path component reverses the encoding")
        func decodesBase64() {
            let original = KeyComponent.segment(identifier: "test-value")
            let encoded = original.pathComponent(using: .base64URL)
            let decoded = KeyComponent(decodingPathComponent: encoded, using: .base64URL)
            #expect(decoded == original)
        }

        @Test("internal hidden names are never decoded as user components", arguments: DepotFileNameCodec.allCases)
        func hiddenNamesAreNotDecoded(codec: DepotFileNameCodec) {
            for name in [".FS_LOCK", ".FS_META", ".hidden"] {
                #expect(KeyComponent(decodingPathComponent: name, using: codec) == nil)
            }
        }

        @Test("decodingPathComponent returns nil for invalid base64")
        func decodingInvalidReturnsNil() {
            let result = KeyComponent(decodingPathComponent: "!!!invalid!!!", using: .base64URL)
            #expect(result == nil)
        }

        @Test("decodingPathComponent succeeds for valid base64url")
        func decodingValidSucceeds() {
            let component = KeyComponent.segment(identifier: "valid")
            let encoded = component.pathComponent(using: .base64URL)
            let decoded = KeyComponent(decodingPathComponent: encoded, using: .base64URL)
            #expect(decoded == component)
        }

        @Test("base64url encoding never contains slash or plus (RFC 4648 §5)")
        func base64urlNoSlashOrPlus() {
            let encoded = "hello\u{fc}world".toBase64URL()
            #expect(!encoded.contains("/"))
            #expect(!encoded.contains("+"))
        }

        @Test("base64url roundtrip with special characters (RFC 4648 §5)")
        func base64urlRoundtrip() {
            let values = ["hello", "a/b/c", "emoji🎉", "spaces in path", "under_score", "hello\u{fc}world", "a+b>c~d"]
            for value in values {
                let encoded = value.toBase64URL()
                #expect(DepotFileNameCodec.base64URL.decode(encoded) == value)
            }
        }
    }

    // MARK: - Key distinct() / isDistinct

    @Suite
    struct DistinctConversion {
        @Test("distinct() succeeds for segment-only keys")
        func distinctSucceeds() throws {
            let key = Key.from("a" / "b" / "c")
            let distinct = try key.key.distinct()
            #expect(distinct.components == key.components)
        }

        @Test("distinct() throws for wildcard key")
        func distinctThrowsForWildcard() {
            let key = Key.from("a" / .wildcard)
            #expect(throws: KeyError.nonDistinctKey) {
                try key.distinct()
            }
        }

        @Test("distinct() throws for globstar key")
        func distinctThrowsForGlobstar() {
            let key = Key.from("a" / .globstar)
            #expect(throws: KeyError.nonDistinctKey) {
                try key.distinct()
            }
        }

        @Test("TypedKey.distinct() throws for pattern")
        func typedDistinctThrows() {
            let key = Key.from("users" / .wildcard, as: String.self)
            #expect(throws: KeyError.nonDistinctKey) {
                try key.distinct()
            }
        }

        @Test("TypedKey.distinct() succeeds for concrete")
        func typedDistinctSucceeds() throws {
            let key = Key.from("users" / "alice", as: String.self)
            let distinct = try key.distinct()
            #expect(distinct.components == key.components)
        }
    }

    // MARK: - Key Hashing

    @Suite
    struct Hashing {
        @Test("equal keys produce equal hashes")
        func equalKeysEqualHash() {
            let k1 = Key.from("a" / "b")
            let k2 = Key.from("a" / "b")
            #expect(k1.key.hashValue == k2.key.hashValue)
        }

        @Test("different keys produce different hashes")
        func differentKeysDifferentHash() {
            let k1 = Key.from("a" / "b")
            let k2 = Key.from("a" / "c")
            #expect(k1.key.hashValue != k2.key.hashValue)
        }

        @Test("keys work correctly in a Set")
        func keysInSet() {
            let k1 = Key.from("a" / "b")
            let k2 = Key.from("a" / "b")
            let k3 = Key.from("a" / "c")

            let set: Set<Key> = [k1.key, k2.key, k3.key]
            #expect(set.count == 2)
        }

        @Test("DistinctKeys work correctly in a Set")
        func distinctKeysInSet() {
            let k1 = Key.from("x" / "y")
            let k2 = Key.from("x" / "y")
            let k3 = Key.from("x" / "z")

            let set: Set<DistinctKey> = [k1, k2, k3]
            #expect(set.count == 2)
        }
    }

    // MARK: - Key Sorting (Comparable)

    @Suite
    struct Sorting {
        @Test("keys sort by component count when prefix matches")
        func sortsByLength() {
            let short = Key.from("a").key
            let long = Key.from("a" / "b").key
            #expect(short < long)
        }

        @Test("keys sort lexicographically by segment identifier")
        func sortsLexicographically() {
            let alpha = Key.from("alpha").key
            let beta = Key.from("beta").key
            #expect(alpha < beta)
        }

        @Test("wildcard sorts before segment")
        func wildcardBeforeSegment() {
            let wild = Key([.wildcard])
            let seg = Key([.segment(identifier: "a")])
            #expect(wild < seg)
        }

        @Test("globstar sorts before wildcard")
        func globstarBeforeWildcard() {
            let glob = Key([.globstar])
            let wild = Key([.wildcard])
            #expect(glob < wild)
        }

        @Test("array of keys sorts deterministically")
        func arraySort() {
            let keys: [Key] = [
                Key.from("c").key,
                Key.from("a").key,
                Key.from("b").key,
                Key.from("a" / "b").key,
            ]
            let sorted = keys.sorted()
            // Single-component keys sort first by identifier, then multi-component
            #expect(sorted[0] == Key.from("a").key)
            #expect(sorted.contains(Key.from("b").key))
            #expect(sorted.contains(Key.from("c").key))
            #expect(sorted.contains(Key.from("a" / "b").key))
        }
    }

    // MARK: - Key Appending

    @Suite
    struct Appending {
        @Test("appending segment to Key")
        func appendSegmentToKey() {
            var key = Key.from("root").key
            key.append("child")
            #expect(key.components == [.segment(identifier: "root"), .segment(identifier: "child")])
            #expect(key.isDistinct)
        }

        @Test("appending wildcard to Key")
        func appendWildcardToKey() {
            var key = Key.from("root").key
            key.append(.wildcard)
            #expect(!key.isDistinct)
            #expect(key.components.last == .wildcard)
        }

        @Test("appending segment to DistinctKey")
        func appendToDistinct() {
            var key = Key.from("root")
            key.append("leaf")
            #expect(key.components == [.segment(identifier: "root"), .segment(identifier: "leaf")])
        }

        @Test("appending to TypedKey preserves type")
        func appendToTypedKey() {
            var key = Key.from("root", as: String.self).key.typed(as: String.self)
            key.append("child")
            #expect(key.components == [.segment(identifier: "root"), .segment(identifier: "child")])
        }

        @Test("appending to TypedDistinctKey preserves type")
        func appendToTypedDistinctKey() {
            var key = Key.from("root", as: String.self)
            key.append("child")
            #expect(key.components == [.segment(identifier: "root"), .segment(identifier: "child")])
        }
    }

    // MARK: - Key Description

    @Suite
    struct Description {
        @Test("Key description includes keyPath")
        func keyDescription() {
            let key = Key.from("users" / .wildcard)
            #expect(key.description.contains("users/*"))
        }

        @Test("DistinctKey description includes keyPath")
        func distinctKeyDescription() {
            let key = Key.from("user" / "name")
            #expect(key.description.contains("user/name"))
        }

        @Test("TypedKey description includes type name and keyPath")
        func typedKeyDescription() {
            let key = Key.from("users" / .wildcard, as: String.self)
            #expect(key.description.contains("String"))
            #expect(key.description.contains("users/*"))
        }

        @Test("TypedDistinctKey description includes type name and keyPath")
        func typedDistinctKeyDescription() {
            let key = Key.from("user" / "name", as: Int.self)
            #expect(key.description.contains("Int"))
            #expect(key.description.contains("user/name"))
        }
    }

    // MARK: - KeyComponent Utilities

    @Suite
    struct ComponentUtilities {
        @Test("isWildcard")
        func isWildcard() {
            #expect(KeyComponent.wildcard.isWildcard)
            #expect(!KeyComponent.globstar.isWildcard)
            #expect(!KeyComponent.segment(identifier: "x").isWildcard)
        }

        @Test("isGlobstar")
        func isGlobstar() {
            #expect(KeyComponent.globstar.isGlobstar)
            #expect(!KeyComponent.wildcard.isGlobstar)
            #expect(!KeyComponent.segment(identifier: "x").isGlobstar)
        }

        @Test("isPattern")
        func isPattern() {
            #expect(KeyComponent.wildcard.isPattern)
            #expect(KeyComponent.globstar.isPattern)
            #expect(!KeyComponent.segment(identifier: "x").isPattern)
        }
    }

    // MARK: - KeyError

    @Suite
    struct KeyErrorTests {
        @Test("KeyError.nonDistinctKey has errorDescription")
        func errorDescription() {
            let error = KeyError.nonDistinctKey
            #expect(error.errorDescription != nil)
            #expect(error.errorDescription!.contains("wildcards"))
        }
    }

    // MARK: - TypedDistinctKey Equatable/Hashable

    @Suite
    struct TypedDistinctKeyEquality {
        @Test("equal TypedDistinctKeys compare equal")
        func equality() {
            let k1 = Key.from("user" / "name", as: String.self)
            let k2 = Key.from("user" / "name", as: String.self)
            #expect(k1 == k2)
        }

        @Test("different TypedDistinctKeys compare unequal")
        func inequality() {
            let k1 = Key.from("user" / "name", as: String.self)
            let k2 = Key.from("user" / "age", as: String.self)
            #expect(k1 != k2)
        }

        @Test("TypedDistinctKeys work in a Set")
        func hashable() {
            let k1 = Key.from("a" / "b", as: Int.self)
            let k2 = Key.from("a" / "b", as: Int.self)
            let k3 = Key.from("a" / "c", as: Int.self)
            let set: Set<TypedDistinctKey<Int>> = [k1, k2, k3]
            #expect(set.count == 2)
        }
    }

    // MARK: - DistinctKey.typed(as:)

    @Suite
    struct DistinctKeyTyped {
        @Test("typed(as:) converts DistinctKey to TypedDistinctKey")
        func typedConversion() {
            let distinct: DistinctKey = Key.from("user" / "name")
            let typed: TypedDistinctKey<String> = distinct.typed(as: String.self)
            #expect(typed.components == distinct.components)
        }

        @Test("typed() infers type from context")
        func typedInferred() {
            let distinct: DistinctKey = Key.from("count")
            let typed: TypedDistinctKey<Int> = distinct.typed()
            #expect(typed.components == distinct.components)
        }
    }

    // MARK: - TypedKey.appending / append

    @Suite
    struct TypedKeyAppending {
        @Test("appending segment to TypedKey")
        func appendingSegment() {
            let base: TypedKey<String> = Key.from("items" / .wildcard).typed()
            let extended = base.appending(.segment(identifier: "name"))
            #expect(extended.components.count == 3)
            #expect(extended.components.last == .segment(identifier: "name"))
        }

        @Test("appending wildcard to TypedKey")
        func appendingWildcard() {
            let base: TypedKey<String> = Key.from("items", as: String.self).key.typed()
            let extended = base.appending(.wildcard)
            #expect(extended.components.last == .wildcard)
            #expect(!extended.isDistinct)
        }

        @Test("appending globstar to TypedKey")
        func appendingGlobstar() {
            let base: TypedKey<String> = Key.from("cache", as: String.self).key.typed()
            let extended = base.appending(.globstar)
            #expect(extended.components.last == .globstar)
        }

        @Test("appending string to TypedKey")
        func appendingString() {
            let base: TypedKey<Int> = Key.from("nums" / .wildcard).typed()
            let extended = base.appending("total")
            #expect(extended.components.last == .segment(identifier: "total"))
        }

        @Test("mutating append on TypedKey")
        func mutatingAppend() {
            var key: TypedKey<String> = Key.from("root", as: String.self).key.typed()
            key.append(.segment(identifier: "child"))
            #expect(key.components == [.segment(identifier: "root"), .segment(identifier: "child")])
        }

        @Test("mutating append string on TypedKey")
        func mutatingAppendString() {
            var key: TypedKey<String> = Key.from("root", as: String.self).key.typed()
            key.append("child")
            #expect(key.components == [.segment(identifier: "root"), .segment(identifier: "child")])
        }
    }

    // MARK: - KeyComponent.matches

    @Suite
    struct KeyComponentMatching {
        @Test("wildcard matches any component")
        func wildcardMatchesAny() {
            #expect(KeyComponent.wildcard.matches(.segment(identifier: "anything")))
            #expect(KeyComponent.wildcard.matches(.wildcard))
            #expect(KeyComponent.wildcard.matches(.globstar))
        }

        @Test("globstar matches any component")
        func globstarMatchesAny() {
            #expect(KeyComponent.globstar.matches(.segment(identifier: "x")))
            #expect(KeyComponent.globstar.matches(.wildcard))
            #expect(KeyComponent.globstar.matches(.globstar))
        }

        @Test("segment matches same segment")
        func segmentMatchesSame() {
            let a = KeyComponent.segment(identifier: "hello")
            let b = KeyComponent.segment(identifier: "hello")
            #expect(a.matches(b))
        }

        @Test("segment does not match different segment")
        func segmentDoesNotMatchDifferent() {
            let a = KeyComponent.segment(identifier: "hello")
            let b = KeyComponent.segment(identifier: "world")
            #expect(!a.matches(b))
        }

        @Test("segment does not match wildcard")
        func segmentDoesNotMatchWildcard() {
            let seg = KeyComponent.segment(identifier: "x")
            #expect(!seg.matches(.wildcard))
        }

        @Test("segment does not match globstar")
        func segmentDoesNotMatchGlobstar() {
            let seg = KeyComponent.segment(identifier: "x")
            #expect(!seg.matches(.globstar))
        }
    }

    // MARK: - Key.appending segment path

    @Suite
    struct KeyAppendingTests {
        @Test("Key.appending with segment component")
        func keyAppendingSegment() {
            let base = Key([.segment(identifier: "root")])
            let result = base.appending(.segment(identifier: "child"))
            #expect(result.components == [.segment(identifier: "root"), .segment(identifier: "child")])
            #expect(result.isDistinct)
        }

        @Test("Key.appending segment to pattern key remains pattern")
        func keyAppendingSegmentToPattern() {
            let base = Key([.wildcard])
            let result = base.appending(.segment(identifier: "leaf"))
            #expect(result.components.count == 2)
            #expect(!result.isDistinct)
        }
    }
}
