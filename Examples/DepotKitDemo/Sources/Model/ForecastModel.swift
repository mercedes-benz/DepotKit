// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import DepotKit
import Foundation
import Observation

/// Loads and refreshes one city's cached forecast. Forecasts expire after
/// 30 min (configured at registration) — an expired value reads as `nil`.
@MainActor
@Observable
final class ForecastModel {
    let city: City

    private(set) var forecast: Forecast?
    private(set) var metadata: ValueMetadata?
    private(set) var isRefreshing = false
    private(set) var lastRemovedCount: Int?

    @ObservationIgnored
    private let store: DepotStore

    @ObservationIgnored
    private let service = WeatherService()

    private var key: TypedDistinctKey<Forecast> {
        DepotKeys.forecastKey(city.id)
    }

    init(store: DepotStore, city: City) {
        self.store = store
        self.city = city
    }

    /// Reads the cached forecast and its file metadata (write date, expiry).
    func load() {
        forecast = try? store.depot.get(valueFor: key)
        metadata = try? store.depot.metadata(for: key)
    }

    /// Fetches fresh data, overwrites the cache, and updates the last-refresh
    /// timestamp (consumed by the Combine-driven status in the Activity tab).
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let fresh = await service.forecast(for: city)
        try? await store.depot.set(value: fresh, for: key)
        try? await store.depot.set(value: Date(), for: store.lastRefreshKey)
        load()
    }

    /// Sweeps all expired values across the entire depot.
    func clearExpired() async {
        lastRemovedCount = try? await store.depot.removeExpired()
        load()
    }
}
