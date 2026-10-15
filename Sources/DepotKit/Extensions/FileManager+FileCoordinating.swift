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
    /// - Parameter touch: If `true`, updates the lock file's modification date after the operation.
    func synchronize<T>(
        withLockAt fileURL: URL,
        filePresenter: NSFilePresenter?,
        touch: Bool,
        _ readerWriter: () throws -> T,
    ) throws -> T {
        try synchronize(withLockAt: fileURL, filePresenter: filePresenter) {
            (try readerWriter(), touch)
        }
    }

    /// Performs a coordinated write with an exclusive file lock.
    ///
    /// Coordinated writes on the same lock file are mutually exclusive across file presenters,
    /// depot instances, and processes, so the caller has exclusive access while `readerWriter` runs.
    /// Coordinations that share the same `filePresenter` do **not** exclude each other.
    ///
    /// - Parameters:
    ///   - lockFileAttributes: Attributes applied when the lock file has to be created.
    ///   - readerWriter: The critical section. Returns its result and whether the lock file's
    ///     modification date should be updated afterwards (which notifies other processes'
    ///     file presenters). A failing touch is logged, not thrown, because the critical
    ///     section already completed.
    func synchronize<T>(
        withLockAt fileURL: URL,
        filePresenter: NSFilePresenter?,
        lockFileAttributes: [FileAttributeKey: Any]? = nil,
        _ readerWriter: () throws -> (result: T, touch: Bool),
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
            // Create the lock file if it doesn't exist yet
            var isDirectory = ObjCBool(false)
            if !fileExists(atPath: fileURL.path(percentEncoded: false), isDirectory: &isDirectory) {
                var attributes = lockFileAttributes ?? [:]
                attributes[.modificationDate] = Date()
                try createLockFile(at: fileURL, attributes: attributes)
            } else if isDirectory.boolValue {
                throw CocoaError(.fileReadCorruptFile)
            }

            let (result, touch) = try readerWriter()

            if touch {
                // Update the modification date
                var resourceValues = URLResourceValues()
                resourceValues.contentModificationDate = Date()

                var resourceFileURL = fileURL
                do {
                    try resourceFileURL.setResourceValues(resourceValues)
                } catch {
                    LOG(level: .error, message: "Failed to touch lock file at \(fileURL) due to error \(error)")
                }
            }

            return result
        }
    }

    /// Creates the shared lock file at `fileURL`.
    ///
    /// Call it inside a coordinated write on `fileURL`. A critical section must not run without the
    /// lock file: other processes are signaled through it.
    ///
    /// - Throws: `CocoaError.fileWriteUnknown` if the file could not be created.
    func createLockFile(at fileURL: URL, attributes: [FileAttributeKey: Any]) throws {
        let path = fileURL.path(percentEncoded: false)
        guard createFile(atPath: path, contents: nil, attributes: attributes) || fileExists(atPath: path) else {
            LOG(level: .error, message: "Failed to create lock file at \(fileURL)")
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path, NSURLErrorKey: fileURL])
        }
    }
}
