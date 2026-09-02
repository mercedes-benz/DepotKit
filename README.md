<picture>
  <img src=".github/images/hero.jpg" alt="DepotKit — A type-safe, composable key-value store for Apple platforms">
</picture>

# DepotKit

**DepotKit** is a type-safe, composable key-value store for Apple platforms — file-system persistence with the ergonomics of a modern Swift API.

[![MIT License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138.svg?style=flat)](https://swift.org)
[![SPM Compatible](https://img.shields.io/badge/SPM-Compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![Platforms](https://img.shields.io/badge/Platforms-iOS_17_|_watchOS_10_|_tvOS_17_|_macOS_14-blue.svg)](https://developer.apple.com)

```swift
// Create a file-backed store
let depot = try Depot(name: "Weather")

// Declare a typed key — path + coder, validated at compile time
let conditions = depot.register(#key("locations/current/conditions", coder: .json(WeatherConditions.self)))

// Write
try await depot.set(value: WeatherConditions(temp: 22, sky: .cloudy), for: conditions)

// Observe — delivers the current value, then every future change
for await case .success(let value) in depot.values(for: conditions) {
    updateWidget(with: value)
}
```

## Motivation

Every app needs to persist state that is too structured for `UserDefaults` and too simple for a database: preferences, cached API responses, drafts, feature state. The usual answer — hand-rolled `Codable` + `FileManager` code — accumulates subtle bugs around atomicity, concurrency, cache invalidation, and change notification.

DepotKit packages those details into one well-tested library:

- **Type-safe keys** — Keys carry their value type at compile time. No stringly-typed lookups, no force casts.
- **Composable coders** — Chain `.json().compressed(using: .lz4)` and more like middleware.
- **Wildcard queries** — Fetch all values matching `"users/*/settings"` or `"cache/**"`.
- **Observation** — `AsyncSequence`, Combine publishers, or `@DepotValue` / `@DepotValues` for SwiftUI.
- **Transactions** — Grouped read-modify-write with rollback on failure and coalesced notifications.
- **TTL / Expiry** — Per-key time-to-live with lazy expiration and automatic background sweep.
- **Encryption** — Built-in AEAD + HMAC, composable with any coder chain.
- **Multi-process** — App group support with automatic external-change detection.
- **Memory-only mode** — Same API without disk I/O, ideal for tests and ephemeral state.
- **File integrity** — 28-byte file header with CRC32 validation on every read.
- **Zero runtime dependencies** — Only swift-syntax for macros (compile-time only).

Written in **Swift 6** with *Strict Concurrency* throughout.

## Table of Contents

- [Usage](#usage)
  - [Creating a Depot](#creating-a-depot)
  - [Keys and Registration](#keys-and-registration)
  - [Reading and Writing](#reading-and-writing)
  - [Observation](#observation)
  - [Transactions](#transactions)
  - [TTL / Expiry](#ttl--expiry)
  - [Coder Composition](#coder-composition)
- [Modules](#modules)
- [Adding DepotKit as a Dependency](#adding-depotkit-as-a-dependency)
- [Example App](#example-app)
- [Documentation](#documentation)
- [Development](#development)
- [Contributing](#contributing)
- [License](#license)

## Usage

### Creating a Depot

A `Depot` manages one directory of values. Create one per logical store:

```swift
import DepotKit

// Application Support (most apps)
let depot = try Depot(name: "Weather")

// Shared between app and extensions, with multi-process change detection
let shared = try Depot(appGroup: "group.com.example.weather", name: "Shared")

// Memory-only — same API, no disk I/O (great for tests and previews)
let ephemeral = Depot()
```

Need more control? Use `DepotConfiguration` to set the directory, file protection, encryption, backup exclusion, and cache size.

### Keys and Registration

Keys are typed, `/`-separated paths. Declare them once with the `#key` and `#pattern` macros, then register them at startup:

```swift
enum WeatherKeys {
    static let units          = #key("preferences/units", coder: .json(UnitPreferences.self))
    static let savedLocations = #key("locations/saved", coder: .json([SavedLocation].self))
    // One pattern covers berlin/forecast, tokyo/forecast, etc.
    static let forecast       = #pattern("locations/*/forecast", coder: .json(Forecast.self))
}

let unitsKey     = depot.register(WeatherKeys.units)
let locationsKey = depot.register(WeatherKeys.savedLocations)
let forecastKey  = depot.register(WeatherKeys.forecast)
```

The macros validate paths at compile time — a typo in a key path is a build error, not a runtime surprise.

### Reading and Writing

Every operation comes in synchronous and `async` variants:

```swift
try await depot.set(value: preferences, for: unitsKey)
let preferences = try await depot.get(valueFor: unitsKey)   // UnitPreferences?
try await depot.remove(valueFor: unitsKey)
```

Pattern keys operate on the whole family:

```swift
let allForecasts = try await depot.get(valuesFor: forecastKey)   // [Forecast]
let count        = try await depot.count(for: forecastKey)
try await depot.remove(valuesFor: forecastKey)

// Address a single member of the family
let berlin = Key.from("locations" / "berlin" / "forecast", as: Forecast.self)
try await depot.set(value: berlinForecast, for: berlin)
```

### Observation

Consume changes as an `AsyncSequence`:

```swift
for await result in depot.values(for: unitsKey) {
    if case .success(let preferences) = result {
        apply(preferences)
    }
}
```

As a Combine publisher (`DepotKitCombine`):

```swift
depot.published(valueFor: unitsKey)
    .compactMap { try? $0.get() }
    .receive(on: DispatchQueue.main)
    .sink { apply($0) }
```

Or directly in SwiftUI (`DepotKitObservation`):

```swift
struct ForecastList: View {
    @DepotValue(definition: WeatherKeys.units, depot: depot)
    var units: UnitPreferences?

    @DepotValues(key: forecastKey, depot: depot)
    var forecasts: [Forecast]

    var body: some View {
        List(forecasts, id: \.self) { forecast in
            ForecastRow(forecast: forecast, units: units)
        }
    }
}
```

### Transactions

Group operations atomically — if the closure throws, all mutations roll back and observers see nothing:

```swift
try depot.transaction { tx in
    var locations = try tx.get(valueFor: locationsKey) ?? []
    locations.append(SavedLocation(name: "Berlin", lat: 52.52, lon: 13.40))
    try tx.set(value: locations, for: locationsKey)
    try tx.set(value: Date.now, for: lastModifiedKey)
}
```

Observer notifications are coalesced: one notification per key, delivered after the transaction commits.

### TTL / Expiry

Give cached values a lifetime at registration:

```swift
let hourlyForecast = depot.register(
    keyPath: "locations" / "current" / "hourly", coder: .json(), expiry: .seconds(30 * 60)
)
// After 30 minutes, get returns nil — your refresh logic kicks in.
// A background sweep removes stale files after launch.
```

### Coder Composition

Coders transform values to bytes and back. Stack them — each wraps the previous:

```swift
let coder: AnyCoder<Forecast> = .json()
    .compressed(using: .lz4)
    .versioned(version: 2) { data, oldVersion in
        // migrate data written by an older schema
    }
```

Built-in coders: JSON, property list, raw `Data`, images, compression, encryption, and versioned migration. Conform to `Coder` to plug in your own.

## Modules

| Module | Purpose |
|--------|---------|
| **DepotKit** | Core — keys, coders, `Depot`, macros, transactions, TTL |
| **DepotKitCombine** | Combine publishers for depot observation |
| **DepotKitObservation** | `@DepotValue` / `@DepotValues` SwiftUI property wrappers |

The optional modules are gated behind [SPM traits](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-trait-system.md), both enabled by default:

| Trait | Default | Description |
|-------|---------|-------------|
| `Combine` | Enabled | Includes `DepotKitCombine` |
| `Observation` | Enabled | Includes `DepotKitObservation` |

## Adding DepotKit as a Dependency

Add DepotKit to the dependencies in your `Package.swift`:

```swift
let package = Package(
    // name, platforms, products, etc.
    dependencies: [
        .package(url: "https://github.com/mercedes-benz/DepotKit.git", from: "1.0.0"),
    ],
    targets: [
        .target(name: "<your-target>", dependencies: [
            .product(name: "DepotKit", package: "DepotKit"),
            .product(name: "DepotKitCombine", package: "DepotKit"),     // optional
            .product(name: "DepotKitObservation", package: "DepotKit"), // optional
        ]),
    ]
)
```

In an Xcode project, choose *File → Add Package Dependencies…* and enter `https://github.com/mercedes-benz/DepotKit.git`.

### Requirements

| | Minimum |
|--|---------|
| **Swift** | **6.2** |
| iOS | 17.0 |
| watchOS | 10.0 |
| tvOS | 17.0 |
| macOS | 14.0 |

## Example App

<p align="center">
  <img src=".github/images/demo-cities.png" width="220" alt="Cities tab — saved locations with live weather conditions">
  &nbsp;&nbsp;
  <img src=".github/images/demo-activity.png" width="220" alt="Activity tab — storage stats and depot event log">
  &nbsp;&nbsp;
  <img src=".github/images/demo-settings.png" width="220" alt="Settings tab — unit preferences and depot info">
</p>

[`Examples/DepotKitDemo`](Examples/DepotKitDemo) is a small SwiftUI weather app that exercises every DepotKit feature in a realistic setting — pattern keys and CRUD for saved cities, TTL-based forecast caching, compressed and versioned coders, live UI updates via `@DepotValue` / `@DepotValues`, Combine publishers, `AsyncSequence` observation, and a memory-only depot for transient search results.

```bash
cd Examples/DepotKitDemo
swift run DepotKitDemo   # macOS — or open DepotKitDemo.xcodeproj to run on iOS
```

## Documentation

Full API documentation is written in DocC. Generate it locally:

```bash
scripts/build-docs.sh
```

Or browse it directly in Xcode via *Product → Build Documentation*.

## Development

After cloning, run the setup script to install the pre-commit hook:

```bash
scripts/setup.sh
```

This installs a Git pre-commit hook that checks SPDX license headers and code formatting before each commit.

### Building & Testing

```bash
swift build
swift test
```

### Formatting

DepotKit uses Apple's [swift-format](https://github.com/swiftlang/swift-format) (ships with Xcode 26+). The configuration lives in `.swift-format` at the repo root.

```bash
scripts/format.sh          # format all source files
scripts/format.sh --check  # check without modifying (used by CI and the pre-commit hook)
```

### License Headers

Every `.swift` file must include an SPDX license header:

```bash
scripts/check-license-headers.sh        # check for missing headers
scripts/check-license-headers.sh --fix  # add missing headers
```

## Contributing

We welcome contributions! Please read our [Contributing Guide](CONTRIBUTING.md). All commits must be signed off under the [Developer Certificate of Origin](https://developercertificate.org/).

## Code of Conduct

Please read our [Code of Conduct](CODE_OF_CONDUCT.md) as it is our base for interaction.

## License

This project is licensed under the [MIT License](LICENSE).

## Notice

**Source code has been tested solely for our own use cases, which might differ from yours.**

## Provider Information

Please visit <https://group.mercedes-benz.com/provider/> for provider information.
