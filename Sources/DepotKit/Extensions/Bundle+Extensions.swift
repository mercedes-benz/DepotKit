// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

extension Bundle {
    /// Returns `true` if the bundle is the main app and not one of its extensions.
    var isApp: Bool {
        bundleURL.pathExtension == "app"
    }

    /// Returns `true` if the bundle is an app extension and not the main app.
    var isAppExtension: Bool {
        bundleURL.pathExtension == "appex"
    }
}
