# Transactions

Group multiple reads and writes into an atomic unit with automatic rollback.

## Overview

A **transaction** buffers all mutations in memory and applies them to storage only after the closure returns successfully. If the closure throws, every mutation is discarded and the depot remains unchanged. Observers receive a single coalesced notification after commit — not one per write.

## Basic Usage

```swift
try depot.transaction { tx in
    var locations = try tx.get(valueFor: locationsKey) ?? []
    locations.append(SavedLocation(name: "Berlin", lat: 52.52, lon: 13.40))
    try tx.set(value: locations, for: locationsKey)
    try tx.set(value: Date.now, for: lastModifiedKey)
}
// Observers are notified once, after both writes are committed.
```

Transactions return whatever the closure returns:

```swift
let newBalance = try depot.transaction { tx in
    let current = try tx.get(valueFor: balanceKey) ?? 0
    let updated = current + 100
    try tx.set(value: updated, for: balanceKey)
    return updated
}
// newBalance == 100 (or whatever it was incremented to)
```

## Rollback Semantics

If the closure throws, **no mutations reach storage**:

```swift
do {
    try depot.transaction { tx in
        try tx.set(value: "partial", for: nameKey)
        try tx.set(value: invalidData, for: dataKey)  // throws
    }
} catch {
    // nameKey is unchanged — the "partial" write was discarded
}
```

## Transaction API

``DepotTransaction`` provides the same read/write methods as ``Depot``:

| Operation | Method |
|-----------|--------|
| Read single | `tx.get(valueFor:)` |
| Read multiple | `tx.get(valuesFor:)` |
| Read with errors | `tx.get(availableValuesFor:)` |
| Read with default | `tx.get(valueFor:default:)` |
| Write / remove | `tx.set(value:for:)` — pass `nil` to remove |
| Check existence | `tx.has(valueFor:)` / `tx.has(valuesFor:)` |
| Count | `tx.count(for:)` |
| Remove by pattern | `tx.remove(valuesFor:)` |
| Remove single | `tx.remove(valueFor:)` |
| Remove all | `tx.removeAll()` |

Reads inside a transaction see the buffered state (overlay semantics): if you write a value and then read it back within the same transaction, you get the written value — not what's on disk.

## Async Transactions

The async overload acquires a concurrency slot before executing. The closure itself must **not** suspend (`await`):

```swift
let newBalance = try await depot.transaction { tx in
    let current = try tx.get(valueFor: balanceKey) ?? 0
    let updated = current + 100
    try tx.set(value: updated, for: balanceKey)
    return updated
}
```

## The Modify Convenience

For simple read-modify-write on a single key, ``Depot/modify(valueFor:action:)-4cfb6`` wraps a transaction for you:

```swift
try depot.modify(valueFor: badgeCountKey) { current in
    .update((current ?? 0) + 1)
}
```

The closure receives the current value (or `nil` if absent) and returns a ``ModifyAction``:

| Action | Effect |
|--------|--------|
| `.keep` | Leave the value unchanged |
| `.update(newValue)` | Write `newValue` |
| `.remove` | Delete the value |

`modify` returns the resulting value (the new value on `.update`, `nil` on `.remove`, or the current value on `.keep`):

```swift
let newCount = try depot.modify(valueFor: badgeCountKey) { current in
    guard let count = current, count < 99 else {
        return .keep
    }
    return .update(count + 1)
}
```

The async version works identically:

```swift
let newCount = try await depot.modify(valueFor: badgeCountKey) { current in
    .update((current ?? 0) + 1)
}
```

## Commit Failure

If the flush to disk fails (e.g. disk full), individual file writes that already succeeded are **not** rolled back — each file is still written atomically, so no single value can be corrupted. The partially applied subset is tracked and observers are notified about exactly what reached storage. This matches the exposure of a crash between individual writes outside a transaction.
