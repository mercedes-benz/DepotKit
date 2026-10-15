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
    let fileNameCodec: DepotFileNameCodec

    // MARK: - Init

    init(
        depotURL: URL,
        fileNameCodec: DepotFileNameCodec,
        fileProtection: URLFileProtection? = nil,
        fileManager: FileManager = .default,
    ) {
        fm = fileManager
        self.depotURL = depotURL
        self.fileNameCodec = fileNameCodec
        self.fileProtection = fileProtection
    }

    // MARK: - Internal

    func hasFiles(for key: some KeyProtocol) throws -> Bool {
        var found = false
        try forEachFile(matching: validatedComponents(of: key).zeroOrMoreGlobstarComponents) { _, _ in
            found = true
            return false
        }
        return found
    }

    func files(for key: some KeyProtocol) throws -> [(fileURL: URL, key: DistinctKey)] {
        try files(matching: validatedComponents(of: key).zeroOrMoreGlobstarComponents)
    }

    /// The files of all keys that `prefix` matches, and of all keys below them.
    ///
    /// For a prefix ending in a globstar this is the same as ``files(for:)``.
    /// The last component of a distinct prefix also names a directory, so it
    /// is validated with the directory budget.
    func files(under prefix: some KeyProtocol) throws -> [(fileURL: URL, key: DistinctKey)] {
        let prefix = Key(prefix)
        try fileNameCodec.validate(prefix, lastComponentIsLeaf: false)
        var components = prefix.zeroOrMoreGlobstarComponents
        if components.last != .globstar {
            components.append(.globstar)
        }
        return try files(matching: components)
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

    /// Whether `directoryURL` is a directory. A symbolic link never counts as
    /// one, so traversal and pruning never leave the depot directory.
    func hasDirectory(at directoryURL: URL) -> Bool {
        itemKind(at: directoryURL) == .directory
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

    /// The canonical components of `key`, after checking that every segment
    /// fits into a file name.
    private func validatedComponents(of key: some KeyProtocol) throws -> Key {
        let key = Key(key)
        try fileNameCodec.validate(key)
        return key
    }

    /// - Parameter pattern: Components in which every globstar matches zero or more components.
    private func files(matching pattern: [KeyComponent]) throws -> [(fileURL: URL, key: DistinctKey)] {
        var files = [(fileURL: URL, key: DistinctKey)]()
        try forEachFile(matching: pattern) { fileURL, fileKey in
            files.append((fileURL, fileKey))
            return true
        }
        return files
    }

    private func encodedName(for component: KeyComponent) -> String {
        component.pathComponent(using: fileNameCodec)
    }

    private func component(decoding pathComponent: String) -> KeyComponent? {
        KeyComponent(decodingPathComponent: pathComponent, using: fileNameCodec)
    }

    func contentsOfDirectory(at directoryURL: URL, skipHiddenFiles: Bool = true) throws -> [URL] {
        let contents: [URL]
        do {
            let options: FileManager.DirectoryEnumerationOptions =
                skipHiddenFiles ? [.skipsHiddenFiles, .skipsPackageDescendants] : [.skipsPackageDescendants]
            contents = try fm.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: Array(Self.itemKindKeys),
                options: options,
            )
        } catch CocoaError.fileReadNoSuchFile {
            contents = []
        } catch {
            throw error
        }

        return contents
    }

    /// Whether `directoryURL` contains a value file at any depth.
    ///
    /// Any non-hidden `.bin` entry counts, decodable or not and including
    /// symbolic links, so pruning never deletes a directory that still holds
    /// file-like content. Linked directories are not searched.
    private func hasFiles(in directoryURL: URL) throws -> Bool {
        for url in try contentsOfDirectory(at: directoryURL) {
            if hasDirectory(at: url) {
                if try hasFiles(in: url) {
                    return true
                }
            } else if url.pathExtension == Depot.PathExtension {
                return true
            }
        }
        return false
    }

    private enum ItemKind {
        case directory
        case regularFile
        case other
    }

    private static let itemKindKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]

    /// The kind of the item at `url`, without following a symbolic link there.
    ///
    /// Symbolic links, missing items and items that cannot be inspected are
    /// ``ItemKind/other``.
    private func itemKind(at url: URL) -> ItemKind {
        guard let values = try? url.resourceValues(forKeys: Self.itemKindKeys), values.isSymbolicLink != true else {
            return .other
        }
        if values.isDirectory == true {
            return .directory
        }
        return values.isRegularFile == true ? .regularFile : .other
    }

    /// Whether `fileURL` is a non-hidden regular file, without following a symbolic link.
    private func hasValueFile(at fileURL: URL) -> Bool {
        guard let values = try? fileURL.resourceValues(forKeys: Self.itemKindKeys.union([.isHiddenKey])) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true && values.isHidden != true
    }

    // MARK: - Pattern Traversal

    /// Visits every value file whose key matches `pattern`, each exactly once.
    ///
    /// Every globstar in `pattern` matches zero or more components; pass
    /// ``KeyProtocol/zeroOrMoreGlobstarComponents`` to get the semantics of
    /// ``KeyProtocol/matches(_:)``, where a trailing `**` matches one or more.
    /// The directory tree is walked once while tracking which pattern positions
    /// are reachable for the current key prefix, so the same file is never
    /// reached through two different globstar partitions.
    ///
    /// Hidden entries, symbolic links and names the codec would not produce
    /// are skipped, so the walk never leaves the depot directory and cannot
    /// loop.
    ///
    /// - Parameter visit: Called with each matching file and its key. Return
    ///   `false` to stop the traversal.
    private func forEachFile(
        matching pattern: [KeyComponent],
        visit: (URL, DistinctKey) throws -> Bool,
    ) throws {
        let matcher = GlobMatcher(pattern: pattern)
        _ = try forEachFile(
            matcher,
            positions: matcher.initialPositions,
            in: depotURL,
            resolvedComponents: [],
            visit: visit,
        )
    }

    /// - Returns: `false` if `visit` stopped the traversal.
    private func forEachFile(
        _ matcher: GlobMatcher,
        positions: [Int],
        in directoryURL: URL,
        resolvedComponents: [KeyComponent],
        visit: (URL, DistinctKey) throws -> Bool,
    ) throws -> Bool {
        if let segments = matcher.literalSegments(at: positions) {
            // Only exact segments can match next: probe their names instead of listing the directory.
            for segment in segments {
                let nextPositions = matcher.advance(positions, over: segment)
                let pathComponent = encodedName(for: segment)
                let components = resolvedComponents + [segment]

                if matcher.isComplete(nextPositions) {
                    let fileURL =
                        directoryURL
                        .appending(component: pathComponent, directoryHint: .notDirectory)
                        .appendingPathExtension(Depot.PathExtension)

                    if hasValueFile(at: fileURL), try !visit(fileURL, DistinctKey(components)) {
                        return false
                    }
                }

                let nextDirectoryURL = directoryURL.appending(component: pathComponent, directoryHint: .isDirectory)
                if matcher.canMatchMore(nextPositions), hasDirectory(at: nextDirectoryURL) {
                    let shouldContinue = try forEachFile(
                        matcher,
                        positions: nextPositions,
                        in: nextDirectoryURL,
                        resolvedComponents: components,
                        visit: visit,
                    )
                    if !shouldContinue {
                        return false
                    }
                }
            }
            return true
        }

        for url in try contentsOfDirectory(at: directoryURL) {
            switch itemKind(at: url) {
            case .directory:
                guard let resolvedComponent = component(decoding: url.lastPathComponent) else {
                    continue
                }

                let nextPositions = matcher.advance(positions, over: resolvedComponent)
                guard matcher.canMatchMore(nextPositions) else {
                    continue
                }

                let shouldContinue = try forEachFile(
                    matcher,
                    positions: nextPositions,
                    in: url,
                    resolvedComponents: resolvedComponents + [resolvedComponent],
                    visit: visit,
                )
                if !shouldContinue {
                    return false
                }
            case .regularFile:
                guard url.pathExtension == Depot.PathExtension,
                    let leafComponent = component(decoding: url.deletingPathExtension().lastPathComponent),
                    matcher.isComplete(matcher.advance(positions, over: leafComponent))
                else {
                    continue
                }

                if try !visit(url, DistinctKey(resolvedComponents + [leafComponent])) {
                    return false
                }
            case .other:
                continue
            }
        }
        return true
    }
}

// MARK: - GlobMatcher

/// Matches a key pattern one concrete component at a time.
///
/// Every globstar matches zero or more components, including a trailing one;
/// build the pattern with ``KeyProtocol/zeroOrMoreGlobstarComponents`` to
/// match like ``KeyProtocol/matches(_:)``.
///
/// A state is the sorted set of pattern positions reachable after consuming a
/// key prefix, closed under globstars matching zero components. Position
/// `pattern.count` means the whole pattern has been matched.
private struct GlobMatcher {
    let pattern: [KeyComponent]

    /// The state before any component has been consumed.
    var initialPositions: [Int] {
        closure(of: [0])
    }

    /// Whether a key ending in this state matches the pattern.
    func isComplete(_ positions: [Int]) -> Bool {
        positions.last == pattern.count
    }

    /// Whether a longer key could still match from this state.
    func canMatchMore(_ positions: [Int]) -> Bool {
        positions.first.map { $0 < pattern.count } ?? false
    }

    /// The distinct segments that can match the next component, or `nil` if
    /// a wildcard or globstar can match any component there.
    func literalSegments(at positions: [Int]) -> [KeyComponent]? {
        var segments = [KeyComponent]()
        for position in positions where position < pattern.count {
            let component = pattern[position]
            guard case .segment = component else {
                return nil
            }
            if !segments.contains(component) {
                segments.append(component)
            }
        }
        return segments
    }

    /// The state after consuming the concrete `component`.
    func advance(_ positions: [Int], over component: KeyComponent) -> [Int] {
        var nextPositions = [Int]()
        for position in positions where position < pattern.count {
            switch pattern[position] {
            case .globstar:
                nextPositions.append(position)
            case .wildcard:
                nextPositions.append(position + 1)
            case .segment:
                if pattern[position] == component {
                    nextPositions.append(position + 1)
                }
            }
        }
        return closure(of: nextPositions)
    }

    private func closure(of positions: [Int]) -> [Int] {
        var result = Set<Int>()
        for var position in positions {
            while result.insert(position).inserted, position < pattern.count, pattern[position] == .globstar {
                position += 1
            }
        }
        return result.sorted()
    }
}
