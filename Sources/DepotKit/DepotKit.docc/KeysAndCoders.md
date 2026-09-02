# Keys and Coders

Understand the key hierarchy, coder composition, and how they work together.

## Overview

DepotKit separates **addressing** (keys) from **serialization** (coders). A key identifies where a value lives; a coder defines how it's converted to and from `Data`. Registering a key with a coder produces a typed handle that the compiler enforces.

## Key Hierarchy

Keys are slash-separated paths. DepotKit provides four key types along two axes — typed vs. untyped, and distinct vs. pattern:

| | Untyped | Typed |
|---|---------|-------|
| **Distinct** (no wildcards) | ``DistinctKey`` | ``TypedDistinctKey`` |
| **Pattern** (may contain wildcards) | ``Key`` | ``TypedKey`` |

Most of the time you work with `TypedDistinctKey<V>` — the return type of `register()` for concrete keys — and `TypedKey<V>` for pattern registrations.

All key types conform to ``KeyProtocol``, which provides the ``KeyProtocol/keyPath`` string representation, ``KeyProtocol/matches(_:)`` for pattern matching, and ``KeyProtocol/appending(_:)-(KeyComponent)`` for building keys dynamically.

## Constructing Keys

Use the `/` operator DSL to build key paths:

```swift
// Distinct keys — concrete path, no wildcards
let key = Key.from("preferences" / "units")                              // DistinctKey
let typed = Key.from("widget" / "config", as: WidgetConfig.self)         // TypedDistinctKey<WidgetConfig>

// Dynamic components — any CustomStringConvertible works
let cityId = "berlin-52-13"
let forecast = Key.from("locations" / cityId / "forecast")               // DistinctKey

// Pattern keys — contain wildcards
let allForecasts = Key.from("locations" / .wildcard / "forecast")        // Key (pattern)
let allCached = Key.from("cache" / .globstar)                            // Key (pattern)
```

### Wildcards

| Symbol | ``KeyComponent`` | Meaning | Example |
|--------|----------|---------|---------|
| `*` | `.wildcard` | Exactly **one** component | `"locations" / .wildcard` matches `locations/berlin` but not `locations/berlin/forecast` |
| `**` | `.globstar` | **Zero or more** components | `"locations" / .globstar` matches `locations`, `locations/berlin`, `locations/berlin/forecast` |

The special ``Key/all`` is a single globstar — it matches every key in the depot.

### Building Keys Dynamically

Keys support `appending` for runtime construction:

```swift
let base = Key.from("locations", as: Forecast.self)
let berlinForecast = base.appending("berlin").appending("forecast")
// → TypedDistinctKey<Forecast> for "locations/berlin/forecast"
```

## Key Definitions

For static keys known at compile time, use ``KeyDefinition`` or the `#key` macro:

```swift
// Macro (preferred — validates the path at compile time)
let savedLocations = #key("locations/saved", coder: .json([SavedLocation].self))
let allForecasts   = #pattern("locations/*/forecast", coder: .json(Forecast.self))

// Manual
let widgetConfig = KeyDefinition<WidgetConfig>(
    path: "widget" / "config",
    coder: .json()
)
```

Both `KeyDefinition` and `PatternKeyDefinition` can include an `expiry`:

```swift
let forecast = PatternKeyDefinition<Forecast>(
    path: "locations" / .wildcard / "forecast",
    coder: .json(),
    expiry: .seconds(1800)   // 30 minutes
)
```

## Coders

``AnyCoder`` is the public coder type. Create instances through static factories:

| Factory | Input Constraint | Encoding |
|---------|-----------------|----------|
| `.json()` | `Codable` | JSON via `JSONEncoder`/`JSONDecoder` |
| `.plist()` | `Codable` | Binary property list |
| `.data()` | `LosslessDataConvertible` | Raw bytes (pass-through) |

All factories accept an explicit type parameter: `.json(Forecast.self)`. When the type can be inferred from context (e.g. inside a `KeyDefinition<Forecast>`), the parameter can be omitted.

### Composition

Coders compose by wrapping. Each transformation adds a layer:

```swift
// Codable → JSON Data
.json(Forecast.self)

// → compressed
.json(Forecast.self).compressed(using: .lz4)

// → encrypted
.json(Forecast.self).encrypted(using: encryptionConfig)

// → compressed, then encrypted
.json(Forecast.self).compressed(using: .lz4).encrypted(using: encryptionConfig)

// → version header + migration
.json(Forecast.self).versioned(version: 2) { data, oldVersion in
    // migrate from older schema
}
```

The full chain applies transformations **left-to-right on write** (encode → compress → encrypt) and **right-to-left on read** (decrypt → decompress → decode).

CRC32 integrity is applied automatically by the depot file header — you don't need to add it to the coder chain.

### Compression Algorithms

``CompressionAlgorithm`` provides four options:

| Algorithm | Trade-off |
|-----------|-----------|
| `.lz4` | Fastest, moderate ratio |
| `.lzfse` | Apple-optimized, good balance |
| `.zlib` | Widely compatible, default |
| `.lzma` | Best ratio, slowest |

### Custom Coders

Implement the ``Coder`` protocol to integrate any serialization format:

```swift
struct ProtobufCoder<T: Message>: Coder {
    func encode(_ value: T) throws -> Data {
        try value.serializedData()
    }
    func decode(_ data: Data) throws -> T {
        try T(serializedBytes: data)
    }
}

// Pass it directly — DepotKit accepts any `some Coder<V>`
let tileKey = depot.register(
    keyPath: "radar" / "tile", coder: ProtobufCoder<RadarTile>()
)
```

Custom coders also compose with the built-in transformations:

```swift
let coder = ProtobufCoder<RadarTile>()
    .eraseToAnyCoder()
    .compressed(using: .lz4)
```

## Registration

Registration tells the depot **how** to serialize a key's values and **when** they expire. It happens **once** at app startup — not before every read or write. Think of it as declaring a schema: you define the shape of your storage up front, then use the returned typed handles throughout the app's lifetime.

### Why Register?

A depot stores raw bytes on disk. Registration associates each key (or key pattern) with:

1. **A coder** — how to encode/decode the value (JSON, plist, compressed, encrypted, etc.)
2. **An expiry** (optional) — how long the value is considered fresh

This binding is what makes the API type-safe: the handle returned by `register()` carries the value type at compile time, so you cannot accidentally read a `Forecast` key as a `[SavedLocation]`.

### When to Register

Register **once**, early — typically during app launch or dependency injection setup. Do **not** register inside a write helper or on every access. Registration is idempotent but it is a setup-time concern, not a per-operation concern:

```swift
// ✅ Register once at startup
final class WeatherStore {
    let depot: Depot
    let forecastKey: TypedKey<Forecast>
    let unitsKey: TypedDistinctKey<UnitPreferences>
    let savedLocationsKey: TypedDistinctKey<[SavedLocation]>

    init() throws {
        depot = try Depot(name: "Weather")

        forecastKey = depot.register(
            #pattern("locations/*/forecast", coder: .json(Forecast.self)),
            expiry: .seconds(1800)
        )
        unitsKey = depot.register(
            #key("preferences/units", coder: .json(UnitPreferences.self))
        )
        savedLocationsKey = depot.register(
            #key("locations/saved", coder: .json([SavedLocation].self))
        )
    }

    func forecast(for locationId: String) async throws -> Forecast? {
        let key = Key.from("locations" / locationId / "forecast", as: Forecast.self)
        return try await depot.get(valueFor: key)
    }
}
```

```swift
// ❌ Don't do this — registering on every write is wasteful and misleading
func saveForecast(_ forecast: Forecast, for locationId: String) async throws {
    let key = depot.register(
        keyPath: "locations" / locationId / "forecast",
        coder: .json(Forecast.self)
    )
    try await depot.set(value: forecast, for: key)
}
```

### Pattern Registration

Pattern keys are the key (pun intended) to avoiding repetitive registration. Register a pattern **once** and it covers every concrete key that matches:

```swift
let forecastKey = depot.register(
    #pattern("locations/*/forecast", coder: .json(Forecast.self)),
    expiry: .seconds(1800)
)
```

Now you can read and write any matching concrete key without further registration:

```swift
let berlinForecast = Key.from("locations" / "berlin" / "forecast", as: Forecast.self)
let tokyoForecast = Key.from("locations" / "tokyo" / "forecast", as: Forecast.self)

try await depot.set(value: forecast, for: berlinForecast)
let all = try await depot.get(valuesFor: forecastKey) // [Forecast] — all locations
```

The coder and expiry from the pattern registration apply to every concrete key that matches.

### Registration Summary

```swift
// Distinct key — one specific value
depot.register(keyPath: "preferences" / "units", coder: .json(UnitPreferences.self))

// From a #key macro
depot.register(#key("locations/saved", coder: .json([SavedLocation].self)))

// Pattern — covers a family of keys
depot.register(
    #pattern("locations/*/forecast", coder: .json(Forecast.self)),
    expiry: .seconds(1800)
)
depot.register(
    #pattern("locations/*/alerts", coder: .json([WeatherAlert].self)),
    expiry: .seconds(3600)
)
```

### Expiry (TTL)

Pass an `expiry` duration at registration time. Values written to that key automatically expire after the given duration. The `expiry` parameter is a Swift `Duration`:

```swift
let hourly = depot.register(
    keyPath: "locations" / "current" / "hourly",
    coder: .json(HourlyForecast.self),
    expiry: .seconds(1800)   // 30 minutes
)
// After 30 minutes, get returns nil — the cached forecast is considered stale.
```

Expiry is checked lazily on every read. A background sweep removes expired files shortly after the depot initializes. You can also call ``Depot/removeExpired()-1gvix`` manually.

## Versioned Coders and Migration

When your data model changes, use `.versioned()` to handle old formats. The migration closure receives the raw `Data` and the old version number (or `nil` if no version header was found). Return the migrated `Value`, or `nil` if migration is not possible:

```swift
let coder: AnyCoder<SavedLocation> = .json().versioned(version: 3) { data, oldVersion in
    switch oldVersion {
    case 1:
        // v1 stored coordinates as strings, v2+ uses Double
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["lat"] = Double(json["lat"] as? String ?? "0")
        json["lon"] = Double(json["lon"] as? String ?? "0")
        json["timezone"] = NSNull()
        let migrated = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(SavedLocation.self, from: migrated)
    case 2:
        // v2 had no timezone, v3 adds it as optional
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["timezone"] = NSNull()
        let migrated = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(SavedLocation.self, from: migrated)
    default:
        return nil
    }
}
```
