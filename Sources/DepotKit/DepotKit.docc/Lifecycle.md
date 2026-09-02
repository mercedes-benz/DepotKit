# Lifecycle

Manage depot integrity, caching, disk usage, and maintenance.

## Overview

Once a depot is created and populated, DepotKit provides tools for verifying its health, managing the in-memory cache, measuring disk usage, and cleaning up expired data. This guide covers the maintenance operations you'll use in production.

## Integrity Verification

``Depot/verifyIntegrity()`` validates that the depot's internal metadata file can be read and decoded. When encryption is enabled, this also confirms the current key matches. Call it on every app launch **before** reading or writing values:

```swift
let depot = try Depot(name: "SecureDepot", encryption: config)

do {
    try depot.verifyIntegrity()
} catch DepotError.metadataNotFound {
    // First launch or depot was wiped externally
} catch {
    // Encryption key mismatch or corruption — reset
    try depot.reset()
}
```

Both sync and async overloads are available.

## Reset

``Depot/reset()`` deletes **all** files in the depot directory and recreates the internal metadata. The memory cache is cleared and all observers are notified that every key was removed:

```swift
try depot.reset()
```

This is the nuclear option — use it when integrity verification fails or when you need a clean slate (e.g. on user logout).

> Note: Throws ``DepotError/readOnlyDepot`` when the depot is configured as read-only.

## Memory Cache

DepotKit maintains an optional in-memory LRU cache to avoid redundant disk reads. Configure its capacity at creation time:

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

### Clearing the Cache

Evict all cached entries, forcing the next read to hit the file system:

```swift
depot.clearCache()
// or
await depot.clearCache()
```

This is a no-op when caching is disabled. The cache is also automatically cleared on ``Depot/reset()``.

## Expired Value Cleanup

Values with a TTL are checked lazily on read — an expired value returns `nil`. A background sweep also runs automatically ~8 seconds after depot initialization to remove stale files from disk.

To trigger a manual sweep:

```swift
let removedCount = try depot.removeExpired()
print("Cleaned up \(removedCount) expired entries")
```

The async version:

```swift
let removedCount = try await depot.removeExpired()
```

Observers are notified for each removed key.

## Disk Usage

Measure how much space the depot (or a subset of its keys) occupies:

```swift
let usage = try depot.diskUsage()
print("\(usage.fileCount) files, \(usage.totalBytes) bytes")

// Measure a subset
let cacheUsage = try depot.diskUsage(under: Key.from("cache" / .globstar))
```

``Depot/DiskUsage`` contains:
- `fileCount` — the number of key files on disk
- `totalBytes` — total size in bytes

Returns zero for memory-only depots.

## File Protection (iOS)

Set the iOS file protection level through ``DepotConfiguration/fileProtection``:

```swift
let config = DepotConfiguration(
    directoryURL: url,
    fileProtection: .completeUntilFirstUserAuthentication
)
```

Every file written by the depot will have this protection level applied. On macOS, file protection is silently ignored by the OS.

## Backup Exclusion

Exclude the depot's files from iCloud and iTunes backup:

```swift
let config = DepotConfiguration(
    directoryURL: url,
    isExcludedFromBackup: true
)
```

This sets the `isExcludedFromBackup` resource value on every file the depot writes.

## Concurrency Control

The `maximumConcurrentTasks` parameter (1–8, default 4) controls how many async operations can execute simultaneously. Reads and writes acquire a slot from an internal semaphore:

```swift
// High-throughput depot
let depot = try Depot(name: "HighVolume", maximumConcurrentTasks: 8)

// Serialized access
let depot = try Depot(name: "Sequential", maximumConcurrentTasks: 1)
```

All synchronous methods are protected by an internal reader/writer lock regardless of this setting.
