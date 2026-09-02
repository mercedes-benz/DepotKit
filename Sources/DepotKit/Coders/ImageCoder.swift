// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if canImport(SwiftUI) && canImport(UIKit)
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension AnyCoder where Value == Image {
    /// Creates a coder that converts SwiftUI `Image` values to and from *HEIF* format.
    ///
    /// ```swift
    /// depot.register(key: Key.from("avatar"), coder: .image())
    /// ```
    ///
    /// > Note: Encoding requires the main actor because `ImageRenderer` is `@MainActor`.
    @MainActor
    public static func image(_ type: Value.Type = Value.self) -> AnyCoder<Value> {
        ImageCoder().eraseToAnyCoder()
    }
}

// MARK: - ImageCoder

/// A coder that converts SwiftUI `Image` values to and from HEIF via `ImageRenderer`.
@MainActor
struct ImageCoder: @preconcurrency Coder {
    var coderDescription: String { ".image()" }

    func encode(_ value: Image) throws(DataCoderError) -> Data {
        let renderer = ImageRenderer(content: value)
        guard let cgImage = renderer.cgImage else {
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

    nonisolated func decode(_ data: Data) throws(DataCoderError) -> Image {
        guard let uiImage = UIImage(data: data) else {
            throw DataCoderError.badData
        }

        return Image(uiImage: uiImage)
    }
}

#endif
