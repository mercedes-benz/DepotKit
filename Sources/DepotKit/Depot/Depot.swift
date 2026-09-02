// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import os

/// A file-system-backed key/value store.
///
/// `Depot` persists every value as a separate file inside a directory you
/// choose via ``DepotConfiguration``. Key identifiers are Base64-encoded
/// into file names, so they are safe on all Apple file systems.
///
/// ## Thread Safety
///
/// All reads and writes are protected by an internal reader/writer lock, so
/// `Depot` is safe to use from any thread or Swift concurrency context.
/// Single-value writes use `Data.write(..., options: .atomic)` to prevent
/// torn or partial files.
///
/// ## Encryption
///
/// When you pass an ``EncryptionConfiguration`` to the initializer, every
/// value is encrypted before it hits disk and its integrity is verified on
/// read. Store the encryption key in the Keychain so it survives app
/// launches.
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
/// let encryption = try EncryptionConfiguration(
///     cipher: .chaChaPoly,
///     hashFunction: .sha256,
///     key: EncryptionConfiguration.generateKey()
/// )
///
/// let depot = try Depot(name: "SecureDepot", encryption: encryption)
///
/// // Verify integrity on launch — reset if the key changed.
/// do {
///     try depot.verifyIntegrity()
/// } catch {
///     try depot.reset()
/// }
/// ```
///
/// ### App-Group Shared Depot (Multi-Process)
///
/// ```swift
/// let shared = try Depot(appGroup: "group.com.example.app", name: "SharedDepot")
///
/// // In the host app, register for external-change notifications:
/// try shared.addFilePresenter()
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
/// //   .custom(count: 2_000_000)  // 2 MB
/// ```
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
    }

    /// In-memory storage for memory-only mode (`directoryURL == nil`).
    struct MemoryEntry: Sendable {
        let value: any Sendable
        let modifiedAt: Date
        let expiresAt: Date?
    }

    let pruneNeeded: OSAllocatedUnfairLock<Bool>
    let memoryEntries: OSAllocatedUnfairLock<[DistinctKey: MemoryEntry]>?

    #if !os(watchOS)
    final class FilePresenterState: @unchecked Sendable {
        var externalChangesCancellable: (any DepotCancellable)?
        var externalChangesDebounceTask: Task<Void, Never>?

        #if os(iOS)
        var didEnterBackgroundNotificationToken: NSObjectProtocol?
        var willEnterForegroundNotificationToken: NSObjectProtocol?
        #endif
    }

    let filePresenterState = OSAllocatedUnfairLock(uncheckedState: FilePresenterState())
    #endif

    let metadataKey = Key.from("\(Depot.HiddenKeyPrefix)META", as: DepotMetadata.self)
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
        self.sweepTask = OSAllocatedUnfairLock(uncheckedState: nil)
        self.pruneNeeded = OSAllocatedUnfairLock(initialState: false)
        lock = ReadWriteLock()

        if configuration.isFileBacked {
            core = DepotCore(encryptionConfiguration: configuration.encryption)
            memoryEntries = nil

            if configuration.cacheInMemory {
                memoryCache = DepotMemoryCache(totalCostLimit: configuration.memoryCache.costLimit)
            } else {
                memoryCache = nil
            }

            if configuration.enableMultiProcessSupport {
                changeTracker = DepotChangeTracker()
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
            )

            LOG(
                level: .info,
                message:
                    """
                    Depot[\(self.label)] initialized at \(configuration.directoryURL!.lastPathComponent) \
                    (encrypted: \(configuration.encryption != nil), \
                    multiProcess: \(configuration.enableMultiProcessSupport), \
                    cache: \(configuration.cacheInMemory))
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

        if !configuration.readOnly {
            let metadataURL = metadataKey.getFileURL(from: configuration.directoryURL!)
            if !fileManager.hasFile(at: metadataURL, skipHiddenFiles: false) {
                do {
                    if try !fileManager.hasFiles(for: Key.all) {
                        try createMetadata()
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

        #if !os(watchOS)
        filePresenterState.withLock { state in
            state.externalChangesCancellable?.cancel()
            state.externalChangesCancellable = nil

            state.externalChangesDebounceTask?.cancel()
            state.externalChangesDebounceTask = nil

            #if os(iOS)
            if let didEnterBackgroundToken = state.didEnterBackgroundNotificationToken {
                NotificationCenter.default.removeObserver(didEnterBackgroundToken)
                state.didEnterBackgroundNotificationToken = nil
            }

            if let willEnterForegroundToken = state.willEnterForegroundNotificationToken {
                NotificationCenter.default.removeObserver(willEnterForegroundToken)
                state.willEnterForegroundNotificationToken = nil
            }
            #endif
        }
        #endif
    }

    private func sweepExpiredAfterInit() {
        guard !configuration.readOnly else {
            return
        }
        let delay = initSweepDelay
        let task = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else {
                return
            }
            let count: Int? = try? { try self.removeExpired() }()
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

    func withSemaphore<T: Sendable>(_ work: @Sendable () throws -> T) async throws -> T {
        try await semaphore.wait()
        defer { semaphore.signal() }
        try Task.checkCancellation()
        return try work()
    }

    // MARK: - Keys

    /// The set of registered keys.
    ///
    /// A key appears in this set after you call ``register(key:coder:)``.
    public var keys: Set<Key> {
        core.keys
    }

    // MARK: - Private

    func checkMetadata(createIfNeeded: Bool = false) throws {
        guard let fileManager, let depotURL = configuration.directoryURL else {
            return
        }

        let fileURL = metadataKey.getFileURL(from: depotURL)
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
        guard let fileManager, let depotURL = configuration.directoryURL else {
            return
        }

        let metadata = DepotMetadata()
        let data = try metadataCoder.encode(metadata)

        let fileURL = metadataKey.getFileURL(from: depotURL)
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        try fileManager.coordinate(writingItemAt: fileURL, options: .forReplacing) { fileURL in
            try data.write(to: fileURL, options: .atomic)

            let modificationDate = updateResourceValues(at: fileURL)
            changeTracker?.modified(key: metadataKey, at: modificationDate)
        }
    }

    func schedulePrune() {
        pruneNeeded.withLock { $0 = true }
    }

    func pruneIfNeeded() {
        guard
            pruneNeeded.withLock({ val in
                defer { val = false }
                return val
            })
        else {
            return
        }
        try? fileManager?.pruneEmptyDirectories()
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
        cache: DepotConfiguration.MemoryCacheCapacity = .default,
        maximumConcurrentTasks: Int = 4,
    ) throws {
        let config = try DepotConfiguration(
            directory: directory,
            name: name,
            encryption: encryption,
            memoryCache: cache
        )
        self.init(
            configuration: config,
            maximumConcurrentTasks: maximumConcurrentTasks
        )
    }

    /// Creates a depot in a shared app-group container.
    public convenience init(
        appGroup: String,
        name: String,
        encryption: EncryptionConfiguration? = nil,
        cache: DepotConfiguration.MemoryCacheCapacity = .default,
        maximumConcurrentTasks: Int = 4,
    ) throws {
        let config = try DepotConfiguration(
            directory: .sharedApplicationSupport(appGroupIdentifier: appGroup),
            name: name,
            enableMultiProcessSupport: true,
            encryption: encryption,
            memoryCache: cache
        )
        self.init(
            configuration: config,
            maximumConcurrentTasks: maximumConcurrentTasks
        )
    }

    /// Creates a memory-only depot with no file-system backing.
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
