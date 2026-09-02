# Getting Started

Create a depot, register keys, and start reading and writing values.

## Overview

DepotKit's workflow has three steps: create a depot, register keys with their coders, then read and write values using those keys. This guide walks through each step and covers the most common patterns.

## Create a Depot

A **depot** is the storage backend. ``Depot`` persists values as individual files inside a directory you choose, with built-in async support and bounded concurrency:

```swift
import DepotKit

// Shortest form — creates a depot in Application Support
let depot = try Depot(name: "Weather")

// Explicit directory and cache for large data
let radarCache = try Depot(directory: .caches, name: "RadarTiles", cache: .large)
```

The `directory` parameter picks a base location (`.applicationSupport`, `.documents`, `.caches`, `.temporary`). The `name` creates a subdirectory for this depot's files.

For full control, pass a ``DepotConfiguration`` directly:

```swift
let config = DepotConfiguration(
    directoryURL: customURL,
    isExcludedFromBackup: true,
    fileProtection: .completeUntilFirstUserAuthentication,
    memoryCache: .medium   // 16 MB in-memory cache
)
let depot = Depot(configuration: config)
```

### Memory-Only Mode

For tests or ephemeral state, create a depot with no disk backing. The API is identical — no files are created:

```swift
let testDepot = Depot(label: "UnitTests")
```

## Register Keys

Every key must be **registered** with a coder before use. Registration tells the depot how to serialize the value and returns a typed key handle. Register **once** at app startup — not before every read or write:

```swift
// Using the #key macro (recommended)
let savedLocations = depot.register(
    #key("locations/saved", coder: .json([SavedLocation].self))
)
// → TypedDistinctKey<[SavedLocation]>

// Or using the key path DSL directly
let units = depot.register(
    keyPath: "preferences" / "units", coder: .json(UnitPreferences.self)
)
// → TypedDistinctKey<UnitPreferences>

// Pattern registration — one call covers all matching concrete keys
let forecastKey = depot.register(
    #pattern("locations/*/forecast", coder: .json(Forecast.self)),
    expiry: .seconds(1800)   // 30 minutes
)
```

The returned key carries the value type at compile time — you cannot accidentally read it as the wrong type. Attempting to read or write with an unregistered key throws ``DepotError/unregisteredKey(keyPath:)``.

## Read and Write

All CRUD operations have both synchronous and async overloads. The async versions use the depot's internal concurrency semaphore:

```swift
// Write
try await depot.set(value: [.berlin, .munich], for: savedLocations)
try await depot.set(value: UnitPreferences(temp: .celsius), for: units)

// Read — returns nil when no value exists or the value has expired
let locations = try await depot.get(valueFor: savedLocations)  // [SavedLocation]?

// Read with a default
let prefs = try await depot.get(
    valueFor: units, default: UnitPreferences.default
)  // UnitPreferences (never nil)

// Check existence without decoding
let exists = try await depot.has(valueFor: units)  // Bool

// Count matching values (useful with patterns)
let cityCount = try await depot.count(for: forecastKey)  // Int

// Remove a single value
try await depot.remove(valueFor: savedLocations)

// Remove everything in the depot
try await depot.removeAll()
```

## Pattern Keys

Keys can contain **wildcards** for bulk operations. A single pattern registration covers an entire family of concrete keys:

```swift
// * matches exactly one path component
let allForecasts = depot.register(
    #pattern("locations/*/forecast", coder: .json(Forecast.self))
)

// ** matches zero or more components
let allCached = depot.register(
    #pattern("cache/**", coder: .data(Data.self))
)

// Write concrete keys that match the pattern — no extra registration needed
let berlinForecast = Key.from("locations" / "berlin" / "forecast", as: Forecast.self)
try await depot.set(value: forecast, for: berlinForecast)

// Read all matching values
let forecasts = try await depot.get(valuesFor: allForecasts)  // [Forecast]

// Remove all matching values
try await depot.remove(valuesFor: allCached)
```

### Partial-Success Reads

When reading multiple values, a single decode failure normally throws and discards all results. Use ``Depot/get(availableValuesFor:)-6jq3p`` to collect errors per-key while still delivering the values that did decode:

```swift
let result = try await depot.get(availableValuesFor: allForecasts)
// result.values  → [Forecast]  — successfully decoded values
// result.errors  → [DistinctKey: Error]  — per-key decode failures
```

## TTL / Expiry

Register keys with a time-to-live. Expired values are treated as absent on read:

```swift
let hourlyForecast = depot.register(
    keyPath: "locations" / "current" / "hourly",
    coder: .json(HourlyForecast.self),
    expiry: .seconds(1800)   // 30 minutes
)
// After 30 minutes, get returns nil — your refresh logic kicks in.
```

Expiry is checked lazily on every read. A background sweep runs automatically after depot initialization to clean up stale files. You can also trigger it manually:

```swift
let removedCount = try depot.removeExpired()
```

## Value Metadata

Inspect when a value was last written and when it will expire without decoding it:

```swift
if let meta = try depot.metadata(for: someKey) {
    print("Written at: \(meta.modifiedAt)")
    if let expires = meta.expiresAt {
        print("Expires at: \(expires)")
    }
}
```

## Organise Keys

Centralise key definitions in an enum for discoverability. Use the `#key` and `#pattern` macros — they validate the path at compile time:

```swift
enum WeatherKeys {
    static let savedLocations = #key("locations/saved", coder: .json([SavedLocation].self))
    static let units          = #key("preferences/units", coder: .json(UnitPreferences.self))
    static let widgetConfig   = #key("widget/config", coder: .json(WidgetConfig.self))
    static let forecast       = #pattern("locations/*/forecast", coder: .json(Forecast.self))
}

// Register at app launch
let locationsKey = depot.register(WeatherKeys.savedLocations)
let unitsKey     = depot.register(WeatherKeys.units)
let widgetKey    = depot.register(WeatherKeys.widgetConfig)
let forecastKey  = depot.register(WeatherKeys.forecast)
```

## Logging

DepotKit has a pluggable log sink. Assign a sink to ``DepotKitLogging/sink`` to see internal operations:

```swift
// Use the built-in os_log sink
DepotKitLogging.sink = .osLog()

// Or route to your own logger
DepotKitLogging.sink = .callback { level, message, _, _, _ in
    myLogger.log(level: level, "\(message())")
}
```

## Next Steps

- <doc:KeysAndCoders> — Deep dive into key types, coder composition, and encryption.
- <doc:Observation> — AsyncSequence, Combine, and SwiftUI observation.
- <doc:Transactions> — Atomic read-modify-write and the `modify` convenience.
- <doc:EncryptionAndMultiProcess> — Encryption, app groups, and multi-process support.
- <doc:Lifecycle> — Integrity checks, cache management, and disk usage.
