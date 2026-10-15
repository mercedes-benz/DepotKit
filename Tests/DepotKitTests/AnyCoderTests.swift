// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

struct TestStringCoder: Coder {
    func encode(_ value: String) throws -> Data {
        value.dataRepresentation!
    }

    func decode(_ data: Data) throws -> String {
        String(dataRepresentation: data)!
    }
}

@Suite
struct AnyCoderTests {
    @Test("eraseToAnyCoder wraps underlying coder")
    func eraseToAnyCoder() throws {
        let coder = TestStringCoder()
        let anyCoder = coder.eraseToAnyCoder()

        let value = "test"
        let data = try anyCoder.encode(value)
        let decoded = try anyCoder.decode(data)

        #expect(data == value.dataRepresentation)
        #expect(decoded == value)
    }

    @Test("double erasure is a no-op")
    func doubleErasure() throws {
        let coder = TestStringCoder().eraseToAnyCoder()
        let doubleErased = coder.eraseToAnyCoder()

        let data = try coder.encode("hello")
        let decoded = try doubleErased.decode(data)
        #expect(decoded == "hello")
    }

    @Test("AnyCoder(AnyCoder) fast path")
    func fastPathInit() throws {
        let coder: AnyCoder<String> = .data()
        let wrapped = AnyCoder(coder)

        let data = try coder.encode("test")
        let decoded = try wrapped.decode(data)
        #expect(decoded == "test")
    }

    @Test("forwards encode errors")
    func forwardsEncodeError() {
        let coder = FailingCoder(shouldFail: true).eraseToAnyCoder()

        #expect(throws: FailingCoderError.self) {
            _ = try coder.encode("anything")
        }
    }

    @Test("forwards decode errors")
    func forwardsDecodeError() {
        let coder = FailingCoder(shouldFail: true).eraseToAnyCoder()

        #expect(throws: FailingCoderError.self) {
            _ = try coder.decode(Data())
        }
    }
}

private enum FailingCoderError: Error { case intentional }

private struct FailingCoder: Coder {
    let shouldFail: Bool

    func encode(_ value: String) throws -> Data {
        if shouldFail { throw FailingCoderError.intentional }
        return Data(value.utf8)
    }

    func decode(_ data: Data) throws -> String {
        if shouldFail { throw FailingCoderError.intentional }
        return String(data: data, encoding: .utf8)!
    }
}
