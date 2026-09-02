// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

extension AnyCoder where Value: Codable {
    /// Creates a coder that converts to and from *JSON* format.
    ///
    /// ```swift
    /// depot.register(key: Key.from("user" / "name"), coder: .json())
    /// #key("user/name", coder: .json(String.self))
    /// ```
    public static func json(_ type: Value.Type = Value.self) -> AnyCoder<Value> {
        JSONCoder<Value>(
            configureEncoder: { encoder in
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .millisecondsSince1970
                encoder.dataEncodingStrategy = .base64
            },
            configureDecoder: { decoder in
                decoder.dateDecodingStrategy = .millisecondsSince1970
                decoder.dataDecodingStrategy = .base64
            }
        ).eraseToAnyCoder()
    }
}

// MARK: - JSONCoder

/// A coder that serializes `Codable` values using `JSONEncoder` / `JSONDecoder`.
struct JSONCoder<Value: Codable & Sendable>: Coder {
    private let configureEncoder: @Sendable (JSONEncoder) -> Void
    private let configureDecoder: @Sendable (JSONDecoder) -> Void

    init(
        configureEncoder: @escaping @Sendable (JSONEncoder) -> Void,
        configureDecoder: @escaping @Sendable (JSONDecoder) -> Void,
    ) {
        self.configureEncoder = configureEncoder
        self.configureDecoder = configureDecoder
    }

    var coderDescription: String { ".json(\(Value.self))" }

    func encode(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        configureEncoder(encoder)
        return try encoder.encode(value)
    }

    func decode(_ data: Data) throws -> Value {
        let decoder = JSONDecoder()
        configureDecoder(decoder)
        return try decoder.decode(Value.self, from: data)
    }
}
