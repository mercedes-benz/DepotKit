// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import os

/// NSFilePresenter conformance and file coordination for depot storage.
///
/// This type manages multi-process coordination: it registers as an
/// `NSFilePresenter` for a lock file and wraps `NSFileCoordinator` calls.
/// Pure file I/O operations live in ``DepotFileIO``.
///
/// - Note: Only to be used by ``DepotFileManager``!
final class DepotFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    // MARK: Properties

    private let fm: FileManager
    private let depotURL: URL
    private let enableMultiProcessSupport: Bool
    /// Read-only depots never create or touch the lock file, and present the depot directory.
    private let readOnly: Bool
    private let fileProtection: URLFileProtection?
    /// Keeps the process from being suspended during coordinated file access; `nil` where
    /// processes are not suspended.
    private let suspensionGuard: SuspensionGuard?

    private let _onExternalChangesDetected = OSAllocatedUnfairLock<CallbackBox?>(initialState: nil)

    var onExternalChangesDetected: (@Sendable () -> Void)? {
        get { _onExternalChangesDetected.withLock { $0 }?.call }
        set { _onExternalChangesDetected.withLock { $0 = CallbackBox(newValue) } }
    }

    private let _willSynchronizeWithLock = OSAllocatedUnfairLock<CallbackBox?>(initialState: nil)

    /// Test hook invoked right before waiting for exclusive coordinated access to the lock file.
    var willSynchronizeWithLock: (@Sendable () -> Void)? {
        get { _willSynchronizeWithLock.withLock { $0 }?.call }
        set { _willSynchronizeWithLock.withLock { $0 = CallbackBox(newValue) } }
    }

    private let _didAcquireLock = OSAllocatedUnfairLock<CallbackBox?>(initialState: nil)

    /// Test hook invoked inside the exclusive coordinated access to the lock file, before the critical section runs.
    var didAcquireLock: (@Sendable () -> Void)? {
        get { _didAcquireLock.withLock { $0 }?.call }
        set { _didAcquireLock.withLock { $0 = CallbackBox(newValue) } }
    }

    /// Serializes registration with `NSFileCoordinator`; guards `isRegistered`.
    private let registrationLock = NSLock()
    private var isRegistered = false

    let presentedItemOperationQueue = {
        let operationQueue = OperationQueue()
        operationQueue.name = "DepotFilePresenter.presented-item-operation-queue"
        operationQueue.qualityOfService = .utility
        operationQueue.maxConcurrentOperationCount = 1

        return operationQueue
    }()

    // MARK: - Init

    init(
        depotURL: URL,
        enableMultiProcessSupport: Bool,
        readOnly: Bool = false,
        fileProtection: URLFileProtection? = nil,
        fileManager: FileManager = .default,
        suspensionGuard: SuspensionGuard? = SuspensionGuard.platform,
    ) {
        fm = fileManager
        self.depotURL = depotURL
        self.enableMultiProcessSupport = enableMultiProcessSupport
        self.readOnly = readOnly
        self.fileProtection = fileProtection
        self.suspensionGuard = suspensionGuard

        super.init()
    }

    // No deinit-time unregistration: `NSFileCoordinator` retains registered presenters, so the owner
    // must call `removeFilePresenter()`. Foundation may release the last reference on its internal
    // queue, where a synchronous `NSFileCoordinator.removeFilePresenter(_:)` would trap. Unregistering
    // on `presentedItemOperationQueue` is safe (covered by the file presenter teardown tests).

    // MARK: - NSFilePresenter

    /// The shared lock file that serializes writers across depot instances and processes, or `nil`
    /// without multi-process support.
    var lockURL: URL? {
        guard enableMultiProcessSupport else {
            return nil
        }

        return depotURL.appending(component: "\(Depot.HiddenKeyPrefix)LOCK")
    }

    /// Writable depots present the lock file, whose modification date every writer updates.
    ///
    /// Read-only depots must not create the lock file, and a presenter registered for a missing
    /// item is not notified when it is created. They present the depot directory instead and are
    /// notified about changes of the items in it, including the lock file.
    var presentedItemURL: URL? {
        guard enableMultiProcessSupport else {
            return nil
        }

        return readOnly ? depotURL : lockURL
    }

    func presentedItemDidChange() {
        onExternalChangesDetected?()
    }

    func presentedSubitemDidChange(at url: URL) {
        onExternalChangesDetected?()
    }

    // MARK: - File Presenter Management

    /// Registers the presenter, creating the lock file first unless the depot is read-only.
    ///
    /// - Parameter shouldRegister: Evaluated while registrations are serialized, after the lock file
    ///   was created; returning `false` skips the registration.
    func addFilePresenter(registeringIf shouldRegister: () -> Bool = { true }) throws {
        guard presentedItemURL != nil else {
            return
        }

        if !readOnly, let lockURL {
            try coordinate(writingItemAt: lockURL, options: .contentIndependentMetadataOnly) { fileURL in
                try createLockFileIfNecessary(at: fileURL)
            }
        }

        registrationLock.withLock {
            guard !isRegistered, shouldRegister() else {
                return
            }
            NSFileCoordinator.addFilePresenter(self)
            isRegistered = true
        }
    }

    /// Unregisters the presenter if it is registered; otherwise does nothing.
    func removeFilePresenter() {
        registrationLock.withLock {
            guard isRegistered else {
                return
            }
            NSFileCoordinator.removeFilePresenter(self)
            isRegistered = false
        }
    }

    func touchLock() throws {
        guard !readOnly, let fileURL = lockURL else {
            return
        }

        try coordinate(writingItemAt: fileURL, options: .contentIndependentMetadataOnly) { fileURL in
            try createLockFileIfNecessary(at: fileURL, touch: true)
        }
    }

    // MARK: - Coordination

    /// Runs `access` — coordinated access to files shared with other processes — while the
    /// process is kept from being suspended.
    ///
    /// - Throws: ``DepotError/suspensionImminent`` without running `access` when the system is
    ///   about to suspend the process.
    private func withoutSuspension<T>(_ access: () throws -> T) throws -> T {
        guard let suspensionGuard else {
            return try access()
        }

        return try suspensionGuard.run(access)
    }

    func coordinate<T>(
        readingItemAt url: URL,
        options: NSFileCoordinator.ReadingOptions = [],
        byAccessor reader: (URL) throws -> T,
    ) throws -> T {
        guard enableMultiProcessSupport else {
            return try reader(url)
        }

        return try withoutSuspension {
            try fm.coordinate(readingItemAt: url, filePresenter: self, options: options, byAccessor: reader)
        }
    }

    func coordinate<T>(
        writingItemAt url: URL,
        options: NSFileCoordinator.WritingOptions = [],
        byAccessor writer: (URL) throws -> T,
    ) throws -> T {
        guard enableMultiProcessSupport else {
            return try writer(url)
        }

        return try withoutSuspension {
            try fm.coordinate(writingItemAt: url, filePresenter: self, options: options, byAccessor: writer)
        }
    }

    func synchronizeWithLock<T>(touch: Bool = false, _ readerWriter: () throws -> T) throws -> T {
        try synchronizeWithLockTouchingIfNeeded {
            (try readerWriter(), touch)
        }
    }

    /// Runs `readerWriter` while holding exclusive coordinated write access to the shared lock file.
    ///
    /// All depot instances and processes that coordinate on the same lock file are serialized,
    /// so this is the cross-process critical section for writes and expiry cleanup.
    /// The lock file is touched afterwards when `readerWriter` returns `touch == true`.
    ///
    /// Read-only depots only read inside the critical section. They coordinate reading the lock
    /// file instead, which waits for coordinated writers without creating the lock file.
    func synchronizeWithLockTouchingIfNeeded<T>(_ readerWriter: () throws -> (result: T, touch: Bool)) throws -> T {
        guard let fileURL = lockURL else {
            return try readerWriter().result
        }

        // The process stays unsuspended while it waits for the lock file, too: its claim is
        // registered with the system as soon as it starts waiting.
        return try withoutSuspension {
            willSynchronizeWithLock?()

            if readOnly {
                return try coordinate(readingItemAt: fileURL) { _ in
                    didAcquireLock?()
                    return try readerWriter().result
                }
            }

            return try fm.synchronize(
                withLockAt: fileURL,
                filePresenter: self,
                lockFileAttributes: fileProtection.map { [.protectionKey: $0.rawValue] },
            ) {
                didAcquireLock?()
                return try readerWriter()
            }
        }
    }

    // MARK: - Private

    private func createLockFileIfNecessary(at fileURL: URL, touch: Bool = false) throws {
        let modificationDate = Date()

        // Create the lock file if it doesn't exist yet
        var isDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: fileURL.path(percentEncoded: false), isDirectory: &isDirectory) else {
            var attributes: [FileAttributeKey: Any] = [
                .modificationDate: modificationDate
            ]
            if let fileProtection {
                attributes[.protectionKey] = fileProtection.rawValue
            }

            try fm.createLockFile(at: fileURL, attributes: attributes)

            return
        }

        // Ensure it's not a directory
        guard !isDirectory.boolValue else {
            throw CocoaError(.fileReadCorruptFile)
        }

        if touch {
            // Update the modification date
            var resourceValues = URLResourceValues()
            resourceValues.contentModificationDate = modificationDate

            var resourceFileURL = fileURL
            try resourceFileURL.setResourceValues(resourceValues)
        }
    }
}
