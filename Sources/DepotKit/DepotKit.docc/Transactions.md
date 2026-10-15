# Transactions

Group reads and writes into a buffered read-modify-write with rollback on error and a single round of notifications.

## Overview

A **transaction** runs a closure while holding the depot's write lock. Mutations made inside the closure are buffered in memory and are applied to storage only after the closure returns. If the closure throws, the buffer is discarded and nothing is written. After the commit, each affected observer is notified once — not once per write, and a pattern observer not once per matching key.

### What Transactions Guarantee — and What They Don't

Read these boundaries before relying on transactions for data that must stay consistent:

| Aspect | Behavior |
|--------|----------|
| Closure throws | **Rollback.** No file is written, no buffered mutation reaches the memory cache, no observer is notified, and other processes are not signaled. |
| Isolation | Within **one `Depot` instance**: other threads cannot write, and never see the buffered, uncommitted mutations. There is **no** isolation from other `Depot` instances or other processes (see <doc:Transactions#Isolation-Is-Per-Depot-Instance>). |
| Commit | Mutations are applied **one file at a time**. Each file is replaced atomically, but the commit as a whole is **not** atomic. |
| Commit error | If writing a file fails (for example, the disk is full), the commit stops and the error is thrown. Mutations that were already applied **stay applied** — the depot holds part of the transaction. |
| Termination during commit | If the process is terminated (crash, kill, power loss) while a commit is in progress, the depot can be left holding part of the transaction. Nothing is rolled back or completed on the next launch; there is no journal. |
| Notifications | At most one notification per observer, after the commit — or, on a commit error, for exactly the mutations that reached storage. |

If an invariant spans several values (for example, a list and its count, or a balance and its ledger) and must survive crashes and I/O errors, **store the related fields together in a single value**: a single write is all-or-nothing for that value. If you need multi-record crash consistency, queries, or cross-process transactions, use a transactional database such as SQLite (for example through GRDB or SwiftData) instead.

## Basic Usage

```swift
try depot.transaction { tx in
    var locations = try tx.get(valueFor: locationsKey) ?? []
    locations.append(SavedLocation(name: "Berlin", lat: 52.52, lon: 13.40))
    try tx.set(value: locations, for: locationsKey)
    try tx.set(value: Date.now, for: lastModifiedKey)
}
// Each affected observer is notified once, after both writes are committed.
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

Each `set(value:for:)` validates the key's registration and value type and — in file-backed depots — encodes the value immediately. A failing write therefore throws at the call site, inside the closure, and nothing is buffered for it. If you catch such an error inside the closure, the transaction continues and commits the remaining mutations.

Rollback only covers errors thrown by the closure. Errors that occur while the buffer is written to storage are described in <doc:Transactions#Commit-Failure>.

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

Reads inside a transaction see the buffered state (overlay semantics): if you write a value and then read it back within the same transaction, you get the written value — not what's on disk. Values that are not in the buffer are read from storage (or this depot's memory cache) at the time of the read.

Use only the transaction handle inside the closure. Calling methods of the depot itself — including starting another transaction or calling ``Depot/checkForExternalChanges()-6akyi`` — from inside the closure would need the lock the transaction already holds and stops the process with a precondition failure.

## Isolation Is Per Depot Instance

The transaction holds the write lock of the `Depot` instance it runs on. That serializes it with every other write — and with every read that goes to disk — **of the same instance**, which makes read-modify-write cycles such as counters or list appends safe between threads that share one `Depot`.

It does **not** isolate the transaction from:

- **Other `Depot` instances** opened on the same directory, in the same process or another one. Each instance has its own lock and memory cache. Open one instance per directory and share it.
- **Other processes** sharing an app-group depot. With ``DepotConfiguration/enableMultiProcessSupport``, the commit itself runs inside a cross-process critical section, so two commits never interleave file by file. The reads inside the closure, however, are not part of that critical section, and may come from this process's memory cache. If another process writes the same key between your read and your commit, your commit overwrites that write — **the other update is lost**. Readers in other processes are not blocked during a commit and can observe it half applied. See <doc:EncryptionAndMultiProcess#Consistency-Across-Processes>.

## Async Transactions

The async overload waits for a concurrency slot (see ``Depot/init(label:configuration:maximumConcurrentTasks:)``) and then runs the same synchronous transaction — for file-backed depots on DepotKit's I/O threads where available (see <doc:Lifecycle#Concurrency-Control>), so do not rely on the closure running on the caller's actor. The closure itself must **not** suspend (`await`):

```swift
let newBalance = try await depot.transaction { tx in
    let current = try tx.get(valueFor: balanceKey) ?? 0
    let updated = current + 100
    try tx.set(value: updated, for: balanceKey)
    return updated
}
```

Task cancellation is checked before the transaction starts; once the closure runs, the transaction completes (commits or rolls back) regardless of cancellation.

## The Modify Convenience

For simple read-modify-write on a single key, ``Depot/modify(valueFor:action:)-4cfb6`` wraps a transaction for you, with the same isolation boundaries:

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

A file-backed commit applies the buffer one file at a time: a pending `removeAll()` first, then every buffered write and removal, in no particular order. If a file operation fails (for example, the disk is full or the file is not accessible while the device is locked), the commit stops and the error is thrown from `transaction`:

- Mutations applied before the failure are **not** rolled back; the remaining mutations are not applied.
- The memory cache and the observers reflect exactly the mutations that reached storage.
- In multi-process depots, other processes are signaled about the applied part, so their next external-change check picks it up.
- Each applied value was written with an atomic file replacement (`Data.write(to:options:)` with `.atomic`, which writes a temporary file and renames it into place), so a reader sees either a value's previous or its new file, not a mixture of both.

If only recreating the internal metadata after a pending `removeAll()` fails, the commit continues and does not throw. As after ``Depot/reset()-z8t6``, the creation stays pending and is retried by the commit's writes, later writes, and ``Depot/verifyIntegrity()-19f86``.

The same partial state can result if the process is terminated while a commit is in progress. DepotKit does not keep a journal, so nothing repairs or completes the transaction on the next launch. Design multi-value updates so that every intermediate combination is acceptable to your app — or keep values that must change together in a single value.

### Durability

DepotKit does not call `fsync` or `F_FULLFSYNC`. A write that has returned has been handed to the file system, but whether it survives a sudden power loss or kernel panic depends on the file system and the OS. If a value file is damaged anyway, the CRC32 checksum in its header makes the read throw ``DepotError/integrityCheckFailed(reason:)`` instead of returning wrong data. The checksum detects accidental damage only; it is not a protection against deliberate modification (see <doc:EncryptionAndMultiProcess#What-Encryption-Does-Not-Protect>).

### Memory-Only Depots

In a memory-only depot, the commit applies the whole buffer at once under a lock and cannot fail part way. Values are kept as Swift values and coders are never invoked, so a memory-only depot does not exercise serialization, encryption, or any of the file-system failure modes described above. Test those with a file-backed depot.
