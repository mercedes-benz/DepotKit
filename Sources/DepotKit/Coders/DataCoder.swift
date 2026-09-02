// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

extension AnyCoder where Value: LosslessDataConvertible {
    /// Creates a coder for raw data (pass-through for `LosslessDataConvertible` types).
    ///
    /// ```swift
    /// depot.register(key: Key.from("user" / "avatar"), coder: .data())
    /// #key("user/avatar", coder: .data(Data.self))
    /// ```
    public static func data(_ type: Value.Type = Value.self) -> AnyCoder<Value> {
        DataCoder<Value>().eraseToAnyCoder()
    }
}

/// Errors related to the data coder.
public enum DataCoderError: Error, Equatable {
    /// No data is available.
    case noData

    /// The data is corrupted in some way.
    case badData
}

extension DataCoderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noData:
            "No data is available for conversion."
        case .badData:
            "The data is corrupted or invalid."
        }
    }
}

// MARK: - DataCoder

/// A coder that passes values through ``LosslessDataConvertible`` for zero-overhead data roundtripping.
struct DataCoder<Value: LosslessDataConvertible>: Coder {
    var coderDescription: String { ".data(\(Value.self))" }

    func encode(_ value: Value) throws(DataCoderError) -> Data {
        guard let data = value.dataRepresentation else {
            throw DataCoderError.noData
        }

        return data
    }

    func decode(_ data: Data) throws(DataCoderError) -> Value {
        guard let value = Value(dataRepresentation: data) else {
            throw DataCoderError.badData
        }

        return value
    }
}
