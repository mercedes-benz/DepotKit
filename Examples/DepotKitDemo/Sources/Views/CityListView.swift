// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import DepotKit
import DepotKitObservation
import SwiftUI

/// Saved-cities list. Three DepotKit observation handles drive the UI:
///
/// - `@DepotValues` on `cities/*` — re-renders live when cities are added/removed.
/// - `@DepotValues` on `forecasts/*` — decorates each row with cached weather.
/// - `@DepotValue` on the settings key — keeps the temperature unit in sync.
struct CityListView: View {
    let store: DepotStore

    @DepotValues
    private var cities: [City]

    @DepotValues
    private var forecasts: [Forecast]

    @DepotValue
    private var settings: AppSettings?

    @State
    private var showingSearch = false

    init(store: DepotStore) {
        self.store = store
        _cities = DepotValues(key: store.citiesKey, depot: store.depot)
        _forecasts = DepotValues(key: store.forecastsKey, depot: store.depot)
        _settings = DepotValue(key: store.settingsKey, depot: store.depot)
    }

    private var sortedCities: [City] {
        cities.sorted { $0.name < $1.name }
    }

    private var unit: TemperatureUnit {
        settings?.unit ?? .celsius
    }

    /// The cached forecast hour closest to "now" for a city, if any.
    private func currentHour(for city: City) -> Forecast.Hour? {
        guard let forecast = forecasts.first(where: { $0.cityID == city.id }) else {
            return nil
        }
        let now = Date()
        return forecast.hours.last { $0.date <= now } ?? forecast.hours.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if cities.isEmpty {
                    emptyState
                } else {
                    List {
                        Section {
                            ForEach(sortedCities) { city in
                                let hour = currentHour(for: city)
                                NavigationLink {
                                    CityDetailView(store: store, city: city)
                                } label: {
                                    CityRow(city: city, hour: hour, unit: unit)
                                }
                                .listRowSeparator(.hidden)
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(
                                            LinearGradient(
                                                colors: hour?.condition.gradientColors
                                                    ?? [.gray, .gray.opacity(0.5)],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .shadow(
                                            color: (hour?.condition.tint ?? .gray).opacity(0.25),
                                            radius: 8,
                                            y: 4
                                        )
                                        .padding(.vertical, 4)
                                )
                                .swipeActions {
                                    Button("Remove", systemImage: "trash", role: .destructive) {
                                        store.remove(city)
                                    }
                                }
                                .contextMenu {
                                    Button("Remove", systemImage: "trash", role: .destructive) {
                                        store.remove(city)
                                    }
                                }
                            }
                        } footer: {
                            VStack(alignment: .leading, spacing: 6) {
                                DepotAnnotation("@DepotValues · values(for:)")
                                Text(
                                    "^[\(cities.count) city](inflect: true) saved — conditions update live from cached forecasts."
                                )
                            }
                            .padding(.top, 4)
                        }
                    }
                }
            }
            .navigationTitle("Weather Depot")
            .toolbar {
                Button("Add City", systemImage: "plus") {
                    showingSearch = true
                }
            }
            .sheet(isPresented: $showingSearch) {
                CitySearchView(store: store)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            SunAndCloudIllustration()
            Text("No Saved Cities")
                .font(.title2.weight(.semibold))
            Text("Add a city to start collecting forecasts.")
                .foregroundStyle(.secondary)
            Button("Add City", systemImage: "plus") {
                showingSearch = true
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A single city row: weather symbol, name, and temperature on a gradient card.
private struct CityRow: View {
    let city: City
    let hour: Forecast.Hour?
    let unit: TemperatureUnit

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let hour {
                    Image(systemName: hour.condition.systemImage)
                        .font(.system(size: 30))
                        .symbolRenderingMode(.hierarchical)
                } else {
                    Image(systemName: "icloud.slash")
                        .font(.title2)
                        .opacity(0.6)
                }
            }
            .frame(width: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(city.name)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .opacity(0.8)
            }

            Spacer()

            if let hour {
                Text(unit.format(celsius: hour.temperature))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical, 6)
    }

    private var subtitle: String {
        if let hour {
            "\(city.country) · \(hour.condition.label)"
        } else {
            "\(city.country) · No forecast cached"
        }
    }
}
