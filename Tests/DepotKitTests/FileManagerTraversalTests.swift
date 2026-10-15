// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

@Suite
struct FileManagerTraversalTests {
    // MARK: - Nested Directory Traversal (globstar)

    @Test("get valuesFor globstar matches deeply nested keys")
    func globstarDeepNesting() throws {
        let depot = Depot.temporary()
        let pattern = depot.register(
            key: Key.from("root" / .globstar),
            coder: .json() as AnyCoder<String>,
        )

        let key1 = Key.from("root" / "a", as: String.self)
        let key2 = Key.from("root" / "a" / "b", as: String.self)
        let key3 = Key.from("root" / "a" / "b" / "c", as: String.self)

        try depot.set(value: "L1", for: key1)
        try depot.set(value: "L2", for: key2)
        try depot.set(value: "L3", for: key3)

        let values = try depot.get(valuesFor: pattern)
        #expect(Set(values) == ["L1", "L2", "L3"])
    }

    @Test("has valuesFor globstar finds nested values")
    func globstarHasNested() throws {
        let depot = Depot.temporary()
        _ = depot.register(key: Key.from("deep" / .globstar), coder: .json() as AnyCoder<Int>)
        let key = Key.from("deep" / "a" / "b" / "c", as: Int.self)
        try depot.set(value: 42, for: key)

        let has = try depot.has(valuesFor: Key.from("deep" / .globstar))
        #expect(has == true)
    }

    @Test("has valuesFor returns false for empty globstar")
    func globstarHasEmpty() throws {
        let depot = Depot.temporary()
        _ = depot.register(key: Key.from("empty" / .globstar), coder: .json() as AnyCoder<Int>)

        let has = try depot.has(valuesFor: Key.from("empty" / .globstar))
        #expect(has == false)
    }

    // MARK: - Wildcard with Nested Structure

    @Test("wildcard matches only one level")
    func wildcardSingleLevel() throws {
        let depot = Depot.temporary()
        let pattern = depot.register(
            key: Key.from("items" / .wildcard),
            coder: .json() as AnyCoder<String>,
        )

        let shallow = Key.from("items" / "x", as: String.self)
        let deep = Key.from("items" / "x" / "nested", as: String.self)

        // Register the deep path pattern too
        _ = depot.register(key: Key.from("items" / .wildcard / "nested"), coder: .json() as AnyCoder<String>)

        try depot.set(value: "shallow", for: shallow)
        try depot.set(value: "deep", for: deep)

        let values = try depot.get(valuesFor: pattern)
        #expect(values == ["shallow"])
    }

    @Test("wildcard in middle matches correct level")
    func wildcardMiddle() throws {
        let depot = Depot.temporary()
        let pattern = depot.register(
            key: Key.from("users" / .wildcard / "name"),
            coder: .json() as AnyCoder<String>,
        )

        let key1 = Key.from("users" / "alice" / "name", as: String.self)
        let key2 = Key.from("users" / "bob" / "name", as: String.self)
        let key3 = Key.from("users" / "alice" / "age", as: String.self)

        // Register age pattern too
        _ = depot.register(key: Key.from("users" / .wildcard / "age"), coder: .json() as AnyCoder<String>)

        try depot.set(value: "Alice", for: key1)
        try depot.set(value: "Bob", for: key2)
        try depot.set(value: "30", for: key3)

        let names = try depot.get(valuesFor: pattern)
        #expect(Set(names) == ["Alice", "Bob"])
    }

    // MARK: - Remove with Patterns

    @Test("remove with globstar clears nested structure")
    func removeGlobstarNested() throws {
        let depot = Depot.temporary()
        _ = depot.register(key: Key.from("cache" / .globstar), coder: .json() as AnyCoder<String>)

        let key1 = Key.from("cache" / "a", as: String.self)
        let key2 = Key.from("cache" / "a" / "b", as: String.self)
        let key3 = Key.from("cache" / "x" / "y" / "z", as: String.self)

        try depot.set(value: "1", for: key1)
        try depot.set(value: "2", for: key2)
        try depot.set(value: "3", for: key3)

        try depot.remove(valuesFor: Key.from("cache" / .globstar))

        let has = try depot.has(valuesFor: Key.from("cache" / .globstar))
        #expect(has == false)
    }

    @Test("remove with wildcard only removes one level")
    func removeWildcardOneLevel() throws {
        let depot = Depot.temporary()
        _ = depot.register(key: Key.from("data" / .wildcard), coder: .json() as AnyCoder<String>)
        _ = depot.register(key: Key.from("data" / .wildcard / "sub"), coder: .json() as AnyCoder<String>)

        let shallow = Key.from("data" / "a", as: String.self)
        let deep = Key.from("data" / "a" / "sub", as: String.self)

        try depot.set(value: "top", for: shallow)
        try depot.set(value: "nested", for: deep)

        try depot.remove(valuesFor: Key.from("data" / .wildcard))

        // Shallow removed, deep still there
        #expect(try depot.get(valueFor: shallow) == nil)
        #expect(try depot.get(valueFor: deep) == "nested")
    }

    // MARK: - Globstar at Start

    @Test("globstar at start matches everything under root")
    func globstarAtStart() throws {
        let depot = Depot.temporary()
        let pattern = depot.register(
            key: Key.all,
            coder: .json() as AnyCoder<String>,
        )

        let key1 = Key.from("a", as: String.self)
        let key2 = Key.from("a" / "b", as: String.self)
        let key3 = Key.from("x" / "y" / "z", as: String.self)

        try depot.set(value: "1", for: key1)
        try depot.set(value: "2", for: key2)
        try depot.set(value: "3", for: key3)

        let values = try depot.get(valuesFor: pattern)
        #expect(values.count == 3)
    }

    // MARK: - Mixed Patterns

    @Test("globstar followed by wildcard matches correctly")
    func globstarThenWildcard() throws {
        let depot = Depot.temporary()
        let pattern = depot.register(
            key: Key.from("root" / .globstar / .wildcard),
            coder: .json() as AnyCoder<String>,
        )

        // "root/a" — globstar matches zero, wildcard matches "a"
        let key1 = Key.from("root" / "a", as: String.self)
        // "root/x/y" — globstar matches "x", wildcard matches "y"
        let key2 = Key.from("root" / "x" / "y", as: String.self)

        try depot.set(value: "A", for: key1)
        try depot.set(value: "B", for: key2)

        let values = try depot.get(valuesFor: pattern)
        #expect(Set(values) == ["A", "B"])
    }

    // MARK: - Disk Usage with Nested Keys

    @Test("diskUsage counts files at one level")
    func diskUsageOneLevel() throws {
        let depot = Depot.temporary()
        _ = depot.register(key: Key.from("ns" / .wildcard), coder: .json() as AnyCoder<String>)

        let key1 = Key.from("ns" / "a", as: String.self)
        let key2 = Key.from("ns" / "b", as: String.self)

        try depot.set(value: "val1", for: key1)
        try depot.set(value: "val2", for: key2)

        let usage = try depot.diskUsage(under: Key.from("ns"))
        #expect(usage.fileCount == 2)
        #expect(usage.totalBytes > 0)
    }

    @Test("diskUsage with no prefix counts all files")
    func diskUsageAll() throws {
        let depot = Depot.temporary()
        _ = depot.register(key: Key.from("a" / .wildcard), coder: .json() as AnyCoder<String>)

        let key1 = Key.from("a" / "1", as: String.self)
        let key2 = Key.from("a" / "2", as: String.self)

        try depot.set(value: "x", for: key1)
        try depot.set(value: "y", for: key2)

        let usage = try depot.diskUsage()
        #expect(usage.fileCount >= 2)
    }

    // MARK: - availableValuesFor with nested patterns

    @Test("availableValuesFor with globstar collects nested values")
    func availableValuesGlobstar() throws {
        let depot = Depot.temporary()
        let pattern = depot.register(
            key: Key.from("data" / .globstar),
            coder: .json() as AnyCoder<Int>,
        )

        let key1 = Key.from("data" / "a", as: Int.self)
        let key2 = Key.from("data" / "b" / "c", as: Int.self)

        try depot.set(value: 1, for: key1)
        try depot.set(value: 2, for: key2)

        let result = try depot.get(availableValuesFor: pattern)
        #expect(Set(result.values) == [1, 2])
        #expect(result.errors.isEmpty)
    }

    // MARK: - has with wildcard in nested directories

    @Test("has with wildcard in middle checks nested dirs")
    func hasWildcardMiddle() throws {
        let depot = Depot.temporary()
        _ = depot.register(key: Key.from("a" / .wildcard / "b"), coder: .json() as AnyCoder<String>)
        let key = Key.from("a" / "x" / "b", as: String.self)
        try depot.set(value: "v", for: key)

        #expect(try depot.has(valuesFor: Key.from("a" / .wildcard / "b")) == true)
        #expect(try depot.has(valuesFor: Key.from("a" / .wildcard / "c")) == false)
    }

    // MARK: - Multi-process file operations

    @Test("touchLock creates and updates lock file")
    func touchLock() throws {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let depot = Depot(
            configuration: .init(directoryURL: url, enableMultiProcessSupport: true),
        )
        let key = depot.register(keyPath: "val", coder: .json() as AnyCoder<String>)

        // Writing should touch the lock
        try depot.set(value: "test", for: key)

        let lockURL = url.appendingPathComponent("\(Depot.HiddenKeyPrefix)LOCK")
        #expect(FileManager.default.fileExists(atPath: lockURL.path))
    }

    // MARK: - pruneEmptyDirectories

    @Test("removing last value in subdirectory prunes empty dirs")
    func pruneEmptyDirs() throws {
        let depot = Depot.temporary()
        _ = depot.register(key: Key.from("a" / .wildcard / "b"), coder: .json() as AnyCoder<String>)
        let key = Key.from("a" / "x" / "b", as: String.self)
        try depot.set(value: "val", for: key)
        try depot.remove(valueFor: key)

        // The intermediate directory "a/x" should have been pruned
        let aDir = depot.configuration.directoryURL!.appendingPathComponent("a", isDirectory: true)
        let xDir = aDir.appendingPathComponent("x", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: xDir.path))
    }
}
