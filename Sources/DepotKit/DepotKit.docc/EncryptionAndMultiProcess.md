# Encryption and Multi-Process

Encrypt depot values at rest and share depots between your app and its extensions.

## Overview

DepotKit supports two features that often go together: at-rest encryption for sensitive data, and multi-process access via app groups. Both are configured at depot creation time through ``DepotConfiguration`` or the convenience initializers.

## Encryption

### Setup

Encryption uses authenticated encryption (AEAD) with HMAC verification. Configure it with an ``EncryptionConfiguration``:

```swift
let config = try EncryptionConfiguration(
    cipher: .chaChaPoly,
    hashFunction: .sha256,
    key: EncryptionConfiguration.generateKey()
)

let depot = try Depot(name: "SecureDepot", encryption: config)
```

The key must be exactly **512 bits (64 bytes)** of high-entropy data. Use ``EncryptionConfiguration/generateKey()`` to create a suitable random key. **Store the key in the Keychain** — if the key is lost, the depot's data is unrecoverable.

### Ciphers and Hash Functions

| Cipher | Description |
|--------|-------------|
| `.chaChaPoly` | ChaCha20-Poly1305 — fast, constant-time, recommended |
| `.aesGCM` | AES-256-GCM — hardware-accelerated on Apple Silicon |

| Hash Function | Digest Size |
|---------------|-------------|
| `.sha256` | 32 bytes |
| `.sha384` | 48 bytes |
| `.sha512` | 64 bytes |

### Depot-Wide vs. Per-Key Encryption

Passing `encryption` to the depot initializer encrypts **all** values (including internal metadata) with the same key. For selective encryption, leave the depot unencrypted and compose `.encrypted(using:)` into specific coders:

```swift
// Only sensitive keys are encrypted
let tokenKey = depot.register(
    keyPath: "auth" / "token",
    coder: .json(AuthToken.self).encrypted(using: config)
)

// Non-sensitive keys use plain JSON
let themeKey = depot.register(
    keyPath: "preferences" / "theme",
    coder: .json(String.self)
)
```

### Integrity Verification

On every app launch, verify that the depot can be decrypted with the current key. If the key has changed (e.g. after a Keychain reset), call ``Depot/reset()`` to wipe and recreate:

```swift
let depot = try Depot(name: "SecureDepot", encryption: config)

do {
    try depot.verifyIntegrity()
} catch {
    // Key mismatch or corruption — wipe and start fresh
    try depot.reset()
}
```

### Memory-Only Mode and Encryption

Encryption is silently ignored in memory-only mode — values are never written to disk, so there's nothing to encrypt. A notice-level log message is emitted when this happens.

## Multi-Process / App Groups

### Creating a Shared Depot

Use the `appGroup` initializer to place the depot in a shared container. This automatically enables multi-process support:

```swift
let shared = try Depot(
    appGroup: "group.com.example.app",
    name: "SharedDepot"
)
```

This is equivalent to:

```swift
let config = try DepotConfiguration(
    directory: .sharedApplicationSupport(appGroupIdentifier: "group.com.example.app"),
    name: "SharedDepot",
    enableMultiProcessSupport: true
)
let shared = Depot(configuration: config)
```

### Detecting External Changes

When another process (e.g. a widget extension) writes to the shared depot, the host app needs to detect those changes. DepotKit uses `NSFilePresenter` for this.

**Recommended: automatic lifecycle management.** Call ``Depot/automaticallyCheckForExternalChanges(debounceInterval:)`` once after creating the depot. On iOS, it registers and unregisters the file presenter around app foreground/background transitions automatically:

```swift
let shared = try Depot(appGroup: "group.com.example.app", name: "SharedDepot")
try shared.automaticallyCheckForExternalChanges()
```

**Manual management.** For more control, add and remove the file presenter yourself:

```swift
// In the host app (not extensions), on foreground:
try shared.addFilePresenter()

// When the app backgrounds:
try shared.removeFilePresenter()

// After returning to foreground, check what changed:
try shared.checkForExternalChanges()
```

> Important: `addFilePresenter()` and `removeFilePresenter()` throw ``DepotError/functionNotAvailable`` on watchOS and when called from an app extension. Extensions should only read and write — the host app is responsible for file presenter management.

### Shared Directories

The `DepotConfiguration.Directory` type provides three shared variants:

| Directory | Location |
|-----------|----------|
| `.sharedDocuments(appGroupIdentifier:)` | App group Documents |
| `.sharedApplicationSupport(appGroupIdentifier:)` | App group Application Support |
| `.sharedCaches(appGroupIdentifier:)` | App group Caches |

### Read-Only Mode

Open a depot in read-only mode to prevent accidental writes from extensions or background processes:

```swift
let config = try DepotConfiguration(
    directory: .sharedApplicationSupport(appGroupIdentifier: "group.com.example.app"),
    name: "SharedDepot",
    enableMultiProcessSupport: true,
    readOnly: true
)
let readOnly = Depot(configuration: config)
// Writes throw DepotError.readOnlyDepot
```

## Combining Encryption and App Groups

Both features compose naturally:

```swift
let shared = try Depot(
    appGroup: "group.com.example.app",
    name: "SecureShared",
    encryption: config
)
try shared.automaticallyCheckForExternalChanges()

// Both the host app and extension must use the same encryption key
```
