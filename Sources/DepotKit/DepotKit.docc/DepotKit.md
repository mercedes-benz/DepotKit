# ``DepotKit``

A type-safe, composable key-value store for Apple platforms.

## Overview

In DepotKit, keys carry their value type at compile time, wildcard patterns address whole families of values, coders compose like middleware, and observation works through AsyncSequence, Combine, or SwiftUI.

```swift
import DepotKit

let depot = try Depot(name: "Weather")

let unitsKey = depot.register(
    #key("preferences/units", coder: .json(UnitPreferences.self))
)
try await depot.set(value: UnitPreferences(temperature: .celsius), for: unitsKey)

for await case .success(let units) in depot.values(for: unitsKey) {
    print(units?.temperature.rawValue ?? "not set")
}
```

Start with <doc:GettingStarted>.

### Design Principles

- **Type safety** — Keys encode their value type. You cannot read a `String` key as an `Int`.
- **Composability** — Coders stack: `.json().compressed(using: .lz4).encrypted(using: config)`.
- **Progressive disclosure** — Start with `Depot` + `.json()`. Add key families, expiry, encryption, or multi-process support when you need them.
- **No runtime dependencies** — swift-syntax is only needed at build time, for the `#key` and `#pattern` macros.

### Guarantees and Limitations

DepotKit stores one file per value. Before relying on it for data you can't recreate, note what it does and doesn't promise:

- **Writes** — Each value is replaced atomically, so readers never see a half-written file, and a CRC32 checksum detects damaged files. Durability on power loss is whatever the file system provides.
- **Transactions** — Buffered read-modify-write with rollback when the closure throws, serialized within one ``Depot`` instance. A commit is not crash-atomic across several values, and there is no isolation between depot instances or processes. See <doc:Transactions>.
- **Observation** — Latest-state delivery in commit order, not a lossless event log. See <doc:Observation>.
- **Expiry** — Expired values read as `nil`; files are removed by sweeps, not at the exact deadline, and there is no disk budget. See <doc:Lifecycle>.
- **App groups and encryption** — Cross-process change detection is eventual, and concurrent read-modify-write from several processes can lose updates. Encryption protects value contents, not file names or headers. See <doc:EncryptionAndMultiProcess>.
- **Memory-only mode** — Same API, but coders are never invoked, so it doesn't test serialization, encryption, or persistence.
- **Data migration** — Changes to value types, coders, and key paths are the app's responsibility. The system's backup and restore and device-to-device migration are supported (an encrypted depot also needs its key after the restore). Moving or copying a store directory yourself to another volume or device is not; export and import the values through the depot API instead. See <doc:KeysAndCoders#Compatibility-and-Migration> and <doc:KeysAndCoders#Backups-and-Moving-Stores>.

### When to Use DepotKit

DepotKit fits structured app state and cached data that you read and write as whole values, especially when values fall into families you observe or invalidate together. For queries, relationships, many small records, or multi-record transactions that must survive a crash, use a database such as SwiftData, Core Data, or SQLite. For a few small preferences, `UserDefaults` is simpler; for secrets, use the Keychain.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:KeysAndCoders>

### Guides

- <doc:Observation>
- <doc:Transactions>
- <doc:EncryptionAndMultiProcess>
- <doc:Lifecycle>

### Depot

- ``Depot``
- ``DepotConfiguration``
- ``DepotError``

### Transaction Types

- ``DepotTransaction``
- ``ModifyAction``

### Keys

- ``Key``
- ``DistinctKey``
- ``TypedKey``
- ``TypedDistinctKey``
- ``KeyComponent``
- ``KeyPathExpression``
- ``PatternKeyPathExpression``
- ``PatternKeyComponent``

### Key Protocols

- ``KeyProtocol``
- ``DistinctKeyProtocol``
- ``TypedKeyProtocol``
- ``TypedDistinctKeyProtocol``

### Key Definitions

- ``KeyDefinition``
- ``PatternKeyDefinition``

### Coders

- ``AnyCoder``
- ``Coder``
- ``CompressionAlgorithm``

### Encryption

- ``EncryptionConfiguration``

### Results & Metadata

- ``AvailableValuesResult``
- ``ValueMetadata``
- ``Depot/DiskUsage``

### Observation (DepotKitObservation)

> See the [Observation guide](<doc:Observation>) for usage with AsyncSequence, Combine, and SwiftUI.

### Combine (DepotKitCombine)

> Combine publishers are provided by the `DepotKitCombine` module. See the [Observation guide](<doc:Observation>) for details.

### Logging

- ``DepotKitLogging``
- ``DepotKitLogSink``
- ``DepotKitLogLevel``
- ``DepotKitOSLogSink``
- ``DepotKitCallbackLogSink``

### Errors

- ``CompressedCoderError``
- ``EncryptedCoderError``
- ``VersionedCoderError``
- ``DataCoderError``
- ``KeyError``

### Macros

- ``key(_:coder:)``
- ``pattern(_:coder:)``
