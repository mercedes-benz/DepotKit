// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing

@testable import DepotKit

@Suite
struct FileCoordinatingTests {
    let fm = FileManager.default
    let baseURL: URL

    init() {
        baseURL = fm.temporaryDirectory.appending(component: UUID().uuidString)
        try? fm.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    // MARK: - Coordinated Read

    @Test("coordinated read returns accessor result")
    func coordinatedReadReturnsResult() throws {
        let fileURL = baseURL.appending(component: "read.txt")
        let content = Data("hello".utf8)
        fm.createFile(atPath: fileURL.path, contents: content)

        let result: Data = try fm.coordinate(
            readingItemAt: fileURL,
            filePresenter: nil,
            options: [],
            byAccessor: { url in
                try Data(contentsOf: url)
            }
        )

        #expect(result == content)
    }

    @Test("coordinated read propagates accessor error")
    func coordinatedReadPropagatesError() {
        let fileURL = baseURL.appending(component: "nonexistent.txt")

        #expect(throws: (any Error).self) {
            try fm.coordinate(
                readingItemAt: fileURL,
                filePresenter: nil,
                options: [],
                byAccessor: { url in
                    try Data(contentsOf: url)
                }
            )
        }
    }

    // MARK: - Coordinated Write

    @Test("coordinated write returns accessor result")
    func coordinatedWriteReturnsResult() throws {
        let fileURL = baseURL.appending(component: "write.txt")
        let content = Data("world".utf8)

        let bytesWritten: Int = try fm.coordinate(
            writingItemAt: fileURL,
            filePresenter: nil,
            options: [],
            byAccessor: { url in
                try content.write(to: url)
                return content.count
            }
        )

        #expect(bytesWritten == 5)
        #expect(fm.fileExists(atPath: fileURL.path))
    }

    @Test("coordinated write propagates accessor error")
    func coordinatedWritePropagatesError() {
        let fileURL = baseURL.appending(component: "sub/deep/nested/file.txt")

        #expect(throws: (any Error).self) {
            let _: Void = try fm.coordinate(
                writingItemAt: fileURL,
                filePresenter: nil,
                options: [],
                byAccessor: { url in
                    // Writing to a path whose parent doesn't exist should fail
                    try Data("x".utf8).write(to: url, options: .withoutOverwriting)
                }
            )
        }
    }

    // MARK: - Synchronize

    @Test("synchronize creates lock file")
    func synchronizeCreatesLockFile() throws {
        let lockURL = baseURL.appending(component: "lock/depot.lock")

        try fm.synchronize(withLockAt: lockURL, filePresenter: nil, touch: false) {}

        #expect(fm.fileExists(atPath: lockURL.path))
    }

    @Test("synchronize touches lock file modification date")
    func synchronizeTouchesLockFile() throws {
        let lockURL = baseURL.appending(component: "touch/depot.lock")

        // Create the lock file with an old date
        try fm.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: lockURL.path, contents: nil)
        let oldDate = Date.distantPast
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: lockURL.path)

        try fm.synchronize(withLockAt: lockURL, filePresenter: nil, touch: true) {}

        let attrs = try fm.attributesOfItem(atPath: lockURL.path)
        let modDate = attrs[.modificationDate] as! Date
        #expect(modDate > oldDate)
    }

    @Test("synchronize propagates closure error")
    func synchronizePropagatesError() {
        let lockURL = baseURL.appending(component: "err/depot.lock")

        #expect(throws: TestError.self) {
            try fm.synchronize(withLockAt: lockURL, filePresenter: nil, touch: false) {
                throw TestError()
            }
        }
    }

    @Test("synchronize throws if lock path is a directory")
    func synchronizeThrowsIfDirectory() throws {
        let lockURL = baseURL.appending(component: "dirlock")
        try fm.createDirectory(at: lockURL, withIntermediateDirectories: true)

        #expect(throws: CocoaError.self) {
            try fm.synchronize(withLockAt: lockURL, filePresenter: nil, touch: false) {}
        }
    }
}

private struct TestError: Error {}
