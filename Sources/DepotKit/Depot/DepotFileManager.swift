// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import os

/// Facade that composes ``DepotFileIO`` (pure file operations) and
/// ``DepotFilePresenter`` (NSFilePresenter / coordination concerns).
///
/// All call sites continue to reference `DepotFileManager` — this type
/// simply delegates to the appropriate subsystem.
///
/// - Note: Only to be used by ``Depot``!
final class DepotFileManager: @unchecked Sendable {
    // MARK: Properties

    private let io: DepotFileIO
    private let presenter: DepotFilePresenter

    /// The file-name codec selected from the volume's case sensitivity when the depot was opened.
    var fileNameCodec: DepotFileNameCodec {
        io.fileNameCodec
    }

    var onExternalChangesDetected: (@Sendable () -> Void)? {
        get { presenter.onExternalChangesDetected }
        set { presenter.onExternalChangesDetected = newValue }
    }

    // MARK: - Init

    /// - Parameter volumeSupportsCaseSensitiveNames: Overrides the volume
    ///   capability query (for testing). `nil` queries the volume of
    ///   `depotURL` (or its nearest existing ancestor).
    init(
        depotURL: URL,
        enableMultiProcessSupport: Bool,
        readOnly: Bool = false,
        fileProtection: URLFileProtection? = nil,
        fileManager: FileManager = .default,
        volumeSupportsCaseSensitiveNames: (@Sendable (URL) -> Bool?)? = nil,
        suspensionGuard: SuspensionGuard? = SuspensionGuard.platform,
    ) {
        if !readOnly {
            do {
                try fileManager.createDirectory(
                    at: depotURL,
                    withIntermediateDirectories: true,
                    attributes: fileProtection.map { [.protectionKey: $0.rawValue] },
                )
            } catch {
                LOG(
                    level: .error,
                    message: "DepotFileManager failed to create directory at \(depotURL) due to error \(error)",
                )
            }
        }

        let caseSensitive =
            if let volumeSupportsCaseSensitiveNames {
                volumeSupportsCaseSensitiveNames(depotURL)
            } else {
                DepotFileNameCodec.volumeSupportsCaseSensitiveNames(at: depotURL, fileManager: fileManager)
            }

        io = DepotFileIO(
            depotURL: depotURL,
            fileNameCodec: DepotFileNameCodec.select(
                volumeSupportsCaseSensitiveNames: caseSensitive,
                depotURL: depotURL,
            ),
            fileProtection: fileProtection,
            fileManager: fileManager,
        )

        presenter = DepotFilePresenter(
            depotURL: depotURL,
            enableMultiProcessSupport: enableMultiProcessSupport,
            readOnly: readOnly,
            fileProtection: fileProtection,
            fileManager: fileManager,
            suspensionGuard: suspensionGuard,
        )
    }

    // MARK: - File I/O (delegated to DepotFileIO)

    func hasFiles(for key: some KeyProtocol) throws -> Bool {
        try io.hasFiles(for: key)
    }

    func files(for key: some KeyProtocol) throws -> [(fileURL: URL, key: DistinctKey)] {
        try io.files(for: key)
    }

    func files(under prefix: some KeyProtocol) throws -> [(fileURL: URL, key: DistinctKey)] {
        try io.files(under: prefix)
    }

    func hasFile(at fileURL: URL, skipHiddenFiles: Bool = true) -> Bool {
        io.hasFile(at: fileURL, skipHiddenFiles: skipHiddenFiles)
    }

    func hasDirectory(at directoryURL: URL) -> Bool {
        io.hasDirectory(at: directoryURL)
    }

    /// Removes every item in the depot directory except the shared lock file,
    /// which must survive a reset so that other processes can still be signaled.
    ///
    /// Stops at the first failure; items removed before it stay removed.
    ///
    /// - Parameter willRemove: Called before each item is removed (test hook).
    func removeDepotContents(willRemove: ((URL) throws -> Void)? = nil) throws {
        let lockName = "\(Depot.HiddenKeyPrefix)LOCK"

        for item in try io.contentsOfDirectory(at: io.depotURL, skipHiddenFiles: false)
        where item.lastPathComponent != lockName {
            try willRemove?(item)
            try io.removeItem(at: item)
        }
    }

    func pruneEmptyDirectories(at directoryURLOrNil: URL? = nil) throws {
        try io.pruneEmptyDirectories(at: directoryURLOrNil)
    }

    func removeItem(at url: URL) throws {
        guard url != presenter.lockURL else {
            return
        }

        try io.removeItem(at: url)
    }

    func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil,
    ) throws {
        try io.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes,
        )
    }

    // MARK: - Snapshot (uses coordination from presenter + I/O from io)

    func takeSnapshotOfModificationDates(at directoryURLOrNil: URL? = nil) throws -> [DistinctKey: Date] {
        var modificationDates = [DistinctKey: Date]()

        try presenter.synchronizeWithLock {
            let directoryURL = directoryURLOrNil ?? self.io.depotURL
            let enumerator = self.io.fm.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
            )

            if let enumerator {
                for case let nextURL as URL in enumerator {
                    do {
                        let resourceValues = try nextURL.resourceValues(forKeys: [
                            .isRegularFileKey, .contentModificationDateKey,
                        ])

                        guard resourceValues.isRegularFile == true,
                            let key = DistinctKey.from(
                                fileURL: nextURL,
                                relativeTo: self.io.depotURL,
                                codec: self.io.fileNameCodec,
                            )
                        else {
                            continue
                        }

                        modificationDates[key] =
                            resourceValues.contentModificationDate ?? Date.distantFuture
                    } catch CocoaError.fileReadNoSuchFile {
                        // ignore
                    } catch {
                        throw error
                    }
                }
            }
        }

        return modificationDates
    }

    // MARK: - File Presenter (delegated to DepotFilePresenter)

    func presentedItemDidChange() {
        presenter.presentedItemDidChange()
    }

    func addFilePresenter(registeringIf shouldRegister: () -> Bool = { true }) throws {
        try presenter.addFilePresenter(registeringIf: shouldRegister)
    }

    func removeFilePresenter() {
        presenter.removeFilePresenter()
    }

    func touchLock() throws {
        try presenter.touchLock()
    }

    func coordinate<T>(
        readingItemAt url: URL,
        options: NSFileCoordinator.ReadingOptions = [],
        byAccessor reader: (URL) throws -> T,
    ) throws -> T {
        try presenter.coordinate(readingItemAt: url, options: options, byAccessor: reader)
    }

    func coordinate<T>(
        writingItemAt url: URL,
        options: NSFileCoordinator.WritingOptions = [],
        byAccessor writer: (URL) throws -> T,
    ) throws -> T {
        try presenter.coordinate(writingItemAt: url, options: options, byAccessor: writer)
    }

    func synchronizeWithLock<T>(touch: Bool = false, _ readerWriter: () throws -> T) throws -> T {
        try presenter.synchronizeWithLock(touch: touch, readerWriter)
    }

    /// Runs `readerWriter` inside the cross-process critical section guarded by the shared lock file.
    ///
    /// When multi-process support is disabled this simply runs `readerWriter`.
    func synchronizeWithLockTouchingIfNeeded<T>(_ readerWriter: () throws -> (result: T, touch: Bool)) throws -> T {
        try presenter.synchronizeWithLockTouchingIfNeeded(readerWriter)
    }

    /// Test hook invoked right before waiting for the cross-process critical section.
    var willSynchronizeWithLock: (@Sendable () -> Void)? {
        get { presenter.willSynchronizeWithLock }
        set { presenter.willSynchronizeWithLock = newValue }
    }

    /// Test hook invoked inside the cross-process critical section, before its work runs.
    var didAcquireLock: (@Sendable () -> Void)? {
        get { presenter.didAcquireLock }
        set { presenter.didAcquireLock = newValue }
    }
}
