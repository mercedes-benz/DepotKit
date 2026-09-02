// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

#if os(iOS)
import UIKit
#endif

// MARK: - Lifecycle & File Management

extension Depot {
    /// Validates that the depot's internal metadata file can be read and
    /// decoded with the current encryption key.
    ///
    /// Call this on every app launch **before** reading or writing values.
    /// If it throws, the depot may have been created with a different
    /// encryption key or the files are corrupted — call ``reset()`` to
    /// wipe and recreate the metadata.
    ///
    /// - Throws: ``DepotError/metadataNotFound`` when the metadata file is
    ///   missing, or a decoding error when the key does not match.
    public func verifyIntegrity() throws {
        guard configuration.isFileBacked else {
            return
        }
        try checkMetadata()
    }

    /// Asynchronously validates depot integrity.
    public func verifyIntegrity() async throws {
        LOG(level: .debug, message: "Depot[\(label)] async verifyIntegrity")
        try await withSemaphore { try self.verifyIntegrity() as Void }
    }

    /// Deletes **all** files in the depot directory and recreates the
    /// internal metadata.
    ///
    /// Observers are notified that every key was removed. The memory
    /// cache (if enabled) is also cleared.
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
            memoryEntries.withLock { $0.removeAll() }
            core.notifyObservers(removed: Key.all, in: self)
            return
        }

        // File-backed path
        try lock.withWriteLock {
            try fileManager!.removeDirectory(at: configuration.directoryURL!, skipHiddenFiles: false)
            changeTracker?.removed(key: Key.all)

            do {
                try checkMetadata(createIfNeeded: true)
            } catch {
                LOG(level: .error, message: "Depot[\(label)] failed to verify its integrity due to error \(error)")
            }

            // cacheInMemory
            memoryCache?.removeAll()
        }

        core.notifyObservers(removed: Key.all, in: self)
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
    /// Call this **once** from the host app (not from an extension) after
    /// creating the depot. It is a no-op when
    /// ``DepotConfiguration/enableMultiProcessSupport`` is `false`.
    ///
    /// - Throws: ``DepotError/functionNotAvailable`` on watchOS or when
    ///   called from an app extension.
    public func addFilePresenter() throws {
        guard configuration.isFileBacked, configuration.enableMultiProcessSupport else {
            return
        }

        #if os(watchOS)
        throw DepotError.functionNotAvailable
        #else
        guard !Bundle.main.isAppExtension else {
            throw DepotError.functionNotAvailable
        }

        try fileManager!.addFilePresenter()
        #endif
    }

    /// Asynchronously registers an `NSFilePresenter`.
    public func addFilePresenter() async throws {
        LOG(level: .debug, message: "Depot[\(label)] async addFilePresenter")
        try await withSemaphore { try self.addFilePresenter() }
    }

    /// Unregisters this depot's `NSFilePresenter`.
    public func removeFilePresenter() throws {
        guard configuration.isFileBacked, configuration.enableMultiProcessSupport else {
            return
        }

        #if os(watchOS)
        throw DepotError.functionNotAvailable
        #else
        guard !Bundle.main.isAppExtension else {
            throw DepotError.functionNotAvailable
        }

        fileManager!.removeFilePresenter()
        #endif
    }

    /// Asynchronously removes a previously registered `NSFilePresenter`.
    public func removeFilePresenter() async throws {
        LOG(level: .debug, message: "Depot[\(label)] async removeFilePresenter")
        try await withSemaphore { try self.removeFilePresenter() }
    }

    /// Compares the current on-disk modification dates against the last
    /// known snapshot and notifies observers of any changes.
    ///
    /// Call this after receiving an ``externalChangesDetected`` signal or
    /// whenever you suspect another process may have written to the depot.
    public func checkForExternalChanges() throws {
        guard configuration.isFileBacked, let changeTracker else {
            return
        }

        let modificationDates = try fileManager!.takeSnapshotOfModificationDates()
        let (modifiedKeys, removedKeys) = changeTracker.setModificationDates(modificationDates)

        guard !modifiedKeys.isEmpty || !removedKeys.isEmpty else {
            LOG(level: .debug, message: "Depot[\(label)] checkForExternalChanges: no changes detected")
            return
        }

        LOG(
            level: .info,
            message:
                "Depot[\(label)] detected external changes: \(modifiedKeys.count) modified, \(removedKeys.count) removed",
        )

        // cacheInMemory
        memoryCache?.invalidate(modified: modifiedKeys, removed: removedKeys)

        core.notifyObservers(modified: modifiedKeys, removed: removedKeys, in: self)
    }

    /// Asynchronously checks for external changes.
    public func checkForExternalChanges() async throws {
        LOG(level: .debug, message: "Depot[\(label)] async checkForExternalChanges")
        try await withSemaphore { try self.checkForExternalChanges() }
    }
}

// MARK: - Automatic External Change Tracking

extension Depot {
    /// Automatically manages the `NSFilePresenter` lifecycle around app foreground/background transitions.
    ///
    /// On iOS this observes `UIApplication.didEnterBackgroundNotification` and
    /// `UIApplication.willEnterForegroundNotification` to add/remove the file presenter
    /// and trigger ``checkForExternalChanges()`` when returning to the foreground.
    /// On macOS, the file presenter is added immediately (no lifecycle management needed).
    ///
    /// - Parameter debounceInterval: The minimum interval (in seconds) between
    ///   consecutive external change checks. Defaults to `1.0`.
    ///
    /// - Throws: ``DepotError/functionNotAvailable`` if called from an app extension.
    public func automaticallyCheckForExternalChanges(debounceInterval: TimeInterval = 1.0) throws {
        #if os(watchOS)
        throw DepotError.functionNotAvailable
        #else
        guard !Bundle.main.isAppExtension else {
            throw DepotError.functionNotAvailable
        }

        // Atomically check-and-set to prevent duplicate registration
        let alreadyRegistered = filePresenterState.withLock { state -> Bool in
            guard state.externalChangesCancellable == nil else {
                return true
            }
            state.externalChangesCancellable = externalChangesDetected?.observe { [weak self] _ in
                guard let self else {
                    return
                }

                filePresenterState.withLock { state in
                    state.externalChangesDebounceTask?.cancel()
                    state.externalChangesDebounceTask = Task { @MainActor [weak self] in
                        guard let self else {
                            return
                        }
                        try? await Task.sleep(for: .seconds(debounceInterval))
                        triggerCheckForExternalChanges()
                    }
                }
            }
            return false
        }

        guard !alreadyRegistered else {
            return
        }

        #if os(iOS)
        Task { @MainActor in
            // Add the file presenter if the application is currently not in the background
            if UIApplication.sharedApplicationState != .background {
                try self.addFilePresenter()
            }

            // Remove the file presenter when the app enters the background
            self.filePresenterState.withLock { state in
                state.didEnterBackgroundNotificationToken = NotificationCenter.default.addObserver(
                    forName: UIApplication.didEnterBackgroundNotification,
                    object: nil,
                    queue: .main,
                ) { [weak self] _ in
                    guard let self else {
                        return
                    }

                    do {
                        LOG(level: .info, message: "Depot[\(label)] removes file presenter")
                        try self.removeFilePresenter()
                    } catch {
                        LOG(
                            level: .error,
                            message:
                                "Depot[\(label)] failed to remove file presenter for multi process support due to error \(error)",
                        )
                    }
                }
            }

            // Add the file presenter when the app enters the foreground
            self.filePresenterState.withLock { state in
                state.willEnterForegroundNotificationToken = NotificationCenter.default.addObserver(
                    forName: UIApplication.willEnterForegroundNotification,
                    object: nil,
                    queue: .main,
                ) { [weak self] _ in
                    guard let self else {
                        return
                    }

                    do {
                        LOG(level: .info, message: "Depot[\(label)] adds file presenter")
                        try self.addFilePresenter()
                    } catch {
                        LOG(
                            level: .error,
                            message:
                                "Depot[\(label)] failed to add file presenter for multi process support due to error \(error)",
                        )
                    }

                    triggerCheckForExternalChanges()
                }
            }
        }
        #elseif os(macOS)
        // Just add the file presenter
        try addFilePresenter()
        #endif
        #endif
    }

    private func triggerCheckForExternalChanges() {
        Task(priority: .utility) { @concurrent [weak self] in
            guard let self else {
                return
            }

            do {
                LOG(level: .info, message: "Depot[\(self.label)] triggers check for external changes")
                try await self.checkForExternalChanges()
            } catch {
                LOG(
                    level: .error,
                    message: "Depot[\(self.label)] failed to check for external changes due to error \(error)",
                )
            }
        }
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

    /// Returns the number of stored key files and their total byte size under the given key prefix.
    ///
    /// Pass ``Key/all`` (the default) to measure the entire depot.
    /// Returns zero for memory-only depots (no disk backing).
    public func diskUsage(under prefix: some KeyProtocol = Key.all) throws -> DiskUsage {
        guard let fileManager else {
            return DiskUsage(fileCount: 0, totalBytes: 0)
        }

        return try lock.withReadLock {
            let queryKey: Key =
                if prefix.components != [.globstar], prefix.components.last != .globstar {
                    Key(prefix.components + [.globstar])
                } else {
                    .all
                }

            let files = try fileManager.files(for: queryKey)

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

// MARK: - Private (UIApplication State)

#if os(iOS)

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

#endif
