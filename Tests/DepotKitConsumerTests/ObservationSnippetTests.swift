// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

// Compiles and runs the AsyncSequence examples from the Observation article.

import DepotKit
import Foundation
import Testing

@Suite("Documentation: Observation")
struct ObservationSnippetTests {

    @Test("single-value stream delivers the current value, changes, and removals")
    func singleValueStream() async throws {
        let depot = makeSnippetDepot()
        defer { removeSnippetDirectory(of: depot) }
        let unitsKey = depot.register(keyPath: "preferences" / "units", coder: .json(UnitPreferences.self))
        try await depot.set(value: .standard, for: unitsKey)

        var received: [UnitPreferences?] = []
        func apply(_ units: UnitPreferences?) {
            received.append(units)
        }

        for await result in depot.values(for: unitsKey) {
            switch result {
            case .success(let units):
                apply(units)
            case .failure(let error):
                print("Observation error: \(error)")
            }
            if received.count == 1 {
                try await depot.remove(valueFor: unitsKey)
            } else {
                break
            }
        }

        #expect(received == [.standard, nil])
    }

    #if DEPOTKIT_MACROS
    @Test("pattern and partial-success streams")
    func patternStreams() async throws {
        let depot = makeSnippetDepot()
        defer { removeSnippetDirectory(of: depot) }
        let forecastsKey = depot.register(#pattern("forecasts/*", coder: .json(Forecast.self)))
        let berlin = Forecast(city: "Berlin", highs: [21])
        try await depot.set(value: berlin, for: Key.from("forecasts" / "berlin", as: Forecast.self))

        var refreshed: [[Forecast]] = []
        func refresh(with forecasts: [Forecast]) {
            refreshed.append(forecasts)
        }

        for await result in depot.values(for: forecastsKey) {
            switch result {
            case .success(let forecasts):
                // forecasts: [Forecast] — every city's current forecast
                refresh(with: forecasts)
            case .failure(let error):
                print("Observation error: \(error)")
            }
            break
        }

        for await result in depot.availableValues(for: forecastsKey) {
            switch result {
            case .success(let available):
                // available.values      → [Forecast] — decoded successfully
                // available.keyedErrors → [DistinctKey: any Error & Sendable] — per-key failures
                refresh(with: available.values)
                for (key, error) in available.keyedErrors {
                    print("Failed to decode \(key.keyPath): \(error)")
                }
            case .failure(let error):
                print("Fatal observation error: \(error)")
            }
            break
        }

        #expect(refreshed == [[berlin], [berlin]])
    }
    #endif

    @Test("suppressing the initial value and waiting for observers")
    func suppressedInitialValue() async throws {
        let depot = Depot()
        let unitsKey = depot.register(keyPath: "preferences" / "units", coder: .json(UnitPreferences.self))
        try await depot.set(value: .standard, for: unitsKey)
        let newUnits = UnitPreferences(temperature: .fahrenheit)

        let stream = depot.values(for: unitsKey, initialValue: false)
        try await depot.set(value: newUnits, for: unitsKey)
        await depot.waitForPendingObservations()
        // Now it's safe to assert that the observer received the value

        for await result in stream {
            // Only fires on writes that happen after this stream was created
            #expect(try result.get() == newUnits)
            break
        }
    }
}
