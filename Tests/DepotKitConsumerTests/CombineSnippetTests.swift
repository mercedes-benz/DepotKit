// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

// Compiles and runs the Combine examples from README.md and the Observation article.

#if COMBINE_ENABLED && canImport(Combine)

import Combine
import DepotKit
import DepotKitCombine
import Foundation
import Testing

/// Collects values delivered on arbitrary threads.
private final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.withLock { storage }
    }

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }
}

/// Polls `predicate` on the main actor, letting main-queue deliveries run between polls. The
/// generous timeout is only reached when a test fails.
@MainActor
private func eventually(timeout: Duration = .seconds(30), _ predicate: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if predicate() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return predicate()
}

// Observation article: "Feeding @Published Properties"
@MainActor
private final class SettingsViewModel: ObservableObject {
    @Published
    var theme: String?

    init(depot: Depot, themeKey: TypedDistinctKey<String>) {
        depot.published(valueFor: themeKey)
            .receive(on: DispatchQueue.main)
            .map { result in try? result.get() }  // nil when missing or unreadable
            .assign(to: &$theme)
    }
}

@MainActor
@Suite("Documentation: Combine")
struct CombineSnippetTests {

    #if DEPOTKIT_MACROS
    @Test("README: Combine publisher")
    func readmePublisher() async throws {
        let depot = makeSnippetDepot()
        defer { removeSnippetDirectory(of: depot) }
        let unitsKey = depot.register(#key("preferences/units", coder: .json(UnitPreferences.self)))
        try await depot.set(value: .standard, for: unitsKey)
        let applied = Recorder<UnitPreferences?>()
        func apply(_ preferences: UnitPreferences?) {
            applied.append(preferences)
        }

        let cancellable = depot.published(valueFor: unitsKey)
            .receive(on: DispatchQueue.main)
            .compactMap { try? $0.get() }
            .sink { apply($0) }

        #expect(await eventually { applied.values == [.standard] })
        cancellable.cancel()
    }
    #endif

    @Test("Observation article: single-value and error-handling publishers")
    func articlePublishers() async throws {
        let depot = makeSnippetDepot()
        defer { removeSnippetDirectory(of: depot) }
        let themeKey = depot.register(keyPath: "settings" / "theme", coder: .json(String.self))
        try await depot.set(value: "dark", for: themeKey)

        let themes = Recorder<String?>()
        func applyTheme(_ theme: String?) {
            themes.append(theme)
        }

        var cancellables = Set<AnyCancellable>()

        depot.published(valueFor: themeKey)
            .receive(on: DispatchQueue.main)
            .compactMap { try? $0.get() }
            .sink { theme in
                applyTheme(theme)
            }
            .store(in: &cancellables)

        depot.published(
            valueFor: themeKey,
            errorHandler: { error, isInitial in
                if isInitial {
                    return .replaceWith("light")  // default theme on first read
                }
                return .skip  // ignore later errors
            }
        )
        .receive(on: DispatchQueue.main)
        .sink(
            receiveCompletion: { completion in
                // Only reached after a `.complete(_:)` decision.
            },
            receiveValue: { theme in
                applyTheme(theme)
            }
        )
        .store(in: &cancellables)

        #expect(await eventually { themes.values == ["dark", "dark"] })
    }

    #if DEPOTKIT_MACROS
    @Test("Observation article: multi-value publisher")
    func multiValuePublisher() async throws {
        let depot = makeSnippetDepot()
        defer { removeSnippetDirectory(of: depot) }
        let forecastsKey = depot.register(#pattern("forecasts/*", coder: .json(Forecast.self)))
        let berlin = Forecast(city: "Berlin", highs: [21])
        try await depot.set(value: berlin, for: Key.from("forecasts" / "berlin", as: Forecast.self))

        let refreshed = Recorder<[Forecast]>()
        func refresh(with forecasts: [Forecast]) {
            refreshed.append(forecasts)
        }

        var cancellables = Set<AnyCancellable>()

        depot.published(valuesFor: forecastsKey)
            .receive(on: DispatchQueue.main)
            .sink { result in
                switch result {
                case .success(let forecasts):
                    refresh(with: forecasts)
                case .failure(let error):
                    print("Observation error: \(error)")
                }
            }
            .store(in: &cancellables)

        #expect(await eventually { refreshed.values == [[berlin]] })
    }
    #endif

    @Test("Observation article: feeding @Published properties")
    func publishedProperty() async throws {
        let depot = makeSnippetDepot()
        defer { removeSnippetDirectory(of: depot) }
        let themeKey = depot.register(keyPath: "settings" / "theme", coder: .json(String.self))
        try await depot.set(value: "dark", for: themeKey)

        let viewModel = SettingsViewModel(depot: depot, themeKey: themeKey)

        #expect(await eventually { viewModel.theme == "dark" })
        try await depot.set(value: "light", for: themeKey)
        #expect(await eventually { viewModel.theme == "light" })
    }
}

#endif
