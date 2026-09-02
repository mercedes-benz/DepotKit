// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import DepotKit
import DepotKitObservation
import SwiftUI

/// Forecast detail for a single city. Shows cached hourly weather, cache age
/// (via `metadata(for:)`), a refresh action, and a "Clear Expired" sweep.
/// The temperature unit reacts live to Settings via `@DepotValue`.
struct CityDetailView: View {
    @State
    private var model: ForecastModel

    @DepotValue
    private var settings: AppSettings?

    init(store: DepotStore, city: City) {
        _model = State(initialValue: ForecastModel(store: store, city: city))
        _settings = DepotValue(key: store.settingsKey, depot: store.depot)
    }

    private var unit: TemperatureUnit {
        settings?.unit ?? .celsius
    }

    private var currentHour: Forecast.Hour? {
        guard let forecast = model.forecast else {
            return nil
        }
        let now = Date()
        return forecast.hours.last { $0.date <= now } ?? forecast.hours.first
    }

    var body: some View {
        List {
            if let hour = currentHour {
                Section {
                    HeroHeader(city: model.city, hour: hour, unit: unit)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            cacheSection

            if let forecast = model.forecast {
                Section("Next 24 Hours") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 18) {
                            ForEach(forecast.hours.prefix(24)) { hour in
                                VStack(spacing: 8) {
                                    Text(hour.date, format: .dateTime.hour())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                    ConditionSymbol(condition: hour.condition)
                                        .font(.title3)
                                        .frame(height: 24)
                                    Text(unit.format(celsius: hour.temperature))
                                        .font(.callout.weight(.medium))
                                        .monospacedDigit()
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } else {
                Section {
                    Text("No cached forecast — it either expired (30 min TTL) or was never fetched.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(model.city.name)
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task {
                    await model.refresh()
                }
            }
            .disabled(model.isRefreshing)
        }
        .task {
            model.load()
            // Auto-fetch on first visit if the cache is cold and settings allow.
            if model.forecast == nil, settings?.autoRefresh ?? true {
                await model.refresh()
            }
        }
    }

    private var cacheSection: some View {
        Section {
            if let metadata = model.metadata {
                LabeledContent {
                    Text(metadata.modifiedAt, format: .relative(presentation: .named))
                } label: {
                    Label("Fetched", systemImage: "clock")
                }
                if let expiresAt = metadata.expiresAt {
                    LabeledContent {
                        Text(expiresAt, format: .relative(presentation: .named))
                    } label: {
                        Label("Expires", systemImage: "timer")
                    }
                }
            } else {
                Label("Nothing cached for this city.", systemImage: "tray")
                    .foregroundStyle(.secondary)
            }

            Button("Clear Expired Values", systemImage: "trash.slash") {
                Task {
                    await model.clearExpired()
                }
            }

            if let removed = model.lastRemovedCount {
                Text("Last sweep removed \(removed) expired value(s).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Cache")
        } footer: {
            DepotAnnotation("metadata(for:) · removeExpired()")
                .padding(.top, 2)
        }
    }
}

/// Gradient hero card: large temperature, pulsing weather symbol, condition-matched background.
private struct HeroHeader: View {
    let city: City
    let hour: Forecast.Hour
    let unit: TemperatureUnit

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(unit.format(celsius: hour.temperature))
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("\(hour.condition.label) · \(city.country)")
                    .font(.subheadline.weight(.medium))
                    .opacity(0.85)
            }

            Spacer()

            Image(systemName: hour.condition.systemImage)
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.pulse, options: .repeating)
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: hour.condition.gradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
