// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

// Compiles and runs the code examples from README.md.

import DepotKit
import Foundation
import Testing

#if DEPOTKIT_MACROS
private enum WeatherKeys {
    static let units = #key("preferences/units", coder: .json(UnitPreferences.self))
    static let savedLocations = #key("locations/saved", coder: .json([SavedLocation].self))
    static let lastModified = #key("locations/lastModified", coder: .json(Date.self))
    // One pattern covers berlin/forecast, tokyo/forecast, etc.
    static let forecast = #pattern("locations/*/forecast", coder: .json(Forecast.self))
}
#endif

/// "Creating a Depot" — compiled only, because it writes to system directories and needs an app group.
private func readmeCreatingADepot() throws -> [Depot] {
    let depot = try Depot(name: "Weather")  // Application Support
    let cache = try Depot(directory: .caches, name: "WeatherCache")  // re-downloadable data
    let ephemeral = Depot()  // memory-only, for previews and tests

    // Shared with app extensions. In the host app, also watch for changes made by other processes:
    let shared = try Depot(appGroup: "group.com.example.weather", name: "Shared")
    try shared.automaticallyCheckForExternalChanges()

    return [depot, cache, ephemeral, shared]
}

/// The lead example's depot location — compiled only.
private func readmeLeadExampleDepot() throws -> Depot {
    try Depot(name: "Weather")
}

@Suite("Documentation: README")
struct ReadmeSnippetTests {

    #if DEPOTKIT_MACROS
    @Test("lead example: keys, a family, reading, writing, and observing")
    func leadExample() async throws {
        let depot = makeSnippetDepot()  // README: try Depot(name: "Weather")
        defer { removeSnippetDirectory(of: depot) }
        var applied: [UnitPreferences?] = []
        func apply(_ value: UnitPreferences?) {
            applied.append(value)
        }

        // A key is a typed path plus a coder; a pattern covers a whole family of keys.
        let units = depot.register(#key("preferences/units", coder: .json(UnitPreferences.self)))
        let forecasts = depot.register(#pattern("forecasts/*", coder: .json(Forecast.self)))
        try await depot.set(
            value: Forecast(city: "Berlin", highs: [21]),
            for: Key.from("forecasts" / "berlin", as: Forecast.self)
        )

        try await depot.set(value: UnitPreferences(temperature: .celsius), for: units)
        let current = try await depot.get(valueFor: units)  // UnitPreferences?
        #expect(current == UnitPreferences(temperature: .celsius))

        let cached = try await depot.get(valuesFor: forecasts)  // [Forecast]
        #expect(cached == [Forecast(city: "Berlin", highs: [21])])
        try await depot.remove(valuesFor: forecasts)  // drop the whole family
        #expect(try await depot.count(for: forecasts) == 0)

        // Observe: the current value first, then the latest state after each change.
        for await case .success(let value) in depot.values(for: units) {
            apply(value)
            break
        }
        #expect(applied == [UnitPreferences(temperature: .celsius)])
    }
    #endif

    #if DEPOTKIT_MACROS
    @Test("keys, registration, reading, and writing")
    func keysAndReadingAndWriting() async throws {
        let depot = makeSnippetDepot()
        defer { removeSnippetDirectory(of: depot) }
        let preferences = UnitPreferences(temperature: .fahrenheit)
        let berlinForecast = Forecast(city: "Berlin", highs: [20])

        let unitsKey = depot.register(WeatherKeys.units)
        let locationsKey = depot.register(WeatherKeys.savedLocations)
        let lastModifiedKey = depot.register(WeatherKeys.lastModified)
        let forecastKey = depot.register(WeatherKeys.forecast)

        // Reading and Writing
        try await depot.set(value: preferences, for: unitsKey)
        let stored = try await depot.get(valueFor: unitsKey)  // UnitPreferences?
        #expect(stored == preferences)
        try await depot.remove(valueFor: unitsKey)
        #expect(try await depot.get(valueFor: unitsKey) == nil)

        // Address a single member of the family
        let berlin = Key.from("locations" / "berlin" / "forecast", as: Forecast.self)
        try await depot.set(value: berlinForecast, for: berlin)

        let allForecasts = try await depot.get(valuesFor: forecastKey)  // [Forecast], in no particular order
        let count = try await depot.count(for: forecastKey)
        #expect(allForecasts == [berlinForecast])
        #expect(count == 1)
        try await depot.remove(valuesFor: forecastKey)
        #expect(try await depot.count(for: forecastKey) == 0)

        // Transactions
        try await depot.transaction { tx in
            var locations = try tx.get(valueFor: locationsKey) ?? []
            locations.append(SavedLocation(name: "Berlin", latitude: 52.52, longitude: 13.40))
            try tx.set(value: locations, for: locationsKey)
            try tx.set(value: Date.now, for: lastModifiedKey)
        }
        #expect(try await depot.get(valueFor: locationsKey)?.map(\.name) == ["Berlin"])
        #expect(try await depot.has(valueFor: lastModifiedKey))
    }

    @Test("registering the same definition again is harmless")
    func reRegistration() throws {
        let depot = makeSnippetDepot()
        defer { removeSnippetDirectory(of: depot) }

        let first = depot.register(WeatherKeys.units)
        try depot.set(value: .standard, for: first)
        let second = depot.register(WeatherKeys.units)

        #expect(first == second)
        #expect(try depot.get(valueFor: first) == .standard)
    }

    @Test("observation as an AsyncSequence")
    func asyncObservation() async throws {
        let depot = makeSnippetDepot()
        defer { removeSnippetDirectory(of: depot) }
        let unitsKey = depot.register(WeatherKeys.units)
        try await depot.set(value: .standard, for: unitsKey)
        var applied: [UnitPreferences?] = []
        func apply(_ preferences: UnitPreferences?) {
            applied.append(preferences)
        }

        for await result in depot.values(for: unitsKey) {
            if case .success(let preferences) = result {
                apply(preferences)
            }
            break
        }

        #expect(applied == [.standard])
    }
    #endif

    @Test("TTL / expiry registration")
    func expiry() async throws {
        let depot = makeSnippetDepot()
        defer { removeSnippetDirectory(of: depot) }

        let hourlyForecast = depot.register(
            keyPath: "locations" / "current" / "hourly",
            coder: .json(Forecast.self),
            expiry: .seconds(30 * 60)
        )

        try await depot.set(value: Forecast(city: "Berlin", highs: [20]), for: hourlyForecast)
        let metadata = try #require(try await depot.metadata(for: hourlyForecast))
        let expiresAt = try #require(metadata.expiresAt)
        #expect(abs(expiresAt.timeIntervalSince(metadata.modifiedAt) - 30 * 60) < 1)
        #expect(try await depot.removeExpired() == 0)
    }

    @Test("coder composition with versioned migration")
    func coderComposition() throws {
        let coder: AnyCoder<Forecast> = .json()
            .versioned(version: 2) { data, oldVersion in
                // Migrates payloads written with an older version.
                let legacy = try JSONDecoder().decode(LegacyForecast.self, from: data)
                return Forecast(city: legacy.name, highs: legacy.highs)
            }
            .compressed(using: .lz4)

        let forecast = Forecast(city: "Berlin", highs: [21])
        #expect(try coder.decode(coder.encode(forecast)) == forecast)

        // A payload written by version 1, which had no version header and a different schema.
        let legacyCoder: AnyCoder<LegacyForecast> = AnyCoder<LegacyForecast>.json().compressed(using: .lz4)
        let legacyData = try legacyCoder.encode(LegacyForecast(name: "Tokyo", highs: [28]))
        #expect(try coder.decode(legacyData) == Forecast(city: "Tokyo", highs: [28]))
    }
}
