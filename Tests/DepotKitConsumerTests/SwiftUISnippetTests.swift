// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

// Compiles the SwiftUI examples from README.md and the Observation article and checks
// that the definition-based initializers register their keys once the view is displayed.

#if OBSERVATION_ENABLED && canImport(SwiftUI) && canImport(Observation)

import DepotKit
import DepotKitObservation
import SwiftUI
import Testing

#if canImport(AppKit)
import AppKit
#endif

// MARK: - README

#if DEPOTKIT_MACROS
private enum ReadmeWeatherKeys {
    static let units = #key("preferences/units", coder: .json(UnitPreferences.self))
    static let forecast = #pattern("locations/*/forecast", coder: .json(Forecast.self))
}
#endif

private struct ForecastRow: View {
    let forecast: Forecast
    let units: UnitPreferences?

    var body: some View {
        Text("\(forecast.city) \(units?.temperature.rawValue ?? "")")
    }
}

#if DEPOTKIT_MACROS
private struct ReadmeForecastList: View {
    @DepotValue
    var units: UnitPreferences?
    @DepotValues
    var forecasts: [Forecast]

    init(depot: Depot) {
        // The definition-based initializers register the key for you.
        _units = DepotValue(definition: ReadmeWeatherKeys.units, depot: depot)
        _forecasts = DepotValues(definition: ReadmeWeatherKeys.forecast, depot: depot)
    }

    var body: some View {
        List(forecasts.sorted { $0.city < $1.city }, id: \.city) { forecast in
            ForecastRow(forecast: forecast, units: units)
        }
    }
}
#endif

// MARK: - Observation article

#if DEPOTKIT_MACROS
private enum WeatherKeys {
    static let units = #key("preferences/units", coder: .json(UnitPreferences.self))
    static let forecasts = #pattern("forecasts/*", coder: .json(Forecast.self))
}
#endif

private struct UnitsLabel: View {
    @DepotValue
    var units: UnitPreferences?

    init(depot: Depot, unitsKey: TypedDistinctKey<UnitPreferences>) {
        _units = DepotValue(key: unitsKey, depot: depot)
    }

    var body: some View {
        Text(units?.temperature.rawValue ?? "—")
    }
}

private struct NotificationsToggle: View {
    @DepotValue
    var enabled: Bool?

    init(depot: Depot, notificationsKey: TypedDistinctKey<Bool>) {
        _enabled = DepotValue(key: notificationsKey, depot: depot)
    }

    var body: some View {
        Toggle(
            "Notifications",
            isOn: Binding(
                get: { enabled ?? false },
                set: { $enabled.wrappedValue = $0 }
            )
        )
    }
}

#if DEPOTKIT_MACROS
private struct UnitsSummary: View {
    @DepotValue
    var units: UnitPreferences?

    init(depot: Depot) {
        _units = DepotValue(definition: WeatherKeys.units, depot: depot)
    }

    var body: some View {
        Text(units?.temperature.rawValue ?? "—")
    }
}
#endif

private struct ForecastList: View {
    @DepotValues
    var forecasts: [Forecast]

    init(depot: Depot, forecastsKey: TypedKey<Forecast>) {
        _forecasts = DepotValues(key: forecastsKey, depot: depot)
    }

    #if DEPOTKIT_MACROS
    init(depot: Depot) {
        _forecasts = DepotValues(definition: WeatherKeys.forecasts, depot: depot)
    }
    #endif

    var body: some View {
        List(forecasts.sorted { $0.city < $1.city }, id: \.city) { forecast in
            Text(forecast.city)
        }
    }
}

#if DEPOTKIT_MACROS
private struct UnitsStatus: View {
    @DepotValue
    var units: UnitPreferences?

    init(depot: Depot) {
        _units = DepotValue(definition: WeatherKeys.units, depot: depot)
    }

    var body: some View {
        if let error = _units.error {
            Text("Error: \(error.localizedDescription)")
        } else {
            Text(units?.temperature.rawValue ?? "Loading…")
        }
    }
}
#endif

@MainActor
@Suite("Documentation: SwiftUI")
struct SwiftUISnippetTests {

    #if DEPOTKIT_MACROS
    @Test("definition-based initializers register their keys when the view is displayed, not when it is created")
    func definitionInitializersRegister() async throws {
        let depot = Depot()
        let units = Key.from("preferences" / "units", as: UnitPreferences.self)
        let forecast = Key.from("locations" / "berlin" / "forecast", as: Forecast.self)
        let cityForecast = Key.from("forecasts" / "berlin", as: Forecast.self)

        for _ in 0..<3 {
            _ = ReadmeForecastList(depot: depot)
            _ = UnitsSummary(depot: depot)
            _ = ForecastList(depot: depot)
        }
        #expect(depot.keys.isEmpty)

        #if canImport(AppKit)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [],
            backing: .buffered,
            defer: true,
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: VStack {
                ReadmeForecastList(depot: depot)
                UnitsSummary(depot: depot)
                ForecastList(depot: depot)
            }
        )
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }
        #expect(depot.keys.count == 3)

        try await depot.set(value: .standard, for: units)
        try await depot.set(value: Forecast(city: "Berlin", highs: [21]), for: forecast)
        try await depot.set(value: Forecast(city: "Berlin", highs: [21]), for: cityForecast)
        #expect(try await depot.get(valueFor: units) == .standard)
        #endif
    }
    #endif

    @Test("key-based initializers compile against registered keys")
    func keyInitializers() {
        let depot = Depot()
        let notificationsKey = depot.register(keyPath: "settings" / "notifications", coder: .json(Bool.self))
        _ = NotificationsToggle(depot: depot, notificationsKey: notificationsKey)

        #if DEPOTKIT_MACROS
        let unitsKey = depot.register(WeatherKeys.units)
        let forecastsKey = depot.register(WeatherKeys.forecasts)

        _ = UnitsLabel(depot: depot, unitsKey: unitsKey)
        _ = ForecastList(depot: depot, forecastsKey: forecastsKey)
        _ = UnitsStatus(depot: depot)
        #endif
    }
}

#endif
