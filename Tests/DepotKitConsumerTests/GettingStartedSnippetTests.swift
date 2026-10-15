// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

// Compiles and runs the code examples from the Getting Started article.

import DepotKit
import Foundation
import Testing

#if DEPOTKIT_MACROS
private enum WeatherKeys {
    static let units = #key("preferences/units", coder: .json(UnitPreferences.self))
    static let forecasts = #pattern("forecasts/*", coder: .json(Forecast.self))
}

private final class WeatherStore: Sendable {
    let depot: Depot
    let units: TypedDistinctKey<UnitPreferences>
    let forecasts: TypedKey<Forecast>

    init() throws {
        depot = try Depot(name: "Weather")
        units = depot.register(WeatherKeys.units)
        forecasts = depot.register(WeatherKeys.forecasts)
    }

    /// Test-only: the same setup in a temporary directory.
    init(depot: Depot) {
        self.depot = depot
        units = depot.register(WeatherKeys.units)
        forecasts = depot.register(WeatherKeys.forecasts)
    }

    func forecast(for city: String) async throws -> Forecast? {
        try await depot.get(valueFor: Key.from("forecasts" / city, as: Forecast.self))
    }
}
#endif

/// Snippets that create depots in system directories or replace the global log sink — compiled only.
private func gettingStartedCompileOnly() throws -> [Depot] {
    let depot = try Depot(name: "Weather")  // Library/Application Support/Weather
    let memoryOnly = Depot()

    let radarCache = try Depot(directory: .caches, name: "RadarTiles", memoryCache: .large)

    let configuration = DepotConfiguration(
        directoryURL: URL.applicationSupportDirectory.appending(path: "Weather", directoryHint: .isDirectory),
        isExcludedFromBackup: true,
        fileProtection: .completeUntilFirstUserAuthentication,
        memoryCache: .medium  // about 16 MB in-memory cache
    )
    let configured = Depot(configuration: configuration)

    // Use the built-in os_log sink
    DepotKitLogging.sink = .osLog()

    // Or route to your own logger
    DepotKitLogging.sink = .callback { level, message, _, _, _ in
        print("[DepotKit] \(level): \(message())")
    }

    #if DEPOTKIT_MACROS
    return [depot, memoryOnly, radarCache, configured, try WeatherStore().depot]
    #else
    return [depot, memoryOnly, radarCache, configured]
    #endif
}

@Suite("Documentation: Getting Started")
struct GettingStartedSnippetTests {

    #if DEPOTKIT_MACROS
    @Test("register, read, write, and observe a key")
    func coreWorkflow() async throws {
        let depot = makeSnippetDepot()  // article: try Depot(name: "Weather")
        defer { removeSnippetDirectory(of: depot) }

        let unitsKey = depot.register(
            #key("preferences/units", coder: .json(UnitPreferences.self))
        )
        // unitsKey: TypedDistinctKey<UnitPreferences>

        try await depot.set(value: UnitPreferences(temperature: .fahrenheit), for: unitsKey)

        let units = try await depot.get(valueFor: unitsKey)  // UnitPreferences?
        let resolved = try await depot.get(valueFor: unitsKey, default: .standard)  // UnitPreferences
        let exists = try await depot.has(valueFor: unitsKey)  // Bool
        #expect(units == UnitPreferences(temperature: .fahrenheit))
        #expect(resolved == units)
        #expect(exists)

        var observed: [String] = []
        for await result in depot.values(for: unitsKey) {
            switch result {
            case .success(let units):
                observed.append(units?.temperature.rawValue ?? "not set")  // nil: removed or expired
            case .failure(let error):
                print("Could not read units:", error)
            }
            if observed.count == 1 {
                try await depot.remove(valueFor: unitsKey)
            } else {
                break
            }
        }

        #expect(observed == ["fahrenheit", "not set"])
        #expect(try await depot.get(valueFor: unitsKey, default: .standard) == .standard)
    }
    #endif

    @Test("unregistered keys throw; the manual form registers the same key")
    func registration() throws {
        let depot = makeSnippetDepot()
        defer { removeSnippetDirectory(of: depot) }
        let key = Key.from("preferences" / "units", as: UnitPreferences.self)

        #expect(throws: DepotError.unregisteredKey(keyPath: "preferences/units")) {
            try depot.set(value: .standard, for: key)
        }

        let unitsKey = depot.register(
            keyPath: "preferences" / "units",
            coder: .json(UnitPreferences.self)
        )
        #if DEPOTKIT_MACROS
        #expect(unitsKey == depot.register(WeatherKeys.units))
        #endif
        try depot.set(value: .standard, for: key)
        #expect(try depot.get(valueFor: unitsKey) == .standard)
    }

    #if DEPOTKIT_MACROS
    @Test("key families and partial-success reads")
    func keyFamilies() async throws {
        let depot = makeSnippetDepot()
        defer { removeSnippetDirectory(of: depot) }

        let forecastsKey = depot.register(
            #pattern("forecasts/*", coder: .json(Forecast.self))
        )

        let berlin = Key.from("forecasts" / "berlin", as: Forecast.self)
        try await depot.set(value: Forecast(city: "Berlin", highs: [21, 23]), for: berlin)

        let all = try await depot.get(valuesFor: forecastsKey)  // [Forecast]
        let count = try await depot.count(for: forecastsKey)  // Int
        #expect(all == [Forecast(city: "Berlin", highs: [21, 23])])
        #expect(count == 1)

        let result = try await depot.get(availableValuesFor: forecastsKey)
        for (key, forecast) in result.keyedValues {
            print(key.keyPath, forecast.highs)
        }
        for (key, error) in result.keyedErrors {
            print("Skipping \(key.keyPath): \(error)")
        }
        #expect(result.values == all)
        #expect(result.errors.isEmpty)

        try await depot.remove(valuesFor: forecastsKey)  // removes every forecast
        #expect(try await depot.count(for: forecastsKey) == 0)
    }
    #endif

    @Test("expiry and metadata")
    func expiryAndMetadata() async throws {
        let depot = makeSnippetDepot()
        defer { removeSnippetDirectory(of: depot) }

        let forecastsKey = depot.register(
            keyPath: "forecasts" / .wildcard,
            coder: .json(Forecast.self),
            expiry: .seconds(30 * 60)  // 30 minutes
        )
        let berlin = Key.from("forecasts" / "berlin", as: Forecast.self)
        try await depot.set(value: Forecast(city: "Berlin", highs: [21]), for: berlin)

        let removedCount = try await depot.removeExpired()
        #expect(removedCount == 0)
        #expect(try await depot.count(for: forecastsKey) == 1)

        var expiry: Date?
        if let metadata = try await depot.metadata(for: berlin) {
            print("Written at:", metadata.modifiedAt)
            if let expiresAt = metadata.expiresAt {
                print("Expires at:", expiresAt)
                expiry = expiresAt
            }
        }
        #expect(expiry != nil)
    }

    #if DEPOTKIT_MACROS
    @Test("documentation landing page overview")
    func landingPageOverview() async throws {
        let depot = makeSnippetDepot()  // article: try Depot(name: "Weather")
        defer { removeSnippetDirectory(of: depot) }

        let unitsKey = depot.register(
            #key("preferences/units", coder: .json(UnitPreferences.self))
        )
        try await depot.set(value: UnitPreferences(temperature: .celsius), for: unitsKey)

        var printed: [String] = []
        for await case .success(let units) in depot.values(for: unitsKey) {
            printed.append(units?.temperature.rawValue ?? "not set")
            break
        }
        #expect(printed == ["celsius"])
    }
    #endif

    #if DEPOTKIT_MACROS
    @Test("organize keys in a store type")
    func weatherStore() async throws {
        let store = WeatherStore(depot: makeSnippetDepot())  // article: try WeatherStore()
        defer { removeSnippetDirectory(of: store.depot) }

        try await store.depot.set(
            value: Forecast(city: "Tokyo", highs: [28]),
            for: Key.from("forecasts" / "tokyo", as: Forecast.self)
        )
        #expect(try await store.forecast(for: "tokyo") == Forecast(city: "Tokyo", highs: [28]))
        #expect(try await store.forecast(for: "berlin") == nil)
        #expect(try await store.depot.get(valuesFor: store.forecasts).count == 1)
    }
    #endif
}
