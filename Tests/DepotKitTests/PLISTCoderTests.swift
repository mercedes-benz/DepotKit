// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

@Suite
struct PLISTCoderTests {
    private struct Entity: Codable, Equatable {
        let id: UUID
        let name: String
        let timestamp: Date

        init(id: UUID = UUID(), name: String = "test", timestamp: Date = Date()) {
            self.id = id
            self.name = name
            self.timestamp = timestamp
        }
    }

    @Test("round-trips complex entities")
    func roundTrips() throws {
        let coder: AnyCoder<Entity> = .plist()

        let values = [
            Entity(),
            Entity(name: ""),
            Entity(name: "😀🙋🏼‍♂️"),
        ]

        for value in values {
            let encoded = try coder.encode(value)
            let decoded = try coder.decode(encoded)
            #expect(decoded == value)
        }
    }

    @Test("round-trips primitive types")
    func primitiveTypes() throws {
        let intCoder: AnyCoder<[Int]> = .plist()
        #expect(try intCoder.decode(intCoder.encode([1, 2, 3])) == [1, 2, 3])

        let dictCoder: AnyCoder<[String: Bool]> = .plist()
        #expect(try dictCoder.decode(dictCoder.encode(["a": true])) == ["a": true])
    }

    @Test("default output is binary format")
    func binaryFormat() throws {
        let coder: AnyCoder<Entity> = .plist()
        let data = try coder.encode(Entity())
        // Binary plists start with "bplist"
        let prefix = String(data: data.prefix(6), encoding: .ascii)
        #expect(prefix == "bplist")
    }

    @Test("supports XML output format")
    func xmlFormat() throws {
        let coder = PLISTCoder<Entity>(
            configureEncoder: { $0.outputFormat = .xml },
            configureDecoder: { _ in }
        )

        let data = try coder.encode(Entity(name: "xml"))
        let prefix = String(data: data.prefix(5), encoding: .utf8)
        #expect(prefix == "<?xml")

        let decoded = try coder.decode(data)
        #expect(decoded.name == "xml")
    }

    @Test("throws on invalid plist data")
    func throwsOnInvalidData() {
        let coder: AnyCoder<Entity> = .plist()

        #expect(throws: (any Error).self) {
            _ = try coder.decode(Data("not a plist".utf8))
        }
    }

    @Test("throws on type mismatch")
    func throwsOnTypeMismatch() throws {
        let stringCoder: AnyCoder<[String]> = .plist()
        let intCoder: AnyCoder<[Int]> = .plist()

        let stringData = try stringCoder.encode(["hello"])
        #expect(throws: (any Error).self) {
            _ = try intCoder.decode(stringData)
        }
    }
}
