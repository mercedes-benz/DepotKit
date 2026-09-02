// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

/// Mock weather service — no network access. Returns canned forecast data
/// with slight randomization so each refresh produces visibly different values.
struct WeatherService: Sendable {
    /// Canned catalog the search view queries.
    static let catalog: [City] = [
        City(id: "berlin", name: "Berlin", country: "Germany", baselineTemperature: 10),
        City(id: "cape-town", name: "Cape Town", country: "South Africa", baselineTemperature: 18),
        City(id: "lisbon", name: "Lisbon", country: "Portugal", baselineTemperature: 17),
        City(id: "london", name: "London", country: "United Kingdom", baselineTemperature: 11),
        City(id: "new-york", name: "New York", country: "United States", baselineTemperature: 13),
        City(id: "oslo", name: "Oslo", country: "Norway", baselineTemperature: 6),
        City(id: "paris", name: "Paris", country: "France", baselineTemperature: 12),
        City(id: "reykjavik", name: "Reykjavík", country: "Iceland", baselineTemperature: 4),
        City(id: "singapore", name: "Singapore", country: "Singapore", baselineTemperature: 28),
        City(id: "stuttgart", name: "Stuttgart", country: "Germany", baselineTemperature: 11),
        City(id: "sydney", name: "Sydney", country: "Australia", baselineTemperature: 19),
        City(id: "tokyo", name: "Tokyo", country: "Japan", baselineTemperature: 16),
    ]

    /// Substring search over the catalog. Empty query returns everything.
    func search(matching query: String) -> [City] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return Self.catalog
        }
        return Self.catalog.filter { city in
            city.name.localizedCaseInsensitiveContains(trimmed)
                || city.country.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Generates a week of hourly data. A short delay simulates latency.
    func forecast(for city: City) async -> Forecast {
        try? await Task.sleep(for: .milliseconds(400))

        let start = Calendar.current.startOfDay(for: Date())
        let jitter = Double.random(in: -2...2)

        let hours = (0..<168).map { offset -> Forecast.Hour in
            let date = start.addingTimeInterval(Double(offset) * 3600)
            let hourOfDay = Double(offset % 24)
            // Simple diurnal curve: coldest at 04:00, warmest at 16:00.
            let diurnal = 5 * sin((hourOfDay - 10) / 24 * 2 * .pi)
            let temperature = city.baselineTemperature + diurnal + jitter + .random(in: -1...1)
            return Forecast.Hour(
                date: date,
                temperature: temperature,
                condition: condition(for: temperature)
            )
        }

        return Forecast(cityID: city.id, generatedAt: Date(), hours: hours)
    }

    private func condition(for temperature: Double) -> Forecast.Condition {
        switch temperature {
        case ..<0: Bool.random() ? .snow : .cloudy
        case ..<10: [.cloudy, .rain, .clear].randomElement() ?? .cloudy
        case ..<25: [.clear, .cloudy, .rain].randomElement() ?? .clear
        default: Bool.random() ? .clear : .storm
        }
    }
}
