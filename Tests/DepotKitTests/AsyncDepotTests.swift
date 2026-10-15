// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

private final class TestConfiguration {
    let depotURL: URL
    let encryptionConfiguration: EncryptionConfiguration

    init() {
        depotURL = try! DepotConfiguration.directoryURL(
            in: .caches,
            name: "AsyncDepotTests-\(UUID().uuidString)",
        )
        encryptionConfiguration = try! EncryptionConfiguration(
            cipher: .aesGCM,
            hashFunction: .sha256,
            key: EncryptionConfiguration.generateKey(),
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
struct AsyncDepotTests {
    @Test("doesn't crash")
    func multipleThreads() async throws {
        let testConfiguration = TestConfiguration()
        let baseDepot = Depot(
            configuration: .init(
                directoryURL: testConfiguration.depotURL,
                encryption: testConfiguration.encryptionConfiguration,
                memoryCache: .disabled
            )
        )
        let depot = baseDepot

        let key = depot.register(
            key: Key.from("id"),
            coder: AnyCoder(UUIDCoder()),
        )

        // The coder sleeps and depot lock waits block their threads, so run the operations on
        // dedicated threads instead of the cooperative pool shared with parallel tests.
        let writes = 100
        let reads = 1000
        await concurrentlyOnDedicatedThreads(iterations: writes + reads) { index in
            if index < writes {
                // write concurrently
                try? depot.set(value: UUID(), for: key)
            } else {
                // read concurrently
                _ = try? depot.get(valueFor: key)
            }
        }
    }
}

private struct UUIDCoder: Coder {
    func encode(_ value: UUID) throws -> Data {
        guard let data = value.uuidString.data(using: .utf8) else {
            throw DataCoderError.noData
        }

        // sleep
        Thread.sleep(forTimeInterval: 0.002)

        return data
    }

    func decode(_ data: Data) throws -> UUID {
        guard let uuidString = String(data: data, encoding: .utf8), let uuid = UUID(uuidString: uuidString) else {
            throw DataCoderError.badData
        }

        // sleep
        Thread.sleep(forTimeInterval: 0.002)

        return uuid
    }
}
