// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

extension FileManager {
    /// Performs a coordinated read using `NSFileCoordinator`.
    /// See `NSFileCoordinator.coordinate(readingItemAt:options:error:)` for more information.
    func coordinate<T>(
        readingItemAt url: URL,
        filePresenter: NSFilePresenter?,
        options: NSFileCoordinator.ReadingOptions,
        byAccessor reader: (URL) throws -> T,
    ) throws -> T {
        let fileCoordinator = NSFileCoordinator(filePresenter: filePresenter)

        var error: NSError?
        var result: Result<T, Error>?
        fileCoordinator.coordinate(readingItemAt: url, options: options, error: &error) { url in
            result = Result {
                try reader(url)
            }
        }

        if let error {
            throw error
        }

        switch result {
        case let .success(value):
            return value
        case let .failure(error):
            throw error
        case .none:
            throw CocoaError(.fileReadUnknown)
        }
    }

    /// Performs a coordinated write using `NSFileCoordinator`.
    /// See `NSFileCoordinator.coordinate(writingItemAt:options:error:)` for more information.
    func coordinate<T>(
        writingItemAt url: URL,
        filePresenter: NSFilePresenter?,
        options: NSFileCoordinator.WritingOptions,
        byAccessor writer: (URL) throws -> T,
    ) throws -> T {
        let fileCoordinator = NSFileCoordinator(filePresenter: filePresenter)

        var error: NSError?
        var result: Result<T, Error>?
        fileCoordinator.coordinate(writingItemAt: url, options: options, error: &error) { url in
            result = Result {
                try writer(url)
            }
        }

        if let error {
            throw error
        }

        switch result {
        case let .success(value):
            return value
        case let .failure(error):
            throw error
        case .none:
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Performs a coordinated write with an exclusive file lock.
    ///
    /// Only one writer is allowed at a time, thus the process has exclusive access.
    /// - Parameter touch: If `true`, updates the lock file's modification date after the operation.
    func synchronize<T>(
        withLockAt fileURL: URL,
        filePresenter: NSFilePresenter?,
        touch: Bool,
        _ readerWriter: () throws -> T,
    ) throws -> T {
        do {
            try createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil,
            )
        } catch CocoaError.fileWriteFileExists {
            // ignore
        } catch {
            throw error
        }

        return try coordinate(writingItemAt: fileURL, filePresenter: filePresenter, options: []) { fileURL in
            let modificationDate = Date()

            // Create the lock file if it doesn't exist yet
            var isDirectory = ObjCBool(false)
            if !fileExists(atPath: fileURL.path(percentEncoded: false), isDirectory: &isDirectory) {
                createFile(
                    atPath: fileURL.path(percentEncoded: false),
                    contents: nil,
                    attributes: [
                        FileAttributeKey.modificationDate: modificationDate
                    ],
                )
            } else if isDirectory.boolValue {
                throw CocoaError(.fileReadCorruptFile)
            }

            let result = try readerWriter()

            if touch {
                // Update the modification date
                var resourceValues = URLResourceValues()
                resourceValues.contentModificationDate = modificationDate

                var resourceFileURL = fileURL
                try resourceFileURL.setResourceValues(resourceValues)
            }

            return result
        }
    }
}
