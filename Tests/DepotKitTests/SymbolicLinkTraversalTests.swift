// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

/// Pattern operations walk the depot directory without following symbolic
/// links, so a link placed inside the depot can neither expose, count, nor
/// delete anything outside of it, and cannot make a traversal loop.
@Suite
struct SymbolicLinkTraversalTests {
    private struct Sandbox {
        let rootURL: URL
        let depotURL: URL
        let outsideURL: URL

        init() throws {
            rootURL = FileManager.default.temporaryDirectory
                .appending(component: "SymbolicLinkTraversal-\(UUID().uuidString)", directoryHint: .isDirectory)
            depotURL = rootURL.appending(component: "depot", directoryHint: .isDirectory)
            outsideURL = rootURL.appending(component: "outside", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }

        func makeDepot(at url: URL) -> Depot {
            let depot = Depot(configuration: .init(directoryURL: url, memoryCache: .disabled))
            depot.register(key: Key.all, coder: .json(Int.self))
            return depot
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    /// The path of `key`'s directory in `depot`, using the depot's file names.
    private static func directoryURL(of key: DistinctKey, in depot: Depot) throws -> URL {
        try depot.fileURL(for: key).deletingPathExtension()
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test("pattern reads, counts, removals and disk usage ignore symbolic links")
    func patternOperationsIgnoreLinks() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }

        // A second depot outside the first one, with values, an empty directory, and a
        // directory without value files that pruning would delete.
        let outside = sandbox.makeDepot(at: sandbox.outsideURL)
        try outside.set(value: 10, for: Key.from("x", as: Int.self))
        try outside.set(value: 11, for: Key.from("sub" / "y", as: Int.self))
        let outsideFileURL = try outside.fileURL(for: Key.from("x"))
        let emptyURL = try Self.directoryURL(of: Key.from("empty"), in: outside)
        let foreignURL = try Self.directoryURL(of: Key.from("foreign"), in: outside)
        try FileManager.default.createDirectory(at: emptyURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: foreignURL, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: foreignURL.appending(component: "readme.txt"))

        let depot = sandbox.makeDepot(at: sandbox.depotURL)
        let inside = Key.from("inside", as: Int.self)
        try depot.set(value: 1, for: inside)

        // Links with encoded names to a directory and a value file outside the depot.
        try FileManager.default.createSymbolicLink(
            at: Self.directoryURL(of: Key.from("linked"), in: depot),
            withDestinationURL: sandbox.outsideURL,
        )
        try FileManager.default.createSymbolicLink(
            at: depot.fileURL(for: Key.from("file")),
            withDestinationURL: outsideFileURL,
        )

        let all = Key.all.typed(as: Int.self)
        let linked = Key.from("linked" / .globstar, as: Int.self)
        #expect(try depot.get(valuesFor: all) == [1])
        #expect(try depot.get(availableValuesFor: all).keyedValues == [DistinctKey(inside): 1])
        #expect(try depot.count(for: all) == 1)
        #expect(try depot.has(valuesFor: linked) == false)
        #expect(try depot.count(for: Key.from(PatternKeyPathExpression(.wildcard))) == 1)
        #expect(try depot.diskUsage(under: Key.all).fileCount == 1)
        #expect(try depot.diskUsage(under: Key.from("linked")).fileCount == 0)
        // Literal components must not lead through a link either.
        #expect(try depot.count(for: Key.from("linked" / "sub" / .wildcard)) == 0)
        #expect(try depot.has(valuesFor: Key.from("linked" / "x")) == false)
        #expect(try depot.count(for: Key.from("file")) == 0)
        try depot.verifyIntegrity()

        try depot.remove(valuesFor: Key.from("linked" / "sub" / .wildcard))
        try depot.remove(valueFor: Key.from("linked" / "x"))
        try depot.remove(valuesFor: linked)
        try depot.remove(valuesFor: Key.from(PatternKeyPathExpression(.wildcard)))
        #expect(try depot.count(for: all) == 0)

        let reopened = sandbox.makeDepot(at: sandbox.outsideURL)
        #expect(try reopened.get(valueFor: Key.from("x", as: Int.self)) == 10)
        #expect(try reopened.get(valueFor: Key.from("sub" / "y", as: Int.self)) == 11)
        #expect(Self.exists(emptyURL))
        #expect(Self.exists(foreignURL.appending(component: "readme.txt")))
    }

    @Test("removals addressed through a linked directory leave its target intact")
    func removalsThroughLinkedDirectory() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }

        let outside = sandbox.makeDepot(at: sandbox.outsideURL)
        try outside.set(value: 10, for: Key.from("x", as: Int.self))
        try outside.set(value: 11, for: Key.from("sub" / "y", as: Int.self))

        let depot = sandbox.makeDepot(at: sandbox.depotURL)
        try FileManager.default.createSymbolicLink(
            at: Self.directoryURL(of: Key.from("linked"), in: depot),
            withDestinationURL: sandbox.outsideURL,
        )

        #expect(try depot.count(for: Key.from("linked" / "sub" / .wildcard)) == 0)
        try depot.remove(valuesFor: Key.from("linked" / "sub" / .wildcard))
        try depot.remove(valueFor: Key.from("linked" / "x"))

        #expect(try outside.get(valueFor: Key.from("x", as: Int.self)) == 10)
        #expect(try outside.get(valueFor: Key.from("sub" / "y", as: Int.self)) == 11)
    }

    @Test("a link back into the depot does not make traversal loop")
    func linkLoopIsNotFollowed() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }

        let depot = sandbox.makeDepot(at: sandbox.depotURL)
        let value = Key.from("dir" / "value", as: Int.self)
        try depot.set(value: 1, for: value)
        try FileManager.default.createSymbolicLink(
            at: Self.directoryURL(of: Key.from("dir" / "loop"), in: depot),
            withDestinationURL: sandbox.depotURL,
        )

        let all = Key.all.typed(as: Int.self)
        #expect(try depot.get(valuesFor: all) == [1])
        #expect(try depot.count(for: Key.from("dir" / "loop" / .globstar)) == 0)
        #expect(try depot.diskUsage(under: Key.from("dir")).fileCount == 1)

        try depot.remove(valuesFor: Key.from("dir" / "loop" / .globstar))
        try depot.remove(valuesFor: Key.from("dir" / .globstar))
        #expect(try depot.count(for: all) == 0)
        #expect(Self.exists(sandbox.depotURL))
    }
}
