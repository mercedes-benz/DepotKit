// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

private final class FileManagementTestConfiguration {
    let depotURL: URL

    init() {
        depotURL = try! DepotConfiguration.directoryURL(
            in: .caches,
            name: "FileManagementTests-\(UUID().uuidString)",
        )
    }

    deinit {
        let depotURL = depotURL

        Task { @concurrent in
            do {
                try FileManager.default.removeItem(at: depotURL)
            } catch {
                // ignore
            }
        }
    }
}

@Suite
struct DepotFileManagementTests {
    @Suite
    struct Integrity {
        @Test("works for new depot")
        func worksForNewDepot() throws {
            let testConfiguration = FileManagementTestConfiguration()

            let depot = Depot(configuration: .init(directoryURL: testConfiguration.depotURL, memoryCache: .disabled))
            #expect(throws: Never.self) {
                try depot.verifyIntegrity()
            }
        }

        @Test("throws during migration from old version without metadata file")
        func throwsDuringMigrationFromOldVersion() throws {
            let testConfiguration = FileManagementTestConfiguration()

            let encryptionConfiguration = try EncryptionConfiguration(key: EncryptionConfiguration.generateKey())
            var depot = Depot(
                configuration: .init(
                    directoryURL: testConfiguration.depotURL,
                    encryption: encryptionConfiguration,
                    memoryCache: .disabled
                )
            )
            #expect(throws: Never.self) {
                try depot.verifyIntegrity()
            }

            // create at least one file
            depot.register(key: Key.all, coder: .data(String.self))
            try depot.set(value: "test", for: Key.from("test", as: String.self))

            // delete the metadata file
            try? FileManager.default.removeItem(
                at: testConfiguration.depotURL.appendingPathComponent(".FS_META.bin", isDirectory: false),
            )

            depot = Depot(
                configuration: .init(
                    directoryURL: testConfiguration.depotURL,
                    encryption: encryptionConfiguration,
                    memoryCache: .disabled
                )
            )
            #expect(throws: (any Error).self) {
                try depot.verifyIntegrity()
            }
        }

        @Test("throws if file content is corrupted (checksum mismatch)")
        func throwsIfChecksumMismatch() throws {
            let testConfiguration = FileManagementTestConfiguration()

            let rawKey = Key.from("checksum-mismatch")
            let coder: AnyCoder<String> = .data()

            var depot = Depot(configuration: .init(directoryURL: testConfiguration.depotURL, memoryCache: .disabled))
            let typedKey = depot.register(key: rawKey, coder: coder)
            try depot.set(value: "hello world", for: typedKey)

            let fileURL = rawKey.getFileURL(from: testConfiguration.depotURL)
            var data = try Data(contentsOf: fileURL)
            data[data.count - 1] = data[data.count - 1].addingReportingOverflow(1).partialValue
            try data.write(to: fileURL, options: .atomic)

            depot = Depot(configuration: .init(directoryURL: testConfiguration.depotURL, memoryCache: .disabled))
            let typedKey2 = depot.register(key: rawKey, coder: coder)

            #expect {
                _ = try depot.get(valueFor: typedKey2)
            } throws: { error in
                guard let depotError = error as? DepotError,
                    case .integrityCheckFailed = depotError
                else {
                    return false
                }
                return true
            }
        }
    }

    @Suite
    struct Reset {
        @Test("recovers from corrupt data")
        func recoversFromCorruptData() throws {
            let testConfiguration = FileManagementTestConfiguration()

            let encryptionConfigurationA = try EncryptionConfiguration(key: EncryptionConfiguration.generateKey())
            let encryptionConfigurationB = try EncryptionConfiguration(key: EncryptionConfiguration.generateKey())

            var depot = Depot(
                configuration: .init(
                    directoryURL: testConfiguration.depotURL,
                    encryption: encryptionConfigurationA,
                    memoryCache: .disabled
                )
            )
            depot.register(key: Key.from("entities" / .wildcard), coder: .data(String.self))

            let value = "lorem ipsum dolor sit amet"
            try depot.set(value: value, for: Key.from("entities" / "WD123", as: String.self))

            #expect(throws: Never.self) {
                try depot.verifyIntegrity()
            }
            #expect(try depot.has(valuesFor: Key.all))

            depot = Depot(
                configuration: .init(
                    directoryURL: testConfiguration.depotURL,
                    encryption: encryptionConfigurationB,
                    memoryCache: .disabled
                )
            )
            #expect(throws: (any Error).self) {
                try depot.verifyIntegrity()
            }

            try depot.reset()
            #expect(throws: Never.self) {
                try depot.verifyIntegrity()
            }
        }
    }

    @Suite
    struct DiskUsageTests {
        @Test("empty depot has zero disk usage")
        func emptyDepotHasZeroDiskUsage() throws {
            let testConfiguration = FileManagementTestConfiguration()
            let depot = Depot(configuration: .init(directoryURL: testConfiguration.depotURL, memoryCache: .disabled))

            let usage = try depot.diskUsage()
            #expect(usage.fileCount == 0)
            #expect(usage.totalBytes == 0)
        }

        @Test("disk usage reflects stored values")
        func diskUsageReflectsStoredValues() throws {
            let testConfiguration = FileManagementTestConfiguration()
            let depot = Depot(configuration: .init(directoryURL: testConfiguration.depotURL, memoryCache: .disabled))
            _ = depot.register(key: Key.from("items" / .wildcard), coder: .data(String.self))

            try depot.set(value: "hello", for: Key.from("items" / "a", as: String.self))
            try depot.set(value: "world", for: Key.from("items" / "b", as: String.self))

            let usage = try depot.diskUsage()
            #expect(usage.fileCount == 2)
            #expect(usage.totalBytes > 0)
        }

        @Test("disk usage under prefix counts only matching keys")
        func diskUsageUnderPrefixCountsMatchingKeys() throws {
            let testConfiguration = FileManagementTestConfiguration()
            let depot = Depot(configuration: .init(directoryURL: testConfiguration.depotURL, memoryCache: .disabled))
            _ = depot.register(key: Key.from("a" / .wildcard), coder: .data(String.self))
            _ = depot.register(key: Key.from("b" / .wildcard), coder: .data(String.self))

            try depot.set(value: "1", for: Key.from("a" / "x", as: String.self))
            try depot.set(value: "2", for: Key.from("a" / "y", as: String.self))
            try depot.set(value: "3", for: Key.from("b" / "x", as: String.self))

            let usageUnderA = try depot.diskUsage(under: Key.from("a"))
            #expect(usageUnderA.fileCount == 2)

            let usageUnderB = try depot.diskUsage(under: Key.from("b"))
            #expect(usageUnderB.fileCount == 1)
        }

        @Test("disk usage decreases after removal")
        func diskUsageDecreasesAfterRemoval() throws {
            let testConfiguration = FileManagementTestConfiguration()
            let depot = Depot(configuration: .init(directoryURL: testConfiguration.depotURL, memoryCache: .disabled))
            _ = depot.register(key: Key.from("data" / .wildcard), coder: .data(String.self))

            let key = Key.from("data" / "item", as: String.self)
            try depot.set(value: "stored", for: key)

            let usageBefore = try depot.diskUsage()
            #expect(usageBefore.fileCount == 1)

            try depot.set(value: nil, for: key)

            let usageAfter = try depot.diskUsage()
            #expect(usageAfter.fileCount == 0)
            #expect(usageAfter.totalBytes == 0)
        }
    }
}
