# ``DepotKit``

A type-safe, composable key-value store for Apple platforms.

## Overview

DepotKit provides file-system persistence with the ergonomics of a modern Swift API. Keys carry their value type at compile time, coders compose like middleware, and observation works through Combine, SwiftUI, or plain AsyncSequence.

```swift
import DepotKit

let depot = try Depot(name: "Weather")

let forecast = depot.register(
    #key("locations/current/forecast", coder: .json(Forecast.self))
)
try await depot.set(value: todaysForecast, for: forecast)
```

### Design Principles

- **Type safety** — Keys encode their value type. You cannot read a `String` key as an `Int`.
- **Composability** — Coders stack: `.json().compressed(.lz4).encrypted(using: config)`.
- **Progressive disclosure** — Start with `Depot` + `.json()`. Add encryption, caching, or multi-process support when you need it.
- **Zero external runtime dependencies** — Only swift-syntax at compile time for macro expansion.

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
