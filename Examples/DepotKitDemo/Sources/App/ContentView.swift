// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import SwiftUI

/// Root view — a three-tab layout wiring each tab to the shared ``DepotStore``.
struct ContentView: View {
    let store: DepotStore

    var body: some View {
        TabView {
            CityListView(store: store)
                .tabItem {
                    Label("Cities", systemImage: "building.2")
                }

            ActivityLogView(store: store)
                .tabItem {
                    Label("Activity", systemImage: "list.bullet.rectangle")
                }

            SettingsView(store: store)
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .tint(.depotAmber)
    }
}
