// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

// Compiles and runs the code examples from the Keys and Coders article.

import DepotKit
import Foundation
import Testing

private struct WidgetConfig: Codable, Sendable, Equatable {
    var showsHighs: Bool
}

private struct WeatherAlert: Codable, Sendable, Equatable {
    var title: String
}

private struct Profile: Codable, Sendable, Equatable {
    var name: String
}

/// Stores a date as an ISO 8601 string with whole-second precision.
private struct ISO8601DateCoder: Coder {
    func encode(_ value: Date) throws -> Data {
        Data(value.formatted(.iso8601).utf8)
    }

    func decode(_ data: Data) throws -> Date {
        try Date(String(decoding: data, as: UTF8.self), strategy: .iso8601)
    }
}

private struct Place: Codable, Sendable, Equatable {
    var name: String
    var latitude: Double
    var longitude: Double
    var timeZone: String?  // added in version 3
}

/// Version 1 stored the coordinates as strings.
private struct PlaceV1: Codable {
    var name: String
    var lat: String
    var lon: String
}

private let placeCoder: AnyCoder<Place> = .json().versioned(version: 3) { data, oldVersion in
    switch oldVersion {
    case nil, 1:
        let old = try JSONDecoder().decode(PlaceV1.self, from: data)
        guard let latitude = Double(old.lat), let longitude = Double(old.lon) else {
            return nil
        }
        return Place(name: old.name, latitude: latitude, longitude: longitude, timeZone: nil)
    case 2:
        // Version 2 had no time zone; the optional property decodes as nil.
        return try JSONDecoder().decode(Place.self, from: data)
    default:
        return nil
    }
}

#if DEPOTKIT_MACROS
private final class WeatherStore {
    let depot: Depot
    let forecastKey: TypedKey<Forecast>
    let unitsKey: TypedDistinctKey<UnitPreferences>
    let savedLocationsKey: TypedDistinctKey<[SavedLocation]>

    init() throws {
        depot = try Depot(name: "Weather")

        forecastKey = depot.register(
            keyPath: "locations" / .wildcard / "forecast",
            coder: .json(Forecast.self),
            expiry: .seconds(1800)
        )
        unitsKey = depot.register(
            #key("preferences/units", coder: .json(UnitPreferences.self))
        )
        savedLocationsKey = depot.register(
            #key("locations/saved", coder: .json([SavedLocation].self))
        )
    }

    /// Test-only: the same registrations on a temporary depot.
    init(depot: Depot) {
        self.depot = depot
        forecastKey = depot.register(
            keyPath: "locations" / .wildcard / "forecast",
            coder: .json(Forecast.self),
            expiry: .seconds(1800)
        )
        unitsKey = depot.register(
            #key("preferences/units", coder: .json(UnitPreferences.self))
        )
        savedLocationsKey = depot.register(
            #key("locations/saved", coder: .json([SavedLocation].self))
        )
    }

    func forecast(for locationId: String) async throws -> Forecast? {
        let key = Key.from("locations" / locationId / "forecast", as: Forecast.self)
        return try await depot.get(valueFor: key)
    }
}

/// Compiled only: creates a depot in Application Support.
private func keysAndCodersCompileOnly() throws -> Depot {
    try WeatherStore().depot
}
#endif

@Suite("Documentation: Keys and Coders")
struct KeysAndCodersSnippetTests {

    @Test("constructing keys with the / operator and appending")
    func constructingKeys() {
        // Distinct keys — concrete path, no wildcards
        let key = Key.from("preferences" / "units")  // DistinctKey
        let typed = Key.from("widget" / "config", as: WidgetConfig.self)  // TypedDistinctKey<WidgetConfig>

        // Dynamic components — any CustomStringConvertible works
        let cityId = "berlin-52-13"
        let forecast = Key.from("locations" / cityId / "forecast")  // DistinctKey

        // Pattern keys — contain wildcards
        let allForecasts = Key.from("locations" / .wildcard / "forecast")  // Key (pattern)
        let allCached = Key.from("cache" / .globstar)  // Key (pattern)

        #expect(key.keyPath == "preferences/units")
        #expect(typed.keyPath == "widget/config")
        #expect(allForecasts.matches(forecast))
        #expect(allCached.matches(Key.from("cache" / "a" / "b")))
        #expect(Key.from("locations" / .wildcard).matches(Key.from("locations" / "berlin")))
        #expect(!Key.from("locations" / .wildcard).matches(Key.from("locations" / "berlin" / "forecast")))
        #expect(Key.from("locations" / .globstar).matches(Key.from("locations" / "berlin" / "forecast")))
        #expect(!Key.from("locations" / .globstar).matches(Key.from("locations")))
        #expect(Key.from(.globstar / "forecast").matches(Key.from("forecast")))
        #expect(Key.from("locations" / .globstar / "forecast").matches(Key.from("locations" / "forecast")))

        let base = Key.from("locations", as: Forecast.self)
        let berlinForecast = base.appending("berlin").appending("forecast")
        // → TypedDistinctKey<Forecast> for "locations/berlin/forecast"
        #expect(berlinForecast == Key.from("locations" / "berlin" / "forecast", as: Forecast.self))
    }

    @Test("a trailing globstar does not cover a differently typed value at its prefix")
    func trailingGlobstarPrefixValue() async throws {
        let depot = Depot()

        let userIDs = depot.register(keyPath: "users", coder: .json([String].self))
        let profiles = depot.register(keyPath: "users" / .wildcard, coder: .json(Profile.self))

        try await depot.set(value: ["alice"], for: userIDs)
        try await depot.set(value: Profile(name: "Alice"), for: Key.from("users" / "alice", as: Profile.self))

        let all = try await depot.get(valuesFor: profiles)  // [Profile] — the list at `users` is not included
        #expect(all == [Profile(name: "Alice")])
        try await depot.remove(valuesFor: Key.from("users" / .globstar))  // removes users/…, keeps the list at `users`
        #expect(try await depot.get(valueFor: userIDs) == ["alice"])
        #expect(try await depot.count(for: profiles) == 0)
    }

    @Test("key definitions with macros, manual initializers, and expiry")
    func keyDefinitions() throws {
        #if DEPOTKIT_MACROS
        let savedLocations = #key("locations/saved", coder: .json([SavedLocation].self))
        let allForecasts = #pattern("locations/*/forecast", coder: .json(Forecast.self))
        #endif
        let widgetConfig = KeyDefinition<WidgetConfig>(
            path: "widget" / "config",
            coder: .json()
        )
        let forecast = PatternKeyDefinition<Forecast>(
            path: "locations" / .wildcard / "forecast",
            coder: .json(),
            expiry: .seconds(1800)  // 30 minutes
        )

        #if DEPOTKIT_MACROS
        #expect(savedLocations.key == Key.from("locations" / "saved"))
        #expect(allForecasts.key == forecast.key)
        #endif
        #expect(widgetConfig.expiry == nil)
        #expect(forecast.expiry == .seconds(1800))

        let depot = makeSnippetDepot()
        defer { removeSnippetDirectory(of: depot) }
        let widgetKey = depot.register(widgetConfig)
        try depot.set(value: WidgetConfig(showsHighs: true), for: widgetKey)
        #expect(try depot.get(valueFor: widgetKey) == WidgetConfig(showsHighs: true))
    }

    @Test("coder composition and custom coders")
    func coders() throws {
        let encryptionConfig = try EncryptionConfiguration(
            cipher: .chaChaPoly,
            hashFunction: .sha256,
            key: EncryptionConfiguration.generateKey()
        )
        let coders: [AnyCoder<Forecast>] = [
            .json(Forecast.self),
            .json(Forecast.self).compressed(using: .lz4),
            .json(Forecast.self).encrypted(using: encryptionConfig),
            .json(Forecast.self).compressed(using: .lz4).encrypted(using: encryptionConfig),
            .json(Forecast.self).versioned(version: 2) { data, oldVersion in
                try? JSONDecoder().decode(Forecast.self, from: data)
            },
        ]
        let value = Forecast(city: "Berlin", highs: [21])
        for coder in coders {
            #expect(try coder.decode(coder.encode(value)) == value)
        }

        let depot = makeSnippetDepot()
        defer { removeSnippetDirectory(of: depot) }
        let lastSyncKey = depot.register(
            keyPath: "sync" / "last",
            coder: ISO8601DateCoder()
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try depot.set(value: now, for: lastSyncKey)
        #expect(try depot.get(valueFor: lastSyncKey) == now)

        let coder = ISO8601DateCoder()
            .eraseToAnyCoder()
            .compressed(using: .lz4)
        #expect(try coder.decode(coder.encode(now)) == now)
    }

    #if DEPOTKIT_MACROS
    @Test("registration: store type, pattern registration, and summary")
    func registration() async throws {
        let depot = makeSnippetDepot()
        defer { removeSnippetDirectory(of: depot) }
        let store = WeatherStore(depot: depot)  // article: try WeatherStore()
        let forecast = Forecast(city: "Berlin", highs: [21])

        let berlinForecast = Key.from("locations" / "berlin" / "forecast", as: Forecast.self)
        let tokyoForecast = Key.from("locations" / "tokyo" / "forecast", as: Forecast.self)
        try await depot.set(value: forecast, for: berlinForecast)
        let all = try await depot.get(valuesFor: store.forecastKey)  // [Forecast] — all locations
        #expect(all == [forecast])
        #expect(try await store.forecast(for: "berlin") == forecast)
        #expect(try await depot.get(valueFor: tokyoForecast) == nil)
        #expect(try await depot.metadata(for: berlinForecast)?.expiresAt != nil)

        // Registration Summary
        depot.register(keyPath: "preferences" / "units", coder: .json(UnitPreferences.self))
        depot.register(#key("locations/saved", coder: .json([SavedLocation].self)))
        depot.register(#pattern("locations/*/alerts", coder: .json([WeatherAlert].self)))
        depot.register(
            keyPath: "locations" / .wildcard / "forecast",
            coder: .json(Forecast.self),
            expiry: .seconds(1800)
        )
        depot.register(
            PatternKeyDefinition<[WeatherAlert]>(
                path: "warnings" / .wildcard,
                coder: .json(),
                expiry: .seconds(3600)
            )
        )
        let alerts = Key.from("warnings" / "berlin", as: [WeatherAlert].self)
        try await depot.set(value: [WeatherAlert(title: "Storm")], for: alerts)
        #expect(try await depot.metadata(for: alerts)?.expiresAt != nil)
    }
    #endif

    @Test("re-registering with a different type makes old handles fail", arguments: [false, true])
    func conflictingRegistration(fileBacked: Bool) throws {
        let depot =
            fileBacked
            ? Depot(configuration: DepotConfiguration(directoryURL: makeSnippetDirectory(), memoryCache: .disabled))
            : Depot()
        defer { removeSnippetDirectory(of: depot) }
        let count = depot.register(keyPath: "stats" / "count", coder: .json(Int.self))
        try depot.set(value: 1, for: count)
        _ = depot.register(keyPath: "stats" / "count", coder: .json(String.self))

        #expect(throws: DepotError.mismatchedTypes(keyPath: "stats/count", expected: "Int", actual: "String")) {
            try depot.set(value: 2, for: count)
        }
        if fileBacked {
            #expect(throws: DepotError.mismatchedTypes(keyPath: "stats/count", expected: "Int", actual: "String")) {
                try depot.get(valueFor: count)
            }
        }
    }

    @Test("versioned coder migrates unversioned, version 1, and version 2 payloads")
    func versionedMigration() throws {
        let v1 = try JSONEncoder().encode(PlaceV1(name: "Berlin", lat: "52.52", lon: "13.40"))
        #expect(
            try placeCoder.decode(v1)
                == Place(name: "Berlin", latitude: 52.52, longitude: 13.40, timeZone: nil)
        )

        struct PlaceV2: Codable, Sendable {
            var name: String
            var latitude: Double
            var longitude: Double
        }
        let v2Coder: AnyCoder<PlaceV2> = .json().versioned(version: 2) { _, _ in nil }
        let v2 = try v2Coder.encode(PlaceV2(name: "Tokyo", latitude: 35.68, longitude: 139.69))
        #expect(
            try placeCoder.decode(v2)
                == Place(name: "Tokyo", latitude: 35.68, longitude: 139.69, timeZone: nil)
        )

        let current = Place(name: "Oslo", latitude: 59.91, longitude: 10.75, timeZone: "Europe/Oslo")
        #expect(try placeCoder.decode(placeCoder.encode(current)) == current)

        let invalid = try JSONEncoder().encode(PlaceV1(name: "Nowhere", lat: "north", lon: "east"))
        #expect(throws: VersionedCoderError.self) {
            try placeCoder.decode(invalid)
        }
    }

    @Test("changing a coder rewrites stored values", arguments: [false, true])
    func changingACoder(reopen: Bool) throws {
        let directory = makeSnippetDirectory()
        let depot = makeSnippetDepot(in: directory)
        defer { removeSnippetDirectory(of: depot) }
        let initial = depot.register(keyPath: "forecasts" / .wildcard, coder: .json(Forecast.self))
        try depot.set(
            value: Forecast(city: "Berlin", highs: [21]),
            for: Key.from("forecasts" / "berlin", as: Forecast.self)
        )
        try depot.set(
            value: Forecast(city: "Tokyo", highs: [28]),
            for: Key.from("forecasts" / "tokyo", as: Forecast.self)
        )
        #expect(try depot.count(for: initial) == 2)

        // 1. Read with the coder the values were written with.
        let oldForecasts = depot.register(keyPath: "forecasts" / .wildcard, coder: .json(Forecast.self))
        let existing = try depot.get(availableValuesFor: oldForecasts).keyedValues

        // 2. Register the new coder and write the values back.
        let forecasts = depot.register(
            keyPath: "forecasts" / .wildcard,
            coder: AnyCoder<Forecast>.json().compressed(using: .lzfse)
        )
        for (key, forecast) in existing {
            try depot.set(value: forecast, for: key.typed(as: Forecast.self))
        }

        let reader: Depot
        if reopen {
            reader = Depot(configuration: DepotConfiguration(directoryURL: directory, memoryCache: .disabled))
            reader.register(
                keyPath: "forecasts" / .wildcard,
                coder: AnyCoder<Forecast>.json().compressed(using: .lzfse)
            )
        } else {
            reader = depot
        }
        let result = try reader.get(availableValuesFor: forecasts)
        #expect(result.keyedErrors.isEmpty)
        #expect(Set(result.values) == [Forecast(city: "Berlin", highs: [21]), Forecast(city: "Tokyo", highs: [28])])
    }

    #if DEPOTKIT_MACROS
    @Test("renaming a key")
    func renamingAKey() throws {
        let depot = makeSnippetDepot()
        defer { removeSnippetDirectory(of: depot) }
        let legacy = depot.register(#key("settings/units", coder: .json(UnitPreferences.self)))
        try depot.set(value: .standard, for: legacy)

        let oldUnits = depot.register(#key("settings/units", coder: .json(UnitPreferences.self)))
        let units = depot.register(#key("preferences/units", coder: .json(UnitPreferences.self)))

        try depot.transaction { tx in
            if let value = try tx.get(valueFor: oldUnits) {
                try tx.set(value: value, for: units)
                try tx.remove(valueFor: oldUnits)
            }
        }

        #expect(try depot.get(valueFor: units) == .standard)
        #expect(try depot.get(valueFor: oldUnits) == nil)
    }
    #endif

    @Test("exporting reads every stored payload through a catch-all registration")
    func exportingData() throws {
        let depot = makeSnippetDepot()
        defer { removeSnippetDirectory(of: depot) }

        // An existing store with several coders, including nested paths.
        let unitsDefinition = KeyDefinition(path: "preferences" / "units", coder: .json(UnitPreferences.self))
        let forecastDefinition = PatternKeyDefinition<Forecast>(
            path: "forecasts" / .wildcard,
            coder: AnyCoder<Forecast>.json().compressed(using: .lz4)
        )
        let units = depot.register(unitsDefinition)
        depot.register(forecastDefinition)
        let berlin = Key.from("forecasts" / "berlin", as: Forecast.self)
        try depot.set(value: .standard, for: units)
        try depot.set(value: Forecast(city: "Berlin", highs: [21]), for: berlin)

        var exported = [([KeyComponent], Data)]()

        let exporter = Depot(configuration: depot.configuration)
        let everything = exporter.register(key: Key.all, coder: .data(Data.self))

        let export = try exporter.get(availableValuesFor: everything)
        for (key, payload) in export.keyedValues {
            // Write key.components and payload in your export format.
            exported.append((key.components, payload))
        }
        // export.keyedErrors lists values that could not be read.
        #expect(export.keyedErrors.isEmpty)
        #expect(exported.count == 2)

        // The importing side writes the payloads through the depot API and
        // decodes them with the same coders.
        let imported = makeSnippetDepot()
        defer { removeSnippetDirectory(of: imported) }
        imported.register(key: Key.all, coder: .data(Data.self))
        for (components, payload) in exported {
            try imported.set(value: payload, for: TypedDistinctKey<Data>(components))
        }

        let reader = Depot(configuration: imported.configuration)
        let importedUnits = reader.register(unitsDefinition)
        reader.register(forecastDefinition)
        #expect(try reader.get(valueFor: importedUnits) == .standard)
        #expect(try reader.get(valueFor: berlin) == Forecast(city: "Berlin", highs: [21]))
    }
}
