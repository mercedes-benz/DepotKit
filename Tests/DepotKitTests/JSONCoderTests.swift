// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

private struct Entity: Codable, Equatable {
    struct Value: Codable, Equatable {
        let test: String

        init(test: String = "test") {
            self.test = test
        }
    }

    let id: UUID
    let timestamp: Date
    let value: Value

    init(id: UUID = UUID(), timestamp: Date = Date(), value: Value = Value()) {
        self.id = id
        // Round to milliseconds to survive JSON round-trip
        self.timestamp = Date(timeIntervalSince1970: (timestamp.timeIntervalSince1970 * 1000).rounded() / 1000)
        self.value = value
    }
}

@Suite
struct JSONCoderTests {
    @Test("round-trips complex entities")
    func roundTrips() throws {
        let coder: AnyCoder<Entity> = .json()

        let values = [
            Entity(),
            Entity(value: .init(test: "")),
            Entity(value: .init(test: "😀🙋🏼‍♂️")),
        ]

        for value in values {
            let encoded = try coder.encode(value)
            let decoded = try coder.decode(encoded)
            #expect(decoded == value)
        }
    }

    @Test("round-trips primitive types")
    func primitiveTypes() throws {
        let intCoder: AnyCoder<Int> = .json()
        #expect(try intCoder.decode(intCoder.encode(42)) == 42)

        let boolCoder: AnyCoder<Bool> = .json()
        #expect(try boolCoder.decode(boolCoder.encode(true)) == true)

        let arrayCoder: AnyCoder<[String]> = .json()
        #expect(try arrayCoder.decode(arrayCoder.encode(["a", "b"])) == ["a", "b"])
    }

    @Test("uses sorted keys")
    func sortedKeys() throws {
        struct AB: Codable {
            let b: Int
            let a: Int
        }
        let coder: AnyCoder<AB> = .json()
        let data = try coder.encode(AB(b: 2, a: 1))
        let json = String(data: data, encoding: .utf8)!
        let aIndex = json.range(of: "\"a\"")!.lowerBound
        let bIndex = json.range(of: "\"b\"")!.lowerBound
        #expect(aIndex < bIndex)
    }

    @Test("uses millisecondsSince1970 for dates")
    func dateStrategy() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        let coder: AnyCoder<[String: Date]> = .json()
        let data = try coder.encode(["d": date])
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let ts = json["d"] as! Double
        #expect(ts == 1_700_000_000_123)
    }

    @Test("uses base64 for Data fields")
    func dataStrategy() throws {
        struct Container: Codable { let payload: Data }
        let coder: AnyCoder<Container> = .json()
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let data = try coder.encode(Container(payload: payload))
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("3q2+7w=="))
    }

    @Test("supports custom encoder/decoder configuration")
    func customConfiguration() throws {
        let coder = JSONCoder<Entity>(
            configureEncoder: { $0.dateEncodingStrategy = .secondsSince1970 },
            configureDecoder: { $0.dateDecodingStrategy = .secondsSince1970 }
        )

        let value = Entity(timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let encoded = try coder.encode(value)
        let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        let ts = (json["timestamp"] as! NSNumber).doubleValue
        #expect(ts == 1_700_000_000)

        let decoded = try coder.decode(encoded)
        #expect(decoded == value)
    }

    @Test("throws on invalid JSON data")
    func throwsOnInvalidData() {
        let coder: AnyCoder<Entity> = .json()

        #expect(throws: (any Error).self) {
            _ = try coder.decode(Data("not json".utf8))
        }
    }

    @Test("throws on type mismatch")
    func throwsOnTypeMismatch() {
        let coder: AnyCoder<Int> = .json()
        let stringData = try! JSONEncoder().encode("hello")

        #expect(throws: (any Error).self) {
            _ = try coder.decode(stringData)
        }
    }
}
