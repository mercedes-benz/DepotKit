// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

/// User key components that start with the internal hidden prefix must
/// still be encoded, so separators and parent segments can never escape the
/// depot directory.
@Suite
struct KeyPathConfinementTests {
    /// A unique sandbox directory that contains the depot directory and
    /// nothing else, so anything written outside the depot is detectable.
    private struct Sandbox {
        let rootURL: URL
        let depotURL: URL

        init() throws {
            rootURL = FileManager.default.temporaryDirectory
                .appending(component: "KeyPathConfinement-\(UUID().uuidString)", directoryHint: .isDirectory)
            // Nest the depot two levels deep so even the deepest hostile
            // identifier below would still land inside the sandbox.
            depotURL = rootURL.appending(path: "nested/depot", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }

        func makeDepot() -> Depot {
            Depot(configuration: .init(directoryURL: depotURL, memoryCache: .disabled))
        }

        /// All items (files and directories) below the sandbox root that are
        /// not the depot directory or inside it.
        func itemsOutsideDepot() -> [String] {
            let depotPath = depotURL.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: [],
            )
            var outside = [String]()
            while let url = enumerator?.nextObject() as? URL {
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
                let normalizedDepotPath = depotPath.hasSuffix("/") ? String(depotPath.dropLast()) : depotPath
                let normalizedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
                if normalizedPath == normalizedDepotPath || normalizedPath.hasPrefix(normalizedDepotPath + "/")
                    || normalizedDepotPath.hasPrefix(normalizedPath + "/")
                {
                    continue
                }
                outside.append(url.lastPathComponent)
            }
            return outside
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    /// Hostile identifiers that begin with the reserved hidden prefix and
    /// contain separators and parent-directory segments.
    static let hostileIdentifiers = [
        "\(Depot.HiddenKeyPrefix)/../../outside",
        "\(Depot.HiddenKeyPrefix)/../outside",
        "\(Depot.HiddenKeyPrefix)/..",
        "\(Depot.HiddenKeyPrefix)META/../../outside",
        "\(Depot.HiddenKeyPrefix)x/../../../outside",
    ]

    @Test("writes, reads and removals of hidden-prefixed components stay inside the depot")
    func crudStaysConfined() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }

        let depot = sandbox.makeDepot()
        depot.register(key: Key.all, coder: .json() as AnyCoder<String>)

        var keys = [TypedDistinctKey<String>]()
        for identifier in Self.hostileIdentifiers {
            keys.append(Key.from(.component(identifier), as: String.self))
            keys.append(Key.from(.component(identifier) / "leaf", as: String.self))
            keys.append(Key.from("dir" / identifier, as: String.self))
        }

        for (index, key) in keys.enumerated() {
            try depot.set(value: "value-\(index)", for: key)
        }
        #expect(sandbox.itemsOutsideDepot().isEmpty)

        for (index, key) in keys.enumerated() {
            #expect(try depot.get(valueFor: key) == "value-\(index)")
        }
        #expect(try depot.count(for: Key.all) == keys.count)

        // Reopen: enumeration must decode every hostile identifier back.
        let reopened = sandbox.makeDepot()
        reopened.register(key: Key.all, coder: .json() as AnyCoder<String>)
        let available = try reopened.get(availableValuesFor: Key.all.typed(as: String.self))
        #expect(Set(available.keyedValues.keys) == Set(keys.map { DistinctKey($0) }))
        #expect(available.keyedErrors.isEmpty)

        for key in keys {
            try reopened.remove(valueFor: key)
            #expect(try reopened.get(valueFor: key) == nil)
        }
        #expect(try reopened.count(for: Key.all) == 0)
        #expect(sandbox.itemsOutsideDepot().isEmpty)
        try reopened.verifyIntegrity()
    }

    @Test("reads and removals cannot reach a file outside the depot")
    func readsAndRemovalsCannotEscape() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }

        let depot = sandbox.makeDepot()
        depot.register(key: Key.all, coder: .json() as AnyCoder<String>)
        let seed = Key.from("seed", as: String.self)
        try depot.set(value: "outside-secret", for: seed)

        // Plant a valid depot file next to the depot directory, and make
        // sure the hidden-prefix directory exists so a raw `..` traversal
        // would resolve.
        let seedFile = try #require(
            FileManager.default.contentsOfDirectory(at: sandbox.depotURL, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == Depot.PathExtension && !$0.lastPathComponent.hasPrefix(".") }
        )
        let plantedURL = sandbox.depotURL.deletingLastPathComponent().appending(component: "outside.bin")
        try FileManager.default.copyItem(at: seedFile, to: plantedURL)
        try FileManager.default.createDirectory(
            at: sandbox.depotURL.appending(component: Depot.HiddenKeyPrefix, directoryHint: .isDirectory),
            withIntermediateDirectories: true,
        )
        try depot.remove(valueFor: seed)

        let hostile = Key.from(.component("\(Depot.HiddenKeyPrefix)/../../outside"), as: String.self)
        #expect(try depot.get(valueFor: hostile) == nil)
        #expect(try depot.has(valueFor: hostile) == false)
        #expect(try depot.metadata(for: hostile) == nil)

        try depot.remove(valueFor: hostile)
        try depot.remove(valuesFor: Key.from(.component("\(Depot.HiddenKeyPrefix)/../..") / .wildcard))
        #expect(FileManager.default.fileExists(atPath: plantedURL.path(percentEncoded: false)))

        try depot.transaction { tx in
            #expect(try tx.get(valueFor: hostile) == nil)
            try tx.remove(valueFor: hostile)
        }
        #expect(FileManager.default.fileExists(atPath: plantedURL.path(percentEncoded: false)))
    }

    @Test("transactions with hidden-prefixed components stay inside the depot")
    func transactionsStayConfined() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }

        let depot = sandbox.makeDepot()
        depot.register(key: Key.all, coder: .json() as AnyCoder<Int>)

        let keys = Self.hostileIdentifiers.map { Key.from(.component($0), as: Int.self) }

        try depot.transaction { tx in
            for (index, key) in keys.enumerated() {
                try tx.set(value: index, for: key)
            }
        }
        #expect(sandbox.itemsOutsideDepot().isEmpty)

        for (index, key) in keys.enumerated() {
            #expect(try depot.get(valueFor: key) == index)
        }

        try depot.transaction { tx in
            for key in keys {
                try tx.remove(valueFor: key)
            }
        }
        #expect(try depot.count(for: Key.all) == 0)
        #expect(sandbox.itemsOutsideDepot().isEmpty)
    }

    @Test("internal metadata keeps working next to hidden-prefixed user keys")
    func metadataStillWorks() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }

        let depot = sandbox.makeDepot()
        depot.register(key: Key.all, coder: .json() as AnyCoder<String>)
        try depot.verifyIntegrity()

        // A user identifier that spells an internal file name is ordinary user data.
        let lookalike = Key.from(.component("\(Depot.HiddenKeyPrefix)LOCK"), as: String.self)
        try depot.set(value: "user", for: lookalike)
        #expect(try depot.get(valueFor: lookalike) == "user")
        try depot.verifyIntegrity()

        try depot.reset()
        try depot.verifyIntegrity()
        #expect(try depot.get(valueFor: lookalike) == nil)
        #expect(sandbox.itemsOutsideDepot().isEmpty)
    }

    @Test(
        "a parent-directory identifier cannot reach a file outside the depot with either file-name codec",
        arguments: DepotFileNameCodec.allCases,
    )
    func confinedWithEitherCodec(codec: DepotFileNameCodec) throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }

        // `depot/.FS_/../../..` resolves to the sandbox root if the identifier were used verbatim.
        let outsideURL = sandbox.rootURL.appending(component: "outside.bin")
        let payload = Data("99".utf8)
        let sentinel =
            FileHeader(modifiedAt: Date(), expiresAt: nil, crc32: CRC32.checksum(payload)).serialized() + payload
        try sentinel.write(to: outsideURL)

        let depot = Depot(
            configuration: .init(directoryURL: sandbox.depotURL, memoryCache: .disabled),
            overrides: .init(volumeSupportsCaseSensitiveNames: { _ in codec == .base64URL }),
        )
        #expect(depot.fileManager?.fileNameCodec == codec)
        depot.register(key: Key.all, coder: .json(Int.self))
        let key = Key.from("entry" / "\(Depot.HiddenKeyPrefix)/../../../outside", as: Int.self)

        #expect(try depot.get(valueFor: key) == nil)
        try depot.set(value: 1, for: key)
        #expect(try Data(contentsOf: outsideURL) == sentinel)
        #expect(try depot.get(valueFor: key) == 1)
        try depot.remove(valueFor: key)
        #expect(try Data(contentsOf: outsideURL) == sentinel)

        try depot.transaction { transaction in
            #expect(try transaction.get(valueFor: key) == nil)
            try transaction.set(value: 2, for: key)
        }
        #expect(try Data(contentsOf: outsideURL) == sentinel)
        try depot.transaction { transaction in
            #expect(try transaction.get(valueFor: key) == 2)
            try transaction.set(value: nil, for: key)
        }
        #expect(try Data(contentsOf: outsideURL) == sentinel)
        #expect(try depot.get(valueFor: key) == nil)
        try depot.verifyIntegrity()
    }
}
