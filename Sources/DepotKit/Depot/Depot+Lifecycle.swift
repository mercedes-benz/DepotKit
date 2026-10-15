// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import os

#if os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#endif

// MARK: - Lifecycle & File Management

extension Depot {
    /// Validates that the depot's internal metadata file can be read and
    /// decoded — with the depot-wide encryption key, if one is configured.
    ///
    /// This confirms that the metadata exists and that the configured key can
    /// authenticate it. It does **not** read, scan, or authenticate the stored
    /// values, and it cannot detect a wrong key used by per-key
    /// `.encrypted(using:)` coders. Damaged values are reported when they are
    /// read.
    ///
    /// A failure does not necessarily mean that data is lost: file-system
    /// errors (for example while protected data is unavailable) are usually
    /// temporary, and a missing or undecodable metadata file says nothing about
    /// the values. Classify the error before acting on it, and reset only data
    /// that your app can recreate. See
    /// <doc:EncryptionAndMultiProcess#Integrity-Verification-and-Recovery>.
    ///
    /// If a writable depot could not create the metadata of an empty store
    /// when it was opened (or after ``reset()-z8t6``), this method and every
    /// later write retry creating it.
    ///
    /// - Throws: ``DepotError/metadataNotFound`` when the metadata file is
    ///   missing, ``EncryptedCoderError`` when it does not authenticate with
    ///   the configured key, a decoding error when it cannot be decoded, or a
    ///   file-system error when it cannot be read.
    public func verifyIntegrity() throws {
        guard configuration.isFileBacked else {
            return
        }
        if metadataCreationPending.withLock({ $0 }) {
            lock.withWriteLock { createPendingMetadataIfNeeded() }
        }
        try checkMetadata()
    }

    /// Asynchronously validates depot integrity.
    public func verifyIntegrity() async throws {
        LOG(level: .debug, message: "Depot[\(label)] async verifyIntegrity")
        try await withSemaphore { try self.verifyIntegrity() as Void }
    }

    /// Deletes **all** values in the depot directory and recreates the
    /// internal metadata.
    ///
    /// The shared lock file is kept.
    /// Observers are notified that every key was removed. The memory
    /// cache (if enabled) is also cleared. Reset is irreversible: use it for
    /// data your app can recreate, or after an explicit decision to discard
    /// durable data.
    ///
    /// If a deletion fails, the error is rethrown. Values deleted before the
    /// failure stay removed; the cache and observers reflect exactly the
    /// values that are gone. If only recreating the metadata fails, all values
    /// are removed and ``verifyIntegrity()-19f86`` reports the missing metadata until
    /// the next write, ``verifyIntegrity()-19f86``, or reset creates it.
    ///
    /// - Throws: ``DepotError/readOnlyDepot`` when
    ///   ``DepotConfiguration/readOnly`` is `true`, or a file-system
    ///   error if deletion fails.
    public func reset() throws {
        guard !configuration.readOnly else {
            throw DepotError.readOnlyDepot
        }

        // Memory-only path
        if let memoryEntries {
            lock.withWriteLock {
                memoryEntries.withLock { $0.removeAll() }
                core.notifyObservers(removed: Key.all, in: self)
            }
            core.runAfterCommitHook()
            return
        }

        // File-backed path
        try lock.withWriteLock {
            // Delete inside the shared lock-file critical section, like writes. The lock file
            // survives the reset and is touched whenever something was deleted, even on failure.
            let outcome = try fileManager!.synchronizeWithLockTouchingIfNeeded {
                var outcome = removeAllFiles()
                reconcile(outcome)

                if outcome.error == nil {
                    do {
                        try recreateMetadata()
                    } catch {
                        outcome.error = error
                    }
                }

                return (outcome, outcome.didChangeStorage)
            }

            // Enqueue under the write lock so notifications follow commit order.
            if outcome.affectsAllKeys {
                core.notifyObservers(removed: Key.all, in: self)
            } else {
                core.notifyObservers(removed: outcome.removedKeys, in: self)
            }

            if let error = outcome.error {
                LOG(
                    level: .error,
                    message:
                        "Depot[\(label)] reset failed (all removed: \(outcome.removedAll), "
                        + "\(outcome.removedKeys.count) values removed): \(error)",
                )
                throw error
            }
        }

        core.runAfterCommitHook()
    }

    /// Asynchronously resets the depot.
    public func reset() async throws {
        LOG(level: .debug, message: "Depot[\(label)] async reset")
        try await withSemaphore { try self.reset() }
    }

    /// Evicts all entries from the in-memory cache.
    ///
    /// The next read for each key will hit the file system. This is a
    /// no-op when memory caching is disabled.
    public func clearCache() {
        memoryCache?.removeAll()
    }

    /// Asynchronously evicts all entries from the in-memory cache.
    public func clearCache() async {
        LOG(level: .debug, message: "Depot[\(label)] async clearCache")
        do {
            try await semaphore.wait()
        } catch {
            return
        }
        defer { semaphore.signal() }
        memoryCache?.removeAll()
    }

    /// Registers this depot as an `NSFilePresenter` so the OS notifies it
    /// when another process modifies the lock file.
    ///
    /// Each notification schedules a ``checkForExternalChanges()-6akyi`` once
    /// notifications have been quiet for the debounce interval — the one passed
    /// to ``automaticallyCheckForExternalChanges(debounceInterval:)``, or one
    /// second — and at the latest three intervals after the first notification.
    /// Registering does not check for changes made while no presenter
    /// was registered; call ``checkForExternalChanges()-6akyi`` after
    /// registering if you need to catch up.
    ///
    /// Use this method together with ``removeFilePresenter()-7csu0`` to control
    /// registration yourself; ``automaticallyCheckForExternalChanges(debounceInterval:)``
    /// manages registration for you. Calling it again while registered has no
    /// effect. It is a no-op when ``DepotConfiguration/enableMultiProcessSupport``
    /// is `false`. Read-only depots register without creating the lock file.
    /// On iOS, iPadOS, tvOS, visionOS, and watchOS, remove the presenter before
    /// the app is suspended.
    ///
    /// - Throws: ``DepotError/functionNotAvailable`` when called from an app
    ///   extension.
    public func addFilePresenter() throws {
        guard configuration.isFileBacked, configuration.enableMultiProcessSupport else {
            return
        }

        guard !Bundle.main.isAppExtension else {
            throw DepotError.functionNotAvailable
        }

        // Handle callbacks that arrive right after registration.
        installExternalChangesHandler()
        try fileManager!.addFilePresenter()
    }

    /// Asynchronously registers an `NSFilePresenter`.
    public func addFilePresenter() async throws {
        LOG(level: .debug, message: "Depot[\(label)] async addFilePresenter")
        try await withSemaphore { try self.addFilePresenter() }
    }

    /// Unregisters this depot's `NSFilePresenter`.
    ///
    /// Does nothing if the presenter is not registered, or when
    /// ``DepotConfiguration/enableMultiProcessSupport`` is `false`.
    ///
    /// - Throws: ``DepotError/functionNotAvailable`` when called from an app
    ///   extension.
    public func removeFilePresenter() throws {
        guard configuration.isFileBacked, configuration.enableMultiProcessSupport else {
            return
        }

        guard !Bundle.main.isAppExtension else {
            throw DepotError.functionNotAvailable
        }

        fileManager!.removeFilePresenter()
    }

    /// Asynchronously removes a previously registered `NSFilePresenter`.
    public func removeFilePresenter() async throws {
        LOG(level: .debug, message: "Depot[\(label)] async removeFilePresenter")
        try await withSemaphore { try self.removeFilePresenter() }
    }

    /// Compares the current on-disk modification dates against the last
    /// known snapshot, invalidates changed entries in the memory cache, and
    /// notifies observers of any changes.
    ///
    /// This is how a depot learns about changes made by other processes (or
    /// other `Depot` instances on the same directory): until it runs, the
    /// memory cache may return previous values and observers are not
    /// notified. Call it whenever you need to catch up — for example when
    /// returning to the foreground, or in an extension before reading.
    /// A registered file presenter (see ``addFilePresenter()-302zu`` and
    /// ``automaticallyCheckForExternalChanges(debounceInterval:)``) schedules it
    /// whenever it reports a change. It works on every
    /// platform and in app extensions, and is a no-op unless
    /// ``DepotConfiguration/enableMultiProcessSupport`` is `true`.
    ///
    /// A value counts as changed when its file's modification date differs
    /// from the last recorded one — earlier dates (for example after a restore)
    /// are detected as well. Content replaced by a writer that deliberately
    /// preserves the previous modification date is **not** detected; call
    /// `clearCache()` after such out-of-band replacements.
    ///
    /// The check waits for in-flight reads and writes of this depot so that a
    /// concurrent read cannot re-cache a value that the check invalidated.
    /// Do not call it from inside a transaction closure.
    public func checkForExternalChanges() throws {
        try checkForExternalChanges(checkingCancellation: false)
    }

    /// Checks for external changes.
    ///
    /// - Parameter checkingCancellation: Whether to throw `CancellationError` instead of scanning
    ///   when the current task was canceled while the check waited for the write lock.
    private func checkForExternalChanges(checkingCancellation: Bool) throws {
        guard configuration.isFileBacked, let changeTracker else {
            return
        }

        // Snapshot, tracker update, and cache invalidation run under the depot's write lock:
        // reads populate the cache under the read lock, so an in-flight read of old bytes
        // either completes before the invalidation or reads the replacement afterwards.
        // Observers are notified after the lock is released.
        testHooks.willAcquireLockForExternalChangesCheck?()
        let (modifiedKeys, removedKeys) = try lock.withWriteLock {
            if checkingCancellation {
                try Task.checkCancellation()
            }
            let modificationDates = try fileManager!.takeSnapshotOfModificationDates()
            let changes = changeTracker.setModificationDates(modificationDates)

            // cacheInMemory
            memoryCache?.invalidate(modified: changes.modified, removed: changes.removed)
            return changes
        }

        guard !modifiedKeys.isEmpty || !removedKeys.isEmpty else {
            LOG(level: .debug, message: "Depot[\(label)] checkForExternalChanges: no changes detected")
            return
        }

        LOG(
            level: .info,
            message:
                "Depot[\(label)] detected external changes: \(modifiedKeys.count) modified, \(removedKeys.count) removed",
        )

        core.notifyObservers(modified: modifiedKeys, removed: removedKeys, in: self)
    }

    /// Asynchronously checks for external changes.
    ///
    /// When the calling task is canceled before the check starts scanning, it throws
    /// `CancellationError` and leaves the pending changes to the next check.
    public func checkForExternalChanges() async throws {
        LOG(level: .debug, message: "Depot[\(label)] async checkForExternalChanges")
        try await withSemaphore { try self.checkForExternalChanges(checkingCancellation: true) }
    }
}

// MARK: - Automatic External Change Tracking

extension Depot {
    /// Starts checking for changes made by other processes, and manages the `NSFilePresenter`
    /// lifecycle where the platform allows it.
    ///
    /// Installs a handler that runs ``checkForExternalChanges()-6akyi`` once file-presenter
    /// callbacks have been quiet for `debounceInterval` seconds, registers the presenter, and
    /// checks once for changes made since the depot was created. Calling the method again has
    /// no effect, and it has no effect when ``DepotConfiguration/enableMultiProcessSupport`` is
    /// `false`. Presenter management depends on the platform:
    ///
    /// - **iOS, iPadOS, Mac Catalyst, tvOS, visionOS:** Registers the presenter asynchronously
    ///   without blocking the main actor, unless the app is in the background, and runs a check. Observes
    ///   `UIApplication.didEnterBackgroundNotification` to remove the presenter and cancel a pending check, and
    ///   `UIApplication.willEnterForegroundNotification` to register it again and run a check,
    ///   so changes made while the app was in the background are picked up on return.
    /// - **watchOS:** The same, following `WKApplication.didEnterBackgroundNotification` and
    ///   `WKApplication.willEnterForegroundNotification`.
    /// - **macOS:** Registers the presenter and runs a check before returning; the presenter
    ///   stays registered. Do not call it from inside a transaction closure.
    ///
    /// Changes still reach this process eventually, not immediately, and detecting them does not
    /// prevent lost updates between concurrent writers. See <doc:EncryptionAndMultiProcess>.
    ///
    /// - Parameter debounceInterval: The quiet period (in seconds) after the last
    ///   change signal before an external change check runs. A burst of signals
    ///   results in a single check. While signals keep arriving, the check runs at
    ///   the latest three intervals after the first signal. Defaults to `1.0`.
    ///
    /// - Throws: ``DepotError/functionNotAvailable`` when called from an app extension, or a
    ///   file-system error when registering the presenter fails on macOS.
    public func automaticallyCheckForExternalChanges(debounceInterval: TimeInterval = 1.0) throws {
        guard !Bundle.main.isAppExtension else {
            throw DepotError.functionNotAvailable
        }

        guard configuration.isFileBacked, configuration.enableMultiProcessSupport else {
            return
        }

        // Atomically check-and-set so that repeated calls neither register again nor add observers.
        let isFirstCall = filePresenterState.withLock { state -> Bool in
            guard !state.isCheckingAutomatically else {
                return false
            }
            state.isCheckingAutomatically = true
            state.externalChangesDebounceInterval = debounceInterval
            return true
        }

        guard isFirstCall else {
            return
        }

        installExternalChangesHandler()

        let lifecycleOverride = testHooks.applicationLifecycle
        if lifecycleOverride != nil || ApplicationLifecycle.platformSuspendsApps {
            Task { @MainActor [weak self] in
                guard let lifecycle = lifecycleOverride ?? ApplicationLifecycle.platform else {
                    return
                }
                self?.followApplicationLifecycle(lifecycle)
            }
        } else {
            do {
                LOG(level: .info, message: "Depot[\(label)] adds file presenter")
                try addFilePresenter()
            } catch {
                filePresenterState.withLock { $0.isCheckingAutomatically = false }
                throw error
            }

            // Catch up on changes made before the presenter was registered.
            do {
                try checkForExternalChanges()
            } catch {
                LOG(
                    level: .error,
                    message: "Depot[\(label)] failed to check for external changes due to error \(error)",
                )
            }
        }
    }

    /// Makes file-presenter callbacks schedule debounced external-change checks (once per depot).
    ///
    /// The callbacks run on the presenter's operation queue. They capture only a weak reference that they never
    /// load there, so they cannot keep the depot alive and make it deinitialize on that queue.
    func installExternalChangesHandler() {
        let depot = WeakDepotReference(self)
        let filePresenterState = filePresenterState
        let testHooks = testHooks
        filePresenterState.withLock { state in
            guard state.externalChangesCancellable == nil else {
                return
            }
            state.externalChangesCancellable = externalChangesDetected?.observe { _ in
                Depot.scheduleDebouncedExternalChangesCheck(
                    for: depot,
                    filePresenterState: filePresenterState,
                    testHooks: testHooks,
                )
            }
        }
    }

    /// Registers the presenter while the app is in the foreground and unregisters it while the
    /// app is in the background.
    @MainActor
    private func followApplicationLifecycle(_ lifecycle: ApplicationLifecycle) {
        let center = NotificationCenter.default
        let observers = [
            center.addObserver(forName: lifecycle.didEnterBackground, object: nil, queue: .main) { [weak self] _ in
                self?.removeFilePresenterForBackground()
            },
            center.addObserver(forName: lifecycle.willEnterForeground, object: nil, queue: .main) { [weak self] _ in
                self?.addFilePresenterAndCheck()
            },
        ]
        filePresenterState.withLockUnchecked { $0.lifecycleObservers = observers }

        if !lifecycle.isInBackground() {
            addFilePresenterAndCheck()
        }
    }

    /// Registers the presenter and catches up on changes, without blocking the main actor.
    ///
    /// Creating the lock file is a coordinated write, which waits while another process holds the
    /// lock file, so it runs in a task. The registration is skipped when the app entered the
    /// background in the meantime.
    private func addFilePresenterAndCheck() {
        filePresenterState.withLock { $0.isInForeground = true }

        let task = startIOTask(priority: .utility) { [weak self] in
            guard let self else {
                return
            }
            do {
                LOG(level: .info, message: "Depot[\(label)] adds file presenter")
                try await withSemaphore {
                    try self.addFilePresenterWhileInForeground()
                }
            } catch {
                LOG(
                    level: .error,
                    message:
                        "Depot[\(label)] failed to add file presenter for multi process support due to error \(error)",
                )
            }

            // Catch up on changes made while no presenter was registered. When the app entered the
            // background in the meantime, the registration was skipped and the next foreground
            // transition catches up instead.
            guard filePresenterState.withLock({ $0.isInForeground }) else {
                return
            }
            await runExternalChangesCheck()
        }
        testHooks.didStartForegroundRegistration?(task)
    }

    private func addFilePresenterWhileInForeground() throws {
        guard !Bundle.main.isAppExtension else {
            throw DepotError.functionNotAvailable
        }

        installExternalChangesHandler()
        try fileManager!.addFilePresenter {
            filePresenterState.withLock { $0.isInForeground }
        }
    }

    private func removeFilePresenterForBackground() {
        // A registration that is still in progress sees this and skips registering. A pending
        // debounced check must not take the depot's lock and the shared lock file while the app
        // may be suspended; returning to the foreground runs a check.
        filePresenterState.withLock { state in
            state.isInForeground = false
            state.externalChangesDebounceTask?.cancel()
            state.externalChangesDebounceTask = nil
            state.externalChangesCheckDeadline = nil
        }

        do {
            LOG(level: .info, message: "Depot[\(label)] removes file presenter")
            try removeFilePresenter()
        } catch {
            LOG(
                level: .error,
                message:
                    "Depot[\(label)] failed to remove file presenter for multi process support due to error \(error)",
            )
        }
    }

    /// How many debounce intervals a check may be postponed by signals that keep arriving.
    static let externalChangesMaximumDelayFactor = 3.0

    private static func scheduleDebouncedExternalChangesCheck(
        for depot: WeakDepotReference,
        filePresenterState: OSAllocatedUnfairLock<FilePresenterState>,
        testHooks: TestHooks,
    ) {
        let sleep = testHooks.debounceSleep
        let now = testHooks.debounceNow()
        let task = filePresenterState.withLock { state -> Task<Void, Never>? in
            // A callback that arrives after the app entered the background (and the presenter was
            // removed) schedules nothing; returning to the foreground runs a check.
            guard state.lifecycleObservers.isEmpty || state.isInForeground else {
                return nil
            }
            state.externalChangesDebounceTask?.cancel()
            let debounceInterval = Duration.seconds(state.externalChangesDebounceInterval)
            // Signals that keep arriving (for example while another process writes continuously)
            // postpone the check, but not beyond a maximum delay after the first signal.
            let deadline =
                state.externalChangesCheckDeadline
                ?? now.advanced(by: debounceInterval * externalChangesMaximumDelayFactor)
            state.externalChangesCheckDeadline = deadline
            let delay = max(.zero, min(debounceInterval, now.duration(to: deadline)))
            state.externalChangesDebounceGeneration += 1
            let generation = state.externalChangesDebounceGeneration
            let task = startIOTask(priority: .utility) {
                // A newer signal (or teardown) cancels this delay; a canceled delay must not scan.
                do {
                    try await sleep(delay)
                } catch {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
                // The check covers all signals so far; the next signal starts a new burst.
                filePresenterState.withLock { state in
                    if state.externalChangesDebounceGeneration == generation {
                        state.externalChangesCheckDeadline = nil
                    }
                }
                guard let depot = depot.depot else {
                    return
                }
                await depot.runExternalChangesCheck()
            }
            state.externalChangesDebounceTask = task
            return task
        }
        if let task {
            testHooks.didScheduleDebounceTask?(task)
        }
    }

    private func runExternalChangesCheck() async {
        do {
            LOG(level: .info, message: "Depot[\(label)] triggers check for external changes")
            if let check = testHooks.externalChangesCheck {
                try await check(self)
            } else {
                try await checkForExternalChanges()
            }
        } catch is CancellationError {
            LOG(level: .debug, message: "Depot[\(label)] check for external changes was cancelled")
        } catch {
            LOG(
                level: .error,
                message: "Depot[\(label)] failed to check for external changes due to error \(error)",
            )
        }
    }
}

/// A weak reference to a depot that closures can capture without retaining the depot.
private final class WeakDepotReference: Sendable {
    weak let depot: Depot?

    init(_ depot: Depot) {
        self.depot = depot
    }
}

// MARK: - Application Lifecycle

/// The application lifecycle that automatic external-change checks follow on platforms whose apps
/// are suspended in the background.
struct ApplicationLifecycle: Sendable {
    var didEnterBackground: Notification.Name
    var willEnterForeground: Notification.Name
    var isInBackground: @MainActor @Sendable () -> Bool

    /// Whether apps on the current platform are suspended in the background (all but macOS).
    static var platformSuspendsApps: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }

    /// The current platform's lifecycle, or `nil` on macOS, where apps keep running in the background.
    @MainActor
    static var platform: ApplicationLifecycle? {
        #if os(iOS) || os(tvOS) || os(visionOS)
        ApplicationLifecycle(
            didEnterBackground: UIApplication.didEnterBackgroundNotification,
            willEnterForeground: UIApplication.willEnterForegroundNotification,
            isInBackground: { UIApplication.sharedApplicationState == .background },
        )
        #elseif os(watchOS)
        // The watchOS 27 SDK (Swift 6.4) renamed the notifications and deprecated the old names.
        #if compiler(>=6.4)
        ApplicationLifecycle(
            didEnterBackground: WKApplication.didEnterBackgroundNotification,
            willEnterForeground: WKApplication.willEnterForegroundNotification,
            isInBackground: { WKApplication.sharedApplicationState == .background },
        )
        #else
        ApplicationLifecycle(
            didEnterBackground: WKExtension.applicationDidEnterBackgroundNotification,
            willEnterForeground: WKExtension.applicationWillEnterForegroundNotification,
            isInBackground: { WKApplication.sharedApplicationState == .background },
        )
        #endif
        #else
        nil
        #endif
    }
}

// MARK: - Disk Usage

extension Depot {
    /// Describes how much disk space a depot (or a subset of its keys) occupies.
    public struct DiskUsage: Sendable, Equatable {
        /// The number of key files on disk.
        public let fileCount: Int

        /// The total size of all key files in bytes.
        public let totalBytes: Int64

        /// Creates a ``DiskUsage`` value.
        public init(fileCount: Int, totalBytes: Int64) {
            self.fileCount = fileCount
            self.totalBytes = totalBytes
        }
    }

    /// Asynchronously returns the number of stored key files and their total byte size under the
    /// given key prefix.
    ///
    /// See ``diskUsage(under:)-4112w`` for how the prefix is matched.
    public func diskUsage(under prefix: some KeyProtocol = Key.all) async throws -> DiskUsage {
        try await withSemaphore { try self.diskUsage(under: prefix) as DiskUsage }
    }

    /// Returns the number of stored key files and their total byte size under the given key prefix.
    ///
    /// Pass ``Key/all`` (the default) to measure the entire depot.
    /// Returns zero for memory-only depots (no disk backing).
    ///
    /// Counts every value whose key `prefix` matches, together with every value below such a key:
    ///
    /// - A distinct prefix counts its own value and everything below it:
    ///   `diskUsage(under: Key.from("cache"))` counts `cache` and `cache/images/logo`.
    /// - A pattern prefix follows the matching rules of ``KeyProtocol/matches(_:)``, extended
    ///   to everything below a match. Because a trailing globstar matches one or more components,
    ///   `diskUsage(under: Key.from("cache" / .globstar))` counts `cache/images/logo` but not
    ///   `cache` itself — the same values that ``count(for:)-1zpu3`` and
    ///   ``remove(valuesFor:)-2ei12`` address with that pattern.
    ///
    /// Expired values whose files have not been removed yet (see ``removeExpired()-1gvix``)
    /// are included. DepotKit does not enforce a disk budget.
    public func diskUsage(under prefix: some KeyProtocol = Key.all) throws -> DiskUsage {
        guard let fileManager else {
            return DiskUsage(fileCount: 0, totalBytes: 0)
        }

        return try lock.withReadLock {
            let files = try fileManager.files(under: prefix)

            var fileCount = 0
            var totalBytes: Int64 = 0

            for (fileURL, _) in files {
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else {
                    continue
                }

                fileCount += 1
                if let size = values?.fileSize {
                    totalBytes += Int64(size)
                }
            }

            return DiskUsage(fileCount: fileCount, totalBytes: totalBytes)
        }
    }
}

// MARK: - Private (Application State)

#if os(iOS) || os(tvOS) || os(visionOS)

extension UIApplication {
    fileprivate static var sharedApplicationState: UIApplication.State? {
        guard Bundle.main.isApp else {
            return nil
        }

        // We can't do a runtime check using #available, therefore we need to resort to Objective-C
        let sharedApplicationSelector = Selector(("sharedApplication"))
        guard UIApplication.responds(to: sharedApplicationSelector),
            let sharedApplication = UIApplication.perform(sharedApplicationSelector).takeUnretainedValue()
                as? UIApplication
        else {
            return nil
        }

        return sharedApplication.applicationState
    }
}

#elseif os(watchOS)

extension WKApplication {
    fileprivate static var sharedApplicationState: WKApplicationState? {
        guard Bundle.main.isApp else {
            return nil
        }

        return WKApplication.shared().applicationState
    }
}

#endif
