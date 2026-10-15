// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// Runs the same pattern scenarios against memory-only and file-backed depots
/// and asserts that every query and removal operation agrees with the
/// key-matching contract (`Key.matches`), emitting each concrete key exactly
/// once.
///
/// All stored values are equal, so any key-level duplication or omission
/// shows up in counts instead of being hidden by value-based comparisons.
@Suite(.offCooperativePool)
struct GlobstarMatchingMatrixTests {
    struct Scenario: Sendable, CustomTestStringConvertible {
        let name: String
        let pattern: String
        let stored: [String]
        let expected: Set<String>

        var testDescription: String {
            "\(name): \(pattern)"
        }
    }

    enum Mode: String, Sendable, CaseIterable, CustomTestStringConvertible {
        case memoryOnly
        case fileBacked
        case fileBackedCached

        var testDescription: String {
            rawValue
        }

        func makeDepot() -> Depot {
            switch self {
            case .memoryOnly:
                Depot()
            case .fileBacked:
                Depot.temporary()
            case .fileBackedCached:
                Depot.temporary(memoryCache: .default)
            }
        }
    }

    static let storedValue = 7

    static let scenarios: [Scenario] = [
        Scenario(
            name: "trailing globstar, prefix only",
            pattern: "users/**",
            stored: ["users", "other"],
            expected: [],
        ),
        Scenario(
            name: "trailing globstar, prefix and descendants",
            pattern: "users/**",
            stored: ["users", "users/alice", "users/alice/settings", "usersX", "other", "other/users"],
            expected: ["users/alice", "users/alice/settings"],
        ),
        Scenario(
            name: "trailing globstar, missing prefix value",
            pattern: "users/**",
            stored: ["users/alice", "users/bob/settings", "other"],
            expected: ["users/alice", "users/bob/settings"],
        ),
        Scenario(
            name: "trailing globstar, nothing stored under prefix",
            pattern: "users/**",
            stored: ["other", "other/users"],
            expected: [],
        ),
        Scenario(
            name: "nested trailing globstar",
            pattern: "app/users/**",
            stored: ["app", "app/users", "app/users/alice", "app/other"],
            expected: ["app/users/alice"],
        ),
        Scenario(
            name: "leading globstar",
            pattern: "**/x",
            stored: ["x", "a/x", "a/b/x", "a/x/b", "xa", "a"],
            expected: ["x", "a/x", "a/b/x"],
        ),
        Scenario(
            name: "middle globstar",
            pattern: "a/**/z",
            stored: ["a", "z", "a/z", "a/b/z", "a/b/c/z", "a/z/q", "b/z"],
            expected: ["a/z", "a/b/z", "a/b/c/z"],
        ),
        Scenario(
            name: "multiple globstars, repeated segment",
            pattern: "**/x/**",
            stored: ["a/x/b/x/c", "x", "x/x", "x/x/x", "a/x", "b", "b/c"],
            expected: ["a/x/b/x/c", "x/x", "x/x/x"],
        ),
        Scenario(
            name: "multiple globstars, deeply repeated segment",
            pattern: "**/a/**/a/**",
            stored: ["a", "a/a", "a/a/a", "a/a/a/a", "a/b/a/b", "b/a"],
            expected: ["a/a/a", "a/a/a/a", "a/b/a/b"],
        ),
        Scenario(
            name: "repeated segments with middle globstar",
            pattern: "a/**/a",
            stored: ["a", "a/a", "a/a/a", "a/b/a", "a/a/b"],
            expected: ["a/a", "a/a/a", "a/b/a"],
        ),
        Scenario(
            name: "wildcard then trailing globstar",
            pattern: "users/*/**",
            stored: ["users", "users/alice", "users/alice/settings", "users/bob/a/b", "other/alice"],
            expected: ["users/alice/settings", "users/bob/a/b"],
        ),
        Scenario(
            name: "leading wildcard then globstar",
            pattern: "*/**",
            stored: ["a", "a/b", "a/b/c"],
            expected: ["a/b", "a/b/c"],
        ),
        Scenario(
            name: "globstar then wildcard",
            pattern: "**/*",
            stored: ["a", "a/b", "a/b/c"],
            expected: ["a", "a/b", "a/b/c"],
        ),
        Scenario(
            name: "globstar, wildcard, segment, globstar",
            pattern: "**/*/x/**",
            stored: ["x", "a/x", "a/x/x", "a/x/b/x", "a/b/x/c", "x/a"],
            expected: ["a/x/x", "a/x/b/x", "a/b/x/c"],
        ),
        Scenario(
            name: "wildcard between globstars",
            pattern: "**/*/**",
            stored: ["a", "a/b", "a/b/c"],
            expected: ["a/b", "a/b/c"],
        ),
        Scenario(
            name: "trailing globstar after a leading globstar",
            pattern: "**/x/**",
            stored: ["x", "a/x", "x/y", "a/x/y", "a/b/x/y/z"],
            expected: ["x/y", "a/x/y", "a/b/x/y/z"],
        ),
        Scenario(
            name: "wildcard below a prefix value",
            pattern: "users/*",
            stored: ["users", "users/alice", "users/alice/settings"],
            expected: ["users/alice"],
        ),
        Scenario(
            name: "globstar only",
            pattern: "**",
            stored: ["a", "a/b", "c/d/e"],
            expected: ["a", "a/b", "c/d/e"],
        ),
        Scenario(
            name: "distinct key",
            pattern: "users/alice",
            stored: ["users", "users/alice", "users/alice/settings"],
            expected: ["users/alice"],
        ),
    ]

    // MARK: - Matrix

    @Test(arguments: scenarios, Mode.allCases)
    func queriesAgreeWithKeyMatching(scenario: Scenario, mode: Mode) throws {
        let pattern = Self.key(scenario.pattern)
        try Self.verifyOracle(scenario)

        let depot = try Self.makeDepot(for: scenario, mode: mode)
        let typedPattern = TypedKey<Int>(pattern.components)
        let expectedKeys = Set(scenario.expected.map { Self.distinctKey($0) })

        let values = try depot.get(valuesFor: typedPattern)
        #expect(values.count == scenario.expected.count)
        #expect(values.allSatisfy { $0 == Self.storedValue })

        let available = try depot.get(availableValuesFor: typedPattern)
        #expect(Set(available.keyedValues.keys) == expectedKeys)
        #expect(available.keyedErrors.isEmpty)

        #expect(try depot.count(for: pattern) == scenario.expected.count)
        #expect(try depot.has(valuesFor: pattern) == !scenario.expected.isEmpty)

        let transactionResults = try depot.transaction { tx in
            (
                count: try tx.count(for: pattern),
                values: try tx.get(valuesFor: typedPattern),
                has: try tx.has(valuesFor: pattern),
            )
        }
        #expect(transactionResults.count == scenario.expected.count)
        #expect(transactionResults.values.count == scenario.expected.count)
        #expect(transactionResults.has == !scenario.expected.isEmpty)

        if mode != .memoryOnly {
            depot.clearCache()
            #expect(try depot.get(valuesFor: typedPattern).count == scenario.expected.count)
            #expect(try depot.has(valuesFor: pattern) == !scenario.expected.isEmpty)

            let files = try #require(depot.fileManager).files(for: pattern)
            #expect(Set(files.map(\.key)) == expectedKeys)
            #expect(files.count == scenario.expected.count)
            #expect(Set(files.map { $0.fileURL.standardizedFileURL.path }).count == files.count)
        }
    }

    @Test(arguments: scenarios, Mode.allCases)
    func removalAgreesWithKeyMatching(scenario: Scenario, mode: Mode) throws {
        let pattern = Self.key(scenario.pattern)
        let depot = try Self.makeDepot(for: scenario, mode: mode)

        try depot.remove(valuesFor: pattern)

        let expectedRemaining = Set(scenario.stored).subtracting(scenario.expected)
        #expect(try Self.storedKeys(in: depot, from: scenario.stored) == expectedRemaining)
        #expect(try depot.count(for: pattern) == 0)
        #expect(try depot.has(valuesFor: pattern) == false)

        if mode != .memoryOnly {
            depot.clearCache()
            #expect(try Self.storedKeys(in: depot, from: scenario.stored) == expectedRemaining)
        }
    }

    @Test(arguments: scenarios.filter { $0.pattern != "**" })
    func fileRemovalVisitsEachFileOnce(scenario: Scenario) throws {
        let pattern = Self.key(scenario.pattern)
        let attemptedRemovals = OSAllocatedUnfairLock(initialState: [URL]())
        var hooks = Depot.TestHooks()
        hooks.willRemoveItem = { url in attemptedRemovals.withLock { $0.append(url.resolvingSymlinksInPath()) } }
        let depot = Depot(
            configuration: .init(
                directoryURL: FileManager.default.temporaryDirectory.appending(component: UUID().uuidString),
                memoryCache: .disabled,
            ),
            overrides: .init(testHooks: hooks),
        )
        _ = depot.register(key: Key.all, coder: .json() as AnyCoder<Int>)
        _ = depot.register(key: pattern, coder: .json() as AnyCoder<Int>)
        for path in scenario.stored {
            try depot.set(value: Self.storedValue, for: TypedDistinctKey<Int>(Self.distinctKey(path).components))
        }
        let expectedURLs = try scenario.expected.map {
            try depot.fileURL(for: Self.distinctKey($0)).resolvingSymlinksInPath()
        }

        try depot.remove(valuesFor: pattern)

        let removedURLs = attemptedRemovals.withLock { $0 }
        #expect(removedURLs.count == scenario.expected.count)
        #expect(Set(removedURLs) == Set(expectedURLs))
        #expect(try #require(depot.fileManager).files(for: pattern).isEmpty)
    }

    @Test(arguments: scenarios)
    func diskUsageAgreesWithKeyMatching(scenario: Scenario) throws {
        let pattern = Self.key(scenario.pattern)
        let depot = try Self.makeDepot(for: scenario, mode: .fileBacked)

        // `diskUsage(under:)` measures every value the prefix matches and everything below it.
        let expectedCount = scenario.stored.count { path in
            let components = Self.distinctKey(path).components
            return (1...components.count).contains { pattern.matches(DistinctKey(Array(components.prefix($0)))) }
        }

        let usage = try depot.diskUsage(under: pattern)
        #expect(usage.fileCount == expectedCount)

        let singleFileSize = try Self.fileSize(of: Self.distinctKey(scenario.stored[0]), in: depot)
        #expect(usage.totalBytes == Int64(expectedCount) * singleFileSize)
    }

    @Test(arguments: Mode.allCases)
    func hiddenAndForeignFilesAreNotMatched(mode: Mode) throws {
        let depot = mode.makeDepot()
        _ = depot.register(key: Key.all, coder: .json() as AnyCoder<Int>)
        try depot.set(value: Self.storedValue, for: TypedDistinctKey<Int>(Self.distinctKey("users/alice").components))

        if let depotURL = depot.configuration.directoryURL {
            let usersDirectory = try depot.fileURL(for: Self.distinctKey("users/alice")).deletingLastPathComponent()
            try Data().write(to: usersDirectory.appending(component: ".hidden.bin"))
            try Data().write(to: usersDirectory.appending(component: "not+valid.bin"))
            try Data().write(to: depotURL.appending(component: ".FS_FOREIGN.bin"))
        }

        let pattern = Self.key("users/**")
        #expect(try depot.count(for: pattern) == 1)
        #expect(try depot.count(for: Key.all) == 1)
        #expect(try depot.get(valuesFor: TypedKey<Int>(pattern.components)) == [Self.storedValue])
    }

    // MARK: - Helpers

    static func key(_ path: String) -> Key {
        Key(
            path.split(separator: "/").map { part -> KeyComponent in
                switch part {
                case "*": .wildcard
                case "**": .globstar
                default: .segment(identifier: String(part))
                }
            }
        )
    }

    static func distinctKey(_ path: String) -> DistinctKey {
        DistinctKey(path.split(separator: "/").map { .segment(identifier: String($0)) })
    }

    /// The expected sets are written out by hand; make sure they agree with `Key.matches`.
    static func verifyOracle(_ scenario: Scenario) throws {
        let pattern = key(scenario.pattern)
        let matched = Set(scenario.stored.filter { pattern.matches(distinctKey($0)) })
        #expect(matched == scenario.expected, "Key.matches disagrees with the scenario's expected keys")
    }

    static func makeDepot(for scenario: Scenario, mode: Mode) throws -> Depot {
        let depot = mode.makeDepot()
        _ = depot.register(key: Key.all, coder: .json() as AnyCoder<Int>)
        _ = depot.register(key: key(scenario.pattern), coder: .json() as AnyCoder<Int>)

        for path in scenario.stored {
            try depot.set(value: storedValue, for: TypedDistinctKey<Int>(distinctKey(path).components))
        }

        return depot
    }

    static func storedKeys(in depot: Depot, from candidates: [String]) throws -> Set<String> {
        var result = Set<String>()
        for path in candidates {
            let key = TypedDistinctKey<Int>(distinctKey(path).components)
            if try depot.get(valueFor: key) != nil {
                result.insert(path)
            }
        }
        return result
    }

    static func fileSize(of key: DistinctKey, in depot: Depot) throws -> Int64 {
        let url = try depot.fileURL(for: key)
        let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        return Int64(size)
    }
}
