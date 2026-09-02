// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import Testing
import UIKit

@testable import DepotKit

@MainActor
@Suite
struct ImageCoderTests {
    @Test(".uiImage() (UIImage) works as expected")
    func worksUIKit() async throws {
        let coder = UIImageCoder.uiImage()

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

    @Test(".swiftUIImage() (Image) works as expected")
    func worksSwiftUI() async throws {
        let coder = ImageCoder.swiftUIImage()

        let values = [
            Image(systemName: "cpu"),
            Image(systemName: "headphones"),
            Image(systemName: "snow"),
        ]

        for value in values {
            #expect(throws: Never.self) {
                let encoded = try coder.encode(value)
                _ = try coder.decode(encoded)
            }
        }
    }
}

#endif
