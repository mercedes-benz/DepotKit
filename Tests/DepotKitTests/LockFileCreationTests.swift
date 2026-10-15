// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import Testing
import os

@testable import DepotKit

/// A coordinated critical section must not run without the shared lock file: other processes are
/// signaled through it, and a missing lock file would go unnoticed until the next write.
@Suite("Lock file creation failures", .offCooperativePool)
struct LockFileCreationTests {
    /// A file manager that fails to create files, like a full or read-only volume.
    final class FailingFileManager: FileManager {
        override func createFile(
            atPath path: String,
            contents data: Data?,
            attributes attr: [FileAttributeKey: Any]? = nil,
        ) -> Bool {
            false
        }
    }

    let depotURL: URL

    init() throws {
        depotURL = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: depotURL, withIntermediateDirectories: true)
    }

    private var lockURL: URL {
        depotURL.appending(component: "\(Depot.HiddenKeyPrefix)LOCK")
    }

    @Test("synchronize does not run the critical section when the lock file cannot be created")
    func synchronizeThrows() {
        let ran = OSAllocatedUnfairLock(initialState: false)

        #expect(throws: CocoaError.self) {
            try FailingFileManager().synchronize(withLockAt: lockURL, filePresenter: nil, touch: true) {
                ran.withLock { $0 = true }
            }
        }
        #expect(!ran.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: lockURL.path(percentEncoded: false)))
    }

    @Test("the presenter reports a lock file that cannot be created")
    func presenterThrows() {
        let presenter = DepotFilePresenter(
            depotURL: depotURL,
            enableMultiProcessSupport: true,
            fileManager: FailingFileManager(),
        )
        let ran = OSAllocatedUnfairLock(initialState: false)

        #expect(throws: CocoaError.self) {
            try presenter.synchronizeWithLock(touch: true) {
                ran.withLock { $0 = true }
            }
        }
        #expect(throws: CocoaError.self) {
            try presenter.touchLock()
        }
        #expect(throws: CocoaError.self) {
            try presenter.addFilePresenter()
        }
        presenter.removeFilePresenter()

        #expect(!ran.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: lockURL.path(percentEncoded: false)))
    }

    @Test("an existing lock file is used even when files cannot be created")
    func existingLockFile() throws {
        #expect(FileManager.default.createFile(atPath: lockURL.path(percentEncoded: false), contents: nil))
        let presenter = DepotFilePresenter(
            depotURL: depotURL,
            enableMultiProcessSupport: true,
            fileManager: FailingFileManager(),
        )

        let result = try presenter.synchronizeWithLock(touch: true) { 42 }
        #expect(result == 42)
        try presenter.touchLock()
    }
}
