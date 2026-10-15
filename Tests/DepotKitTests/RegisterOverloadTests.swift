// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

@Suite
struct RegisterOverloadTests {
    struct CustomCoder: Coder {
        typealias Value = String
        func encode(_ value: String) throws -> Data { Data(value.utf8) }
        func decode(_ data: Data) throws -> String { String(data: data, encoding: .utf8)! }
    }

    @Test("register with concrete Coder type")
    func registerWithCustomCoder() throws {
        let depot = Depot.temporary()
        let key = depot.register(key: Key.from("test" / "custom"), coder: CustomCoder())
        try depot.set(value: "hello", for: key)
        #expect(try depot.get(valueFor: key) == "hello")
    }

    @Test("register with AnyCoder still works (code completion path)")
    func registerWithAnyCoder() throws {
        let depot = Depot.temporary()
        let key = depot.register(key: Key.from("test" / "json"), coder: .json() as AnyCoder<String>)
        try depot.set(value: "world", for: key)
        #expect(try depot.get(valueFor: key) == "world")
    }
}
