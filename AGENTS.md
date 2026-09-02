# AGENTS.md

Guidance for AI coding agents working in this repository.

## Project Overview

DepotKit is a type-safe, composable key-value store for Apple platforms (Swift 6.2, SPM, zero runtime dependencies). Values are persisted as individual files with a CRC32-validated header; keys carry their value type at compile time.

| Target | Path | Purpose |
|--------|------|---------|
| `DepotKit` | `Sources/DepotKit` | Core: `Depot`, keys, coders, transactions, TTL, observation |
| `DepotKitMacros` | `Sources/DepotKitMacros` | `#key` / `#pattern` macros (swift-syntax, compile-time only) |
| `DepotKitCombine` | `Sources/DepotKitCombine` | Combine publishers (`Combine` trait, default on) |
| `DepotKitObservation` | `Sources/DepotKitObservation` | `@DepotValue` / `@DepotValues` SwiftUI wrappers (`Observation` trait, default on) |
| Tests | `Tests/DepotKitTests`, `Tests/DepotKitMacroTests` | Swift Testing based |
| Example | `Examples/DepotKitDemo` | Standalone SPM package; SwiftUI weather demo covering all features (build with `swift build` inside that folder) |

Key source areas inside `Sources/DepotKit`: `Depot/` (storage engine, CRUD, transactions, observation, file I/O), `Key/` (key types, validation, path expressions), `Coders/` (JSON, plist, data, image, compressed, encrypted, versioned).

## Commands

```bash
swift build                            # build
swift test                             # run all tests
swift test --filter DepotCoreTests     # run one suite
scripts/format.sh                      # format (Apple swift-format, config in .swift-format)
scripts/format.sh --check              # lint formatting (CI + pre-commit)
scripts/check-license-headers.sh       # verify SPDX headers
scripts/check-license-headers.sh --fix # add missing headers
scripts/setup.sh                       # install pre-commit hook (one-time)
scripts/build-docs.sh                  # generate DocC
```

## Conventions

- **Every `.swift` file needs an SPDX license header.** Run `scripts/check-license-headers.sh --fix` after creating files.
- Run `scripts/format.sh` before committing; CI enforces `--check`.
- Commit format: `type: summary` where type ∈ `feat|fix|refactor|test|docs|chore`. All commits require DCO sign-off (`git commit -s`).
- Swift 6 strict concurrency is enabled — new code must be `Sendable`-correct.
- Add tests for new functionality; coverage must not decrease.
- Public API requires doc comments (DocC builds with zero warnings).

## Using the Library

### Creating a depot

```swift
import DepotKit

let depot = try Depot(name: "MyStore")                          // Application Support
let shared = try Depot(appGroup: "group.com.example", name: "Shared") // multi-process
let ephemeral = Depot()                                         // memory-only (tests)

// Full control:
let config = try DepotConfiguration(
    directory: .applicationSupport,
    name: "MyStore",
    encryption: nil,
    memoryCache: .default
)
let custom = Depot(configuration: config)
```

### Keys and registration

Keys are typed paths. Declare them with macros, register once at startup:

```swift
enum Keys {
    static let settings = #key("app/settings", coder: .json(Settings.self))
    static let forecast = #pattern("locations/*/forecast", coder: .json(Forecast.self))
}

let settingsKey = depot.register(Keys.settings)
let forecastKey = depot.register(Keys.forecast)

// Or without macros (expiry/TTL is set at registration):
let avatarKey = depot.register(keyPath: "user" / "avatar", coder: .data())
let tokenKey = depot.register(
    keyPath: "auth" / "token", coder: .json(Token.self), expiry: .seconds(3600)
)
```

### Read / write / remove (sync and async variants exist)

```swift
try await depot.set(value: settings, for: settingsKey)
let settings = try await depot.get(valueFor: settingsKey)   // V?
try await depot.remove(valueFor: settingsKey)

// Pattern keys — operate on the whole family:
let all = try await depot.get(valuesFor: forecastKey)       // [Forecast]
let count = try await depot.count(for: forecastKey)
try await depot.remove(valuesFor: forecastKey)

// Distinct key covered by a registered pattern:
let berlin = Key.from("locations" / "berlin" / "forecast", as: Forecast.self)
try await depot.set(value: forecast, for: berlin)
```

### Transactions (atomic, rollback on throw)

```swift
try depot.transaction { tx in
    var list = try tx.get(valueFor: listKey) ?? []
    list.append(item)
    try tx.set(value: list, for: listKey)
    try tx.set(value: Date.now, for: modifiedKey)
}
```

### Observation

```swift
// AsyncStream (core):
for await result in depot.values(for: settingsKey) {
    if case .success(let value) = result { render(value) }
}

// Combine (DepotKitCombine):
depot.published(valueFor: settingsKey)
    .compactMap { try? $0.get() }
    .sink { render($0) }

// SwiftUI (DepotKitObservation):
@DepotValue(definition: Keys.settings, depot: depot) var settings: Settings?
```

### Coder composition

```swift
let coder: AnyCoder<Forecast> = .json()
    .compressed(using: .lz4)
    .versioned(version: 2) { data, oldVersion in /* migrate */ }
```

## Gotchas

- `DepotKitCombine` / `DepotKitObservation` are gated behind SPM traits; tests use `COMBINE_ENABLED` / `OBSERVATION_ENABLED` defines.
- File-backed depots write one file per key with a 28-byte header — never bypass `Depot` to touch files directly.
- Pattern keys (`*`, `**`) must be registered before distinct keys they cover are used.
- Use `Depot()` (memory-only) in tests; `Tests/DepotKitTests/Depot+Temporary.swift` has helpers for file-backed test depots.
