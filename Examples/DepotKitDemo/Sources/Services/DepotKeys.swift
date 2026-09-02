// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import DepotKit
import Foundation

/// Central namespace for all depot key definitions — the app's storage
/// schema at a glance.
enum DepotKeys {
    // MARK: Macro-defined keys

    /// All saved cities under `cities/<id>`. Compile-time validated.
    static let allCities = #pattern("cities/*", coder: .json(City.self))

    /// Timestamp of the most recent forecast refresh.
    static let lastRefresh = #key("stats/lastRefresh", coder: .json(Date.self))

    /// Transient city-search results. Registered on the memory-only depot.
    static let searchResults = #pattern("search/*", coder: .json(City.self))

    // MARK: Versioned settings

    /// App settings with schema migration. V1 stored a raw unit string;
    /// v2 stores the full `AppSettings` struct. The migration closure
    /// upgrades old payloads transparently on first read.
    static let settings = KeyDefinition<AppSettings>(
        path: "settings" / "app",
        coder: AnyCoder<AppSettings>.json().versioned(version: 2) { data, version in
            guard version == nil || version == 1 else {
                return nil
            }
            // v1 (or unversioned) payloads were a bare JSON-encoded unit string.
            let unit = try JSONDecoder().decode(TemperatureUnit.self, from: data)
            return AppSettings(unit: unit)
        }
    )

    // MARK: Distinct keys derived from patterns

    /// Distinct key for one city, covered by the `cities/*` pattern.
    static func cityKey(_ id: String) -> TypedDistinctKey<City> {
        Key.from("cities" / id, as: City.self)
    }

    /// Distinct key for one forecast, covered by the `forecasts/*` pattern.
    static func forecastKey(_ id: String) -> TypedDistinctKey<Forecast> {
        Key.from("forecasts" / id, as: Forecast.self)
    }
}
