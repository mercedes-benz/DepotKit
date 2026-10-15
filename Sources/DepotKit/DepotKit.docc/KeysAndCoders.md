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
| `**` (trailing) | `.globstar` | **One or more** components | `"locations" / .globstar` matches `locations/berlin` and `locations/berlin/forecast`, but not `locations` |
| `**` (leading or middle) | `.globstar` | **Zero or more** components | `.globstar / "forecast"` matches `forecast` and `locations/berlin/forecast`; `"locations" / .globstar / "forecast"` matches `locations/forecast` and `locations/berlin/forecast` |

These are the `**` rules of `.gitignore`: a trailing `**` matches everything *inside* a prefix, but not the prefix itself. A value stored at the prefix can therefore have a type of its own — for example, a list of user IDs at `users` next to one profile per user at `users/<id>`:

```swift
let userIDs = depot.register(keyPath: "users", coder: .json([String].self))
let profiles = depot.register(keyPath: "users" / .wildcard, coder: .json(Profile.self))

try await depot.set(value: ["alice"], for: userIDs)
try await depot.set(value: Profile(name: "Alice"), for: Key.from("users" / "alice", as: Profile.self))

let all = try await depot.get(valuesFor: profiles)            // [Profile] — the list at `users` is not included
try await depot.remove(valuesFor: Key.from("users" / .globstar)) // removes users/…, keeps the list at `users`
```

The special ``Key/all`` is a single globstar — it matches every key in the depot.

### Building Keys Dynamically

Keys support `appending` for runtime construction:

```swift
let base = Key.from("locations", as: Forecast.self)
let berlinForecast = base.appending("berlin").appending("forecast")
// → TypedDistinctKey<Forecast> for "locations/berlin/forecast"
```

### Key Identifiers on Disk

Identifiers are normalized to Unicode Normalization Form C (NFC) when a key is constructed — through the `/` DSL, `Key.from`, ``KeyDefinition``/`#key`, `appending`, the component-array initializers, and at the depot boundary for custom ``KeyProtocol`` types. Canonically equivalent spellings such as `"é"` (U+00E9) and `"e\u{301}"`, or Hangul syllables and their conjoining jamo, therefore name the same value in memory and on disk. Normalization never folds letter case or compatibility characters: `"A"` and `"a"` remain different keys.

A file-backed depot stores every value in its own file. Each key component becomes one path component and the last one gets a `.bin` extension, e.g. `locations/berlin/forecast` → `<encoded locations>/<encoded berlin>/<encoded forecast>.bin`. Every component is encoded, whatever its spelling, so no identifier — including ones containing `/`, `..` or a leading `.` — can address files outside the depot directory or its hidden internal files.

DepotKit never creates symbolic links. Pattern reads, counts and removals, disk-usage measurements, and the pruning of empty directories walk the depot directory without following symbolic links, so a link placed there by other code is ignored and never leads them outside the depot directory.

The encoding follows the case sensitivity of the volume that holds the depot directory:

| Volume | File names | Example (`aaa`) |
|---|---|---|
| Case-sensitive (e.g. iOS devices) | RFC 4648 Base64url (`-`, `_`) with `=` padding | `YWFh.bin` |
| Case-insensitive (e.g. default macOS, the iOS Simulator) | RFC 4648 Base32 (`A–Z`, `2–7`) with `=` padding | `MFQWC===.bin` |

DepotKit chooses the encoding each time the depot is opened by querying the volume's `volumeSupportsCaseSensitiveNames` capability (using the nearest existing ancestor when the depot directory does not exist yet). If the capability cannot be determined, DepotKit falls back to the platform's usual volume type — Base32 on macOS, Mac Catalyst and the Simulator, Base64url on devices of all other platforms — and logs an error naming the chosen encoding. File names carry no per-file tag, and DepotKit never guesses the encoding from a file name.

Each encoded component must fit into the 255-byte file-name limit, including the `.bin` extension of the last component. The supported identifier lengths, measured in UTF-8 bytes of the NFC form, are:

| Format | Directory component | Last component |
|---|---|---|
| Base64url | 189 bytes | 186 bytes |
| Base32 | 155 bytes | 155 bytes |

Longer components are rejected with ``DepotError/keyComponentTooLong(keyPath:byteCount:maximumByteCount:)``; they are never truncated or hashed. Memory-only depots have no length limit.

## Key Definitions

For static keys known at compile time, use ``KeyDefinition`` and ``PatternKeyDefinition``, or the `#key` and `#pattern` macros that create them:

```swift
// Macros — check the path syntax at compile time
let savedLocations = #key("locations/saved", coder: .json([SavedLocation].self))
let allForecasts   = #pattern("locations/*/forecast", coder: .json(Forecast.self))

// Manual — no macro needed
let widgetConfig = KeyDefinition<WidgetConfig>(
    path: "widget" / "config",
    coder: .json()
)
```

The macros validate path **syntax**: an empty path or component, interpolation, an invalid escape, consecutive wildcards, a wildcard in `#key`, or a `#pattern` without a wildcard is a compile-time error. They can't detect a misspelled but well-formed identifier — `"locations/saevd"` is a valid, different key — so declare each key once and use the definition everywhere. The manual initializers accept the same paths through the `/` operator and are fully supported.

The macro path must be a plain string literal (no interpolation). It is resolved in two stages: first as a Swift string literal, then DepotKit's key path escapes — `\/` for a literal `/`, `\*` for a literal `*`, and `\\` for a literal backslash — are applied. In an ordinary string literal a key path escape therefore needs a doubled backslash (`"a\\/b"`), in a raw string literal a single one (`#"a\/b"#`). See ``key(_:coder:)`` for details.

Both `KeyDefinition` and `PatternKeyDefinition` can include an `expiry`; the macros can't:

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

// → version header + migration (see "Versioned Coders and Migration")
.json(Forecast.self).versioned(version: 2) { data, oldVersion in
    try? JSONDecoder().decode(Forecast.self, from: data)
}
```

The full chain applies transformations **left-to-right on write** (encode → compress → encrypt) and **right-to-left on read** (decrypt → decompress → decode).

CRC32 integrity is applied automatically by the depot file header — you don't need to add it to the coder chain. The checksum detects accidental corruption such as truncated files; it is not a cryptographic authentication of the content.

### Compression Algorithms

``CompressionAlgorithm`` provides four options:

| Algorithm | Trade-off |
|-----------|-----------|
| `.lz4` | Fastest, moderate ratio |
| `.lzfse` | Apple-optimized, good balance |
| `.zlib` | Widely compatible, default |
| `.lzma` | Best ratio, slowest |

### Custom Coders

Implement the ``Coder`` protocol to integrate any serialization format — for example a third-party format such as Protocol Buffers, or a compact text representation:

```swift
/// Stores a date as an ISO 8601 string with whole-second precision.
struct ISO8601DateCoder: Coder {
    func encode(_ value: Date) throws -> Data {
        Data(value.formatted(.iso8601).utf8)
    }

    func decode(_ data: Data) throws -> Date {
        try Date(String(decoding: data, as: UTF8.self), strategy: .iso8601)
    }
}

// Pass it directly — DepotKit accepts any `some Coder<V>`
let lastSyncKey = depot.register(
    keyPath: "sync" / "last", coder: ISO8601DateCoder()
)
```

Custom coders also compose with the built-in transformations:

```swift
let coder = ISO8601DateCoder()
    .eraseToAnyCoder()
    .compressed(using: .lz4)
```

## Registration

Registration tells the depot **how** to serialize a key's values and **when** they expire. Think of it as declaring a schema: you define the shape of your storage when you create the depot, then use the returned typed handles throughout the app's lifetime.

### Why Register?

A depot stores raw bytes on disk. Registration associates each key (or key pattern) with:

1. **A coder** — how to encode/decode the value (JSON, plist, compressed, encrypted, etc.)
2. **An expiry** (optional) — how long the value is considered fresh

This binding is what makes the API type-safe: the handle returned by `register()` carries the value type at compile time, so you cannot accidentally read a `Forecast` key as a `[SavedLocation]`.

### When to Register

Register early — typically when you create the depot during app launch or dependency injection setup — and keep the returned handles. Don't register inside a write helper or on every access:

```swift
// ✅ Register when the depot is created
final class WeatherStore {
    let depot: Depot
    let forecastKey: TypedKey<Forecast>
    let unitsKey: TypedDistinctKey<UnitPreferences>
    let savedLocationsKey: TypedDistinctKey<[SavedLocation]>

    init() throws {
        depot = try Depot(name: "Weather")

        forecastKey = depot.register(
            keyPath: "locations" / .wildcard / "forecast",
            coder: .json(Forecast.self),
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

Each registration **replaces** any earlier registration of the same path (or pattern). Registering an identical definition again is therefore harmless: the `definition:` initializers of `@DepotValue` and `@DepotValues` register their key when the view starts observing (and again only if the key or depot changes). What causes problems is registering the same path with a **different** coder, value type, or expiry — the last registration wins, values written in the old format may no longer decode, and handles of the old value type fail with ``DepotError/mismatchedTypes(keyPath:expected:actual:)``. Keep exactly one definition per path.

### Pattern Registration

Pattern keys are the key (pun intended) to avoiding repetitive registration. Register a pattern **once** and it covers every concrete key that matches:

```swift
let forecastKey = depot.register(
    keyPath: "locations" / .wildcard / "forecast",
    coder: .json(Forecast.self),
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
depot.register(#pattern("locations/*/alerts", coder: .json([WeatherAlert].self)))

// Pattern with expiry — macros don't take an expiry
depot.register(
    keyPath: "locations" / .wildcard / "forecast",
    coder: .json(Forecast.self),
    expiry: .seconds(1800)
)
depot.register(
    PatternKeyDefinition<[WeatherAlert]>(
        path: "warnings" / .wildcard,
        coder: .json(),
        expiry: .seconds(3600)
    )
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

Expiry is checked lazily on every read; an expired value reads as `nil`. There is no timer, so observers are not notified at the exact expiry time. A file-backed depot removes expired files in a sweep shortly after it opens, and ``Depot/removeExpired()-1gvix`` runs the same sweep on demand. See <doc:Lifecycle> for details.

## Versioned Coders and Migration

When your data model changes, use `.versioned(version:migration:)` to read old formats. The coder prefixes each payload with a version header. When it reads a payload with a different version, it calls the migration closure with the inner payload and the old version — `nil` for data written without a version header, for example before you added `.versioned`. Return the migrated value; returning `nil` makes the read fail with ``VersionedCoderError``.

```swift
struct Place: Codable, Sendable, Equatable {
    var name: String
    var latitude: Double
    var longitude: Double
    var timeZone: String?   // added in version 3
}

/// Version 1 stored the coordinates as strings.
struct PlaceV1: Codable {
    var name: String
    var lat: String
    var lon: String
}

let placeCoder: AnyCoder<Place> = .json().versioned(version: 3) { data, oldVersion in
    switch oldVersion {
    case nil, 1:
        let old = try JSONDecoder().decode(PlaceV1.self, from: data)
        guard let latitude = Double(old.lat), let longitude = Double(old.lon) else {
            return nil
        }
        return Place(name: old.name, latitude: latitude, longitude: longitude, timeZone: nil)
    case 2:
        // Version 2 had no time zone; the optional property decodes as nil.
        return try JSONDecoder().decode(Place.self, from: data)
    default:
        return nil
    }
}
```

Migration happens on read and is not written back automatically: the stored payload is upgraded the next time the value is written.

## Compatibility and Migration

DepotKit follows Semantic Versioning: source-breaking API changes happen only in a new major version. Each value file starts with a versioned header; newer releases read files written by earlier releases of the same major version, and a release that can't interpret a newer file throws ``DepotError/incompatibleVersion(fileVersion:readerVersion:)``. A store keeps the file-name format it was created with.

DepotKit does not migrate your data model. These changes are your responsibility:

| Change | What to do |
|---|---|
| Value type changes shape | Wrap the coder in `.versioned(version:migration:)` (see above). |
| Different coder for existing values (e.g. adding compression or encryption) | Read the values with the old registration, register the new coder, and write them back. |
| Renamed key or pattern | Read with the old key, write with the new key, then remove the old value. |
| Data needed on another volume or device | System backup and restore and device-to-device migration need no action. Otherwise, export the values through the depot API and import them there; see <doc:KeysAndCoders#Backups-and-Moving-Stores>. |

### Changing a Coder

Registering a new coder for a path doesn't convert stored values. Read them with the old coder first, then write them with the new one:

```swift
// 1. Read with the coder the values were written with.
let oldForecasts = depot.register(keyPath: "forecasts" / .wildcard, coder: .json(Forecast.self))
let existing = try depot.get(availableValuesFor: oldForecasts).keyedValues

// 2. Register the new coder and write the values back.
let forecasts = depot.register(
    keyPath: "forecasts" / .wildcard,
    coder: AnyCoder<Forecast>.json().compressed(using: .lzfse)
)
for (key, forecast) in existing {
    try depot.set(value: forecast, for: key.typed(as: Forecast.self))
}
```

Do this once, before other code uses the keys — for example in your store's initializer, guarded by a stored schema version. Rewriting a value restarts its expiry period.

### Renaming a Key

Write the new key before removing the old one, so an interrupted migration can simply run again:

```swift
let oldUnits = depot.register(#key("settings/units", coder: .json(UnitPreferences.self)))
let units = depot.register(#key("preferences/units", coder: .json(UnitPreferences.self)))

try depot.transaction { tx in
    if let value = try tx.get(valueFor: oldUnits) {
        try tx.set(value: value, for: units)
        try tx.remove(valueFor: oldUnits)
    }
}
```

### Backups and Moving Stores

DepotKit chooses the file-name encoding from the case sensitivity of the volume (see <doc:KeysAndCoders#Key-Identifiers-on-Disk>) and assumes that a store stays on the same kind of volume.

The system's own backup and restore is supported: iCloud and Finder device backups restored onto the same or a new device, and device-to-device migration such as Quick Start or Migration Assistant. The restored store lands on the same kind of volume. An encrypted depot additionally needs its key to be available after the restore; see <doc:EncryptionAndMultiProcess#Managing-Keys>.

Moving or copying a store directory yourself to another volume or device is not supported — for example to an external drive, to a Mac, into another app's container, or between a device and the Simulator. To take data elsewhere, build an export into your app: read the values through the depot API, write them in whatever format you need, and import them on the other side by writing them through the depot API into a new store.

A separate depot instance with only a catch-all registration reads every stored value as raw bytes, exactly as your regular coders encoded it:

```swift
let exporter = Depot(configuration: depot.configuration)
let everything = exporter.register(key: Key.all, coder: .data(Data.self))

let export = try exporter.get(availableValuesFor: everything)
for (key, payload) in export.keyedValues {
    // Write key.components and payload in your export format.
}
// export.keyedErrors lists values that could not be read.
```

These payloads are still encoded with your regular coders, so the importing side must decode them with the same coders. To export in a format of your own instead, read the values with your regular registrations.
