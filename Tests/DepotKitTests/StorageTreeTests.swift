// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

@Suite("storageTree()")
struct StorageTreeTests {
    @Test("empty depot")
    func emptyDepot() {
        let depot = Depot(label: "TestDepot")
        #expect(depot.storageTree() == "TestDepot (empty)")
    }

    @Test("single distinct key shows type and coder")
    func singleDistinctKey() {
        let depot = Depot(label: "TestDepot")
        depot.register(keyPath: "settings" / "app", coder: .json(String.self))

        let tree = depot.storageTree()
        #expect(tree.contains("settings"))
        #expect(tree.contains("app [String] .json(String)"))
        #expect(!tree.contains("pattern"))
    }

    @Test("pattern key is annotated")
    func patternKey() {
        let depot = Depot(label: "TestDepot")
        depot.register(keyPath: "cities" / .wildcard, coder: .json(String.self))

        let tree = depot.storageTree()
        #expect(tree.contains("* [String] .json(String) (pattern)"))
    }

    @Test("expiry is shown")
    func expiryAnnotation() {
        let depot = Depot(label: "TestDepot")
        depot.register(
            keyPath: "forecasts" / .wildcard,
            coder: .json(String.self),
            expiry: .seconds(1800)
        )

        let tree = depot.storageTree()
        #expect(tree.contains("expires: 30m"))
    }

    @Test("compressed coder chain")
    func compressedCoderChain() {
        let depot = Depot(label: "TestDepot")
        depot.register(
            keyPath: "data" / .wildcard,
            coder: AnyCoder<String>.json().compressed(using: .zlib)
        )

        let tree = depot.storageTree()
        #expect(tree.contains(".json(String).compressed(.zlib)"))
    }

    @Test("versioned coder chain")
    func versionedCoderChain() {
        let depot = Depot(label: "TestDepot")
        depot.register(
            keyPath: "config" / "v2",
            coder: AnyCoder<String>.json().versioned(version: 2) { _, _ in nil }
        )

        let tree = depot.storageTree()
        #expect(tree.contains(".json(String).versioned(v2)"))
    }

    @Test("data coder")
    func dataCoder() {
        let depot = Depot(label: "TestDepot")
        depot.register(
            keyPath: "blobs" / .wildcard,
            coder: .data(Data.self)
        )

        let tree = depot.storageTree()
        #expect(tree.contains(".data(Data)"))
    }

    @Test("plist coder")
    func plistCoder() {
        let depot = Depot(label: "TestDepot")
        depot.register(
            keyPath: "prefs" / "main",
            coder: .plist(String.self)
        )

        let tree = depot.storageTree()
        #expect(tree.contains(".plist(String)"))
    }

    @Test("exact output for weather depot layout")
    func exactOutput() {
        let depot = Depot(label: "WeatherDepot")
        depot.register(keyPath: "cities" / .wildcard, coder: .json(String.self))
        depot.register(
            keyPath: "forecasts" / .wildcard,
            coder: AnyCoder<String>.json().compressed(using: .zlib),
            expiry: .seconds(1800)
        )
        depot.register(
            keyPath: "settings" / "app",
            coder: AnyCoder<String>.json().versioned(version: 2) { _, _ in nil }
        )
        depot.register(keyPath: "stats" / "lastRefresh", coder: .json(Date.self))

        let expected = """
            WeatherDepot
            ├── cities
            │   └── * [String] .json(String) (pattern)
            ├── forecasts
            │   └── * [String] .json(String).compressed(.zlib) (pattern, expires: 30m)
            ├── settings
            │   └── app [String] .json(String).versioned(v2)
            └── stats
                └── lastRefresh [Date] .json(Date)
            """

        #expect(depot.storageTree() == expected)
    }

    @Test("short expiry shows seconds")
    func shortExpiry() {
        let depot = Depot(label: "TestDepot")
        depot.register(
            keyPath: "cache" / .wildcard,
            coder: .json(String.self),
            expiry: .seconds(45)
        )

        let tree = depot.storageTree()
        #expect(tree.contains("expires: 45s"))
    }

    @Test("hour expiry shows hours")
    func hourExpiry() {
        let depot = Depot(label: "TestDepot")
        depot.register(
            keyPath: "tokens" / .wildcard,
            coder: .json(String.self),
            expiry: .seconds(3600)
        )

        let tree = depot.storageTree()
        #expect(tree.contains("expires: 1h"))
    }
}
