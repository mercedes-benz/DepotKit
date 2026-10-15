// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import os

/// A file-system-backed key/value store.
///
/// `Depot` persists every value as a separate file inside a directory you
/// choose via ``DepotConfiguration``. Key identifiers are normalized to NFC
/// and encoded into file names (Base64url on case-sensitive volumes, Base32 on
/// case-insensitive volumes), so they are safe on all Apple file systems and
/// can never address files outside the depot directory. See
/// <doc:KeysAndCoders#Key-Identifiers-on-Disk> for details.
///
/// ## Thread Safety
///
/// All reads and writes are protected by an internal reader/writer lock, so
/// `Depot` is safe to use from any thread or Swift concurrency context.
///
/// ## Guarantees and Limitations
///
/// - **Single values:** Every value file is replaced atomically
///   (`Data.write(to:options:)` with `.atomic`), so a reader sees either the
///   previous or the new file. A CRC32 checksum detects accidental damage of
///   the stored bytes. DepotKit does not `fsync`; whether the latest write
///   survives a sudden power loss depends on the file system.
/// - **Several values:** There is no crash atomicity across files. A
///   transaction commit that fails, or a process that is terminated during a
///   commit, can leave part of a transaction applied. See <doc:Transactions>.
/// - **Isolation:** Transactions and ``modify(valueFor:action:)-4cfb6`` are
///   isolated from other threads using the **same** `Depot` instance only —
///   not from other instances or processes.
/// - **Observation:** Observers receive the latest state, not every
///   intermediate change. See <doc:Observation>.
/// - **Expiry:** Expired values read as absent; they are deleted only by
///   ``removeExpired()-1gvix`` or the one-time startup sweep, and observers
///   are not notified at the deadline. See <doc:Lifecycle>.
/// - **Multi-process:** Cache invalidation and notifications across
///   processes are eventual, and concurrent read-modify-write cycles in
///   different processes can lose updates. See <doc:EncryptionAndMultiProcess>.
/// - **Memory-only mode:** Values are kept as Swift values; coders,
///   encryption, file names, and persistence are not exercised.
///
/// ## Encryption
///
/// When you pass an ``EncryptionConfiguration`` to the initializer, every
/// value is encrypted and authenticated before it hits disk; reading a value
/// that fails authentication throws. File names, file headers (including
/// expiry dates), and the assignment of files to keys are not protected — see
/// <doc:EncryptionAndMultiProcess> for the threat model. Store the encryption
/// key in the Keychain so it survives app launches.
///
/// ## Typical Usage
///
/// ```swift
/// let depot = try Depot(name: "MyAppDepot")
/// ```
///
/// ### Setup with Encryption
///
/// ```swift
/// // Generate the key once, store it in the Keychain, and load it on later launches.
/// let encryption = try EncryptionConfiguration(
///     cipher: .chaChaPoly,
///     hashFunction: .sha256,
///     key: keyFromKeychain
/// )
///
/// let depot = try Depot(name: "SecureDepot", encryption: encryption)
///
/// // Checks the internal metadata (not the stored values) against the key.
/// // Classify a failure before acting on it (see the Encryption and
/// // Multi-Process guide); never reset durable data automatically.
/// try depot.verifyIntegrity()
/// ```
///
/// ### App-Group Shared Depot (Multi-Process)
///
/// ```swift
/// let shared = try Depot(appGroup: "group.com.example.app", name: "SharedDepot")
///
/// // In the host app, check for changes made by extensions:
/// try shared.automaticallyCheckForExternalChanges()
/// ```
///
/// ### Memory Cache Configuration
///
/// ```swift
/// let config = DepotConfiguration(
///     directoryURL: url,
///     memoryCache: .default          // ~8 MB
/// )
///
/// // Or choose a preset / custom size:
/// //   .small   (~4 MB)
/// //   .medium  (~16 MB)
/// //   .large   (~32 MB)
/// //   MemoryCacheCapacity(byteCount: 2_000_000)  // 2 MB
/// ```
///
/// The memory-cache capacity limits memory only; it does not limit disk usage.
///
/// ### File Protection Levels (iOS)
///
/// ```swift
/// let config = DepotConfiguration(
///     directoryURL: url,
///     fileProtection: .completeUntilFirstUserAuthentication
/// )
/// // On macOS, file protection is silently ignored by the OS.
/// ```
public final class Depot: @unchecked Sendable {
    static let PathExtension = "bin"
    static let HiddenKeyPrefix = ".FS_"

    // MARK: Properties

    /// A human-readable label used to identify this depot in log output.
    public let label: String

    /// The configuration that was used to create this depot.
    public let configuration: DepotConfiguration

    /// A signal that fires when another process modifies files in this depot's directory.
    let externalChangesDetected: DepotSignal<Void>?

    let core: DepotCore
    let lock: ReadWriteLock
    let memoryCache: DepotMemoryCache?
    let changeTracker: DepotChangeTracker?
    let fileManager: DepotFileManager?
    let semaphore: AsyncSemaphore
    let clock: any DepotClock
    private let initSweepDelay: Duration
    private let sweepTask: OSAllocatedUnfairLock<Task<Void, Never>?>

    struct Overrides: Sendable {
        var clock: any DepotClock = SystemClock()
        var initSweepDelay: Duration = .seconds(8)
        /// Replaces the storage volume's case-sensitivity query; `nil` uses the real volume.
        var volumeSupportsCaseSensitiveNames: (@Sendable (URL) -> Bool?)?
        /// Keeps the process from being suspended during cross-process file access.
        var suspensionGuard: SuspensionGuard? = SuspensionGuard.platform
        var testHooks = TestHooks()
    }

    /// Internal instrumentation points that let tests force deterministic interleavings.
    struct TestHooks: Sendable {
        /// Called by ``removeExpired()`` after a file's header was found expired and before the file is deleted.
        var willRemoveExpiredFile: (@Sendable (URL) -> Void)?

        /// Waits for the debounce interval of automatic external-change checks.
        var debounceSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

        /// The current time for the maximum delay of automatic external-change checks.
        var debounceNow: @Sendable () -> ContinuousClock.Instant = { .now }

        /// Called with every debounce task scheduled by automatic external-change checks.
        var didScheduleDebounceTask: (@Sendable (Task<Void, Never>) -> Void)?

        /// Replaces the check run by automatic external-change checks (defaults to ``checkForExternalChanges()``).
        var externalChangesCheck: (@Sendable (Depot) async throws -> Void)?

        /// Called by ``checkForExternalChanges()`` right before it waits for the depot's write lock.
        var willAcquireLockForExternalChangesCheck: (@Sendable () -> Void)?

        /// Called before ``reset()``, pattern removals, and transaction commits delete a file-system item.
        /// Throwing simulates a deletion failure for that item.
        var willRemoveItem: (@Sendable (URL) throws -> Void)?

        /// Called before ``reset()`` and transactional `removeAll()` recreate the metadata file.
        /// Throwing simulates a metadata-recreation failure.
        var willRecreateMetadata: (@Sendable () throws -> Void)?

        /// Replaces the platform's application lifecycle followed by automatic external-change checks.
        var applicationLifecycle: ApplicationLifecycle?

        /// Called with every task that registers the presenter and catches up on changes when the
        /// app enters the foreground while automatic checks follow the app lifecycle.
        var didStartForegroundRegistration: (@Sendable (Task<Void, Never>) -> Void)?
    }

    let testHooks: TestHooks

    /// In-memory storage for memory-only mode (`directoryURL == nil`).
    struct MemoryEntry: Sendable {
        let value: any Sendable
        let modifiedAt: Date
        let expiresAt: Date?
    }

    let memoryEntries: OSAllocatedUnfairLock<[DistinctKey: MemoryEntry]>?

    final class FilePresenterState: @unchecked Sendable {
        /// Runs a debounced external-change check for every file-presenter callback.
        var externalChangesCancellable: (any DepotCancellable)?
        var externalChangesDebounceInterval: TimeInterval = 1.0
        var externalChangesDebounceTask: Task<Void, Never>?
        /// When the pending check runs at the latest, however many signals keep arriving.
        /// Set by the first signal of a burst, cleared when the check starts or is cancelled.
        var externalChangesCheckDeadline: ContinuousClock.Instant?
        /// Identifies the most recently scheduled debounce task.
        var externalChangesDebounceGeneration = 0
        var isCheckingAutomatically = false
        /// Whether the app is in the foreground while automatic checks follow the app lifecycle.
        var isInForeground = false
        var lifecycleObservers: [any NSObjectProtocol] = []
    }

    let filePresenterState = OSAllocatedUnfairLock(uncheckedState: FilePresenterState())

    /// Set while the metadata of a store that was empty could not be created (for example while
    /// protected data was unavailable). Writes and ``verifyIntegrity()`` retry the creation.
    let metadataCreationPending = OSAllocatedUnfairLock(initialState: false)

    /// The single-component key that spells the metadata file's name.
    ///
    /// Public APIs keep rejecting it with ``DepotError/reservedKey(keyPath:)``.
    /// It no longer addresses the metadata: user keys are always encoded and
    /// the metadata lives at the fixed internal location ``metadataFileURL``.
    static let metadataKey = Key.from("\(Depot.HiddenKeyPrefix)META", as: DepotMetadata.self)

    /// The same key as the static `metadataKey`.
    let metadataKey = Depot.metadataKey

    /// The location of the depot's internal metadata file (`.FS_META.bin`).
    var metadataFileURL: URL? {
        configuration.directoryURL.map {
            Depot.internalFileURL(named: "META", in: $0).appendingPathExtension(Depot.PathExtension)
        }
    }

    var metadataCoder: AnyCoder<DepotMetadata> {
        let baseCoder: AnyCoder<DepotMetadata> = .plist()
        if let encryption = configuration.encryption {
            return baseCoder.encrypted(using: encryption)
        } else {
            return baseCoder
        }
    }

    // MARK: - Init

    /// Creates a new file-backed depot.
    ///
    /// - Parameters:
    ///   - label: A human-readable label for log output.
    ///   - configuration: Storage location, caching, encryption, and multi-process settings.
    ///   - maximumConcurrentTasks: The maximum number of concurrent async
    ///     operations allowed (1–8, default 4).
    public convenience init(
        label: String? = nil,
        configuration: DepotConfiguration,
        maximumConcurrentTasks: Int = 4,
    ) {
        self.init(
            label: label,
            configuration: configuration,
            maximumConcurrentTasks: maximumConcurrentTasks,
            overrides: Overrides()
        )
    }

    init(
        label: String? = nil,
        configuration: DepotConfiguration,
        maximumConcurrentTasks: Int = 4,
        overrides: Overrides,
    ) {
        precondition(
            maximumConcurrentTasks >= 1 && maximumConcurrentTasks <= 8,
            "maximumConcurrentTasks must be between 1 and 8 inclusive",
        )
        self.semaphore = AsyncSemaphore(value: maximumConcurrentTasks)
        self.label = label ?? configuration.directoryURL?.lastPathComponent ?? "InMemory"
        self.configuration = configuration
        self.clock = overrides.clock
        self.initSweepDelay = overrides.initSweepDelay
        self.testHooks = overrides.testHooks
        self.sweepTask = OSAllocatedUnfairLock(uncheckedState: nil)
        lock = ReadWriteLock()

        if configuration.isFileBacked {
            core = DepotCore(encryptionConfiguration: configuration.encryption, runsObserversOnIOExecutor: true)
            memoryEntries = nil

            if configuration.cacheInMemory {
                memoryCache = DepotMemoryCache(totalCostLimit: configuration.memoryCache.byteCount)
            } else {
                memoryCache = nil
            }

            if configuration.enableMultiProcessSupport {
                // The metadata file is not part of modification-date snapshots.
                changeTracker = DepotChangeTracker(ignoredKeys: [DistinctKey(Depot.metadataKey)])
                externalChangesDetected = DepotSignal()
            } else {
                changeTracker = nil
                externalChangesDetected = nil
            }

            fileManager = DepotFileManager(
                depotURL: configuration.directoryURL!,
                enableMultiProcessSupport: configuration.enableMultiProcessSupport,
                readOnly: configuration.readOnly,
                fileProtection: configuration.fileProtection,
                volumeSupportsCaseSensitiveNames: overrides.volumeSupportsCaseSensitiveNames,
                suspensionGuard: overrides.suspensionGuard,
            )

            LOG(
                level: .info,
                message:
                    """
                    Depot[\(self.label)] initialized at \(configuration.directoryURL!.lastPathComponent) \
                    (encrypted: \(configuration.encryption != nil), \
                    multiProcess: \(configuration.enableMultiProcessSupport), \
                    cache: \(configuration.cacheInMemory), \
                    fileNames: \(fileManager!.fileNameCodec.rawValue))
                    """,
            )

            postInit()
            sweepExpiredAfterInit()
        } else {
            if configuration.encryption != nil {
                LOG(
                    level: .notice,
                    message: "Depot[\(self.label)] encryption configuration is ignored in memory-only mode",
                )
            }
            core = DepotCore(encryptionConfiguration: nil)
            memoryEntries = OSAllocatedUnfairLock(uncheckedState: [:])
            memoryCache = nil
            changeTracker = nil
            externalChangesDetected = nil
            fileManager = nil

            LOG(level: .info, message: "Depot[\(self.label)] initialized in memory-only mode")
        }
    }

    private func postInit() {
        guard let fileManager else {
            return
        }

        if !configuration.readOnly, let metadataURL = metadataFileURL {
            if !fileManager.hasFile(at: metadataURL, skipHiddenFiles: false) {
                do {
                    if try !fileManager.hasFiles(for: Key.all) {
                        do {
                            try createMetadata()
                        } catch {
                            // The store is empty, so creating the metadata later is safe.
                            metadataCreationPending.withLock { $0 = true }
                            throw error
                        }
                    }
                } catch {
                    LOG(level: .error, message: "Depot[\(label)] failed to create metadata: \(error)")
                }
            }
        }

        if let changeTracker {
            do {
                let modificationDates = try fileManager.takeSnapshotOfModificationDates()
                changeTracker.setModificationDates(modificationDates)
            } catch {
                LOG(
                    level: .error,
                    message:
                        "Depot[\(label)] failed to take snapshot of modification dates lock for multi process support due to error \(error)",
                )
            }
        }

        fileManager.onExternalChangesDetected = { @Sendable [weak externalChangesDetected] in
            externalChangesDetected?.emit()
        }
    }

    deinit {
        sweepTask.withLock { $0?.cancel() }

        // `NSFileCoordinator` retains registered presenters, so the presenter's own deinit cannot unregister it.
        fileManager?.removeFilePresenter()

        let lifecycleObservers = filePresenterState.withLockUnchecked { state in
            state.externalChangesCancellable?.cancel()
            state.externalChangesCancellable = nil

            state.externalChangesDebounceTask?.cancel()
            state.externalChangesDebounceTask = nil

            defer { state.lifecycleObservers.removeAll() }
            return state.lifecycleObservers
        }

        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func sweepExpiredAfterInit() {
        guard !configuration.readOnly else {
            return
        }
        let delay = initSweepDelay
        let task = startDetachedIOTask(priority: .utility) { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else {
                return
            }
            let count = try? await self.removeExpired()
            if let count, count > 0 {
                LOG(level: .info, message: "Depot[\(self.label)] init sweep removed \(count) expired entries")
            }
        }
        sweepTask.withLock { $0 = task }
    }

    func waitForInitSweep() async {
        let task = sweepTask.withLock { $0 }
        await task?.value
    }

    // MARK: - Concurrency

    // The async helpers below are `@concurrent`: they must never run on the caller's actor, because
    // they wait for the semaphore and run blocking storage work (also under
    // `NonisolatedNonsendingByDefault`, where nonisolated async functions would otherwise inherit it).

    /// Runs `work` for an async API: waits for a slot of `maximumConcurrentTasks`, checks for
    /// cancellation, and runs the work via ``performBlocking(_:)``.
    @concurrent
    func withSemaphore<T: Sendable>(_ work: @Sendable () throws -> T) async throws -> T {
        try await withSemaphore(inlineResult: { nil }, work)
    }

    /// Like `withSemaphore(_:)`, but returns the result of `inlineResult` without switching to
    /// ``DepotIOExecutor`` when it is not `nil`. Use it for answers that never block, such as
    /// memory-cache hits.
    @concurrent
    func withSemaphore<T: Sendable>(
        inlineResult: () -> T?,
        _ work: @Sendable () throws -> T,
    ) async throws -> T {
        try await semaphore.wait()
        defer { semaphore.signal() }
        try Task.checkCancellation()
        if let result = inlineResult() {
            return result
        }
        return try await performBlocking(work)
    }

    /// Runs synchronous storage work for an async caller without blocking Swift concurrency's
    /// cooperative pool where the system allows it.
    ///
    /// File-backed depots run `work` on ``DepotIOExecutor`` (macOS 15, iOS 18, tvOS 18, watchOS 11,
    /// visionOS 2, and later) while the calling task is suspended; the work stays in the calling task.
    /// Memory-only depots, whose work never waits for the file system, and earlier systems run it
    /// directly in this function, off the caller's actor.
    @concurrent
    func performBlocking<T: Sendable, Failure: Error>(
        _ work: @Sendable () throws(Failure) -> T,
    ) async throws(Failure) -> T {
        if fileManager != nil, #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
            return try await withTaskExecutorPreference(DepotIOExecutor.shared) { () throws(Failure) -> T in
                try work()
            }
        }
        return try work()
    }

    // MARK: - Keys

    /// The set of registered keys.
    ///
    /// A key appears in this set after you call ``register(key:coder:expiry:)-(KeyProtocol,AnyCoder<V>,_)``.
    public var keys: Set<Key> {
        core.keys
    }

    // MARK: - Private

    func checkMetadata(createIfNeeded: Bool = false) throws {
        guard let fileManager, let fileURL = metadataFileURL else {
            return
        }

        guard fileManager.hasFile(at: fileURL, skipHiddenFiles: false) else {
            if createIfNeeded {
                try createMetadata()
                return
            }

            throw DepotError.metadataNotFound
        }

        let data = try fileManager.coordinate(readingItemAt: fileURL, options: .withoutChanges) { fileURL in
            try Data(contentsOf: fileURL, options: .uncached)
        }

        _ = try metadataCoder.decode(data)
    }

    private func createMetadata() throws {
        guard !configuration.readOnly else {
            throw DepotError.readOnlyDepot
        }
        guard let fileManager, let fileURL = metadataFileURL else {
            return
        }

        let metadata = DepotMetadata()
        let data = try metadataCoder.encode(metadata)

        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        try fileManager.coordinate(writingItemAt: fileURL, options: .forReplacing) { fileURL in
            try data.write(to: fileURL, options: .atomic)

            let modificationDate = updateResourceValues(at: fileURL)
            changeTracker?.modified(key: metadataKey, at: modificationDate)
        }

        metadataCreationPending.withLock { $0 = false }
    }

    /// Creates the metadata if creating it failed earlier while the store was empty.
    ///
    /// Call with the write lock held. A failure is logged and leaves the creation pending.
    func createPendingMetadataIfNeeded() {
        guard metadataCreationPending.withLock({ $0 }), let fileManager, let fileURL = metadataFileURL else {
            return
        }

        do {
            if fileManager.hasFile(at: fileURL, skipHiddenFiles: false) {
                // Created in the meantime, for example by another process.
                metadataCreationPending.withLock { $0 = false }
            } else {
                try createMetadata()
                LOG(level: .info, message: "Depot[\(label)] created the pending metadata")
            }
        } catch {
            LOG(level: .error, message: "Depot[\(label)] failed to create pending metadata: \(error)")
        }
    }

    /// The file URL that stores the value of `key` in this file-backed depot.
    ///
    /// - Throws: ``DepotError/keyComponentTooLong(keyPath:byteCount:maximumByteCount:)``
    ///   if a component does not fit into a file name.
    func fileURL(for key: some DistinctKeyProtocol) throws -> URL {
        guard let fileManager, let depotURL = configuration.directoryURL else {
            preconditionFailure("fileURL(for:) requires a file-backed depot")
        }
        return try DistinctKey(key).getFileURL(from: depotURL, codec: fileManager.fileNameCodec)
    }

    /// Checks that `key` can be persisted by this depot (always true for
    /// memory-only depots).
    func validateFileName(for key: DistinctKey) throws {
        guard let fileManager else {
            return
        }
        try fileManager.fileNameCodec.validate(key.key)
    }

    @discardableResult
    func updateResourceValues(at fileURL: URL) -> Date {
        let modificationDate = Date()

        if !configuration.isExcludedFromBackup, configuration.fileProtection == nil, changeTracker == nil {
            return modificationDate
        }

        var resourceValues = URLResourceValues()
        resourceValues.contentModificationDate = modificationDate

        if configuration.isExcludedFromBackup {
            resourceValues.isExcludedFromBackup = true
        }

        do {
            var resourceFileURL = fileURL
            try resourceFileURL.setResourceValues(resourceValues)
        } catch {
            LOG(
                level: .error,
                message:
                    "Depot[\(label)] failed to set resource values on file at URL \(fileURL) due to error \(error)",
            )
        }

        #if !os(macOS)
        if let fileProtection = configuration.fileProtection {
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: fileProtection.rawValue],
                    ofItemAtPath: fileURL.path(percentEncoded: false),
                )
            } catch {
                LOG(
                    level: .error,
                    message:
                        "Depot[\(label)] failed to set file protection on file at URL \(fileURL) due to error \(error)",
                )
            }
        }
        #endif

        // Record the timestamp as stored by the file system: its resolution may be coarser than `Date`,
        // and the change tracker compares recorded and on-disk dates for equality.
        if changeTracker != nil {
            var resourceFileURL = fileURL
            resourceFileURL.removeAllCachedResourceValues()
            if let storedDate = try? resourceFileURL.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            {
                return storedDate
            }
        }

        return modificationDate
    }
}

// MARK: - Convenience Initializers

extension Depot {
    /// Creates a depot in the specified system directory.
    public convenience init(
        directory: DepotConfiguration.Directory = .applicationSupport,
        name: String,
        encryption: EncryptionConfiguration? = nil,
        memoryCache: DepotConfiguration.MemoryCacheCapacity = .default,
        maximumConcurrentTasks: Int = 4,
    ) throws {
        let config = try DepotConfiguration(
            directory: directory,
            name: name,
            encryption: encryption,
            memoryCache: memoryCache
        )
        self.init(
            configuration: config,
            maximumConcurrentTasks: maximumConcurrentTasks
        )
    }

    /// Creates a depot in a shared app-group container.
    ///
    /// The depot is placed in
    /// ``DepotConfiguration/Directory/sharedApplicationSupport(appGroupIdentifier:)``
    /// and ``DepotConfiguration/enableMultiProcessSupport`` is enabled. This
    /// does **not** start detecting changes made by other processes: in the
    /// host app, call ``automaticallyCheckForExternalChanges(debounceInterval:)``;
    /// in extensions, call ``checkForExternalChanges()-6akyi`` when needed.
    /// See <doc:EncryptionAndMultiProcess> for the consistency guarantees
    /// across processes.
    public convenience init(
        appGroup: String,
        name: String,
        encryption: EncryptionConfiguration? = nil,
        memoryCache: DepotConfiguration.MemoryCacheCapacity = .default,
        maximumConcurrentTasks: Int = 4,
    ) throws {
        let config = try DepotConfiguration(
            directory: .sharedApplicationSupport(appGroupIdentifier: appGroup),
            name: name,
            enableMultiProcessSupport: true,
            encryption: encryption,
            memoryCache: memoryCache
        )
        self.init(
            configuration: config,
            maximumConcurrentTasks: maximumConcurrentTasks
        )
    }

    /// Creates a memory-only depot with no file-system backing.
    ///
    /// Values are kept as Swift values: coders are not invoked, and no
    /// serialization, encryption, file-name, or persistence behavior is
    /// exercised. Nothing survives the process. Use a file-backed depot to test
    /// those aspects.
    public convenience init(
        label: String = "InMemory",
        maximumConcurrentTasks: Int = 4,
    ) {
        self.init(
            label: label,
            configuration: .inMemory(),
            maximumConcurrentTasks: maximumConcurrentTasks,
        )
    }
}
