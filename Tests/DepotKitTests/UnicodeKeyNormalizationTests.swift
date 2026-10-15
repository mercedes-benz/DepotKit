// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

/// Canonically equivalent identifiers are the same key everywhere —
/// in memory, on disk, after cache eviction and after reopening.
@Suite
struct UnicodeKeyNormalizationTests {
    struct Spelling: Sendable, CustomTestStringConvertible {
        let name: String
        let composed: String
        let decomposed: String

        var testDescription: String { name }
    }

    static let spellings = [
        Spelling(name: "e acute", composed: "caf\u{E9}", decomposed: "cafe\u{301}"),
        Spelling(
            name: "Hangul",
            composed: "\u{D55C}\u{AE00}",
            decomposed: "\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}"
        ),
        Spelling(name: "Angstrom sign", composed: "\u{00C5}ngstr\u{F6}m", decomposed: "\u{212B}ngstro\u{308}m"),
    ]

    enum Placement: String, CaseIterable, Sendable {
        case leaf
        case directory
    }

    private static func key(_ identifier: String, _ placement: Placement) -> TypedDistinctKey<String> {
        switch placement {
        case .leaf:
            Key.from("names" / identifier, as: String.self)
        case .directory:
            Key.from(.component(identifier) / "value", as: String.self)
        }
    }

    private static func makeDepot(at url: URL, cache: Bool) -> Depot {
        let depot = Depot(configuration: .init(directoryURL: url, memoryCache: cache ? .default : .disabled))
        depot.register(key: Key.all, coder: .json() as AnyCoder<String>)
        return depot
    }

    @Test("equivalent spellings read the same value", arguments: spellings, Placement.allCases)
    func equivalentSpellingsShareStorage(spelling: Spelling, placement: Placement) throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }

        let written = Self.key(spelling.decomposed, placement)
        let read = Self.key(spelling.composed, placement)

        let depot = Self.makeDepot(at: url, cache: true)
        try depot.set(value: "stored", for: written)

        // Warm cache.
        #expect(try depot.get(valueFor: read) == "stored")

        // After eviction.
        depot.clearCache()
        #expect(try depot.get(valueFor: read) == "stored")
        #expect(try depot.has(valueFor: read))

        // After reopening, with and without a cache.
        for cache in [true, false] {
            let reopened = Self.makeDepot(at: url, cache: cache)
            #expect(try reopened.get(valueFor: read) == "stored")
            #expect(try reopened.get(valueFor: written) == "stored")
        }

        // Writing through the other spelling replaces, it does not duplicate.
        try depot.set(value: "replaced", for: read)
        depot.clearCache()
        #expect(try depot.get(valueFor: written) == "replaced")
        #expect(try depot.count(for: Key.all) == 1)

        // Enumeration returns one canonical (NFC) key that equals both spellings.
        let available = try Self.makeDepot(at: url, cache: false)
            .get(availableValuesFor: Key.all.typed(as: String.self))
        #expect(available.keyedValues.count == 1)
        let enumeratedKey = try #require(available.keyedValues.keys.first)
        #expect(enumeratedKey == DistinctKey(read))
        #expect(enumeratedKey == DistinctKey(written))
        for case let .segment(identifier) in enumeratedKey.components {
            #expect(Array(identifier.utf8) == Array(identifier.precomposedStringWithCanonicalMapping.utf8))
        }

        // Pattern matching agrees with reads.
        let pattern: Key =
            switch placement {
            case .leaf: Key.from("names" / .wildcard)
            case .directory: Key.from(.component(spelling.composed) / .wildcard)
            }
        #expect(try depot.count(for: pattern) == 1)

        // Removal through the other spelling removes the stored file.
        try depot.remove(valueFor: written)
        #expect(try depot.get(valueFor: read) == nil)
        let cold = Self.makeDepot(at: url, cache: false)
        #expect(try cold.get(valueFor: read) == nil)
        #expect(try cold.count(for: Key.all) == 0)
    }

    @Test("pattern removal with one spelling removes values written with the other", arguments: spellings)
    func patternRemovalAgrees(spelling: Spelling) throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }

        let depot = Self.makeDepot(at: url, cache: true)
        try depot.set(value: "a", for: Key.from(.component(spelling.decomposed) / "a", as: String.self))
        try depot.set(value: "b", for: Key.from(.component(spelling.decomposed) / "b", as: String.self))

        try depot.remove(valuesFor: Key.from(.component(spelling.composed) / .wildcard))
        #expect(try depot.count(for: Key.all) == 0)
        depot.clearCache()
        #expect(try depot.get(valueFor: Key.from(.component(spelling.composed) / "a", as: String.self)) == nil)
    }

    @Test("transactions see equivalent spellings as the same key", arguments: spellings)
    func transactionsAgree(spelling: Spelling) throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }

        let depot = Self.makeDepot(at: url, cache: false)
        try depot.transaction { tx in
            try tx.set(value: "tx", for: Key.from(.component(spelling.decomposed), as: String.self))
        }

        let reopened = Self.makeDepot(at: url, cache: false)
        #expect(try reopened.get(valueFor: Key.from(.component(spelling.composed), as: String.self)) == "tx")
    }

    private struct RawKey: TypedDistinctKeyProtocol {
        typealias Value = String
        let components: [KeyComponent]
        var isDistinct: Bool { true }
    }

    private struct RawPattern: TypedKeyProtocol {
        typealias Value = String
        let components: [KeyComponent]
        var isDistinct: Bool { false }
    }

    @Test(
        "custom key types with decomposed identifiers survive cold reads, reopening and transactions",
        arguments: spellings,
        [false, true],
    )
    func customKeyTypesPersistCanonically(spelling: Spelling, cache: Bool) throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let configuration = DepotConfiguration(directoryURL: url, memoryCache: cache ? .default : .disabled)

        let depot = Depot(configuration: configuration)
        let pattern = depot.register(
            key: RawPattern(components: [.segment(identifier: spelling.decomposed), .globstar]),
            coder: .json(String.self),
        )
        let original = RawKey(components: [
            .segment(identifier: spelling.decomposed), .segment(identifier: spelling.decomposed),
        ])
        let equivalent = Key.from(.component(spelling.composed) / spelling.composed, as: String.self)
        #expect(pattern.matches(equivalent))

        try depot.set(value: "first", for: original)
        #expect(try depot.get(valueFor: equivalent) == "first")
        depot.clearCache()
        #expect(try depot.get(valueFor: equivalent) == "first")
        #expect(try depot.get(valuesFor: pattern) == ["first"])

        let reopened = Depot(configuration: configuration)
        reopened.register(key: Key.from(.component(spelling.composed) / .globstar), coder: .json(String.self))
        #expect(try reopened.get(valueFor: original) == "first")
        try reopened.transaction { transaction in
            #expect(try transaction.get(valueFor: original) == "first")
            try transaction.set(value: "second", for: equivalent)
        }
        reopened.clearCache()
        #expect(try reopened.get(valueFor: original) == "second")
        #expect(try reopened.count(for: pattern) == 1)
        try reopened.remove(valueFor: original)
        #expect(try reopened.get(valueFor: equivalent) == nil)
        #expect(try reopened.count(for: pattern) == 0)
    }

    @Test(
        "observers of decomposed custom keys receive values written with the composed spelling",
        arguments: spellings,
        [false, true],
    )
    func observationUsesCanonicalKeys(spelling: Spelling, memoryOnly: Bool) async throws {
        let depot = memoryOnly ? Depot() : Depot.temporary()
        defer {
            if let url = depot.configuration.directoryURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let rawPattern = RawPattern(components: [.segment(identifier: spelling.decomposed), .globstar])
        let registered = depot.register(key: rawPattern, coder: .json(String.self))
        #expect(Array(registered.keyPath.utf8) == Array("\(spelling.composed)/**".utf8))

        let original = RawKey(components: [
            .segment(identifier: spelling.decomposed), .segment(identifier: spelling.decomposed),
        ])
        let equivalent = Key.from(.component(spelling.composed) / spelling.composed, as: String.self)
        try await depot.set(value: "first", for: original)
        await depot.clearCache()

        var single = depot.values(for: original).makeAsyncIterator()
        var multiple = depot.values(for: rawPattern).makeAsyncIterator()
        var available = depot.availableValues(for: rawPattern).makeAsyncIterator()
        await depot.waitForPendingObservations()
        #expect(try await single.next()?.get() == "first")
        #expect(try await multiple.next()?.get() == ["first"])
        #expect(try await available.next()?.get().keyedValues == [DistinctKey(equivalent): "first"])

        try await depot.set(value: "second", for: equivalent)
        await depot.waitForPendingObservations()
        #expect(try await single.next()?.get() == "second")
        #expect(try await multiple.next()?.get() == ["second"])
        #expect(try await available.next()?.get().keyedValues == [DistinctKey(equivalent): "second"])

        try await depot.remove(valueFor: original)
        await depot.waitForPendingObservations()
        let removed = try #require(await single.next())
        #expect(try removed.get() == nil)
        #expect(try await multiple.next()?.get() == [])
        #expect(try await available.next()?.get().keyedValues.isEmpty == true)
    }
}
