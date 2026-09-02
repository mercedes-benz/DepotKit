// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

extension AnyCoder where Value: Codable {
    /// Creates a coder that converts to and from *PLIST* (binary) format.
    ///
    /// ```swift
    /// depot.register(key: Key.from("user" / "prefs"), coder: .plist())
    /// #key("user/prefs", coder: .plist(Settings.self))
    /// ```
    public static func plist(_ type: Value.Type = Value.self) -> AnyCoder<Value> {
        PLISTCoder<Value>(
            configureEncoder: { encoder in encoder.outputFormat = .binary },
            configureDecoder: { _ in }
        ).eraseToAnyCoder()
    }
}

// MARK: - PLISTCoder

/// A coder that serializes `Codable` values using `PropertyListEncoder` / `PropertyListDecoder`.
struct PLISTCoder<Value: Codable & Sendable>: Coder {
    private let configureEncoder: @Sendable (PropertyListEncoder) -> Void
    private let configureDecoder: @Sendable (PropertyListDecoder) -> Void

    init(
        configureEncoder: @escaping @Sendable (PropertyListEncoder) -> Void,
        configureDecoder: @escaping @Sendable (PropertyListDecoder) -> Void,
    ) {
        self.configureEncoder = configureEncoder
        self.configureDecoder = configureDecoder
    }

    var coderDescription: String { ".plist(\(Value.self))" }

    func encode(_ value: Value) throws -> Data {
        let encoder = PropertyListEncoder()
        configureEncoder(encoder)
        return try encoder.encode(value)
    }

    func decode(_ data: Data) throws -> Value {
        let decoder = PropertyListDecoder()
        configureDecoder(decoder)
        return try decoder.decode(Value.self, from: data)
    }
}
