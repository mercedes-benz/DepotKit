# Encryption and Multi-Process

Encrypt depot values at rest and share depots between your app and its extensions.

## Overview

DepotKit supports two features that often go together: at-rest encryption for sensitive data, and multi-process access via app groups. Both are configured at depot creation time through ``DepotConfiguration`` or the convenience initializers. Both have boundaries that you need to know before relying on them; this guide states them explicitly.

## Encryption

### Setup

Configure encryption with an ``EncryptionConfiguration``:

```swift
let config = try EncryptionConfiguration(
    cipher: .chaChaPoly,
    hashFunction: .sha256,
    key: keyData   // 64 random bytes, see "Managing Keys"
)

let depot = try Depot(name: "SecureDepot", encryption: config)
```

Every encoded value is sealed with an authenticated cipher (AEAD) under a fresh random nonce; an HMAC over the sealed box is prepended as an additional, independent authentication check (encrypt-then-MAC). The 64-byte key is split into a 32-byte cipher key and a 32-byte HMAC key. When a value fails authentication — because it was modified or written with a different key — reading it throws ``EncryptedCoderError/invalidAuthenticationCode``.

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

With per-key encryption the depot's internal metadata is not encrypted, so ``Depot/verifyIntegrity()-19f86`` cannot detect a wrong key for those values (see <doc:EncryptionAndMultiProcess#Integrity-Verification-and-Recovery>).

### Managing Keys

DepotKit uses the key you pass in; storing, protecting, and replacing that key is your app's responsibility.

- **Generate a random key.** ``EncryptionConfiguration/generateKey()`` returns 64 bytes from a cryptographically secure random generator. Generate it once, when the depot is created for the first time.
- **Store it in the Keychain.** Choose an accessibility class that matches when the depot is used: a depot that is read during background work or by an extension needs a key that is available after the first unlock (`kSecAttrAccessibleAfterFirstUnlock` or its `ThisDeviceOnly` variant). Note that a `ThisDeviceOnly` key is not migrated by backups, so a restored backup of the depot files cannot be decrypted on a new device. To share the key with your extensions, store it in a shared Keychain access group.
- **Tell "missing" from "temporarily unavailable".** Only generate a new key when the Keychain reports that no key exists (`errSecItemNotFound`). A Keychain read can fail temporarily — for example with `errSecInteractionNotAllowed` before the first unlock. If you create a new key in that case, all existing values become unreadable.
- **Key loss is data loss.** Without the original key, encrypted values cannot be recovered. DepotKit has no key escrow or recovery mechanism.
- **Key replacement is a migration.** DepotKit has no built-in key rotation. To change the key, open the existing depot with the old key, read the values you want to keep, write them to a new depot (in a different directory) configured with the new key, and then reset the old depot.

#### Password-Derived Keys

Prefer a random key stored in the Keychain. If a key must be derived from a user's password or passphrase, never pass the password itself, and do not use a fast key-derivation function such as HKDF — HKDF is designed for high-entropy input and does nothing to slow down password guessing. Use a deliberately slow password-hashing KDF instead, such as PBKDF2-HMAC-SHA256 (`CCKeyDerivationPBKDF` in CommonCrypto), scrypt, or Argon2id:

- Use a unique, random salt of at least 16 bytes per depot. The salt is not secret; store it next to the depot (for example in `UserDefaults`), because the same salt is needed to derive the same key again.
- Choose the work factor (iteration count, or memory and time cost) as high as your slowest supported device tolerates, and follow current guidance such as the OWASP Password Storage Cheat Sheet.
- Derive exactly 64 bytes of output.
- Changing the password changes the key, which requires the migration described above.

### What Encryption Protects

For someone who can read or modify the depot's files but does not have the key, encryption keeps the **content of each value** confidential and makes modifications of that content detectable: a changed value fails authentication on read.

### What Encryption Does Not Protect

The encryption covers the encoded value bytes. It does **not** cover:

- **File and directory names.** Key paths are *encoded* into file names (Base64url or Base32), not encrypted. Anyone with access to the files can decode them. Do not put secrets or sensitive personal data into key paths.
- **The file header.** Every value file starts with a plaintext header containing its modification date and expiry date. The header is not authenticated: someone with write access can change the expiry date — making a value expire early or never — without the change being detected. The number and sizes of files are visible as well.
- **Key-path identity.** A value's ciphertext is not bound to its key path. A valid encrypted file copied to the file name of another key in the same depot decrypts successfully and is decoded with that key's coder.
- **Rollback and deletion.** An older copy of a file (for example from a backup) can be put back and still decrypts successfully. A deleted file simply reads as absent. DepotKit does not detect substitution, replay, or removal of whole files.
- **Values in memory.** Decrypted values live in your process and in the depot's memory cache.

The CRC32 checksum in every file header detects accidental damage of the stored value bytes. It is **not** cryptographic authentication: anyone can recompute it after modifying a file, and it does not cover the header itself. Damage to the header is detected only in part:

- An empty file, or a file whose magic bytes are damaged but whose header is otherwise recognizable — or whose checksum still matches the value — fails to read with ``DepotError/integrityCheckFailed(reason:)``. `count(for:)` and `has(valuesFor:)` still include such a file, and writing the key again replaces it. Files that DepotKit did not write with a header are read as plain values without a checksum.
- Damage to the dates in a header with intact magic bytes is not detected. A damaged expiry date can make a value expire early or never.

Time-to-live is not a security boundary either: expiry dates are stored in the unauthenticated header and compared with the device's wall clock, which the user can change. Do not use TTL to enforce access windows such as session timeouts. Keep the tokens and secrets you need to enforce such policies in the Keychain.

### Integrity Verification and Recovery

``Depot/verifyIntegrity()-19f86`` reads and decodes the depot's **internal metadata file** — with the depot-wide key if encryption is configured. It confirms that the metadata exists and that the depot-wide key can authenticate it. It does **not** read, scan, or authenticate the stored values, and it cannot detect a wrong key used by per-key `.encrypted(using:)` coders. A damaged or unreadable value is reported only when it is read: `get` throws for that value, and ``Depot/get(availableValuesFor:)-6jq3p`` collects such per-value errors without failing the whole read.

If a writable depot cannot create the metadata of an empty store when it is opened or reset — for example while protected data is unavailable — the same depot instance retries on every write and on every `verifyIntegrity()` until it succeeds. The metadata is never created next to values written by an earlier instance, because it could then confirm a key that does not match those values.

A failing verification does not necessarily mean that the data is lost. Classify the error before deciding what to do:

| Error | Meaning | Data |
|-------|---------|------|
| ``EncryptedCoderError`` | The metadata does not authenticate with the configured key: a different key was loaded, or the metadata file was damaged or replaced. | Unreadable **with this key**. Make sure you loaded the right key before concluding anything. |
| `DecodingError` | The metadata decodes as nothing valid, for example because the depot was created with encryption and opened without it, or the metadata file was damaged. | Values may still be readable. |
| ``DepotError/metadataNotFound`` | The metadata file is missing: a read-only depot was opened before a writer created the store, creating the metadata failed and has not succeeded since, or the file was deleted while values remained. | Values may still be readable. |
| File-system errors (`CocoaError`, `POSIXError`) | The file could not be read right now, for example while protected data is unavailable because the device is locked. | Nothing is known to be wrong. Retry later. |

A destructive ``Depot/reset()-z8t6`` is appropriate only for data your app can recreate, such as downloaded caches:

```swift
enum IntegrityState {
    case verified
    case retryLater(any Error)
    case unreadable(any Error)
}

func integrityState(of depot: Depot) -> IntegrityState {
    do {
        try depot.verifyIntegrity()
        return .verified
    } catch let error as EncryptedCoderError {
        return .unreadable(error)
    } catch let error as DecodingError {
        return .unreadable(error)
    } catch DepotError.metadataNotFound {
        return .unreadable(DepotError.metadataNotFound)
    } catch {
        // For example, protected data is unavailable while the device is locked.
        return .retryLater(error)
    }
}

// A disposable cache: everything in it can be downloaded again.
switch integrityState(of: forecastCache) {
case .verified:
    break
case .retryLater:
    // Keep the files; check again later, for example after
    // UIApplication.protectedDataDidBecomeAvailableNotification.
    break
case .unreadable:
    try forecastCache.reset()
}
```

For durable data — user content, settings, anything that cannot be recreated — do **not** reset automatically. Keep the files, rule out a key-loading problem, report the condition, and make deleting the data an explicit decision of your app's recovery policy or of the user.

### Memory-Only Mode and Encryption

Encryption is ignored in memory-only mode — values are never written to disk and coders are never invoked, so there's nothing to encrypt. A notice-level log message is emitted when an encryption configuration is passed to a memory-only depot. A memory-only depot therefore does not test your encryption setup; use a file-backed depot for that.

## Multi-Process / App Groups

### Creating a Shared Depot

Use the `appGroup` initializer to place the depot in a shared container. This enables multi-process support, but it does **not** by itself detect changes made by other processes. In the host app, also start automatic external-change checks:

```swift
// Host app
let shared = try Depot(
    appGroup: "group.com.example.app",
    name: "SharedDepot"
)
try shared.automaticallyCheckForExternalChanges()
```

```swift
// App extension — file presenters are not available here
let shared = try Depot(
    appGroup: "group.com.example.app",
    name: "SharedDepot",
    memoryCache: .disabled
)
```

Extensions that only read should open the depot read-only instead; see <doc:EncryptionAndMultiProcess#Writing-from-Several-Processes>.

The `appGroup` initializer is equivalent to:

```swift
let config = try DepotConfiguration(
    directory: .sharedApplicationSupport(appGroupIdentifier: "group.com.example.app"),
    name: "SharedDepot",
    enableMultiProcessSupport: true
)
let shared = Depot(configuration: config)
```

Every process that opens the depot must enable multi-process support, use the same encryption configuration, and register the same keys with the same coders.

Creating a shared depot reads the depot directory on the calling thread and can briefly wait for other processes that are inside the critical section described below. With large stores, create it off the main actor.

### How Changes Reach Other Processes

With multi-process support enabled, writes, removals, transaction commits, expiry cleanup, and ``Depot/reset()-z8t6`` run inside a cross-process critical section: exclusive coordinated access (`NSFileCoordinator`) to a lock file in the depot directory. When something reached disk — including the applied part of a transaction whose commit failed — the depot updates the lock file's modification date. File presenters registered by other processes are notified about that change by the OS.

Another process learns about the change only when it runs ``Depot/checkForExternalChanges()-6akyi``. The check compares the modification date of every value file with the last date this depot recorded, invalidates changed entries in its memory cache, and notifies its observers. A value counts as changed when its file's modification date **differs** from the recorded one — earlier dates, for example after a restore, count as well. A writer that replaces content while deliberately preserving the previous modification date is not detected; call `clearCache()` after such out-of-band replacements. The check waits for in-flight reads and writes of the depot, so never call it from inside a transaction closure.

While another process is inside the critical section, writes of this process wait for it. Async methods wait without occupying Swift's shared threads on iOS 18, macOS 15, watchOS 11, tvOS 18, visionOS 2, and later; on earlier systems, keep the number of concurrent async calls on shared depots low. See <doc:Lifecycle#Concurrency-Control>.

### Writing from Several Processes

While the host app's file presenter is registered, each write from another process — for example an extension — waits for the system's file coordination with the app and takes about half a second. The same holds for `checkForExternalChanges()` of a writable depot, which coordinates on the lock file like a write. Writes of the app wait behind them. Reading values never coordinates, and a read-only depot checks for external changes by reading the lock file, which does not wait for the app; neither is slowed down by the presenter.

- **Extensions:** Open the shared depot read-only (see <doc:EncryptionAndMultiProcess#Read-Only-Mode>) and leave writing to the app.
- **If an extension must write,** batch its changes into one ``Depot/transaction(_:)-3sxxl``: the commit waits only once.
- Serializing the writes does not make concurrent read-modify-write safe: updates can still be lost (see <doc:EncryptionAndMultiProcess#Consistency-Across-Processes>).

### App Suspension

On iOS, iPadOS, tvOS, visionOS, and watchOS, a process that is suspended while it is inside the critical section — or waiting for it — blocks the other processes, and the system may terminate it. DepotKit therefore keeps the process from being suspended during each of its short cross-process operations — writes, removals, transaction commits, expiry cleanup, `reset()`, and `checkForExternalChanges()` — and for one second after the last of them, in apps and in app extensions. These operations count as background work: an app that keeps writing after it entered the background runs until its background time ends.

When the system is about to suspend the process, operations that are already running finish, and new ones throw ``DepotError/suspensionImminent`` without changing anything — for ten seconds, or until the app (or the host app of an extension) returns to the foreground — so that the process can be suspended. Finish writes before the app moves to the background, or within background time that you requested, and retry a write that failed with this error later. Reading values is not affected.

### Detecting External Changes

There are three ways to trigger that check.

**Automatic lifecycle management (recommended for host apps).** Call ``Depot/automaticallyCheckForExternalChanges(debounceInterval:)`` once after creating the depot. It registers the file presenter, runs a check after presenter callbacks have been quiet for `debounceInterval` seconds (default 1) — while callbacks keep arriving, at the latest three intervals after the first one — and runs one check right away to pick up changes made since the depot was created. Further calls have no effect. Presenter registration follows the platform's app lifecycle:

| Platform | Behavior of `automaticallyCheckForExternalChanges()` |
|----------|------------------------------------------------------|
| iOS, iPadOS, Mac Catalyst, tvOS, visionOS | Registers the presenter (asynchronously, without blocking the main actor) unless the app is in the background, and runs a check. Removes the presenter on `UIApplication.didEnterBackgroundNotification`; registers it again and runs a check on `UIApplication.willEnterForegroundNotification`. |
| watchOS | The same, following `WKApplication.didEnterBackgroundNotification` and `WKApplication.willEnterForegroundNotification`. |
| macOS | Registers the presenter and runs a check before returning; the presenter stays registered. |
| App extensions (all platforms) | Throws ``DepotError/functionNotAvailable``. |

**Manual presenter management.** ``Depot/addFilePresenter()-302zu`` and ``Depot/removeFilePresenter()-7csu0`` control registration yourself. While the presenter is registered, every callback schedules a debounced check — with the interval passed to `automaticallyCheckForExternalChanges()`, or one second. Registering does not catch up on changes made while no presenter was registered; call `checkForExternalChanges()` after registering if you need them. If you combine both, `automaticallyCheckForExternalChanges()` still takes over the lifecycle management, and its background notification removes a presenter that you registered.

**Explicit checks.** ``Depot/checkForExternalChanges()-6akyi`` works on every platform and in extensions. Call it wherever you need to catch up with other processes: when an extension starts handling a request, before a widget builds its timeline, after background work, or when returning to the foreground if you manage the presenter yourself.

```swift
// For example in a widget's timeline provider:
try shared.checkForExternalChanges()
let entries = try shared.get(valuesFor: forecastKey)
```

> Important: File presenters are restricted. `addFilePresenter()`, `removeFilePresenter()`, and `automaticallyCheckForExternalChanges()` throw ``DepotError/functionNotAvailable`` when called from an app extension. Extensions can only read, write, and check explicitly. On every platform except macOS, a file presenter must not stay registered while the app is suspended — Apple advises removing presenters before suspension, because a suspended presenter can stall coordinated file access of other processes. The automatic lifecycle management does this for you; if you manage presenters yourself, remove them when the app enters the background.

### Consistency Across Processes

Multi-process support keeps the files consistent and lets processes discover each other's changes. It does **not** turn concurrent writers into serializable transactions:

- **Each file is replaced atomically.** A reader in another process sees either the previous or the new version of a value. Readers are not blocked by the critical section, so they can see a multi-value commit half applied.
- **Writers do not interleave.** Commits, removals, and expiry cleanup of different processes run one after another. Expiry cleanup never deletes a value that another process has just written.
- **Change propagation is eventual.** Until a process runs `checkForExternalChanges()`, its memory cache may return the previous value (or remember a value as absent), and its observers have not been notified. With automatic checks the delay is the OS's callback delivery plus the debounce interval; on iOS, changes made while the app is in the background are picked up when it returns to the foreground.
- **Concurrent read-modify-write loses updates.** A ``Depot/transaction(_:)-3sxxl`` or `modify` reads without holding the cross-process critical section — possibly from the process's memory cache. If two processes update the same value concurrently, the last commit wins and the other update is lost. Invariants that span several values can break the same way.

Choose an arrangement that avoids concurrent writers for the same data:

- **Single writer.** Let one process — usually the host app — write a value or key family. Other processes open the depot read-only (see below) and ask the writer to make changes, for example through your app's own messaging.
- **Disjoint keys.** If several processes must write, give each its own key family (for example `widget/**` and `app/**`), so no value has more than one writer.
- **Fresh reads in short-lived processes.** Extensions cannot register a file presenter. Open the depot with `memoryCache: .disabled` so that every read sees the latest file, or call `checkForExternalChanges()` before reading.
- **One instance per process.** Open a single `Depot` for each directory in each process and share it. Separate instances in one process each have their own cache and lock, and behave like separate processes.

If you need serializable updates across processes, use a store that provides them, such as a database with cross-process locking.

### Shared Directories

The `DepotConfiguration.Directory` type provides three shared variants:

| Directory | Location |
|-----------|----------|
| `.sharedDocuments(appGroupIdentifier:)` | `<group container>/Documents/<name>` |
| `.sharedApplicationSupport(appGroupIdentifier:)` | `<group container>/Library/Application Support/<name>` |
| `.sharedCaches(appGroupIdentifier:)` | `<group container>/Library/Caches/<name>` |

Depots with the same name in different shared directories are independent: resetting a shared cache depot never touches the shared application-support depot.

### Read-Only Mode

Open a depot in read-only mode to prevent writes from extensions or background processes:

```swift
let config = try DepotConfiguration(
    directory: .sharedApplicationSupport(appGroupIdentifier: "group.com.example.app"),
    name: "SharedDepot",
    enableMultiProcessSupport: true,
    readOnly: true,
    memoryCache: .disabled
)
let readOnly = Depot(configuration: config)
// Writes, removals, reset() and removeExpired() throw DepotError.readOnlyDepot
```

A read-only depot never writes to its directory: it does not create the directory, the store's metadata, or the lock file, and it does not run the startup expiry sweep; expired values still read as absent. Its external-change checks coordinate with writers by reading the lock file.

Because it must not create the lock file, the file presenter of a read-only depot presents the depot **directory** and is notified about changes of the items in it — including the lock file that a writer creates or updates. A presenter is only notified about items that existed when it was registered: if the depot directory does not exist yet, the presenter learns nothing until it is registered again (automatic management does that whenever the app returns to the foreground). Explicit `checkForExternalChanges()` calls always work.

## Combining Encryption and App Groups

Both features compose:

```swift
let shared = try Depot(
    appGroup: "group.com.example.app",
    name: "SecureShared",
    encryption: config
)
try shared.automaticallyCheckForExternalChanges()

// The host app and its extensions must use the same encryption key —
// share it through a Keychain access group.
```
