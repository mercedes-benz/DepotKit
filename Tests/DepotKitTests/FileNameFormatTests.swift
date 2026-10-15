// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// File-name codecs, codec selection by volume and per-component length budgets.
@Suite
struct FileNameFormatTests {
    // MARK: - Helpers

    private static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appending(component: "FileNameFormat-\(UUID().uuidString)")
    }

    /// Opens a depot whose volume case-sensitivity query is replaced by `caseSensitive`
    /// (`nil` simulates a failed query).
    private static func depot(
        at url: URL,
        caseSensitive: Bool?,
        cache: Bool = false,
        readOnly: Bool = false,
    ) -> Depot {
        let depot = Depot(
            configuration: .init(directoryURL: url, readOnly: readOnly, memoryCache: cache ? .default : .disabled),
            overrides: .init(volumeSupportsCaseSensitiveNames: { _ in caseSensitive }),
        )
        depot.register(key: Key.all, coder: .json() as AnyCoder<String>)
        return depot
    }

    /// Opens a depot on a volume for which `codec` is selected.
    private static func depot(at url: URL, codec: DepotFileNameCodec, cache: Bool = false) -> Depot {
        depot(at: url, caseSensitive: codec == .base64URL, cache: cache)
    }

    /// The internal files a depot may create in its root directory.
    private static let internalFileNames: Set<String> = [".FS_META.bin", ".FS_LOCK"]

    /// Names of the hidden items in the root of the depot directory at `url`.
    private static func hiddenItems(in url: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
        return Set(names.filter { $0.hasPrefix(".") })
    }

    /// Relative paths of all non-hidden files below `url`.
    private static func userFiles(in url: URL) -> [String] {
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
        )
        let basePath = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        var files = [String]()
        while let fileURL = enumerator?.nextObject() as? URL {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let path = fileURL.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            files.append(String(path.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
        return files.sorted()
    }

    // MARK: - Codecs

    @Test("Base64url produces RFC 4648 §5 file names")
    func base64URLFileNames() throws {
        let codec = DepotFileNameCodec.base64URL
        #expect(codec.encode("aaa") == "YWFh")
        #expect(codec.encode("aaG") == "YWFH")
        #expect(codec.encode("hello") == "aGVsbG8=")
        #expect(codec.encode("\u{83F}") == "4KC_")  // standard Base64 "4KC/"
        #expect(codec.encode("\u{FB}\u{FF}") == "w7vDvw==")  // standard Base64 "w7vDvw=="
        #expect(codec.encode(">>>") == "Pj4-")  // standard Base64 "Pj4+"

        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let depot = Self.depot(at: url, codec: .base64URL)
        try depot.set(value: "x", for: Key.from("entities" / "W1K2951221F000002" / "status", as: String.self))
        #expect(Self.userFiles(in: url) == ["ZW50aXRpZXM=/VzFLMjk1MTIyMUYwMDAwMDI=/c3RhdHVz.bin"])
    }

    @Test("Base32 matches the RFC 4648 test vectors")
    func base32TestVectors() {
        let vectors = [
            ("f", "MY======"),
            ("fo", "MZXQ===="),
            ("foo", "MZXW6==="),
            ("foob", "MZXW6YQ="),
            ("fooba", "MZXW6YTB"),
            ("foobar", "MZXW6YTBOI======"),
        ]
        for (plain, encoded) in vectors {
            #expect(DepotFileNameCodec.base32.encode(plain) == encoded)
            #expect(DepotFileNameCodec.base32.decode(encoded) == plain)
        }
    }

    @Test("both codecs round-trip identifiers", arguments: DepotFileNameCodec.allCases)
    func roundTrip(codec: DepotFileNameCodec) {
        var identifiers = [
            "a", "aaa", "aaG", "a/b/c", "..", ".", ".FS_META", "\(Depot.HiddenKeyPrefix)/../../outside",
            "emoji🎉", "spaces in path", "caf\u{E9}", "\u{D55C}\u{AE00}", "\u{0}", "*", "**", "\\",
        ]
        var generator = SystemRandomNumberGenerator()
        for length in 1...40 {
            let scalars = (0..<length).map { _ in
                Character(Unicode.Scalar(UInt8.random(in: 0x20...0x7E, using: &generator)))
            }
            identifiers.append(String(scalars))
        }

        for identifier in identifiers {
            let encoded = codec.encode(identifier)
            #expect(!encoded.hasPrefix("."))
            #expect(!encoded.contains("/"))
            #expect(encoded.utf8.count == codec.encodedLength(ofByteCount: identifier.utf8.count))
            #expect(codec.decode(encoded) == identifier)
        }
    }

    @Test("Base32 names are distinct regardless of letter case")
    func base32IsCaseInsensitiveInjective() {
        let codec = DepotFileNameCodec.base32
        let identifiers = ["aaa", "aaG", "AAA", "aAa", "Aaa", "a", "A", "b", "B", "abc", "ABC", "\u{E9}", "\u{C9}"]
        let folded = identifiers.map { codec.encode($0).lowercased() }
        #expect(Set(folded).count == identifiers.count)
        for identifier in identifiers {
            let encoded = codec.encode(identifier)
            #expect(encoded == encoded.uppercased())
        }
    }

    @Test("decoders reject names the encoder would not produce")
    func strictDecoding() {
        let base32 = DepotFileNameCodec.base32
        for name in [
            "", "mzxw6===", "MY=====", "M=======", "MZXW6Y==", "MZ======", "MY======MY======", "MZXW1===",
            ".FS_META", ".FS_LOCK", "MY==\u{3D}=X=",
        ] {
            #expect(base32.decode(name) == nil, "\(name)")
        }

        let base64 = DepotFileNameCodec.base64URL
        for name in ["", "QR==", "YWFh+", "YW/h", "YWF", "_w==", ".FS_LOCK", "!!!invalid!!!", "aGVsbG8"] {
            #expect(base64.decode(name) == nil, "\(name)")
        }
    }

    // MARK: - Length budgets

    @Test("length budgets per component", arguments: DepotFileNameCodec.allCases)
    func lengthBudgets(codec: DepotFileNameCodec) {
        for isLeaf in [false, true] {
            let suffix = isLeaf ? 4 : 0
            let maximum = codec.maximumIdentifierByteCount(isLeaf: isLeaf)
            #expect(codec.encodedLength(ofByteCount: maximum) + suffix <= 255)
            #expect(codec.encodedLength(ofByteCount: maximum + 1) + suffix > 255)
        }

        switch codec {
        case .base64URL:
            #expect(codec.maximumIdentifierByteCount(isLeaf: false) == 189)
            #expect(codec.maximumIdentifierByteCount(isLeaf: true) == 186)
        case .base32:
            #expect(codec.maximumIdentifierByteCount(isLeaf: false) == 155)
            #expect(codec.maximumIdentifierByteCount(isLeaf: true) == 155)
        }
    }

    @Test("oversized components are rejected at the boundary", arguments: DepotFileNameCodec.allCases)
    func boundaryRejection(codec: DepotFileNameCodec) throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let depot = Self.depot(at: url, codec: codec)
        #expect(depot.fileManager?.fileNameCodec == codec)

        let leafMaximum = codec.maximumIdentifierByteCount(isLeaf: true)
        let directoryMaximum = codec.maximumIdentifierByteCount(isLeaf: false)

        // Largest supported leaf and directory components work end to end.
        let leaf = Key.from(.component(String(repeating: "l", count: leafMaximum)), as: String.self)
        let directory = Key.from(
            .component(String(repeating: "d", count: directoryMaximum)) / "leaf",
            as: String.self,
        )
        try depot.set(value: "leaf", for: leaf)
        try depot.set(value: "directory", for: directory)
        #expect(try depot.get(valueFor: leaf) == "leaf")
        #expect(try depot.get(valueFor: directory) == "directory")
        let reopened = Self.depot(at: url, codec: codec)
        #expect(try reopened.count(for: Key.all) == 2)
        #expect(try reopened.get(valueFor: directory) == "directory")
        for name in Self.userFiles(in: url).flatMap({ $0.split(separator: "/") }) {
            #expect(name.utf8.count <= 255)
        }

        // One byte more is rejected explicitly by every operation.
        let tooLongLeaf = Key.from(.component(String(repeating: "l", count: leafMaximum + 1)), as: String.self)
        let tooLongDirectory = Key.from(
            .component(String(repeating: "d", count: directoryMaximum + 1)) / "leaf",
            as: String.self,
        )
        let expectedLeafError = DepotError.keyComponentTooLong(
            keyPath: tooLongLeaf.keyPath,
            byteCount: leafMaximum + 1,
            maximumByteCount: leafMaximum,
        )
        let expectedDirectoryError = DepotError.keyComponentTooLong(
            keyPath: tooLongDirectory.keyPath,
            byteCount: directoryMaximum + 1,
            maximumByteCount: directoryMaximum,
        )

        #expect(expectedLeafError.errorDescription?.contains("at most \(leafMaximum) bytes") == true)

        for (key, error) in [(tooLongLeaf, expectedLeafError), (tooLongDirectory, expectedDirectoryError)] {
            #expect(throws: error) { try depot.set(value: "x", for: key) }
            #expect(throws: error) { try depot.get(valueFor: key) }
            #expect(throws: error) { try depot.has(valueFor: key) }
            #expect(throws: error) { try depot.remove(valueFor: key) }
            #expect(throws: error) { try depot.metadata(for: key) }
            #expect(throws: error) {
                try depot.transaction { tx in
                    try tx.set(value: "x", for: key)
                }
            }
            #expect(throws: error) {
                try depot.transaction { tx in
                    try tx.remove(valueFor: key)
                }
            }
        }

        // A directory-position component longer than the leaf budget is fine as a directory.
        if directoryMaximum > leafMaximum {
            let pattern = Key.from(.component(String(repeating: "p", count: directoryMaximum)) / .wildcard)
            #expect(try depot.count(for: pattern) == 0)
        }
        let tooLongPattern = Key.from(.component(String(repeating: "p", count: directoryMaximum + 1)) / .wildcard)
        #expect(throws: DepotError.self) { try depot.count(for: tooLongPattern) }
        #expect(throws: DepotError.self) { try depot.remove(valuesFor: tooLongPattern) }

        // A rejected transaction does not apply earlier mutations.
        let fine = Key.from("fine", as: String.self)
        #expect(throws: expectedLeafError) {
            try depot.transaction { tx in
                try tx.set(value: "applied?", for: fine)
                try tx.set(value: "x", for: tooLongLeaf)
            }
        }
        #expect(try depot.get(valueFor: fine) == nil)
        #expect(try depot.count(for: Key.all) == 2)
    }

    @Test("length limits apply to the NFC form", arguments: DepotFileNameCodec.allCases)
    func lengthAfterNormalization(codec: DepotFileNameCodec) throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let depot = Self.depot(at: url, codec: codec)

        // NFC "é" is 2 bytes; the decomposed spelling is 3 bytes.
        let count = codec.maximumIdentifierByteCount(isLeaf: true) / 2
        let decomposed = String(repeating: "e\u{301}", count: count)
        #expect(decomposed.utf8.count > codec.maximumIdentifierByteCount(isLeaf: true))

        let key = Key.from(.component(decomposed), as: String.self)
        try depot.set(value: "fits", for: key)
        let composed = Key.from(.component(String(repeating: "\u{E9}", count: count)), as: String.self)
        #expect(try Self.depot(at: url, codec: codec).get(valueFor: composed) == "fits")
    }

    @Test("memory-only depots have no file-name limit and never probe the volume")
    func memoryOnlyDepots() throws {
        let probed = OSAllocatedUnfairLock(initialState: false)
        let depot = Depot(
            configuration: .inMemory(),
            overrides: .init(volumeSupportsCaseSensitiveNames: { _ in
                probed.withLock { $0 = true }
                return true
            }),
        )
        depot.register(key: Key.all, coder: .json() as AnyCoder<String>)
        let key = Key.from(.component(String(repeating: "x", count: 1000)), as: String.self)
        try depot.set(value: "long", for: key)
        #expect(try depot.get(valueFor: key) == "long")
        #expect(probed.withLock { $0 } == false)
    }

    // MARK: - Codec selection

    @Test(
        "the codec follows the volume's case sensitivity",
        arguments: [(true, DepotFileNameCodec.base64URL), (false, .base32), (nil, .platformFallback)]
            as [(Bool?, DepotFileNameCodec)],
    )
    func selectionByVolume(caseSensitive: Bool?, expected: DepotFileNameCodec) throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let depot = Self.depot(at: url, caseSensitive: caseSensitive)
        #expect(depot.fileManager?.fileNameCodec == expected)

        try depot.set(value: "v", for: Key.from("aaa" / "aaG", as: String.self))
        #expect(Self.userFiles(in: url) == ["\(expected.encode("aaa"))/\(expected.encode("aaG")).bin"])
        if expected == .base32 {
            let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567=/")
            for file in Self.userFiles(in: url) {
                #expect(file.hasSuffix(".bin"))
                #expect(file.dropLast(4).allSatisfy { allowed.contains($0) }, "\(file)")
            }
        }
        #expect(Self.hiddenItems(in: url).isSubset(of: Self.internalFileNames))
    }

    @Test("the volume is queried once per depot", arguments: [true, false, nil] as [Bool?])
    func volumeQueriedOnce(caseSensitive: Bool?) throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let queries = OSAllocatedUnfairLock(initialState: [URL]())
        let depot = Depot(
            configuration: .init(directoryURL: url, memoryCache: .disabled),
            overrides: .init(volumeSupportsCaseSensitiveNames: { queried in
                queries.withLock { $0.append(queried) }
                return caseSensitive
            }),
        )
        depot.register(key: Key.all, coder: .json() as AnyCoder<String>)
        try depot.set(value: "v", for: Key.from("a" / "b", as: String.self))
        #expect(try depot.get(valueFor: Key.from("a" / "b", as: String.self)) == "v")
        try depot.remove(valuesFor: Key.all)
        try depot.reset()
        #expect(queries.withLock { $0.count } == 1)
    }

    @Test("the fallback is Base32 on macOS, Mac Catalyst and the Simulator, and Base64url on devices")
    func platformFallback() {
        #if os(macOS) || targetEnvironment(macCatalyst) || targetEnvironment(simulator)
        #expect(DepotFileNameCodec.platformFallback == .base32)
        #else
        #expect(DepotFileNameCodec.platformFallback == .base64URL)
        #endif
    }

    @Test("a failed volume query selects the fallback and logs it", arguments: DepotFileNameCodec.allCases)
    func failedQuerySelectsFallback(fallback: DepotFileNameCodec) async throws {
        let url = Self.temporaryURL()
        let name = url.lastPathComponent

        let (selected, errors) = try await LogSinkTestLock.withExclusiveSink {
            let errors = OSAllocatedUnfairLock(initialState: [String]())
            DepotKitLogging.sink = .callback { level, message, _, _, _ in
                let message = message()
                guard level == .error, message.contains(name) else {
                    return
                }
                errors.withLock { $0.append(message) }
            }

            let selected = DepotFileNameCodec.select(
                volumeSupportsCaseSensitiveNames: nil,
                depotURL: url,
                fallback: fallback,
            )
            return (selected, errors.withLock { $0 })
        }

        #expect(selected == fallback)
        #expect(errors.count == 1)
        #expect(errors.first?.contains("case-sensitive") == true)
        #expect(errors.first?.contains("using \(fallback.displayName) file names") == true)
    }

    @Test("a known volume capability ignores the fallback", arguments: DepotFileNameCodec.allCases)
    func knownCapabilityIgnoresFallback(fallback: DepotFileNameCodec) {
        let url = Self.temporaryURL()
        #expect(
            DepotFileNameCodec.select(volumeSupportsCaseSensitiveNames: true, depotURL: url, fallback: fallback)
                == .base64URL
        )
        #expect(
            DepotFileNameCodec.select(volumeSupportsCaseSensitiveNames: false, depotURL: url, fallback: fallback)
                == .base32
        )
    }

    @Test("a depot whose volume query fails uses the platform fallback and logs an error")
    func failedQueryLogsError() async throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let name = url.lastPathComponent

        let errors = try await LogSinkTestLock.withExclusiveSink {
            let errors = OSAllocatedUnfairLock(initialState: [String]())
            DepotKitLogging.sink = .callback { level, message, _, _, _ in
                let message = message()
                guard level == .error, message.contains(name) else {
                    return
                }
                errors.withLock { $0.append(message) }
            }

            let depot = Self.depot(at: url, caseSensitive: nil)
            #expect(depot.fileManager?.fileNameCodec == DepotFileNameCodec.platformFallback)
            return errors.withLock { $0 }
        }

        #expect(errors.count == 1)
        #expect(errors.first?.contains("case-sensitive") == true)
        #expect(errors.first?.contains(DepotFileNameCodec.platformFallback.displayName) == true)
    }

    @Test("reopening on the same volume reads the stored values", arguments: [true, false, nil] as [Bool?])
    func reopenOnSameVolume(caseSensitive: Bool?) throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = Self.depot(at: url, caseSensitive: caseSensitive)
        try first.set(value: "lower", for: Key.from("aaa", as: String.self))
        try first.set(value: "upper", for: Key.from("aaG" / "x", as: String.self))

        let reopened = Self.depot(at: url, caseSensitive: caseSensitive)
        #expect(reopened.fileManager?.fileNameCodec == first.fileManager?.fileNameCodec)
        #expect(try reopened.get(valueFor: Key.from("aaa", as: String.self)) == "lower")
        #expect(try reopened.get(valueFor: Key.from("aaG" / "x", as: String.self)) == "upper")
        #expect(try reopened.count(for: Key.all) == 2)

        let readOnly = Self.depot(at: url, caseSensitive: caseSensitive, readOnly: true)
        #expect(readOnly.fileManager?.fileNameCodec == first.fileManager?.fileNameCodec)
        #expect(try readOnly.get(valueFor: Key.from("aaa", as: String.self)) == "lower")
        #expect(try readOnly.count(for: Key.all) == 2)
    }

    @Test("the codec is chosen from the volume, not from the store's contents")
    func selectionIgnoresStoreContents() throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try Self.depot(at: url, codec: .base64URL).set(value: "v", for: Key.from("aaa", as: String.self))
        #expect(Self.userFiles(in: url) == ["YWFh.bin"])

        // Files written with the other encoding are not decoded by guessing.
        let other = Self.depot(at: url, caseSensitive: false)
        #expect(other.fileManager?.fileNameCodec == .base32)
        #expect(try other.count(for: Key.all) == 0)
        #expect(try other.get(valueFor: Key.from("aaa", as: String.self)) == nil)
        #expect(Self.hiddenItems(in: url).isSubset(of: Self.internalFileNames))
    }

    @Test("read-only depots never create directories")
    func readOnlyDoesNotCreate() throws {
        let parent = Self.temporaryURL()
        let url = parent.appending(path: "nested/store")
        defer { try? FileManager.default.removeItem(at: parent) }

        let depot = Self.depot(at: url, caseSensitive: false, readOnly: true)
        #expect(depot.fileManager?.fileNameCodec == .base32)
        #expect(!FileManager.default.fileExists(atPath: parent.path(percentEncoded: false)))
        #expect(try depot.get(valueFor: Key.from("missing", as: String.self)) == nil)
        #expect(!FileManager.default.fileExists(atPath: parent.path(percentEncoded: false)))
    }

    @Test("the volume query uses the nearest existing ancestor without creating directories")
    func volumeQueryUsesAncestor() {
        let missing = Self.temporaryURL().appending(path: "a/b/c")
        let expected = DepotFileNameCodec.volumeSupportsCaseSensitiveNames(
            at: FileManager.default.temporaryDirectory
        )
        #expect(expected != nil)
        #expect(DepotFileNameCodec.volumeSupportsCaseSensitiveNames(at: missing) == expected)
        #expect(
            !FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path(percentEncoded: false))
        )
    }

    @Test(
        "real case-sensitive volume selects Base64url (set DEPOTKIT_CASE_SENSITIVE_VOLUME to a case-sensitive directory)",
        .enabled(if: ProcessInfo.processInfo.environment["DEPOTKIT_CASE_SENSITIVE_VOLUME"] != nil),
    )
    func realCaseSensitiveVolume() throws {
        let volume = try #require(ProcessInfo.processInfo.environment["DEPOTKIT_CASE_SENSITIVE_VOLUME"])
        let url = URL(filePath: volume, directoryHint: .isDirectory).appending(component: "Depot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DepotFileNameCodec.volumeSupportsCaseSensitiveNames(at: url) == true)

        // Real volume query, no override.
        let depot = Depot(configuration: .init(directoryURL: url, memoryCache: .disabled))
        depot.register(key: Key.all, coder: .json() as AnyCoder<String>)
        #expect(depot.fileManager?.fileNameCodec == .base64URL)

        try depot.set(value: "lower", for: Key.from("aaa", as: String.self))
        try depot.set(value: "upper", for: Key.from("aaG", as: String.self))
        #expect(Self.userFiles(in: url) == ["YWFH.bin", "YWFh.bin"])

        let reopened = Depot(configuration: .init(directoryURL: url, memoryCache: .disabled))
        reopened.register(key: Key.all, coder: .json() as AnyCoder<String>)
        #expect(reopened.fileManager?.fileNameCodec == .base64URL)
        #expect(try reopened.get(valueFor: Key.from("aaa", as: String.self)) == "lower")
        #expect(try reopened.get(valueFor: Key.from("aaG", as: String.self)) == "upper")
    }

    @Test("the real volume query selects the codec")
    func realVolumeSelection() throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        guard
            let caseSensitive = DepotFileNameCodec.volumeSupportsCaseSensitiveNames(
                at: FileManager.default.temporaryDirectory
            )
        else {
            Issue.record("The temporary directory's volume capability could not be determined")
            return
        }

        // Real volume query, no override.
        let depot = Depot(configuration: .init(directoryURL: url, memoryCache: .disabled))
        depot.register(key: Key.all, coder: .json() as AnyCoder<String>)
        #expect(depot.fileManager?.fileNameCodec == (caseSensitive ? .base64URL : .base32))

        try depot.set(value: "lower", for: Key.from("aaa", as: String.self))
        try depot.set(value: "upper", for: Key.from("aaG", as: String.self))
        #expect(Self.userFiles(in: url).count == 2)

        let reopened = Depot(configuration: .init(directoryURL: url, memoryCache: .disabled))
        reopened.register(key: Key.all, coder: .json() as AnyCoder<String>)
        #expect(reopened.fileManager?.fileNameCodec == depot.fileManager?.fileNameCodec)
        #expect(try reopened.get(valueFor: Key.from("aaa", as: String.self)) == "lower")
        #expect(try reopened.get(valueFor: Key.from("aaG", as: String.self)) == "upper")
    }

    @Test(
        "reset and removeAll keep the codec and create no extra internal files",
        arguments: DepotFileNameCodec.allCases
    )
    func resetKeepsCodec(codec: DepotFileNameCodec) throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let depot = Depot(
            configuration: .init(directoryURL: url, enableMultiProcessSupport: true, memoryCache: .disabled),
            overrides: .init(volumeSupportsCaseSensitiveNames: { _ in codec == .base64URL }),
        )
        depot.register(key: Key.all, coder: .json() as AnyCoder<String>)
        try depot.set(value: "before", for: Key.from("a", as: String.self))
        try depot.reset()
        #expect(Self.userFiles(in: url).isEmpty)
        #expect(Self.hiddenItems(in: url).isSubset(of: Self.internalFileNames))
        try depot.set(value: "after-reset", for: Key.from("b", as: String.self))
        #expect(Self.userFiles(in: url) == ["\(codec.encode("b")).bin"])

        try depot.transaction { tx in
            try tx.removeAll()
            try tx.set(value: "after-remove-all", for: Key.from("c", as: String.self))
        }
        #expect(Self.userFiles(in: url) == ["\(codec.encode("c")).bin"])

        try depot.removeAll()
        try depot.set(value: "final", for: Key.from("d", as: String.self))
        #expect(Self.userFiles(in: url) == ["\(codec.encode("d")).bin"])
        #expect(Self.hiddenItems(in: url).isSubset(of: Self.internalFileNames))

        let reopened = Self.depot(at: url, codec: codec)
        #expect(try reopened.get(valueFor: Key.from("d", as: String.self)) == "final")
        #expect(try reopened.count(for: Key.all) == 1)
        try reopened.verifyIntegrity()
    }

    @Test(
        "writes after the store directory was removed externally keep the codec",
        arguments: DepotFileNameCodec.allCases
    )
    func writeAfterExternalRemoval(codec: DepotFileNameCodec) throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let depot = Self.depot(at: url, codec: codec)
        try FileManager.default.removeItem(at: url)
        try depot.set(value: "v", for: Key.from("x" / "y", as: String.self))
        #expect(Self.userFiles(in: url) == ["\(codec.encode("x"))/\(codec.encode("y")).bin"])
        #expect(Self.hiddenItems(in: url).isSubset(of: Self.internalFileNames))
        #expect(try Self.depot(at: url, codec: codec).get(valueFor: Key.from("x" / "y", as: String.self)) == "v")
    }

    @Test("internal files are never enumerated as user keys", arguments: DepotFileNameCodec.allCases)
    func internalFilesAreHidden(codec: DepotFileNameCodec) throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let depot = Depot(
            configuration: .init(directoryURL: url, enableMultiProcessSupport: true, memoryCache: .disabled),
            overrides: .init(volumeSupportsCaseSensitiveNames: { _ in codec == .base64URL }),
        )
        depot.register(key: Key.all, coder: .json() as AnyCoder<String>)
        try depot.addFilePresenter()
        defer { try? depot.removeFilePresenter() }
        try depot.verifyIntegrity()
        try depot.set(value: "v", for: Key.from("k", as: String.self))

        #expect(try depot.count(for: Key.all) == 1)
        #expect(try depot.fileManager?.takeSnapshotOfModificationDates().keys.map(\.keyPath) == ["k"])
        #expect(try depot.diskUsage().fileCount == 1)
    }

    @Test("Unicode spellings agree after reopening with either codec", arguments: DepotFileNameCodec.allCases)
    func normalizationWithBothCodecs(codec: DepotFileNameCodec) throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try Self.depot(at: url, codec: codec)
            .set(value: "v", for: Key.from(.component("Cafe\u{301}") / "\u{212B}", as: String.self))

        let reopened = Self.depot(at: url, codec: codec)
        #expect(try reopened.get(valueFor: Key.from(.component("Caf\u{E9}") / "\u{C5}", as: String.self)) == "v")
        #expect(try reopened.count(for: Key.from(.component("Caf\u{E9}") / .wildcard)) == 1)
        try reopened.remove(valuesFor: Key.from("Caf\u{E9}" / .globstar))
        #expect(try reopened.count(for: Key.all) == 0)
    }
}

// MARK: - Key normalization

@Suite
struct KeyNormalizationTests {
    @Test("key constructors store NFC identifiers")
    func constructorsNormalize() {
        let decomposed = "e\u{301}"
        let nfc = Array("\u{E9}".utf8)

        func identifierBytes(_ key: some KeyProtocol) -> [[UInt8]] {
            key.components.compactMap {
                if case let .segment(identifier) = $0 { Array(identifier.utf8) } else { nil }
            }
        }

        #expect(identifierBytes(Key.from(.component(decomposed))) == [nfc])
        #expect(identifierBytes(Key.from("x" / decomposed)) == [Array("x".utf8), nfc])
        #expect(identifierBytes(Key.from(.component(decomposed) / .wildcard)) == [nfc])
        #expect(identifierBytes(Key([.segment(identifier: decomposed)])) == [nfc])
        #expect(identifierBytes(DistinctKey([.segment(identifier: decomposed)])) == [nfc])
        #expect(identifierBytes(TypedKey<Int>([.segment(identifier: decomposed)])) == [nfc])
        #expect(identifierBytes(TypedDistinctKey<Int>([.segment(identifier: decomposed)])) == [nfc])
        #expect(identifierBytes(Key.from("x").appending(decomposed)) == [Array("x".utf8), nfc])
        #expect(
            identifierBytes(KeyDefinition(path: .component(decomposed), coder: .json() as AnyCoder<Int>).key) == [nfc]
        )
        #expect(
            identifierBytes(
                PatternKeyDefinition(path: .component(decomposed) / .wildcard, coder: .json() as AnyCoder<Int>).key
            )
                == [nfc]
        )
        #expect(Array(Key.from(.component(decomposed)).keyPath.utf8) == nfc)
    }

    @Test("normalization does not fold case or compatibility characters")
    func noCaseFolding() {
        #expect(Key.from("A").components != Key.from("a").components)
        #expect(Key.from("\u{C5}").components != Key.from("\u{E5}").components)
        // NFC (not NFKC): the "fi" ligature stays distinct from "fi".
        #expect(Key.from("\u{FB01}").keyPath != "fi")
    }

    @Test("custom key types are normalized at the depot boundary")
    func customKeyProtocol() throws {
        struct CustomKey: TypedDistinctKeyProtocol {
            typealias Value = String
            let components: [KeyComponent]
            var isDistinct: Bool { true }
        }

        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let depot = Depot(configuration: .init(directoryURL: url, memoryCache: .disabled))
        depot.register(key: Key.all, coder: .json() as AnyCoder<String>)

        try depot.set(value: "custom", for: CustomKey(components: [.segment(identifier: "e\u{301}")]))
        #expect(try depot.get(valueFor: Key.from("\u{E9}", as: String.self)) == "custom")

        let reopened = Depot(configuration: .init(directoryURL: url, memoryCache: .disabled))
        reopened.register(key: Key.all, coder: .json() as AnyCoder<String>)
        #expect(try reopened.get(valueFor: CustomKey(components: [.segment(identifier: "\u{E9}")])) == "custom")
        #expect(try reopened.has(valuesFor: Key([.segment(identifier: "e\u{301}")])))
    }

    @Test(
        "custom key types render their NFC key path",
        arguments: [("\u{E9}", "e\u{301}"), ("\u{AC00}", "\u{1100}\u{1161}")]
    )
    func customKeyPath(canonical: String, decomposed: String) throws {
        struct CustomKey: TypedDistinctKeyProtocol {
            typealias Value = Int
            let components: [KeyComponent]
            var isDistinct: Bool { true }
        }

        struct CustomPattern: KeyProtocol {
            let components: [KeyComponent]
            var isDistinct: Bool { false }
        }

        let key = CustomKey(components: [.segment(identifier: "root"), .segment(identifier: decomposed)])
        #expect(Array(key.keyPath.utf8) == Array("root/\(canonical)".utf8))

        let pattern = CustomPattern(components: [.segment(identifier: decomposed), .globstar])
        #expect(Array(pattern.keyPath.utf8) == Array("\(canonical)/**".utf8))

        let depot = Depot()
        do {
            try depot.set(value: 1, for: key)
            Issue.record("Writing an unregistered key succeeded")
        } catch let DepotError.unregisteredKey(keyPath) {
            #expect(Array(keyPath.utf8) == Array("root/\(canonical)".utf8))
        }
    }
}
