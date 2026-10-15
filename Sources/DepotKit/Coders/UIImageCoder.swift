// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if canImport(UIKit)
import UIKit

import ImageIO
import UniformTypeIdentifiers

extension AnyCoder where Value == UIImage {
    /// Creates a coder that converts `UIImage` to and from *HEIC* format.
    ///
    /// Images are encoded as *PNG* where no HEIC encoder is available, for
    /// example on simulators. Decoding accepts both formats on every platform.
    ///
    /// ```swift
    /// depot.register(key: Key.from("avatar"), coder: .uiImage())
    /// ```
    public static func uiImage(_ type: Value.Type = Value.self) -> AnyCoder<Value> {
        UIImageCoder().eraseToAnyCoder()
    }
}

// MARK: - UIImageCoder

/// A coder that converts `UIImage` values to and from HEIC data (PNG where HEIC can't be encoded).
struct UIImageCoder: Coder {
    /// The formats to try, in order of preference.
    static let preferredTypes: [UTType] = {
        #if targetEnvironment(simulator)
        // Simulators can't encode HEIC.
        return [.png]
        #else
        // Devices encode the HEIC variant of HEIF (`public.heic`), not `public.heif`.
        return [.heic, .png]
        #endif
    }()

    /// The encodable formats among ``preferredTypes``, in order of preference.
    static let encodableTypes: [UTType] = {
        let identifiers = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        let types = preferredTypes.filter { identifiers.contains($0.identifier) }
        return types.isEmpty ? [.png] : types
    }()

    /// The format that images are encoded in.
    static var encodedType: UTType {
        encodableTypes[0]
    }

    let types: [UTType]

    init(types: [UTType] = UIImageCoder.encodableTypes) {
        self.types = types
    }

    var coderDescription: String { ".uiImage()" }

    func encode(_ value: UIImage) throws(DataCoderError) -> Data {
        let normalized = value.normalizedImage()
        guard let cgImage = normalized.cgImage else {
            throw DataCoderError.noData
        }

        // Fall back to the next format when a destination can't be created or finalized.
        for type in types {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
                continue
            }

            CGImageDestinationAddImage(destination, cgImage, nil)
            if CGImageDestinationFinalize(destination) {
                return data as Data
            }
        }

        throw DataCoderError.noData
    }

    func decode(_ data: Data) throws(DataCoderError) -> UIImage {
        guard let value = UIImage(data: data) else {
            throw DataCoderError.badData
        }

        return value
    }
}

extension UIImage {
    fileprivate func normalizedImage() -> UIImage {
        guard imageOrientation != .up else {
            return self
        }
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        draw(in: CGRect(origin: .zero, size: size))
        let normalized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return normalized ?? self
    }
}

#endif
