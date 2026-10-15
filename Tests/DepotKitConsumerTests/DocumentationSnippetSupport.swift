// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

// Shared model types and helpers for the documentation snippet tests.
//
// The snippet tests compile (and, where possible, run) the code examples from
// README.md and the DocC articles against DepotKit's public API. Keep each
// test identical in substance to its snippet; only the depot location differs:
// snippets that create depots in system directories run against a temporary
// directory here, or are compiled without being executed.

import DepotKit
import Foundation

struct Forecast: Codable, Sendable, Hashable {
    var city: String
    var highs: [Double]
}

struct LegacyForecast: Codable, Sendable {
    var name: String
    var highs: [Double]
}

struct UnitPreferences: Codable, Sendable, Equatable {
    enum Temperature: String, Codable, Sendable {
        case celsius
        case fahrenheit
    }

    var temperature: Temperature

    static let standard = UnitPreferences(temperature: .celsius)
}

struct SavedLocation: Codable, Sendable, Equatable {
    var name: String
    var latitude: Double
    var longitude: Double
}

/// A unique, not yet existing directory for a file-backed test depot.
func makeSnippetDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "DepotKitDocumentationSnippets", directoryHint: .isDirectory)
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
}

/// A file-backed depot in a fresh temporary directory.
///
/// Stands in for `try Depot(name:)` and similar initializers that would write
/// to the user's Application Support or Caches directory.
func makeSnippetDepot(in directory: URL = makeSnippetDirectory()) -> Depot {
    Depot(configuration: DepotConfiguration(directoryURL: directory))
}

/// Removes the directory of a file-backed depot.
func removeSnippetDirectory(of depot: Depot) {
    if let url = depot.configuration.directoryURL {
        try? FileManager.default.removeItem(at: url)
    }
}
