// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

/// A writable depot retries creating its metadata when that failed while the store was empty.
@Suite("Deferred metadata creation")
struct DeferredMetadataCreationTests {
    private static func makeURL() -> URL {
        FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    }

    /// Opens a depot whose metadata cannot be created: a directory occupies the metadata file's path.
    private static func makeDepotWithBlockedMetadata(at url: URL) throws -> (depot: Depot, blocker: URL) {
        let blocker = url.appending(component: "\(Depot.HiddenKeyPrefix)META.\(Depot.PathExtension)")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try Data().write(to: blocker.appending(component: "occupied"))

        let depot = Depot(configuration: .init(directoryURL: url, memoryCache: .disabled))
        #expect(throws: DepotError.metadataNotFound) { try depot.verifyIntegrity() }
        return (depot, blocker)
    }

    @Test("verifyIntegrity creates the metadata once creating it succeeds")
    func verifyIntegrityRetriesCreation() throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (depot, blocker) = try Self.makeDepotWithBlockedMetadata(at: url)

        try FileManager.default.removeItem(at: blocker)

        try depot.verifyIntegrity()
    }

    @Test("the next write creates the metadata, so a later launch verifies")
    func writeRetriesCreation() throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (depot, blocker) = try Self.makeDepotWithBlockedMetadata(at: url)
        let key = depot.register(keyPath: "value", coder: .json(String.self))

        try FileManager.default.removeItem(at: blocker)
        try depot.set(value: "v1", for: key)

        let reopened = Depot(configuration: .init(directoryURL: url, memoryCache: .disabled))
        try reopened.verifyIntegrity()
    }

    @Test("a committed transaction creates the metadata")
    func transactionRetriesCreation() throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (depot, blocker) = try Self.makeDepotWithBlockedMetadata(at: url)
        let key = depot.register(keyPath: "value", coder: .json(String.self))

        try FileManager.default.removeItem(at: blocker)
        try depot.transaction { try $0.set(value: "v1", for: key) }

        let reopened = Depot(configuration: .init(directoryURL: url, memoryCache: .disabled))
        try reopened.verifyIntegrity()
    }

    @Test("a failed write leaves the creation pending")
    func creationStaysPendingWhileBlocked() throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (depot, blocker) = try Self.makeDepotWithBlockedMetadata(at: url)
        let key = depot.register(keyPath: "value", coder: .json(String.self))

        // The write succeeds even though the metadata still cannot be created.
        try depot.set(value: "v1", for: key)
        #expect(throws: DepotError.metadataNotFound) { try depot.verifyIntegrity() }

        try FileManager.default.removeItem(at: blocker)
        try depot.verifyIntegrity()
    }

    @Test("missing metadata next to existing values is not recreated")
    func missingMetadataWithValuesIsReported() throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let depot = Depot(configuration: .init(directoryURL: url, memoryCache: .disabled))
        let key = depot.register(keyPath: "value", coder: .json(String.self))
        try depot.set(value: "v1", for: key)
        let metadataURL = try #require(depot.metadataFileURL)
        try FileManager.default.removeItem(at: metadataURL)

        let reopened = Depot(configuration: .init(directoryURL: url, memoryCache: .disabled))
        let reopenedKey = reopened.register(keyPath: "value", coder: .json(String.self))
        try reopened.set(value: "v2", for: reopenedKey)

        #expect(throws: DepotError.metadataNotFound) { try reopened.verifyIntegrity() }
        #expect(!FileManager.default.fileExists(atPath: metadataURL.path(percentEncoded: false)))
    }

    @Test("a failed metadata recreation after reset is retried by the next write")
    func resetRecreationIsRetried() throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let failRecreation = MetadataFailureSwitch()
        var hooks = Depot.TestHooks()
        hooks.willRecreateMetadata = { try failRecreation.check() }
        let depot = Depot(
            configuration: .init(directoryURL: url, memoryCache: .disabled),
            overrides: .init(testHooks: hooks),
        )
        let key = depot.register(keyPath: "value", coder: .json(String.self))
        try depot.set(value: "v1", for: key)

        failRecreation.isFailing = true
        #expect(throws: CocoaError(.fileWriteNoPermission)) { try depot.reset() }
        let metadataURL = try #require(depot.metadataFileURL)
        #expect(!FileManager.default.fileExists(atPath: metadataURL.path(percentEncoded: false)))

        // The store is empty after the reset, so the next write creates the metadata.
        try depot.set(value: "v2", for: key)
        let reopened = Depot(configuration: .init(directoryURL: url, memoryCache: .disabled))
        try reopened.verifyIntegrity()
    }
}

private final class MetadataFailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var _isFailing = false

    var isFailing: Bool {
        get { lock.withLock { _isFailing } }
        set { lock.withLock { _isFailing = newValue } }
    }

    func check() throws {
        if isFailing {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}
