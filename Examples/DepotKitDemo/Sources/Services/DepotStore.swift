// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import DepotKit
import Foundation

/// Owns the two depots and all registered key handles.
///
/// - `depot` — persistent, file-backed. Cities, forecasts, and settings
///   survive restarts.
/// - `searchDepot` — memory-only. Transient search results, gone on quit.
@MainActor
final class DepotStore {
    let depot: Depot
    let searchDepot = Depot(label: "CitySearch")

    let citiesKey: TypedKey<City>
    let forecastsKey: TypedKey<Forecast>
    let settingsKey: TypedDistinctKey<AppSettings>
    let lastRefreshKey: TypedDistinctKey<Date>
    let searchResultsKey: TypedKey<City>

    init() {
        do {
            // Persistent depot in Application Support, named "WeatherDepot".
            depot = try Depot(name: "WeatherDepot")
        } catch {
            // Sandboxing problems shouldn't kill a demo — degrade to memory.
            print("WeatherDepot could not be created on disk (\(error)); using in-memory fallback.")
            depot = Depot(label: "WeatherDepot")
        }

        citiesKey = depot.register(DepotKeys.allCities)
        settingsKey = depot.register(DepotKeys.settings)
        lastRefreshKey = depot.register(DepotKeys.lastRefresh)

        // Forecasts are large (168 hourly entries) — compress on disk, expire after 30 min.
        let forecastCoder: AnyCoder<Forecast> = .json().compressed(using: .zlib)
        forecastsKey = depot.register(
            keyPath: "forecasts" / .wildcard,
            coder: forecastCoder,
            expiry: .seconds(1800)
        )

        searchResultsKey = searchDepot.register(DepotKeys.searchResults)
    }

    // MARK: - Cities

    /// Saves a city under `cities/<id>`, picked up by the `cities/*` pattern.
    func add(_ city: City) {
        try? depot.set(value: city, for: DepotKeys.cityKey(city.id))
    }

    /// Removes a city and its cached forecast.
    func remove(_ city: City) {
        try? depot.remove(valueFor: DepotKeys.cityKey(city.id))
        try? depot.remove(valueFor: DepotKeys.forecastKey(city.id))
    }

    /// Snapshot read of all saved cities.
    func savedCities() -> [City] {
        (try? depot.get(valuesFor: citiesKey)) ?? []
    }

    // MARK: - Search (memory-only depot)

    /// Replaces the transient search results in the memory depot.
    func updateSearchResults(_ cities: [City]) {
        try? searchDepot.remove(valuesFor: searchResultsKey)
        for city in cities {
            try? searchDepot.set(value: city, for: Key.from("search" / city.id, as: City.self))
        }
    }
}
