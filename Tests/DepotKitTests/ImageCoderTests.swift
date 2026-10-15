// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if canImport(UIKit)
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import DepotKit

@Suite
struct ImageCoderTests {
    @Test(".uiImage() (UIImage) works as expected")
    func worksUIKit() async throws {
        let coder: AnyCoder<UIImage> = .uiImage()

        let values = [
            UIImage(systemName: "cpu")!,
            UIImage(systemName: "headphones")!,
            UIImage(systemName: "snow")!,
        ]

        for value in values {
            #expect(throws: Never.self) {
                let encoded = try coder.encode(value)
                _ = try coder.decode(encoded)
            }
        }
    }

    @Test(".uiImage() encodes HEIC where an encoder is available and PNG otherwise")
    func encodedFormat() throws {
        let encoded = try AnyCoder<UIImage>.uiImage().encode(UIImage(systemName: "cpu")!)

        #if targetEnvironment(simulator)
        #expect(UIImageCoder.encodedType == .png)
        #expect(Self.isPNG(encoded))
        #else
        let writers = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        if writers.contains(UTType.heic.identifier) {
            #expect(UIImageCoder.encodedType == .heic)
            #expect(Self.isHEIC(encoded))
        } else {
            #expect(UIImageCoder.encodedType == .png)
            #expect(Self.isPNG(encoded))
        }
        #endif
    }

    @Test(".uiImage() falls back to PNG when the preferred format can't be encoded")
    func fallsBackToPNG() throws {
        // No image destination can be created for plain text.
        let coder = UIImageCoder(types: [.plainText, .png])
        let encoded = try coder.encode(UIImage(systemName: "cpu")!)

        #expect(Self.isPNG(encoded))
        #expect(throws: Never.self) { try coder.decode(encoded) }
    }

    @Test(".uiImage() throws when no format can be encoded")
    func throwsWithoutEncodableFormat() {
        let coder = UIImageCoder(types: [.plainText])
        #expect(throws: DataCoderError.noData) { try coder.encode(UIImage(systemName: "cpu")!) }
    }

    private static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    }

    /// An ISO base media file whose major brand is a HEIC brand.
    private static func isHEIC(_ data: Data) -> Bool {
        guard data.count >= 12, data.dropFirst(4).starts(with: Array("ftyp".utf8)) else {
            return false
        }
        let brand = String(decoding: data.dropFirst(8).prefix(4), as: UTF8.self)
        return ["heic", "heix", "mif1"].contains(brand)
    }
}

#endif
