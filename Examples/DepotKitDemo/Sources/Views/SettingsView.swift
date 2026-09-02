// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import DepotKit
import DepotKitObservation
import SwiftUI

/// App settings backed by the versioned `settings/app` key. `@DepotValue`
/// gives `@AppStorage`-like ergonomics — writes propagate to every observer.
struct SettingsView: View {
    let store: DepotStore

    @DepotValue
    private var settings: AppSettings?

    init(store: DepotStore) {
        self.store = store
        _settings = DepotValue(key: store.settingsKey, depot: store.depot)
    }

    private var current: AppSettings {
        settings ?? AppSettings()
    }

    private func update(_ transform: (inout AppSettings) -> Void) {
        var updated = current
        transform(&updated)
        $settings.wrappedValue = updated
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(Color.depotAmber)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("DepotKit Demo")
                                .font(.headline)
                            Text("Weather showcase app")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Units") {
                    HStack {
                        Label("Temperature", systemImage: "thermometer.medium")
                        Spacer()
                        Picker(
                            "Temperature",
                            selection: Binding(
                                get: { current.unit },
                                set: { newUnit in update { $0.unit = newUnit } }
                            )
                        ) {
                            ForEach(TemperatureUnit.allCases) { unit in
                                Text(unit.symbol).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                Section("Forecasts") {
                    Toggle(isOn: Binding(
                        get: { current.autoRefresh },
                        set: { newValue in update { $0.autoRefresh = newValue } }
                    )) {
                        Label("Auto-fetch when cache is cold", systemImage: "arrow.clockwise")
                    }
                    .tint(.depotAmber)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        DepotAnnotation(".json().versioned(version:migrate:)")
                        Text(
                            """
                            Settings are stored with a versioned coder (schema v2). \
                            If this app previously wrote v1 data (a bare unit string), \
                            the migration closure upgrades it transparently on first read.
                            """
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                Section("Depot") {
                    LabeledContent {
                        Text("WeatherDepot")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Name", systemImage: "externaldrive")
                    }
                    LabeledContent {
                        Text("Application Support")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Directory", systemImage: "folder")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
        }
    }
}
