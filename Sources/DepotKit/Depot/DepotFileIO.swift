// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import os

/// Pure file I/O operations for depot storage.
///
/// This type handles all file-system reads, writes, deletions, directory
/// management, and file enumeration. It has no awareness of NSFilePresenter
/// or NSFileCoordinator — those concerns live in ``DepotFilePresenter``.
///
/// - Note: Only to be used by ``DepotFileManager``!
final class DepotFileIO: @unchecked Sendable {
    // MARK: Properties

    let fm: FileManager
    let depotURL: URL
    let fileProtection: URLFileProtection?

    // MARK: - Init

    init(
        depotURL: URL,
        fileProtection: URLFileProtection? = nil,
        fileManager: FileManager = .default,
    ) {
        fm = fileManager
        self.depotURL = depotURL
        self.fileProtection = fileProtection
    }

    // MARK: - Internal

    func hasFiles(for key: some KeyProtocol) throws -> Bool {
        try hasFiles(matching: key.components[...], in: depotURL)
    }

    func files(for key: some KeyProtocol) throws -> [(fileURL: URL, key: DistinctKey)] {
        try files(matching: key.components[...], in: depotURL, resolvedComponents: [])
    }

    @discardableResult
    func removeFiles(for key: some KeyProtocol, collectRemovedKeys: Bool = false) throws -> [DistinctKey] {
        try removeFiles(matching: key.components[...], in: depotURL, collectRemovedKeys: collectRemovedKeys)
    }

    func hasFile(at fileURL: URL, skipHiddenFiles: Bool = true) -> Bool {
        var isDirectory = ObjCBool(false)
        guard
            fm.fileExists(atPath: fileURL.path(percentEncoded: false), isDirectory: &isDirectory)
                && !isDirectory.boolValue
        else {
            return false
        }

        return !skipHiddenFiles || (try? fileURL.resourceValues(forKeys: [.isHiddenKey]).isHidden) != true
    }

    func hasDirectory(at directoryURL: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return fm.fileExists(atPath: directoryURL.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    func removeDirectory(at directoryURL: URL, skipHiddenFiles: Bool = true) throws {
        let contents: [URL] =
            if directoryURL.path(percentEncoded: false) == depotURL.path(percentEncoded: false) {
                try contentsOfDirectory(at: directoryURL, skipHiddenFiles: skipHiddenFiles)
            } else {
                [directoryURL]
            }

        for item in contents {
            try removeItem(at: item)
        }
    }

    func pruneEmptyDirectories(at directoryURLOrNil: URL? = nil) throws {
        let directoryURL = directoryURLOrNil ?? depotURL
        let contents = try contentsOfDirectory(at: directoryURL)
        guard !contents.isEmpty, try hasFiles(in: directoryURL) else {
            try removeDirectory(at: directoryURL)
            return
        }

        for url in contents where hasDirectory(at: url) {
            try pruneEmptyDirectories(at: url)
        }
    }

    // MARK: - File Operations (wrapping FileManager with error handling)

    func removeItem(at url: URL) throws {
        do {
            try fm.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // ignore
        } catch {
            throw error
        }
    }

    func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil,
    ) throws {
        let effectiveAttributes: [FileAttributeKey: Any]? =
            attributes ?? fileProtection.map { [.protectionKey: $0.rawValue] }

        do {
            try fm.createDirectory(
                at: url,
                withIntermediateDirectories: createIntermediates,
                attributes: effectiveAttributes,
            )
        } catch CocoaError.fileWriteFileExists {
            // ignore
        } catch {
            throw error
        }
    }

    // MARK: - Private

    func contentsOfDirectory(at directoryURL: URL, skipHiddenFiles: Bool = true) throws -> [URL] {
        let contents: [URL]
        do {
            let options: FileManager.DirectoryEnumerationOptions =
                skipHiddenFiles ? [.skipsHiddenFiles, .skipsPackageDescendants] : [.skipsPackageDescendants]
            contents = try fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil, options: options)
        } catch CocoaError.fileReadNoSuchFile {
            contents = []
        } catch {
            throw error
        }

        return contents
    }

    private func hasFiles(in directoryURL: URL) throws -> Bool {
        try hasFiles(matching: [.globstar][...], in: directoryURL)
    }

    private func hasFiles(matching keyComponents: ArraySlice<KeyComponent>, in directoryURL: URL) throws -> Bool {
        guard let firstComponent = keyComponents.first else {
            return false
        }

        switch firstComponent {
        case .segment:
            let pathComponent = firstComponent.pathComponent
            let remainingComponents = keyComponents.dropFirst()
            if !remainingComponents.isEmpty {
                let nextDirectoryURL =
                    directoryURL
                    .appending(component: pathComponent, directoryHint: .isDirectory)

                return try hasFiles(matching: remainingComponents, in: nextDirectoryURL)
            } else {
                let fileURL =
                    directoryURL
                    .appending(component: pathComponent, directoryHint: .notDirectory)
                    .appendingPathExtension(Depot.PathExtension)

                return hasFile(at: fileURL)
            }
        case .wildcard:
            let contents = try contentsOfDirectory(at: directoryURL)
            guard !contents.isEmpty else {
                return false
            }

            let remainingComponents = keyComponents.dropFirst()
            if !remainingComponents.isEmpty {
                for nextURL in contents where hasDirectory(at: nextURL) {
                    if try hasFiles(matching: remainingComponents, in: nextURL) {
                        return true
                    }
                }
                return false
            } else {
                for url in contents {
                    if !hasDirectory(at: url), url.pathExtension == Depot.PathExtension {
                        return true
                    }
                }
                return false
            }
        case .globstar:
            let remainingComponents = keyComponents.dropFirst()
            if try hasFiles(matching: remainingComponents, in: directoryURL) {
                return true
            }

            let contents = try contentsOfDirectory(at: directoryURL)
            for nextURL in contents where hasDirectory(at: nextURL) {
                if try hasFiles(matching: keyComponents, in: nextURL) {
                    return true
                }
            }

            if remainingComponents.isEmpty {
                for url in contents where !hasDirectory(at: url) {
                    if url.pathExtension == Depot.PathExtension {
                        return true
                    }
                }
            }

            return false
        }
    }

    private func files(
        matching keyComponents: ArraySlice<KeyComponent>,
        in directoryURL: URL,
        resolvedComponents: [KeyComponent],
    ) throws -> [(URL, DistinctKey)] {
        guard let firstComponent = keyComponents.first else {
            return []
        }

        switch firstComponent {
        case .segment:
            let pathComponent = firstComponent.pathComponent
            let remainingComponents = keyComponents.dropFirst()
            let accumulated = resolvedComponents + [firstComponent]
            if !remainingComponents.isEmpty {
                let nextDirectoryURL =
                    directoryURL
                    .appending(component: pathComponent, directoryHint: .isDirectory)

                return try files(
                    matching: remainingComponents,
                    in: nextDirectoryURL,
                    resolvedComponents: accumulated,
                )
            } else {
                let fileURL =
                    directoryURL
                    .appending(component: pathComponent, directoryHint: .notDirectory)
                    .appendingPathExtension(Depot.PathExtension)

                if hasFile(at: fileURL) {
                    return [(fileURL, DistinctKey(accumulated))]
                } else {
                    return []
                }
            }
        case .wildcard:
            let contents = try contentsOfDirectory(at: directoryURL)
            guard !contents.isEmpty else {
                return []
            }

            let remainingComponents = keyComponents.dropFirst()
            if !remainingComponents.isEmpty {
                var fileURLs = [(fileURL: URL, key: DistinctKey)]()
                for nextURL in contents where hasDirectory(at: nextURL) {
                    guard let resolvedComponent = KeyComponent(decodingPathComponent: nextURL.lastPathComponent) else {
                        continue
                    }

                    let nextFileURLs = try files(
                        matching: remainingComponents,
                        in: nextURL,
                        resolvedComponents: resolvedComponents + [resolvedComponent],
                    )

                    fileURLs.append(contentsOf: nextFileURLs)
                }

                return fileURLs
            } else {
                var fileURLs = [(fileURL: URL, key: DistinctKey)]()
                for url in contents where !hasDirectory(at: url) {
                    guard url.pathExtension == Depot.PathExtension else { continue }
                    let leafName = url.deletingPathExtension().lastPathComponent
                    guard let leafComponent = KeyComponent(decodingPathComponent: leafName) else { continue }
                    fileURLs.append((url, DistinctKey(resolvedComponents + [leafComponent])))
                }
                return fileURLs
            }
        case .globstar:
            var fileURLs = [(fileURL: URL, key: DistinctKey)]()
            let remainingComponents = keyComponents.dropFirst()

            let matchesHere = try files(
                matching: remainingComponents,
                in: directoryURL,
                resolvedComponents: resolvedComponents,
            )
            fileURLs.append(contentsOf: matchesHere)

            let contents = try contentsOfDirectory(at: directoryURL)
            for nextURL in contents where hasDirectory(at: nextURL) {
                guard let resolvedComponent = KeyComponent(decodingPathComponent: nextURL.lastPathComponent) else {
                    continue
                }

                let deeper = try files(
                    matching: keyComponents,
                    in: nextURL,
                    resolvedComponents: resolvedComponents + [resolvedComponent],
                )
                fileURLs.append(contentsOf: deeper)
            }

            if remainingComponents.isEmpty {
                for url in contents where !hasDirectory(at: url) {
                    guard url.pathExtension == Depot.PathExtension else { continue }
                    let leafName = url.deletingPathExtension().lastPathComponent
                    guard let leafComponent = KeyComponent(decodingPathComponent: leafName) else { continue }
                    fileURLs.append((url, DistinctKey(resolvedComponents + [leafComponent])))
                }
            }

            return fileURLs
        }
    }

    private func removeFiles(
        matching keyComponents: ArraySlice<KeyComponent>,
        in directoryURL: URL,
        resolvedComponents: [KeyComponent] = [],
        collectRemovedKeys: Bool = false,
    ) throws -> [DistinctKey] {
        guard let firstComponent = keyComponents.first else {
            return []
        }

        switch firstComponent {
        case .segment:
            let pathComponent = firstComponent.pathComponent
            let remainingComponents = keyComponents.dropFirst()
            let accumulated = resolvedComponents + [firstComponent]
            if !remainingComponents.isEmpty {
                let nextDirectoryURL = directoryURL.appending(component: pathComponent, directoryHint: .isDirectory)
                return try removeFiles(
                    matching: remainingComponents,
                    in: nextDirectoryURL,
                    resolvedComponents: accumulated,
                    collectRemovedKeys: collectRemovedKeys,
                )
            } else {
                let fileURL =
                    directoryURL
                    .appending(component: pathComponent, directoryHint: .notDirectory)
                    .appendingPathExtension(Depot.PathExtension)

                guard hasFile(at: fileURL) else {
                    return []
                }

                try removeItem(at: fileURL)
                return [DistinctKey(accumulated)]
            }
        case .wildcard:
            let contents = try contentsOfDirectory(at: directoryURL)
            guard !contents.isEmpty else {
                return []
            }

            let remainingComponents = keyComponents.dropFirst()
            if !remainingComponents.isEmpty {
                var removedKeys = [DistinctKey]()
                for nextURL in contents where hasDirectory(at: nextURL) {
                    guard let resolvedComponent = KeyComponent(decodingPathComponent: nextURL.lastPathComponent) else {
                        continue
                    }

                    let nextRemovedKeys = try removeFiles(
                        matching: remainingComponents,
                        in: nextURL,
                        resolvedComponents: resolvedComponents + [resolvedComponent],
                        collectRemovedKeys: collectRemovedKeys,
                    )

                    removedKeys.append(contentsOf: nextRemovedKeys)
                }

                return removedKeys
            } else {
                var removedKeys = [DistinctKey]()
                for url in contents where !hasDirectory(at: url) {
                    guard url.pathExtension == Depot.PathExtension else { continue }
                    let leafName = url.deletingPathExtension().lastPathComponent
                    guard let leafComponent = KeyComponent(decodingPathComponent: leafName) else { continue }
                    if collectRemovedKeys {
                        removedKeys.append(DistinctKey(resolvedComponents + [leafComponent]))
                    }
                    try removeItem(at: url)
                }
                return removedKeys
            }
        case .globstar:
            var removedKeys = [DistinctKey]()

            let remainingComponents = keyComponents.dropFirst()
            let removedHere = try removeFiles(
                matching: remainingComponents,
                in: directoryURL,
                resolvedComponents: resolvedComponents,
                collectRemovedKeys: collectRemovedKeys,
            )
            removedKeys.append(contentsOf: removedHere)

            let contents = try contentsOfDirectory(at: directoryURL)
            for nextURL in contents where hasDirectory(at: nextURL) {
                guard let resolvedComponent = KeyComponent(decodingPathComponent: nextURL.lastPathComponent) else {
                    continue
                }

                let deeper = try removeFiles(
                    matching: keyComponents,
                    in: nextURL,
                    resolvedComponents: resolvedComponents + [resolvedComponent],
                    collectRemovedKeys: collectRemovedKeys,
                )
                removedKeys.append(contentsOf: deeper)
            }

            if remainingComponents.isEmpty {
                for url in contents where !hasDirectory(at: url) {
                    guard url.pathExtension == Depot.PathExtension else { continue }
                    let leafName = url.deletingPathExtension().lastPathComponent
                    guard let leafComponent = KeyComponent(decodingPathComponent: leafName) else { continue }
                    if collectRemovedKeys {
                        removedKeys.append(DistinctKey(resolvedComponents + [leafComponent]))
                    }
                    try removeItem(at: url)
                }
            }

            return removedKeys
        }
    }
}
