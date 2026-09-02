// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

private struct DataEntity: Equatable {
    let uuid: UUID

    init(uuid: UUID = UUID()) {
        self.uuid = uuid
    }
}

extension DataEntity: LosslessDataConvertible {
    var dataRepresentation: Data? {
        uuid.dataRepresentation
    }

    init?(dataRepresentation: Data) {
        guard let uuid = UUID(dataRepresentation: dataRepresentation) else {
            return nil
        }

        self.init(uuid: uuid)
    }
}

private struct FailingEntity: LosslessDataConvertible, Sendable {
    var dataRepresentation: Data? { nil }
    init?(dataRepresentation _: Data) { nil }
    init() {}
}

@Suite
struct DataCoderTests {
    @Test("round-trips String values")
    func string() throws {
        let coder: AnyCoder<String> = .data()

        let values = [
            "",
            "hello",
            "world",
            "😀🙋🏼‍♂️",
            String(repeating: "x", count: 10000),
        ]

        for value in values {
            let encoded = try coder.encode(value)
            let decoded = try coder.decode(encoded)
            #expect(decoded == value)
        }
    }

    @Test("round-trips Data values")
    func data() throws {
        let coder: AnyCoder<Data> = .data()

        let values: [Data] = [
            Data(),
            Data([0x00]),
            Data([0xDE, 0xAD, 0xBE, 0xEF]),
            Data(repeating: 0xFF, count: 1024),
        ]

        for value in values {
            let encoded = try coder.encode(value)
            let decoded = try coder.decode(encoded)
            #expect(decoded == value)
        }
    }

    @Test("round-trips custom LosslessDataConvertible")
    func dataEntity() throws {
        let coder: AnyCoder<DataEntity> = .data()

        for _ in 0..<5 {
            let value = DataEntity()
            let encoded = try coder.encode(value)
            let decoded = try coder.decode(encoded)
            #expect(decoded == value)
        }
    }

    @Test("encode throws noData when dataRepresentation is nil")
    func encodeThrowsNoData() {
        let coder: AnyCoder<FailingEntity> = .data()

        #expect(throws: DataCoderError.noData) {
            _ = try coder.encode(FailingEntity())
        }
    }

    @Test("decode throws badData when init returns nil")
    func decodeThrowsBadData() {
        let coder: AnyCoder<FailingEntity> = .data()

        #expect(throws: DataCoderError.badData) {
            _ = try coder.decode(Data([0x01, 0x02, 0x03]))
        }
    }

    @Test("round-trips Int via LosslessDataConvertible")
    func intRoundTrip() throws {
        let coder: AnyCoder<Int> = .data()
        let values = [0, 1, -1, Int.max, Int.min]

        for value in values {
            let encoded = try coder.encode(value)
            let decoded = try coder.decode(encoded)
            #expect(decoded == value)
        }
    }

    @Test("round-trips Bool via LosslessDataConvertible")
    func boolRoundTrip() throws {
        let coder: AnyCoder<Bool> = .data()
        #expect(try coder.decode(coder.encode(true)) == true)
        #expect(try coder.decode(coder.encode(false)) == false)
    }
}
