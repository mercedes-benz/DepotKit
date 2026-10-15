# Weather Depot — DepotKit Demo

A SwiftUI weather app that exercises every major DepotKit feature in a
realistic setting. No network access — forecasts come from a mock service with
randomized canned data so each refresh is visibly different.

## Run it

**macOS (command line):**

```sh
cd Examples/DepotKitDemo
swift run DepotKitDemo
```

**macOS / iOS (Xcode):** Open `DepotKitDemo.xcodeproj` and run the
`DepotKitDemo` scheme. The Xcode project is needed for iOS because SwiftPM
executables can't produce an iOS app bundle.

## Source files

Paths are relative to `Sources/`.

| File | Purpose |
| --- | --- |
| `App/DepotKitDemoApp.swift` | App entry point; creates the `DepotStore` and sets the macOS Dock icon |
| `App/ContentView.swift` | Root tab view wiring each tab to the shared store |
| `Services/DepotStore.swift` | Owns the persistent and memory-only depots and all registered key handles |
| `Services/DepotKeys.swift` | Central key definitions — the app's storage schema at a glance |
| `Model/Models.swift` | `City`, `Forecast`, `TemperatureUnit`, `AppSettings` data types |
| `Services/WeatherService.swift` | Mock weather service generating canned hourly forecasts |
| `Views/CityListView.swift` | Saved-cities list driven by `@DepotValues` observation |
| `Views/CityDetailView.swift` | Forecast detail with cache metadata, refresh, and TTL sweep |
| `Views/CitySearchView.swift` | City search backed by a memory-only depot |
| `Views/SettingsView.swift` | Settings with `@DepotValue` and a versioned coder |
| `Views/ActivityLogView.swift` | Live depot event log via `AsyncStream`, storage breakdown, and Combine status |
| `Model/ForecastModel.swift` | Loads/refreshes one city's cached forecast |
| `Model/RefreshStatusModel.swift` | Combine `published(valueFor:)` bridge for the last-refresh timestamp |
| `Helpers/ConditionSymbol.swift` | Shared UI: color theming, weather symbols, empty-state illustration, API annotation pill |

## DepotKit features demonstrated

| Feature | Where |
| --- | --- |
| Persistent named depot vs. memory-only depot | `Services/DepotStore.swift` |
| `#key` / `#pattern` macros | `Services/DepotKeys.swift` |
| Pattern keys + per-item distinct keys (`cities/*`) | `DepotKeys.swift`, `CityListView.swift` |
| Manual registration with explicit coder + expiry (30 min TTL) | `Services/DepotStore.swift` |
| Compressed coder (`.json().compressed(using: .zlib)`) | `Services/DepotStore.swift` |
| Versioned coder with schema migration (v1 → v2) | `DepotKeys.swift`, `SettingsView.swift` |
| `metadata(for:)` cache age + `removeExpired()` sweep | `ForecastModel.swift`, `CityDetailView.swift` |
| `@DepotValue` (settings react across views) | `SettingsView.swift`, `CityDetailView.swift` |
| `@DepotValues` (live saved-cities list) | `CityListView.swift`, `CitySearchView.swift` |
| Combine `published(valueFor:)` | `Model/RefreshStatusModel.swift` |
| `AsyncStream` `depot.values(for:)` | `Views/ActivityLogView.swift` |
| `diskUsage()` / `diskUsage(under:)` / `count(for:)` | `Views/ActivityLogView.swift` |

## Storage layout

Saved cities, cached forecasts, and settings persist in a file-backed depot
named **WeatherDepot** (Application Support). City-search results live in a
memory-only depot and vanish on quit.

To keep the demo small, the re-downloadable forecast cache shares a depot with
durable data. In a real app, put disposable cache data in its own depot under
`Library/Caches` (`Depot(directory: .caches, name: ...)`), so it is not backed
up and the system may purge it. Note also that a memory-only depot never invokes
coders, so it is a stand-in for transient state, not a test of persistence.

Call `depot.storageTree()` at runtime to print this tree from the actual
registered keys:

```
WeatherDepot
├── cities
│   └── * [City] .json(City) (pattern)
├── forecasts
│   └── * [Forecast] .json(Forecast).compressed(.zlib) (pattern, expires: 30m)
├── settings
│   └── app [AppSettings] .json(AppSettings).versioned(v2)
└── stats
    └── lastRefresh [Date] .json(Date)
```
