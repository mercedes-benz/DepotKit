// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

/// Configuration for ``Depot``.
public struct DepotConfiguration: Sendable {

    /// The directory URL that is managed by the depot.
    ///
    /// When `nil`, the depot operates as a pure in-memory store:
    /// - No file I/O is performed
    /// - Coders are not invoked — values are stored directly in memory as their Swift types
    /// - The ``memoryCache`` setting is ignored (there is no disk to cache in front of)
    /// - File-management methods (``Depot/verifyIntegrity()``,
    ///   ``Depot/addFilePresenter()``, etc.) become no-ops
    /// - Data does not survive process termination
    public let directoryURL: URL?

    /// If set to `true` all files are marked as being exluded from backup.
    public let isExcludedFromBackup: Bool

    /// The file protection level applied to files and directories managed by the depot.
    ///
    /// When non-`nil`, the depot sets this protection level on every file it writes and every
    /// directory it creates. Pass `nil` (the default) to use the OS default protection level.
    ///
    /// > Important: On macOS, file protection is silently ignored by the OS.
    ///
    /// > Note: When using ``enableMultiProcessSupport`` together with
    /// `Foundation/URLFileProtection/complete`, files become inaccessible while the device is
    /// locked. Extensions that write while the device is locked should use a less restrictive level.
    public let fileProtection: URLFileProtection?

    /// Must be set to `true` if the depot is shared by multiple processes (e.g. app and extension).
    public let enableMultiProcessSupport: Bool

    /// When set to `true` the depot will throw an error when trying to modify it.
    ///
    /// > Can be useful for read-only access in e.g. extensions.
    public let readOnly: Bool

    /// The encryption configuration, or `nil` for unencrypted storage.
    ///
    /// When non-`nil`, every value is encrypted before it is written to disk
    /// and its integrity is verified on read. Store the encryption key in the
    /// Keychain so it survives app launches.
    ///
    /// > Note: This setting is ignored when ``directoryURL`` is `nil` (memory-only mode).
    public let encryption: EncryptionConfiguration?

    /// Determines whether values are cached in memory.
    ///
    /// > Note: This setting is ignored when ``directoryURL`` is `nil` (memory-only mode).
    public let memoryCache: MemoryCacheCapacity

    /// Returns `true` if the depot is backed by the file system.
    public var isFileBacked: Bool {
        directoryURL != nil
    }

    /// Returns `true` if memory caching is enabled and `false` otherwise.
    ///
    /// Always returns `false` in memory-only mode (``directoryURL`` is `nil`).
    public var cacheInMemory: Bool {
        guard isFileBacked else {
            return false
        }
        return memoryCache.costLimit > 0
    }

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - directoryURL: The directory that is managed by the depot. Pass `nil` for a memory-only depot.
    ///   - isExcludedFromBackup: `true` if all files should be marked as being excluded from backup. Defaults to `false`.
    ///   - fileProtection: The file protection level for files and directories managed by the depot. Defaults to `nil` (OS default).
    ///   - enableMultiProcessSupport: Must be set to `true` if the depot is shared by multiple processes (e.g. app and extension). Defaults to `false`.
    ///   - readOnly: `true` if the depot should be read-only. Defaults to `false`.
    ///   - encryption: The encryption configuration. Defaults to `nil` (unencrypted). Ignored when `directoryURL` is `nil`.
    ///   - memoryCache: The memory cache size. Defaults to ``MemoryCacheCapacity/default``. Ignored when `directoryURL` is `nil`.
    public init(
        directoryURL: URL?,
        isExcludedFromBackup: Bool = false,
        fileProtection: URLFileProtection? = nil,
        enableMultiProcessSupport: Bool = false,
        readOnly: Bool = false,
        encryption: EncryptionConfiguration? = nil,
        memoryCache: MemoryCacheCapacity = .default,
    ) {
        self.directoryURL = directoryURL
        self.isExcludedFromBackup = isExcludedFromBackup
        self.fileProtection = fileProtection
        self.enableMultiProcessSupport = enableMultiProcessSupport
        self.readOnly = readOnly
        self.encryption = encryption
        self.memoryCache = memoryCache
    }

    /// Convenience initializer that resolves the depot URL from a ``Directory`` and path component.
    ///
    /// This is the recommended way to create a configuration for most apps:
    ///
    /// ```swift
    /// let config = try DepotConfiguration(
    ///     directory: .applicationSupport,
    ///     pathComponent: "MyAppDepot"
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - directory: The system directory in which to create the depot's storage folder.
    ///   - name: The folder name relative to `directory`.
    ///   - isExcludedFromBackup: `true` if all files should be marked as being excluded from backup. Defaults to `false`.
    ///   - fileProtection: The file protection level for files and directories managed by the depot. Defaults to `nil` (OS default).
    ///   - enableMultiProcessSupport: Must be set to `true` if the depot is shared by multiple processes (e.g. app and extension). Defaults to `false`.
    ///   - readOnly: `true` if the depot should be read-only. Defaults to `false`.
    ///   - encryption: The encryption configuration. Defaults to `nil` (unencrypted).
    ///   - memoryCache: The memory cache size. Defaults to ``MemoryCacheCapacity/default``.
    ///
    /// - Throws: If the directory URL cannot be resolved (e.g. invalid app group identifier).
    public init(
        directory: Directory,
        name: String,
        isExcludedFromBackup: Bool = false,
        fileProtection: URLFileProtection? = nil,
        enableMultiProcessSupport: Bool = false,
        readOnly: Bool = false,
        encryption: EncryptionConfiguration? = nil,
        memoryCache: MemoryCacheCapacity = .default
    ) throws {
        self.directoryURL = try Self.directoryURL(in: directory, name: name)
        self.isExcludedFromBackup = isExcludedFromBackup
        self.fileProtection = fileProtection
        self.enableMultiProcessSupport = enableMultiProcessSupport
        self.readOnly = readOnly
        self.encryption = encryption
        self.memoryCache = memoryCache
    }
}

extension DepotConfiguration {
    /// Configuration for a memory-only depot (no persistence, no serialization).
    ///
    /// Values are stored directly in memory as their Swift types. Coders are
    /// not invoked, the ``memoryCache`` and ``isExcludedFromBackup`` settings
    /// are ignored, and multi-process support is not available.
    ///
    /// - Parameter readOnly: `true` if the depot should be read-only. Defaults to `false`.
    public static func inMemory() -> DepotConfiguration {
        DepotConfiguration(directoryURL: nil)
    }

    /// Common directories where the data can be stored.
    ///
    /// From [File System Programming Guide](
    /// https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html#//apple_ref/doc/uid/TP40010672-CH2-SW13
    /// ):
    ///
    /// To prevent the syncing and backup processes on iOS devices from taking a long time, be selective about where you place files.
    ///
    /// Apps that store large files can slow down the process of backing up to iTunes or iCloud.
    /// These apps can also consume a large amount of a user's available storage, which may encourage the user to delete the app or disable backup of that app's data to iCloud.
    ///
    /// With this in mind, you should store app data according to the following guidelines:
    ///
    /// - Put user data in `Documents/`
    ///
    /// User data generally includes any files you might want to expose to the user—anything you might want the user to create, import, delete or edit.
    ///
    /// For a drawing app, user data includes any graphic files the user might create.
    /// For a text editor, it includes the text files.
    /// Video and audio apps may even include files that the user has downloaded to watch or listen to later.
    ///
    /// - Put app-created support files in the `Library/Application support/` directory
    ///
    ///  In general, this directory includes files that the app uses to run but that should remain hidden from the user.
    ///  This directory can also include data files, configuration files, templates and modified versions of resources loaded from the app bundle.
    ///
    /// - Remember that files in `Documents/` and `Application Support/` are backed up by default
    ///
    ///  You can exclude files from the backup by calling `-[NSURL setResourceValue:forKey:error:]` using the `NSURLIsExcludedFromBackupKey` key.
    ///
    ///  Any file that can be re-created or downloaded must be excluded from the backup.
    ///  This is particularly important for large media files. If your application downloads video or audio files, make sure they are not included in the backup.
    ///
    /// - Put data cache files in the `Library/Caches/` directory
    ///
    ///  Cache data can be used for any data that needs to persist longer than temporary data, but not as long as a support file.
    ///
    ///  Generally speaking, the application does not require cache data to operate properly, but it can use cache data to improve performance.
    ///  Examples of cache data include (but are not limited to) database cache files and transient, downloadable content.
    ///
    ///  Note that the system may delete the `Caches/` directory to free up disk space, so your app must be able to re-create or download these files as needed.
    public struct Directory: Equatable, Sendable {
        /// The FileManager search path for the directory, or `nil` for shared/temporary directories.
        public let searchPath: FileManager.SearchPathDirectory?

        /// The application group identifier, or `nil` for non-shared directories.
        public let appGroupIdentifier: String?

        /// The path component relative to the root container.
        public let pathComponent: String

        /// `Documents/` directory.
        public static let documents = Directory(
            searchPath: .documentDirectory,
            appGroupIdentifier: nil,
            pathComponent: "Documents/"
        )

        /// `Library/Application Support/` directory.
        public static let applicationSupport = Directory(
            searchPath: .applicationSupportDirectory,
            appGroupIdentifier: nil,
            pathComponent: "Library/Application Support/"
        )

        /// `Library/Caches/` directory.
        public static let caches = Directory(
            searchPath: .cachesDirectory,
            appGroupIdentifier: nil,
            pathComponent: "Library/Caches/"
        )

        /// `tmp/` temporary directory.
        public static let temporary = Directory(
            searchPath: nil,
            appGroupIdentifier: nil,
            pathComponent: "tmp/"
        )

        /// `Documents/` directory in a shared container.
        public static func sharedDocuments(appGroupIdentifier: String) -> Directory {
            Directory(searchPath: nil, appGroupIdentifier: appGroupIdentifier, pathComponent: "Documents/")
        }

        /// `Library/Application Support/` directory in a shared container.
        public static func sharedApplicationSupport(appGroupIdentifier: String) -> Directory {
            Directory(
                searchPath: nil,
                appGroupIdentifier: appGroupIdentifier,
                pathComponent: "Library/Application Support/"
            )
        }

        /// `Library/Caches/` directory in a shared container.
        public static func sharedCaches(appGroupIdentifier: String) -> Directory {
            Directory(searchPath: nil, appGroupIdentifier: appGroupIdentifier, pathComponent: "Library/Caches/")
        }
    }

    /// Allowed total capacity of the memory cache.
    public struct MemoryCacheCapacity: Equatable, Sendable {
        /// The limit of the memory cache capacity in bytes.
        public let costLimit: Int

        /// Creates a memory cache capacity with a custom byte count.
        public init(byteCount: Int) {
            costLimit = byteCount
        }

        /// No memory cache — every read hits disk.
        public static let disabled = MemoryCacheCapacity(byteCount: 0)

        /// Small memory cache capacity (around 4 MB).
        public static let small = MemoryCacheCapacity(byteCount: 4 * 1024 * 1024)

        /// Default memory cache capacity (around 8 MB).
        public static let `default` = MemoryCacheCapacity(byteCount: 8 * 1024 * 1024)

        /// Medium memory cache capacity (around 16 MB).
        public static let medium = MemoryCacheCapacity(byteCount: 16 * 1024 * 1024)

        /// Large memory cache capacity (around 32 MB).
        public static let large = MemoryCacheCapacity(byteCount: 32 * 1024 * 1024)
    }

    /// Creates the directory URL that will be managed by the depot.
    ///
    /// See ``Directory`` for guidance on where to store your data.
    ///
    /// - Parameters:
    ///   - directory: The system directory in which to create the depot's storage folder.
    ///   - pathComponent: The folder name relative to `directory`.
    ///
    /// - Returns: A `URL` to the depot's directory.
    ///
    /// - Throws: If the directory URL cannot be resolved (e.g. invalid app group identifier).
    public static func directoryURL(in directory: Directory, name: String) throws -> URL {
        let directoryURL: URL = try {
            if let searchPath = directory.searchPath {
                return try FileManager.default.url(
                    for: searchPath,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: false,
                )
            }

            if let appGroupIdentifier = directory.appGroupIdentifier {
                guard
                    let containerURL = FileManager.default.containerURL(
                        forSecurityApplicationGroupIdentifier: appGroupIdentifier,
                    )
                else {
                    throw CocoaError(.fileReadNoPermission)
                }

                return containerURL
            }

            return FileManager.default.temporaryDirectory
        }()

        let depotURL = directoryURL.appending(path: name, directoryHint: .isDirectory)

        var isDirectory = ObjCBool(true)
        if FileManager.default.fileExists(atPath: depotURL.path(percentEncoded: false), isDirectory: &isDirectory),
            !isDirectory.boolValue
        {
            throw CocoaError(.fileReadCorruptFile)
        }

        return depotURL
    }
}
