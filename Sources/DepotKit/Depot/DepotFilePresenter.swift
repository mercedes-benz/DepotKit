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
    private let fileProtection: URLFileProtection?

    private let _onExternalChangesDetected: OSAllocatedUnfairLock<(@Sendable () -> Void)?> = .init(uncheckedState: nil)

    var onExternalChangesDetected: (@Sendable () -> Void)? {
        get { _onExternalChangesDetected.withLock { $0 } }
        set { _onExternalChangesDetected.withLock { $0 = newValue } }
    }

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
        fileProtection: URLFileProtection? = nil,
        fileManager: FileManager = .default,
    ) {
        fm = fileManager
        self.depotURL = depotURL
        self.enableMultiProcessSupport = enableMultiProcessSupport
        self.fileProtection = fileProtection

        super.init()
    }

    deinit {
        removeFilePresenter()
    }

    // MARK: - NSFilePresenter

    var presentedItemURL: URL? {
        guard enableMultiProcessSupport else {
            return nil
        }

        return depotURL.appending(component: "\(Depot.HiddenKeyPrefix)LOCK")
    }

    func presentedItemDidChange() {
        onExternalChangesDetected?()
    }

    // MARK: - File Presenter Management

    func addFilePresenter() throws {
        guard let fileURL = presentedItemURL else {
            return
        }

        try coordinate(writingItemAt: fileURL, options: .contentIndependentMetadataOnly) { fileURL in
            try createLockFileIfNecessary(at: fileURL)
        }

        NSFileCoordinator.addFilePresenter(self)
    }

    func removeFilePresenter() {
        NSFileCoordinator.removeFilePresenter(self)
    }

    func touchLock() throws {
        guard let fileURL = presentedItemURL else {
            return
        }

        try coordinate(writingItemAt: fileURL, options: .contentIndependentMetadataOnly) { fileURL in
            try createLockFileIfNecessary(at: fileURL, touch: true)
        }
    }

    // MARK: - Coordination

    func coordinate<T>(
        readingItemAt url: URL,
        options: NSFileCoordinator.ReadingOptions = [],
        byAccessor reader: (URL) throws -> T,
    ) throws -> T {
        guard enableMultiProcessSupport else {
            return try reader(url)
        }

        return try fm.coordinate(readingItemAt: url, filePresenter: self, options: options, byAccessor: reader)
    }

    func coordinate<T>(
        writingItemAt url: URL,
        options: NSFileCoordinator.WritingOptions = [],
        byAccessor writer: (URL) throws -> T,
    ) throws -> T {
        guard enableMultiProcessSupport else {
            return try writer(url)
        }

        return try fm.coordinate(writingItemAt: url, filePresenter: self, options: options, byAccessor: writer)
    }

    func synchronizeWithLock(touch: Bool = false, _ readerWriter: () throws -> Void) throws {
        guard let fileURL = presentedItemURL else {
            try readerWriter()
            return
        }

        try fm.synchronize(withLockAt: fileURL, filePresenter: self, touch: touch, readerWriter)
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

            fm.createFile(
                atPath: fileURL.path(percentEncoded: false),
                contents: nil,
                attributes: attributes,
            )

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
