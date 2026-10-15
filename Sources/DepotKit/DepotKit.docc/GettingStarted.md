# Getting Started

Create a depot, register a key, read and write a value, and observe changes.

## Overview

This guide follows one path through DepotKit: create a depot, register a key, read and write a value, and observe it. Later sections introduce key families, expiry, and ways to organize keys.

The examples use two value types. Any `Codable` and `Sendable` type works with the JSON coder:

```swift
struct UnitPreferences: Codable, Sendable, Equatable {
    enum Temperature: String, Codable, Sendable {
        case celsius
        case fahrenheit
    }

    var temperature: Temperature

    static let standard = UnitPreferences(temperature: .celsius)
}

struct Forecast: Codable, Sendable, Hashable {
    var city: String
    var highs: [Double]
}
```

## Create a Depot

A ``Depot`` manages one directory and stores each value in its own file there:

```swift
import DepotKit

let depot = try Depot(name: "Weather")   // Library/Application Support/Weather
```

For previews and tests, `Depot()` creates a **memory-only** depot with the same API and no files.

> Note: A memory-only depot keeps values as Swift values and never invokes coders. Tests against it don't exercise serialization, encryption, or persistence, so keep some tests with a file-backed depot in a temporary directory.

## Register a Key

A key is a typed, `/`-separated path. Registering it tells the depot which coder to use and returns a handle that carries the value type:

```swift
let unitsKey = depot.register(
    #key("preferences/units", coder: .json(UnitPreferences.self))
)
// unitsKey: TypedDistinctKey<UnitPreferences>
```

Reading or writing a key that is not registered throws ``DepotError/unregisteredKey(keyPath:)``. Register your keys when you create the depot and keep the returned handles — see <doc:GettingStarted#Organize-Keys>.

The `#key` macro checks the path *syntax* at compile time: empty components, interpolation, invalid escapes, and wildcards are build errors. It can't tell whether a well-formed path is the one you meant — `"preferences/unit"` is simply a different key — so define each key in one place.

Without the macro, register the same key with the `/` operator. This form also works when you disable the package's default `Macros` trait, which keeps swift-syntax out of your build:

```swift
let unitsKey = depot.register(
    keyPath: "preferences" / "units", coder: .json(UnitPreferences.self)
)
```

## Read and Write

```swift
try await depot.set(value: UnitPreferences(temperature: .fahrenheit), for: unitsKey)

let units = try await depot.get(valueFor: unitsKey)                          // UnitPreferences?
let resolved = try await depot.get(valueFor: unitsKey, default: .standard)   // UnitPreferences
let exists = try await depot.has(valueFor: unitsKey)                         // Bool

try await depot.remove(valueFor: unitsKey)
```

Every operation also has a synchronous variant — call it without `await` from synchronous code. The async variants limit how many operations run at once (`maximumConcurrentTasks`, 4 by default).

## Observe Changes

``Depot/values(for:initialValue:)`` returns an `AsyncStream` that starts with the current value and then delivers the latest value after each change:

```swift
for await result in depot.values(for: unitsKey) {
    switch result {
    case .success(let units):
        print("Units:", units?.temperature.rawValue ?? "not set")   // nil: removed or expired
    case .failure(let error):
        print("Could not read units:", error)
    }
}
```

The loop runs until its task is cancelled, so start it in a `Task` you keep (or SwiftUI's `.task` modifier). Observation delivers the latest state rather than every intermediate value. Combine publishers and SwiftUI property wrappers are covered in <doc:Observation>.

That's the core workflow. The following sections add features as you need them.

## Work with Key Families

A **pattern** key contains wildcards and stands for a family of keys. Register the pattern once, then use distinct keys that it covers:

```swift
let forecastsKey = depot.register(
    #pattern("forecasts/*", coder: .json(Forecast.self))
)

let berlin = Key.from("forecasts" / "berlin", as: Forecast.self)
try await depot.set(value: Forecast(city: "Berlin", highs: [21, 23]), for: berlin)

let all = try await depot.get(valuesFor: forecastsKey)   // [Forecast]
let count = try await depot.count(for: forecastsKey)     // Int
try await depot.remove(valuesFor: forecastsKey)          // removes every forecast
```

`*` matches exactly one path component. `**` matches one or more components at the end of a pattern — `forecasts/**` covers everything below `forecasts`, but not a value stored at `forecasts` itself — and zero or more anywhere else, as in `.gitignore` (see <doc:KeysAndCoders#Wildcards>). The pattern must be registered before you use the distinct keys it covers. `depot.values(for: forecastsKey)` observes the whole family.

The order of the values that pattern reads and observations return is unspecified; sort them if you need a stable order.

### Partial-Success Reads

``Depot/get(valuesFor:)-51ef6`` throws if any value fails to decode. ``Depot/get(availableValuesFor:)-21xqj`` returns the values that decoded and the errors per key:

```swift
let result = try await depot.get(availableValuesFor: forecastsKey)
for (key, forecast) in result.keyedValues {
    print(key.keyPath, forecast.highs)
}
for (key, error) in result.keyedErrors {
    print("Skipping \(key.keyPath): \(error)")
}
```

``AvailableValuesResult/values`` and ``AvailableValuesResult/errors`` offer the same results without keys.

## Expire Cached Values

Expiry is part of the registration. The macros don't take an expiry, so register with a key path (or use a ``PatternKeyDefinition`` with `expiry:`):

```swift
let forecastsKey = depot.register(
    keyPath: "forecasts" / .wildcard,
    coder: .json(Forecast.self),
    expiry: .seconds(30 * 60)   // 30 minutes
)
```

An expired value reads as `nil`, so your refresh logic can treat it like a missing value. Expiry is checked when a value is read; there is no timer, so observers are not notified at the exact expiry time. A file-backed depot removes expired files in a sweep shortly after it opens, and you can run the sweep yourself:

```swift
let removedCount = try await depot.removeExpired()
```

Expiry is not a disk budget: DepotKit never deletes unexpired values to save space. See <doc:Lifecycle> for cleanup and disk usage.

## Inspect Metadata

Find out when a value was written and when it expires, without decoding it:

```swift
if let metadata = try await depot.metadata(for: berlin) {
    print("Written at:", metadata.modifiedAt)
    if let expiresAt = metadata.expiresAt {
        print("Expires at:", expiresAt)
    }
}
```

## Organize Keys

Define keys in one place and register them together with the depot. A small store type keeps the depot and its typed handles together:

```swift
enum WeatherKeys {
    static let units = #key("preferences/units", coder: .json(UnitPreferences.self))
    static let forecasts = #pattern("forecasts/*", coder: .json(Forecast.self))
}

final class WeatherStore: Sendable {
    let depot: Depot
    let units: TypedDistinctKey<UnitPreferences>
    let forecasts: TypedKey<Forecast>

    init() throws {
        depot = try Depot(name: "Weather")
        units = depot.register(WeatherKeys.units)
        forecasts = depot.register(WeatherKeys.forecasts)
    }

    func forecast(for city: String) async throws -> Forecast? {
        try await depot.get(valueFor: Key.from("forecasts" / city, as: Forecast.self))
    }
}
```

Registration replaces any earlier registration of the same path. Registering the same definition again is therefore harmless — the SwiftUI `definition:` initializers rely on this — but registering a path with a *different* coder or type changes how existing values are read. Keep one definition per path.

For the complete key model — distinct and pattern keys, typed and untyped — see <doc:KeysAndCoders>.

## Configure Storage

Pick the directory by the kind of data. Re-downloadable data belongs in `Library/Caches`, which the system may purge:

```swift
let radarCache = try Depot(directory: .caches, name: "RadarTiles", memoryCache: .large)
```

For full control, pass a ``DepotConfiguration``:

```swift
let configuration = DepotConfiguration(
    directoryURL: URL.applicationSupportDirectory.appending(path: "Weather", directoryHint: .isDirectory),
    isExcludedFromBackup: true,
    fileProtection: .completeUntilFirstUserAuthentication,
    memoryCache: .medium   // about 16 MB in-memory cache
)
let configured = Depot(configuration: configuration)
```

The memory cache limits how much memory DepotKit uses for cached values; it does not limit disk usage.

## Logging

DepotKit has a pluggable log sink. Assign a sink to ``DepotKitLogging/sink`` to see internal operations:

```swift
// Use the built-in os_log sink
DepotKitLogging.sink = .osLog()

// Or route to your own logger
DepotKitLogging.sink = .callback { level, message, _, _, _ in
    print("[DepotKit] \(level): \(message())")
}
```

## Next Steps

- <doc:KeysAndCoders> — Key types, coder composition, and data migration.
- <doc:Observation> — AsyncSequence, Combine, and SwiftUI observation.
- <doc:Transactions> — Read-modify-write with rollback and the `modify` convenience.
- <doc:EncryptionAndMultiProcess> — Encryption, app groups, and multi-process support.
- <doc:Lifecycle> — Integrity checks, cache management, and disk usage.
