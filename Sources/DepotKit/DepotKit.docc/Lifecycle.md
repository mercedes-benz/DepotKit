# Lifecycle

Manage depot integrity, caching, expiry, disk usage, and maintenance.

## Overview

Once a depot is created and populated, DepotKit provides tools for verifying its health, managing the in-memory cache, cleaning up expired data, and measuring disk usage. This guide covers the maintenance operations you'll use in production and the limits of each.

## Persistent State vs. Disposable Data

Decide for every depot whether its contents are **persistent state** (settings, drafts, user content — losing it is a bug) or **disposable data** (downloaded caches — it can be fetched again). Keep the two in separate depots: storage location, backup policy, TTLs, and recovery policy all follow from that decision.

```swift
// Persistent state: Application Support, included in backups, no TTL.
let stateDepot = try Depot(name: "State")

// Disposable data: Caches directory, TTL on the keys.
// The system does not back up Caches and may purge it when storage runs low.
let cacheDepot = try Depot(directory: .caches, name: "ForecastCache", memoryCache: .medium)
let forecastKey = cacheDepot.register(
    keyPath: "forecasts" / .wildcard,
    coder: .json(Forecast.self),
    expiry: .seconds(30 * 60)
)
```

If disposable data must survive storage pressure but should not be backed up, keep it in Application Support and exclude it from backup:

```swift
let config = try DepotConfiguration(
    directory: .applicationSupport,
    name: "OfflineMaps",
    isExcludedFromBackup: true
)
let offlineMaps = Depot(configuration: config)
```

Only disposable depots should ever be reset automatically (see <doc:EncryptionAndMultiProcess#Integrity-Verification-and-Recovery>).

## Integrity Verification

``Depot/verifyIntegrity()-19f86`` reads and decodes the depot's internal metadata file. When depot-wide encryption is enabled, this also confirms that the current key can authenticate the metadata. It does **not** read or verify the stored values: a damaged value is reported only when it is read.

```swift
let depot = try Depot(name: "SecureDepot", encryption: config)

do {
    try depot.verifyIntegrity()
} catch {
    // Classify the error before acting on it — a failure can be temporary
    // (for example, the device is locked) and does not prove that values are lost.
}
```

The metadata is created when a writable depot is opened on a directory without values, and again by ``Depot/reset()-z8t6``. If creating it fails — for example while protected data is unavailable — the same depot instance retries on its next write and on every `verifyIntegrity()` call. See <doc:EncryptionAndMultiProcess#Integrity-Verification-and-Recovery> for how to classify verification errors and choose a recovery policy.

Both sync and async overloads are available.

## Reset

``Depot/reset()-z8t6`` deletes **all** values and internal files in the depot directory — except the shared lock file — and recreates the internal metadata. The memory cache is cleared and all observers are notified that every key was removed:

```swift
try depot.reset()
```

Reset is irreversible. Use it for disposable data, or for persistent data only after an explicit decision by your app's recovery policy or by the user (for example, on logout).

> Note: Throws ``DepotError/readOnlyDepot`` when the depot is configured as read-only.

## Memory Cache

File-backed depots maintain an optional in-memory LRU cache of decoded values to avoid redundant disk reads. Configure its capacity at creation time:

| Preset | Capacity |
|--------|----------|
| `.disabled` | No caching |
| `.small` | ~4 MB |
| `.default` | ~8 MB |
| `.medium` | ~16 MB |
| `.large` | ~32 MB |

Or specify an exact byte count:

```swift
let config = DepotConfiguration(
    directoryURL: url,
    memoryCache: DepotConfiguration.MemoryCacheCapacity(byteCount: 2_000_000)
)
```

The capacity limits **only the memory cache**. Each cached value is charged with the size of its file on disk, which approximates — but is not — the memory its decoded value occupies, plus the UTF-8 length of its key and a fixed bookkeeping overhead of about 128 bytes. The cache also remembers keys it found absent and charges them their key and the overhead, so many tiny entries cannot grow it without bound. A value whose charge exceeds the capacity is not cached; it is read from disk every time. The capacity does **not** limit how much the depot stores on disk; DepotKit has no disk budget and never evicts stored values to save space (see <doc:Lifecycle#Disk-Usage>).

Memory-only depots ignore this setting: they keep every value in memory, without a size limit, until it is removed.

### Cached State and Disk Changes

The memory cache answers single-value reads without touching the disk. Once ``Depot/get(valueFor:)-5hm8k`` has read a value — or found it absent — later reads of that key return the cached value or `nil` until the entry is evicted, its expiry deadline passes, or the depot itself changes the key. A file that is changed, added, or deleted by anything other than this depot instance therefore goes unnoticed while the cache is warm. Pattern reads (`get(valuesFor:)`, `get(availableValuesFor:)`) list the matching files on disk every time, but take each listed value from the cache when it is cached, and skip a listed file whose key the cache remembers as absent. `count(for:)`, `metadata(for:)`, and `diskUsage(under:)` always read the disk; `has(valuesFor:)` answers from the cache when it knows the key, or when a cached value matches the pattern.

To pick up such changes, call `clearCache()` so that the next reads go to the disk. Depots with ``DepotConfiguration/enableMultiProcessSupport`` can instead run ``Depot/checkForExternalChanges()-6akyi``, which updates the cache for files that were added, changed, or removed (see <doc:EncryptionAndMultiProcess#Consistency-Across-Processes>); without multi-process support, a depot never looks for changes it did not make. A depot opened with `memoryCache: .disabled` reads every value from disk.

### Clearing the Cache

Evict all cached entries, forcing the next read to hit the file system:

```swift
depot.clearCache()
// or
await depot.clearCache()
```

This is a no-op when caching is disabled. The cache is also automatically cleared on ``Depot/reset()-z8t6``.

## Expiry (TTL)

A key registered with an `expiry` gets a deadline every time a value is written for it: the write time plus the expiry duration. Each write — including a transaction commit — starts a new deadline. The deadline is stored in the value's file header as a wall-clock timestamp, so changing the device clock changes when values expire. The header's checksum covers only the value bytes, not the deadline: a damaged deadline is not detected and can make a value expire early or never (see <doc:EncryptionAndMultiProcess#What-Encryption-Does-Not-Protect>).

### Lazy Expiry

Expiry is evaluated when a value is accessed. After its deadline, a value reads as absent: `get` returns `nil`, and `get(valuesFor:)`, `has`, `count`, and `metadata(for:)` skip it. The memory cache applies the same deadline.

DepotKit runs no timers. When a deadline passes:

- **Observers are not notified at the deadline.** An observer keeps the last value it received until something else notifies it — for example, ``Depot/removeExpired()-1gvix`` deleting the value, a new write, or a removal. When an observer is notified for another reason, it re-reads and then sees the value as absent.
- **The file stays on disk** until it is overwritten, removed, or deleted by an expiry sweep. ``Depot/diskUsage(under:)-4112w`` counts expired files that have not been deleted yet.

If your UI must react exactly at a deadline, schedule your own timer from ``ValueMetadata/expiresAt`` (see ``Depot/metadata(for:)-3rcvg``) and refresh or call `removeExpired()` when it fires.

### Startup Sweep

A writable file-backed depot runs ``Depot/removeExpired()-1gvix`` **once**, about 8 seconds after it is created, in a low-priority background task. The sweep is skipped if the depot is deallocated before then, and errors are ignored. There is no continuously running eviction: values that expire after the sweep stay on disk until the next sweep — usually the next launch — or until you remove them.

Memory-only depots and read-only depots never sweep automatically.

### Removing Expired Values

``Depot/removeExpired()-1gvix`` scans every value file, deletes the expired ones, and notifies the observers of the removed values — each observer once per call, however many of its values expired:

```swift
let removedCount = try depot.removeExpired()
print("Cleaned up \(removedCount) expired entries")
```

The async version:

```swift
let removedCount = try await depot.removeExpired()
```

Call it when:

- a long-running process uses TTLs — for example, when the app returns to the foreground or after a background refresh;
- a **memory-only** depot uses TTLs — this is the only way its expired values are freed and its observers are told about them;
- observers must learn that values expired;
- you are about to measure disk usage.

Each call reads the header of every value file in the depot. With multi-process support, the scan holds the cross-process critical section, during which writes of other processes wait. Avoid calling it at high frequency on large depots.

## Disk Usage

Measure how much space the depot (or a subset of its keys) occupies:

```swift
let usage = try depot.diskUsage()
print("\(usage.fileCount) files, \(usage.totalBytes) bytes")

// Measure a subset: the value at `cache` (if any) and everything below it
let cacheUsage = try depot.diskUsage(under: Key.from("cache"))
```

``Depot/DiskUsage`` contains:
- `fileCount` — the number of key files on disk
- `totalBytes` — total size in bytes

Returns zero for memory-only depots.

The measurement covers every value whose key the prefix matches, together with everything below such a key. A distinct prefix such as `cache` therefore counts the value stored at `cache` itself as well as `cache/...`. A pattern prefix follows the usual matching rules: because a trailing `**` matches one or more components, `diskUsage(under: Key.from("cache" / .globstar))` counts only `cache/...` — the same values that `count(for:)` and `remove(valuesFor:)` address with that pattern.

The result includes expired values that have not been deleted yet. DepotKit does not enforce a disk budget: if a cache can grow without bound, measure it and remove key families yourself, for example with `remove(valuesFor:)`.

## File Protection (iOS)

Set the iOS file protection level through ``DepotConfiguration/fileProtection``:

```swift
let config = DepotConfiguration(
    directoryURL: url,
    fileProtection: .completeUntilFirstUserAuthentication
)
```

Every file written by the depot will have this protection level applied. On macOS, file protection is silently ignored by the OS. While protected data is unavailable, reads and writes fail with file-system errors; treat those as temporary rather than as data loss.

## Backup Exclusion

Exclude the depot's files from iCloud and device backups:

```swift
let config = DepotConfiguration(
    directoryURL: url,
    isExcludedFromBackup: true
)
```

This sets the `isExcludedFromBackup` resource value on every file the depot writes. Files written before you enabled the option keep their previous setting until they are written again. Use it for data that can be recreated; leave persistent state in backups.

## Concurrency Control

The `maximumConcurrentTasks` parameter (1–8, default 4) controls how many async operations can execute simultaneously. Reads and writes acquire a slot from an internal semaphore:

```swift
// High-throughput depot
let depot = try Depot(name: "HighVolume", maximumConcurrentTasks: 8)

// Serialized access
let depot = try Depot(name: "Sequential", maximumConcurrentTasks: 1)
```

All synchronous methods are protected by an internal reader/writer lock regardless of this setting.

On iOS 18, macOS 15, watchOS 11, tvOS 18, visionOS 2, and later, the async methods of file-backed depots run their storage work on DepotKit's own I/O threads while the calling task is suspended. Waiting for the file system, for the depot's lock, or for another process that holds the shared lock file therefore never occupies Swift's shared threads or the main actor. Coders and the closures of async transactions run on these threads, still within the calling task (task-local values, priority, and cancellation checks work as usual). Memory-only depots, and single-value reads that the memory cache answers, don't switch to DepotKit's I/O threads; their work still runs off the caller's actor.

On earlier systems that waiting occupies one of Swift's shared threads, of which there is only one per CPU core. Avoid issuing many concurrent async calls on depots shared with other processes there.

Synchronous methods run on the calling thread. In multi-process depots they can wait as long as another process holds the shared lock file, so prefer the async methods on the main actor and in Swift concurrency tasks.

On iOS, iPadOS, tvOS, visionOS, and watchOS, multi-process depots keep the process from being suspended during their short cross-process operations. When the system is about to suspend the process, new ones throw ``DepotError/suspensionImminent``; finish writes before the app moves to the background. See <doc:EncryptionAndMultiProcess#App-Suspension>.

Observer notifications, including the reads they need, run in a separate task at medium priority, whatever the priority of the code that created the depot or changed the value.
