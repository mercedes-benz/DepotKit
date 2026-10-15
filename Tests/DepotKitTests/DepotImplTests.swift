// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

private final class TestConfiguration {
    let depotURL: URL

    init() {
        depotURL = try! DepotConfiguration.directoryURL(
            in: .caches,
            name: "DepotTests-\(UUID().uuidString)",
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
struct DepotImplTests {
    @Suite
    struct Persistence {
        @Test("is persistent")
        func isPersistent() throws {
            let testConfiguration = TestConfiguration()

            var depot = Depot(configuration: .init(directoryURL: testConfiguration.depotURL, memoryCache: .disabled))
            var key = depot.register(
                key: Key.from("accounts"),
                coder: .data(String.self),
            )

            let value = "lorem ipsum dolor sit amet"
            try depot.set(value: value, for: key)

            depot = Depot(configuration: .init(directoryURL: testConfiguration.depotURL, memoryCache: .default))
            key = depot.register(
                key: Key.from("accounts"),
                coder: .data(String.self),
            )

            #expect(try depot.get(valueFor: key) == value)
        }
    }

    @Suite
    struct Deleting {
        @Test("does not delete top level file")
        func doesNotDeleteTopLevelFile() throws {
            let testConfiguration = TestConfiguration()

            let depot = Depot(configuration: .init(directoryURL: testConfiguration.depotURL, memoryCache: .disabled))
            depot.register(key: Key.from("entities" / .globstar), coder: .data(String.self))

            let value = "lorem ipsum dolor sit amet"
            try depot.set(value: value, for: Key.from("entities" / "WD123", as: String.self))
            try depot.set(
                value: value,
                for: Key.from("entities" / "WD123" / "status", as: String.self),
            )
            #expect(try depot.has(valuesFor: Key.from("entities" / .globstar)))

            try depot.remove(valuesFor: Key.from("entities" / "WD123" / .wildcard))
            #expect(try depot.has(valuesFor: Key.from("entities" / .globstar)))
            #expect(try depot.has(valuesFor: Key.from("entities" / "WD123" / .wildcard)) == false)
        }
    }

    @Suite
    struct KeyExtensions {
        @Test("getFileURL works as expected")
        func getFileURL() throws {
            let fileURL = URL(
                fileURLWithPath:
                    "/var/mobile/Containers/Data/Library/Caches/DepotKit/Depot/Cache/ZW50aXRpZXM=/VzFLMjk1MTIyMUYwMDAwMDI=/c3RhdHVz.bin",
            )
            let depotURL = URL(fileURLWithPath: "/var/mobile/Containers/Data/Library/Caches/DepotKit/Depot/Cache")

            let key = Key.from("entities" / "W1K2951221F000002" / "status")
            #expect(try key.getFileURL(from: depotURL, codec: .base64URL) == fileURL)
        }

        @Test("init from fileURL relative to depotURL works as exptected")
        func initFromFileURLRelativeFromSimulator() throws {
            let fileURL = URL(
                fileURLWithPath:
                    "/var/mobile/Containers/Data/Library/Caches/DepotKit/Depot/Cache/ZW50aXRpZXM=/VzFLMjk1MTIyMUYwMDAwMDI=/c3RhdHVz.bin",
            )
            let depotURL = URL(fileURLWithPath: "/var/mobile/Containers/Data/Library/Caches/DepotKit/Depot/Cache")

            let key = Key.from("entities" / "W1K2951221F000002" / "status")
            #expect(DistinctKey.from(fileURL: fileURL, relativeTo: depotURL, codec: .base64URL) == key)
        }

        @Test("init from fileURL relative to depotURL works as exptected with paths from device")
        func initFromFileURLRelativeFromDevice() throws {
            let fileURL = URL(
                fileURLWithPath:
                    "/private/var/mobile/Containers/Data/Library/Caches/DepotKit/Depot/Cache/ZW50aXRpZXM=/VzFLMjk1MTIyMUYwMDAwMDI=/c3RhdHVz.bin",
            )
            let depotURL = URL(fileURLWithPath: "/var/mobile/Containers/Data/Library/Caches/DepotKit/Depot/Cache")

            let key = Key.from("entities" / "W1K2951221F000002" / "status")
            #expect(DistinctKey.from(fileURL: fileURL, relativeTo: depotURL, codec: .base64URL) == key)
        }

        @Test("round-trip works for identifiers with base64 slash")
        func roundTripWithBase64Slash() throws {
            let depotURL = URL(fileURLWithPath: "/tmp/DepotKit-DepotTests")
            let identifier = "࠿"  // base64: "4KC/" (contains "/")

            let key = Key.from("root" / identifier / "test")
            let fileURL = try key.getFileURL(from: depotURL, codec: .base64URL)

            #expect(DistinctKey.from(fileURL: fileURL, relativeTo: depotURL, codec: .base64URL) == key)
        }
    }

}
