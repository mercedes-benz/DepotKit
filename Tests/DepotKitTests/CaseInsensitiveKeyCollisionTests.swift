// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

/// Identifiers whose Base64 encodings differ only by letter case must
/// stay independent on the host's temporary directory, which is a
/// case-insensitive APFS volume on default macOS installations.
@Suite
struct CaseInsensitiveKeyCollisionTests {
    enum Placement: String, CaseIterable, Sendable {
        case leaf
        case directory
    }

    /// The answer of the volume case-sensitivity query.
    enum Volume: String, CaseIterable, Sendable {
        /// The real query for the host's temporary directory.
        case real
        /// Reported as case-insensitive.
        case caseInsensitive
        /// The query fails.
        case unknown

        /// The answers for which identifiers differing only in case must stay distinct on the
        /// host's temporary directory. A failed query falls back to Base32 only on macOS volumes
        /// (macOS, Mac Catalyst and the Simulator).
        static var tested: [Volume] {
            DepotFileNameCodec.platformFallback == .base32 ? allCases : [.real, .caseInsensitive]
        }
    }

    private static func keys(_ placement: Placement) -> (TypedDistinctKey<Int>, TypedDistinctKey<Int>) {
        // Base64: "aaa" → "YWFh", "aaG" → "YWFH" (differ only by case).
        switch placement {
        case .leaf:
            (Key.from("aaa", as: Int.self), Key.from("aaG", as: Int.self))
        case .directory:
            (Key.from("aaa" / "value", as: Int.self), Key.from("aaG" / "value", as: Int.self))
        }
    }

    private static func makeDepot(at url: URL, cache: Bool, volume: Volume = .real) -> Depot {
        let configuration = DepotConfiguration(directoryURL: url, memoryCache: cache ? .default : .disabled)
        let depot =
            switch volume {
            case .real:
                Depot(configuration: configuration)
            case .caseInsensitive:
                Depot(configuration: configuration, overrides: .init(volumeSupportsCaseSensitiveNames: { _ in false }))
            case .unknown:
                Depot(configuration: configuration, overrides: .init(volumeSupportsCaseSensitiveNames: { _ in nil }))
            }
        depot.register(key: Key.all, coder: .json() as AnyCoder<Int>)
        switch volume {
        case .real:
            break
        case .caseInsensitive:
            #expect(depot.fileManager?.fileNameCodec == .base32)
        case .unknown:
            #expect(depot.fileManager?.fileNameCodec == DepotFileNameCodec.platformFallback)
        }
        return depot
    }

    @Test(
        "colliding Base64 spellings stay independent",
        arguments: Placement.allCases,
        Volume.tested,
    )
    func independentValues(placement: Placement, volume: Volume) throws {
        for cache in [false, true] {
            try independentValues(placement: placement, volume: volume, cache: cache)
        }
    }

    private func independentValues(placement: Placement, volume: Volume, cache: Bool) throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }

        let (lower, upper) = Self.keys(placement)
        let depot = Self.makeDepot(at: url, cache: cache, volume: volume)

        try depot.set(value: 1, for: lower)
        try depot.set(value: 2, for: upper)
        #expect(try depot.get(valueFor: lower) == 1)
        #expect(try depot.get(valueFor: upper) == 2)

        depot.clearCache()
        #expect(try depot.get(valueFor: lower) == 1)
        #expect(try depot.get(valueFor: upper) == 2)

        let all = try depot.get(availableValuesFor: Key.all.typed(as: Int.self))
        #expect(all.keyedValues == [DistinctKey(lower): 1, DistinctKey(upper): 2])
        #expect(try depot.count(for: Key.all) == 2)

        // Reopen.
        let reopened = Self.makeDepot(at: url, cache: cache, volume: volume)
        #expect(try reopened.get(valueFor: lower) == 1)
        #expect(try reopened.get(valueFor: upper) == 2)
        #expect(try reopened.count(for: Key.all) == 2)

        // Independent removal.
        try reopened.remove(valueFor: lower)
        #expect(try reopened.get(valueFor: lower) == nil)
        #expect(try reopened.get(valueFor: upper) == 2)
        reopened.clearCache()
        #expect(try reopened.get(valueFor: upper) == 2)
        #expect(try reopened.count(for: Key.all) == 1)

        // Independent overwrite.
        try reopened.set(value: 3, for: lower)
        reopened.clearCache()
        #expect(try reopened.get(valueFor: lower) == 3)
        #expect(try reopened.get(valueFor: upper) == 2)

        let final = Self.makeDepot(at: url, cache: cache, volume: volume)
        let values = try final.get(availableValuesFor: Key.all.typed(as: Int.self))
        #expect(values.keyedValues == [DistinctKey(lower): 3, DistinctKey(upper): 2])
    }

    @Test(
        "colliding directory components keep separate pattern enumeration and removal",
        arguments: Volume.tested,
    )
    func directoryPatternsStayIndependent(volume: Volume) throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }

        let depot = Self.makeDepot(at: url, cache: false, volume: volume)
        try depot.set(value: 1, for: Key.from("aaa" / "x", as: Int.self))
        try depot.set(value: 2, for: Key.from("aaa" / "y", as: Int.self))
        try depot.set(value: 3, for: Key.from("aaG" / "x", as: Int.self))

        #expect(try depot.count(for: Key.from("aaa" / .wildcard)) == 2)
        #expect(try depot.count(for: Key.from("aaG" / .wildcard)) == 1)

        try depot.remove(valuesFor: Key.from("aaa" / .wildcard))
        #expect(try depot.count(for: Key.from("aaa" / .wildcard)) == 0)
        #expect(try depot.get(valueFor: Key.from("aaG" / "x", as: Int.self)) == 3)
    }
}
