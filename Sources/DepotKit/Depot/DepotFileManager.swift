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

    var onExternalChangesDetected: (@Sendable () -> Void)? {
        get { presenter.onExternalChangesDetected }
        set { presenter.onExternalChangesDetected = newValue }
    }

    // MARK: - Init

    init(
        depotURL: URL,
        enableMultiProcessSupport: Bool,
        readOnly: Bool = false,
        fileProtection: URLFileProtection? = nil,
        fileManager: FileManager = .default,
    ) {
        io = DepotFileIO(
            depotURL: depotURL,
            fileProtection: fileProtection,
            fileManager: fileManager,
        )

        presenter = DepotFilePresenter(
            depotURL: depotURL,
            enableMultiProcessSupport: enableMultiProcessSupport,
            fileProtection: fileProtection,
            fileManager: fileManager,
        )

        guard !readOnly else {
            return
        }

        do {
            try io.createDirectory(
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

    // MARK: - File I/O (delegated to DepotFileIO)

    func hasFiles(for key: some KeyProtocol) throws -> Bool {
        try io.hasFiles(for: key)
    }

    func files(for key: some KeyProtocol) throws -> [(fileURL: URL, key: DistinctKey)] {
        try io.files(for: key)
    }

    @discardableResult
    func removeFiles(for key: some KeyProtocol, collectRemovedKeys: Bool = false) throws -> [DistinctKey] {
        try io.removeFiles(for: key, collectRemovedKeys: collectRemovedKeys)
    }

    func hasFile(at fileURL: URL, skipHiddenFiles: Bool = true) -> Bool {
        io.hasFile(at: fileURL, skipHiddenFiles: skipHiddenFiles)
    }

    func hasDirectory(at directoryURL: URL) -> Bool {
        io.hasDirectory(at: directoryURL)
    }

    func removeDirectory(at directoryURL: URL, skipHiddenFiles: Bool = true) throws {
        try io.removeDirectory(at: directoryURL, skipHiddenFiles: skipHiddenFiles)
    }

    func pruneEmptyDirectories(at directoryURLOrNil: URL? = nil) throws {
        try io.pruneEmptyDirectories(at: directoryURLOrNil)
    }

    func removeItem(at url: URL) throws {
        guard url != presenter.presentedItemURL else {
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
                            let key = try? DistinctKey.from(fileURL: nextURL, relativeTo: self.io.depotURL)
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

    func addFilePresenter() throws {
        try presenter.addFilePresenter()
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

    func synchronizeWithLock(touch: Bool = false, _ readerWriter: () throws -> Void) throws {
        try presenter.synchronizeWithLock(touch: touch, readerWriter)
    }
}
