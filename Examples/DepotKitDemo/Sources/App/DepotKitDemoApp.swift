// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import SwiftUI

#if os(macOS)
import AppKit
#endif

/// "Weather Depot" — a small weather/trip app demonstrating every major
/// DepotKit feature in a realistic setting. See the README next to this
/// package for a feature-to-file map.
@main
struct DepotKitDemoApp: App {
    @State
    private var store = DepotStore()

    init() {
        #if os(macOS)
        // When launched via `swift run` (no app bundle), the process starts
        // as a background app and its windows never accept keyboard input.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
            let image = NSImage(contentsOf: url)
        {
            NSApplication.shared.applicationIconImage = Self.roundedIcon(image)
        }
        #endif
        #endif
    }

    #if os(macOS)
    private static func roundedIcon(_ source: NSImage) -> NSImage {
        let size = source.size
        let radius = size.width * 0.22
        let result = NSImage(size: size)
        result.lockFocus()
        let path = NSBezierPath(
            roundedRect: NSRect(origin: .zero, size: size),
            xRadius: radius,
            yRadius: radius
        )
        path.addClip()
        source.draw(in: NSRect(origin: .zero, size: size))
        result.unlockFocus()
        result.isTemplate = false
        return result
    }
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                #if os(macOS)
            .frame(minWidth: 560, minHeight: 480)
                #endif
        }
    }
}
