// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

// MARK: - City

/// A city the user can save. The `id` doubles as the depot key path component
/// (`cities/<id>`).
struct City: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let country: String

    /// Baseline temperature in °C used by the mock weather service.
    let baselineTemperature: Double
}

// MARK: - Forecast

/// A week of hourly forecast data (168 entries). Stored with a compressed
/// coder because the JSON payloads are large.
struct Forecast: Codable, Sendable {
    struct Hour: Codable, Identifiable, Sendable {
        let date: Date
        let temperature: Double
        let condition: Condition

        var id: Date { date }
    }

    enum Condition: String, Codable, CaseIterable, Sendable {
        case clear
        case cloudy
        case rain
        case snow
        case storm

        var systemImage: String {
            switch self {
            case .clear: "sun.max.fill"
            case .cloudy: "cloud.fill"
            case .rain: "cloud.rain.fill"
            case .snow: "cloud.snow.fill"
            case .storm: "cloud.bolt.rain.fill"
            }
        }

        var label: String {
            switch self {
            case .clear: "Clear"
            case .cloudy: "Cloudy"
            case .rain: "Rain"
            case .snow: "Snow"
            case .storm: "Storm"
            }
        }
    }

    let cityID: String
    let generatedAt: Date
    let hours: [Hour]
}

// MARK: - Settings

enum TemperatureUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case celsius
    case fahrenheit

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .celsius: "°C"
        case .fahrenheit: "°F"
        }
    }

    /// Formats a °C value in this unit.
    func format(celsius: Double) -> String {
        let value = self == .celsius ? celsius : celsius * 9 / 5 + 32
        return String(format: "%.0f%@", value, symbol)
    }
}

/// App settings (schema v2). V1 stored a bare `TemperatureUnit` string —
/// the versioned coder in ``DepotKeys/settings`` migrates on first read.
struct AppSettings: Codable, Equatable, Sendable {
    var unit: TemperatureUnit = .celsius
    var autoRefresh: Bool = true
}
