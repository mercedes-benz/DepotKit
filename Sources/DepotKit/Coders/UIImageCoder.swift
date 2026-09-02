// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if canImport(UIKit)
import UIKit

import ImageIO
import UniformTypeIdentifiers

extension AnyCoder where Value == UIImage {
    /// Creates a coder that converts `UIImage` to and from *HEIF* format.
    ///
    /// ```swift
    /// depot.register(key: Key.from("avatar"), coder: .uiImage())
    /// ```
    public static func uiImage(_ type: Value.Type = Value.self) -> AnyCoder<Value> {
        UIImageCoder().eraseToAnyCoder()
    }
}

// MARK: - UIImageCoder

/// A coder that converts `UIImage` values to and from HEIF data.
struct UIImageCoder: Coder {
    var coderDescription: String { ".uiImage()" }

    func encode(_ value: UIImage) throws(DataCoderError) -> Data {
        guard let cgImage = value.cgImage else {
            throw DataCoderError.noData
        }

        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data,
                UTType.heif.identifier as CFString,
                1,
                nil,
            )
        else {
            throw DataCoderError.noData
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw DataCoderError.noData
        }

        return data as Data
    }

    func decode(_ data: Data) throws(DataCoderError) -> UIImage {
        guard let value = UIImage(data: data) else {
            throw DataCoderError.badData
        }

        return value
    }
}

#endif
