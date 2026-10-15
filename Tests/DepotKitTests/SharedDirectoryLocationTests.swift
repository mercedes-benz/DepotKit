// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

/// Shared app-group directory variants must resolve to distinct
/// locations inside the group container.
@Suite
struct SharedDirectoryLocationTests {
    private static let group = "group.com.example.depotkit"
    private static let container = URL(filePath: "/tmp/AppGroupContainer", directoryHint: .isDirectory)

    private static func resolve(_ directory: DepotConfiguration.Directory, name: String = "Store") throws -> URL {
        try DepotConfiguration.directoryURL(in: directory, name: name) { identifier in
            identifier == group ? container : nil
        }
    }

    @Test("shared directories resolve to distinct URLs with the expected suffixes")
    func distinctSharedLocations() throws {
        let documents = try Self.resolve(.sharedDocuments(appGroupIdentifier: Self.group))
        let caches = try Self.resolve(.sharedCaches(appGroupIdentifier: Self.group))
        let applicationSupport = try Self.resolve(.sharedApplicationSupport(appGroupIdentifier: Self.group))

        #expect(Set([documents, caches, applicationSupport]).count == 3)

        let containerPath = Self.container.path(percentEncoded: false)
        #expect(documents.path(percentEncoded: false) == containerPath + "Documents/Store/")
        #expect(caches.path(percentEncoded: false) == containerPath + "Library/Caches/Store/")
        #expect(
            applicationSupport.path(percentEncoded: false) == containerPath + "Library/Application Support/Store/"
        )
        #expect(documents.hasDirectoryPath && caches.hasDirectoryPath && applicationSupport.hasDirectoryPath)
    }

    @Test("same name in different shared directories gives independent stores")
    func independentStores() throws {
        let container = FileManager.default.temporaryDirectory
            .appending(component: "AppGroup-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: container) }

        func depot(_ directory: DepotConfiguration.Directory) throws -> Depot {
            let url = try DepotConfiguration.directoryURL(in: directory, name: "Shared") { _ in container }
            let depot = Depot(configuration: .init(directoryURL: url, memoryCache: .disabled))
            depot.register(key: Key.all, coder: .json() as AnyCoder<String>)
            return depot
        }

        let cache = try depot(.sharedCaches(appGroupIdentifier: Self.group))
        let support = try depot(.sharedApplicationSupport(appGroupIdentifier: Self.group))
        let key = Key.from("value", as: String.self)

        try cache.set(value: "cache", for: key)
        try support.set(value: "support", for: key)
        try cache.reset()

        #expect(try cache.get(valueFor: key) == nil)
        #expect(try support.get(valueFor: key) == "support")
    }

    @Test("an unknown app group still throws")
    func unknownGroupThrows() {
        #expect(throws: CocoaError.self) {
            _ = try Self.resolve(.sharedCaches(appGroupIdentifier: "group.unknown"))
        }
    }

    @Test("non-shared directories are unaffected")
    func nonSharedDirectories() throws {
        let caches = try DepotConfiguration.directoryURL(in: .caches, name: "Store")
        let expected = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false,
        )
        #expect(caches == expected.appending(component: "Store", directoryHint: .isDirectory))
    }
}
