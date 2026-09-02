// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

// MARK: - Read / Write / Exists / Remove

extension Depot {
    /// Returns the value for a distinct key, or `nil` if no value exists or it has expired.
    ///
    /// - Parameter key: A typed distinct key identifying the value.
    /// - Returns: The decoded value, or `nil` if absent or expired.
    /// - Throws: ``DepotError/reservedKey(keyPath:)`` if the key is reserved,
    ///   ``DepotError/mismatchedTypes(keyPath:expected:actual:)`` on type mismatch,
    ///   or a decoding error from the registered coder.

    public func get<V>(valueFor key: some TypedDistinctKeyProtocol<V>) throws -> V? {
        LOG(level: .debug, message: "Depot[\(label)] get '\(key)'")
        guard key.components != metadataKey.components else {
            throw DepotError.reservedKey(keyPath: key.keyPath)
        }

        let distinctKey = DistinctKey(key)
        let now = clock.now()

        // Memory-only path
        if let memoryEntries {
            guard let entry = memoryEntries.withLock({ $0[distinctKey] }) else {
                return nil
            }
            // Lazy expiry check
            if let expiresAt = entry.expiresAt, now >= expiresAt {
                return nil
            }
            guard let value = entry.value as? V else {
                throw DepotError.mismatchedTypes(
                    keyPath: distinctKey.keyPath,
                    expected: "\(V.self)",
                    actual: "\(type(of: entry.value))",
                )
            }
            return value
        }

        // Fast path: check memory cache without depot lock
        if let memoryCache {
            switch memoryCache.lookup(valueFor: distinctKey, at: now) as DepotMemoryCache.CacheLookupResult<V> {
            case let .hit(value):
                LOG(level: .debug, message: "Depot[\(label)] cache hit for \(key)")
                return value
            case .confirmedAbsent:
                LOG(level: .debug, message: "Depot[\(label)] cache miss (absent) for \(key)")
                return nil
            case .expired, .miss:
                break
            }
        }

        // Slow path: read from disk under lock
        return try lock.withReadLock {
            // Re-check cache inside lock (another thread may have populated it)
            if let memoryCache {
                switch memoryCache.lookup(valueFor: distinctKey, at: now) as DepotMemoryCache.CacheLookupResult<V> {
                case let .hit(value):
                    return value
                case .confirmedAbsent:
                    return nil
                case .expired:
                    LOG(level: .debug, message: "Depot[\(label)] cache expired for \(key)")
                    memoryCache.markExpired(for: distinctKey)
                    return nil
                case .miss:
                    break
                }
            }

            let fileURL = distinctKey.getFileURL(from: configuration.directoryURL!)

            let fileData: Data
            do {
                fileData = try Data(
                    contentsOf: fileURL,
                    options: configuration.cacheInMemory ? .uncached : .mappedIfSafe,
                )
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                LOG(level: .debug, message: "Depot[\(label)] get \(key): no file on disk")
                memoryCache?.set(value: nil as V?, for: distinctKey, expiresAt: nil)
                return nil
            }

            guard let (header, valueData) = try FileHeader.parseAndValidate(fileData, at: now) else {
                LOG(level: .debug, message: "Depot[\(label)] get \(key): expired")
                memoryCache?.markExpired(for: distinctKey)
                return nil
            }

            let value: V = try core.coder(for: distinctKey.key, as: V.self).decode(valueData)

            memoryCache?.set(
                value: value,
                for: distinctKey,
                cost: fileData.count,
                expiresAt: header?.expiresAt
            )

            LOG(level: .debug, message: "Depot[\(label)] get \(key): read \(fileData.count) bytes from disk")
            return value
        }
    }

    /// Returns all values matching a key pattern, skipping expired entries.
    ///
    /// - Parameter key: A typed key that may contain wildcards.
    /// - Returns: An array of decoded values. Empty if no matches exist.
    /// - Throws: ``DepotError/mismatchedTypes(keyPath:expected:actual:)`` on type mismatch,
    ///   or a decoding error from the registered coder.

    public func get<V>(valuesFor key: some TypedKeyProtocol<V>) throws -> [V] {
        // Memory-only path
        if let memoryEntries {
            let now = clock.now()
            let matches = memoryEntries.withLock { entries in
                entries.filter { key.matches($0.key) }
            }
            var values = [V]()
            for (distinctKey, entry) in matches {
                if let expiresAt = entry.expiresAt, now >= expiresAt {
                    continue
                }
                guard let value = entry.value as? V else {
                    throw DepotError.mismatchedTypes(
                        keyPath: distinctKey.keyPath,
                        expected: "\(V.self)",
                        actual: "\(type(of: entry.value))",
                    )
                }
                values.append(value)
            }
            return values
        }

        return try lock.withReadLock {
            let now = clock.now()
            var values = [V]()
            let files = try fileManager!.files(for: key)

            for (fileURL, fileKey) in files {
                if let memoryCache {
                    switch memoryCache.lookup(valueFor: fileKey, at: now) as DepotMemoryCache.CacheLookupResult<V> {
                    case let .hit(value):
                        values.append(value)
                        continue
                    case .confirmedAbsent:
                        continue
                    case .expired:
                        memoryCache.markExpired(for: fileKey)
                        continue
                    case .miss:
                        break
                    }
                }

                let fileData = try Data(
                    contentsOf: fileURL,
                    options: configuration.cacheInMemory ? .uncached : .mappedIfSafe,
                )

                guard let (header, valueData) = try FileHeader.parseAndValidate(fileData, at: now) else {
                    memoryCache?.markExpired(for: fileKey)
                    continue
                }

                let value = try core.coder(for: fileKey.key, as: V.self).decode(valueData)
                memoryCache?.set(
                    value: value,
                    for: fileKey,
                    cost: fileData.count,
                    expiresAt: header?.expiresAt
                )
                values.append(value)
            }

            return values
        }
    }

    /// Returns all decodable values matching a key pattern, collecting per-key errors instead of throwing.
    ///
    /// Unlike ``get(valuesFor:)``, this method does not throw when individual
    /// values fail to decode — it collects them in ``AvailableValuesResult/keyedErrors``.
    ///
    /// - Parameter key: A typed key that may contain wildcards.
    /// - Returns: An ``AvailableValuesResult`` containing decoded values and any per-key errors.

    public func get<V>(availableValuesFor key: some TypedKeyProtocol<V>) throws -> AvailableValuesResult<V> {
        // Memory-only path
        if let memoryEntries {
            let now = clock.now()
            let matches = memoryEntries.withLock { entries in
                entries.filter { key.matches($0.key) }
            }
            var keyedValues = [DistinctKey: V]()
            var keyedErrors = [DistinctKey: any Error & Sendable]()
            for (distinctKey, entry) in matches {
                if let expiresAt = entry.expiresAt, now >= expiresAt {
                    continue
                }
                if let value = entry.value as? V {
                    keyedValues[distinctKey] = value
                } else {
                    keyedErrors[distinctKey] = DepotError.mismatchedTypes(
                        keyPath: distinctKey.keyPath,
                        expected: "\(V.self)",
                        actual: "\(type(of: entry.value))",
                    )
                }
            }
            return AvailableValuesResult(keyedValues: keyedValues, keyedErrors: keyedErrors)
        }

        return try lock.withReadLock {
            let now = clock.now()
            var keyedValues = [DistinctKey: V]()
            var keyedErrors = [DistinctKey: any Error & Sendable]()
            let files = try fileManager!.files(for: key)

            for (fileURL, fileKey) in files {
                if let memoryCache {
                    switch memoryCache.lookup(valueFor: fileKey, at: now) as DepotMemoryCache.CacheLookupResult<V> {
                    case let .hit(value):
                        keyedValues[fileKey] = value
                        continue
                    case .confirmedAbsent:
                        continue
                    case .expired:
                        memoryCache.markExpired(for: fileKey)
                        continue
                    case .miss:
                        break
                    }
                }

                do {
                    let fileData = try Data(
                        contentsOf: fileURL,
                        options: configuration.cacheInMemory ? .uncached : .mappedIfSafe,
                    )

                    guard let (header, valueData) = try FileHeader.parseAndValidate(fileData, at: now) else {
                        memoryCache?.markExpired(for: fileKey)
                        continue
                    }

                    let value = try core.coder(for: fileKey.key, as: V.self).decode(valueData)
                    memoryCache?.set(
                        value: value,
                        for: fileKey,
                        cost: fileData.count,
                        expiresAt: header?.expiresAt
                    )
                    keyedValues[fileKey] = value
                } catch {
                    keyedErrors[fileKey] = error
                }
            }

            return AvailableValuesResult(keyedValues: keyedValues, keyedErrors: keyedErrors)
        }
    }

    /// Stores a value for a distinct key, or removes it when `value` is `nil`.
    ///
    /// Writes are atomic on disk. Observers are notified after the write completes.
    ///
    /// - Parameters:
    ///   - value: The value to store, or `nil` to remove.
    ///   - key: A typed distinct key identifying the value.
    /// - Throws: ``DepotError/readOnlyDepot`` if the depot is read-only,
    ///   ``DepotError/reservedKey(keyPath:)`` if the key is reserved,
    ///   or an encoding error from the registered coder.

    public func set<V>(value: V?, for key: some TypedDistinctKeyProtocol<V>) throws {
        LOG(level: .debug, message: "Depot[\(label)] set '\(key)' \u{2192} \(value == nil ? "nil" : "value")")
        guard !configuration.readOnly else {
            throw DepotError.readOnlyDepot
        }

        guard key.components != metadataKey.components else {
            throw DepotError.reservedKey(keyPath: key.keyPath)
        }

        let distinctKey = DistinctKey(key)

        // Memory-only path
        if let memoryEntries {
            if let value {
                let now = clock.now()
                let expiry = core.expiry(for: distinctKey)
                let expiresAt = expiry.map { now.addingTimeInterval($0.timeInterval) }
                memoryEntries.withLock {
                    $0[distinctKey] = MemoryEntry(value: value, modifiedAt: now, expiresAt: expiresAt)
                }
            } else {
                _ = memoryEntries.withLock { $0.removeValue(forKey: distinctKey) }
            }

            if let value {
                core.notifyObservers(updated: distinctKey, with: value, in: self)
            } else {
                core.notifyObservers(removed: distinctKey, in: self)
            }
            return
        }

        // File-backed path
        let (resolvedCoder, resolvedExpiry): (AnyCoder<V>, Duration?) =
            if value != nil {
                try core.coderAndExpiry(for: distinctKey.key, as: V.self)
            } else {
                (try core.coder(for: distinctKey.key, as: V.self), nil)
            }

        let encodedData =
            if let value {
                try resolvedCoder.encode(value)
            } else {
                nil as Data?
            }

        try lock.withWriteLock {
            let fileURL = distinctKey.getFileURL(from: configuration.directoryURL!)

            if let encodedData {
                let now = clock.now()
                let expiresAt = resolvedExpiry.map { now.addingTimeInterval($0.timeInterval) }
                let crc32 = CRC32.checksum(encodedData)
                let header = FileHeader(modifiedAt: now, expiresAt: expiresAt, crc32: crc32)
                let fileData = header.serialized() + encodedData

                try fileManager!.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                )

                try fileData.write(to: fileURL, options: .atomic)
                LOG(level: .debug, message: "Depot[\(label)] set \(key): wrote \(fileData.count) bytes")

                let modificationDate = updateResourceValues(at: fileURL)
                changeTracker?.modified(key: distinctKey, at: modificationDate)

                memoryCache?.set(
                    value: value,
                    for: distinctKey,
                    cost: fileData.count,
                    expiresAt: expiresAt
                )
            } else {
                try fileManager!.removeItem(at: fileURL)
                schedulePrune()
                LOG(level: .debug, message: "Depot[\(label)] set \(key): removed (nil value)")

                changeTracker?.removed(key: distinctKey)
                memoryCache?.set(value: nil as V?, for: distinctKey, expiresAt: nil)
            }

            do {
                try fileManager!.touchLock()
            } catch {
                LOG(
                    level: .error,
                    message: "Depot[\(label)] failed to touch lock for multi process support due to error \(error)",
                )
            }

            pruneIfNeeded()
        }

        if let value {
            core.notifyObservers(updated: distinctKey, with: value, in: self)
        } else {
            core.notifyObservers(removed: distinctKey, in: self)
        }
    }

    /// Returns whether at least one non-expired value exists for the key.
    ///
    /// - Parameter key: A key that may contain wildcards.
    /// - Returns: `true` if at least one matching, non-expired value exists.
    public func has(valuesFor key: some KeyProtocol) throws -> Bool {
        LOG(level: .debug, message: "Depot[\(label)] has '\(key)'")

        // Memory-only path
        if let memoryEntries {
            let now = clock.now()
            return memoryEntries.withLock { entries in
                entries.contains { entryKey, entry in
                    guard key.matches(entryKey) else {
                        return false
                    }
                    if let expiresAt = entry.expiresAt, now >= expiresAt {
                        return false
                    }
                    return true
                }
            }
        }

        return try lock.withReadLock {
            if let memoryCache, let hasValue = memoryCache.has(valuesFor: key, at: clock.now()) {
                return hasValue
            }

            let files = try fileManager!.files(for: key)
            let now = clock.now()
            for (fileURL, _) in files where FileHeader.isNonExpired(at: fileURL, now: now) == true {
                return true
            }
            return false
        }
    }

    /// Returns the number of values matching a key without decoding them.
    ///
    /// Only non-expired values are counted.
    ///
    /// - Parameter key: A key that may contain wildcards.
    /// - Returns: The count of non-expired values matching the key.
    public func count(for key: some KeyProtocol) throws -> Int {
        LOG(level: .debug, message: "Depot[\(label)] count '\(key)'")

        // Memory-only path
        if let memoryEntries {
            let now = clock.now()
            return memoryEntries.withLock { entries in
                entries.count { entryKey, entry in
                    guard key.matches(entryKey) else {
                        return false
                    }
                    if let expiresAt = entry.expiresAt, now >= expiresAt {
                        return false
                    }
                    return true
                }
            }
        }

        return try lock.withReadLock {
            let files = try fileManager!.files(for: key)
            let now = clock.now()
            var count = 0
            for (fileURL, _) in files where FileHeader.isNonExpired(at: fileURL, now: now) == true {
                count += 1
            }
            return count
        }
    }

    /// Removes all values matching a key pattern.
    ///
    /// Passing ``Key/all`` removes every value in the depot (equivalent to ``removeAll()``).
    /// Observers are notified after removal.
    ///
    /// - Parameter key: A key that may contain wildcards.
    /// - Throws: ``DepotError/readOnlyDepot`` if the depot is read-only.
    public func remove(valuesFor key: some KeyProtocol) throws {
        LOG(level: .debug, message: "Depot[\(label)] remove '\(key)'")
        guard !configuration.readOnly else {
            throw DepotError.readOnlyDepot
        }

        // Memory-only path
        if let memoryEntries {
            memoryEntries.withLock { entries in
                let keysToRemove = entries.keys.filter { key.matches($0) }
                for k in keysToRemove {
                    entries.removeValue(forKey: k)
                }
            }
            core.notifyObservers(removed: key, in: self)
            return
        }

        // File-backed path
        guard key.components != [.globstar] else {
            LOG(level: .debug, message: "Depot[\(label)] remove all values (reset)")
            try reset()
            return
        }
        try lock.withWriteLock {
            try fileManager!.removeFiles(for: key)
            schedulePrune()

            changeTracker?.removed(key: key)

            do {
                try fileManager!.touchLock()
            } catch {
                LOG(
                    level: .error,
                    message: "Depot[\(label)] failed to touch lock for multi process support due to error \(error)",
                )
            }

            // cacheInMemory
            memoryCache?.remove(valuesFor: key)

            pruneIfNeeded()
        }

        core.notifyObservers(removed: key, in: self)
    }

    // MARK: - Convenience

    /// Returns the stored value or a default when no value exists.
    public func get<V>(
        valueFor key: some TypedDistinctKeyProtocol<V>,
        default defaultValue: @autoclosure () -> V,
    ) throws -> V where V: Sendable {
        try get(valueFor: key) ?? defaultValue()
    }

    /// Returns whether a value exists for a single distinct key.
    public func has(valueFor key: some DistinctKeyProtocol) throws -> Bool {
        try has(valuesFor: key)
    }

    /// Removes the value stored for a single distinct key.
    public func remove(valueFor key: some DistinctKeyProtocol) throws {
        try remove(valuesFor: key)
    }

    /// Removes **all** values stored in the depot.
    public func removeAll() throws {
        try remove(valuesFor: Key.all)
    }

    // MARK: - Async

    /// Asynchronously returns the value for a distinct key, or `nil` if no value exists.
    public func get<V>(valueFor key: some TypedDistinctKeyProtocol<V>) async throws -> V? where V: Sendable {
        try await withSemaphore { try self.get(valueFor: key) }
    }

    /// Asynchronously returns all values matching a key, or an empty array if none exist.
    public func get<V>(valuesFor key: some TypedKeyProtocol<V>) async throws -> [V] where V: Sendable {
        try await withSemaphore { try self.get(valuesFor: key) }
    }

    /// Asynchronously returns all decodable values matching a key along with per-key errors.
    public func get<V>(
        availableValuesFor key: some TypedKeyProtocol<V>,
    ) async throws -> AvailableValuesResult<V> where V: Sendable {
        try await withSemaphore { try self.get(availableValuesFor: key) }
    }

    /// Asynchronously sets (or removes) the value for a distinct key.
    public func set<V>(value: V?, for key: some TypedDistinctKeyProtocol<V>) async throws where V: Sendable {
        try await withSemaphore { try self.set(value: value, for: key) }
    }

    /// Asynchronously checks whether at least one value exists for the key.
    public func has(valuesFor key: some KeyProtocol) async throws -> Bool {
        try await withSemaphore { try self.has(valuesFor: key) }
    }

    /// Asynchronously returns the number of values matching a key without decoding them.
    public func count(for key: some KeyProtocol) async throws -> Int {
        try await withSemaphore { try self.count(for: key) }
    }

    /// Asynchronously removes the value(s) matching the key.
    public func remove(valuesFor key: some KeyProtocol) async throws {
        try await withSemaphore { try self.remove(valuesFor: key) }
    }

    /// Returns the stored value or a default when no value exists.
    public func get<V>(
        valueFor key: some TypedDistinctKeyProtocol<V>,
        default defaultValue: @autoclosure () -> V,
    ) async throws -> V where V: Sendable {
        try await get(valueFor: key) ?? defaultValue()
    }

    /// Asynchronously checks whether a value exists for a distinct key.
    public func has(valueFor key: some DistinctKeyProtocol) async throws -> Bool {
        try await has(valuesFor: key)
    }

    /// Asynchronously removes the value for a distinct key.
    public func remove(valueFor key: some DistinctKeyProtocol) async throws {
        try await remove(valuesFor: key)
    }

    /// Asynchronously removes all values in the depot.
    public func removeAll() async throws {
        try await remove(valuesFor: Key.all)
    }

    // MARK: - Modify

    /// Atomically reads, modifies, and writes back a value for a distinct key.
    @discardableResult
    public func modify<V>(
        valueFor key: some TypedDistinctKeyProtocol<V>,
        action: (_ currentValue: V?) throws -> ModifyAction<V>,
    ) throws -> V? where V: Sendable {
        try transaction { transaction in
            let current = try transaction.get(valueFor: key)
            switch try action(current) {
            case .keep:
                return current
            case let .update(newValue):
                try transaction.set(value: newValue, for: key)
                return newValue
            case .remove:
                try transaction.set(value: nil, for: key)
                return nil
            }
        }
    }

    /// Asynchronously reads, modifies, and writes back a value for a distinct key.
    @discardableResult
    public func modify<V>(
        valueFor key: some TypedDistinctKeyProtocol<V>,
        action: @escaping @Sendable (_ currentValue: V?) throws -> ModifyAction<V>,
    ) async throws -> V? where V: Sendable {
        try await transaction { transaction in
            let current = try transaction.get(valueFor: key)
            switch try action(current) {
            case .keep:
                return current
            case let .update(newValue):
                try transaction.set(value: newValue, for: key)
                return newValue
            case .remove:
                try transaction.set(value: nil, for: key)
                return nil
            }
        }
    }

    // MARK: - Metadata

    /// Returns the metadata for a stored value, or `nil` if no value exists or it has expired.
    public func metadata(for key: some DistinctKeyProtocol) throws -> ValueMetadata? {
        let distinctKey = DistinctKey(key)

        // Memory-only path
        if let memoryEntries {
            guard let entry = memoryEntries.withLock({ $0[distinctKey] }) else {
                return nil
            }
            if let expiresAt = entry.expiresAt, clock.now() >= expiresAt {
                return nil
            }
            return ValueMetadata(modifiedAt: entry.modifiedAt, expiresAt: entry.expiresAt)
        }

        // File-backed path
        return lock.withReadLock {
            let fileURL = distinctKey.getFileURL(from: configuration.directoryURL!)

            guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
                return nil
            }
            defer { try? handle.close() }

            guard let headerData = try? handle.read(upToCount: FileHeader.size) else {
                return nil
            }

            guard let header = try? FileHeader.parse(headerData) else {
                return nil
            }

            if header.isExpired(at: clock.now()) {
                return nil
            }

            return ValueMetadata(modifiedAt: header.modifiedAt, expiresAt: header.expiresAt)
        }
    }

    /// Asynchronously returns the metadata for a stored value.
    public func metadata(for key: some DistinctKeyProtocol) async throws -> ValueMetadata? {
        try await withSemaphore { try self.metadata(for: key) }
    }

    // MARK: - Expiry

    /// Removes all expired values from the depot.
    ///
    /// Returns the number of entries removed. Fires observer notifications for
    /// each removed key.
    @discardableResult
    public func removeExpired() throws -> Int {
        guard !configuration.readOnly else {
            throw DepotError.readOnlyDepot
        }

        // Memory-only path
        if let memoryEntries {
            let now = clock.now()
            let expired = memoryEntries.withLock { entries in
                let expired = entries.filter { _, entry in
                    guard let expiresAt = entry.expiresAt else {
                        return false
                    }
                    return now >= expiresAt
                }.map(\.key)
                for key in expired {
                    entries.removeValue(forKey: key)
                }
                return expired
            }
            for key in expired {
                core.notifyObservers(removed: key, in: self)
            }
            return expired.count
        }

        // File-backed path
        let now = clock.now()
        var expiredKeys = [DistinctKey]()

        try lock.withWriteLock {
            let files = try fileManager!.files(for: Key.all)

            for (fileURL, fileKey) in files {
                guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
                    continue
                }
                defer { try? handle.close() }
                guard let headerData = try? handle.read(upToCount: FileHeader.size),
                    let header = try? FileHeader.parse(headerData),
                    header.isExpired(at: now)
                else {
                    continue
                }

                do {
                    try fileManager!.removeItem(at: fileURL)
                    changeTracker?.removed(key: fileKey)
                    memoryCache?.remove(valuesFor: fileKey)
                    expiredKeys.append(fileKey)
                } catch {
                    LOG(
                        level: .error,
                        message:
                            "Depot[\(label)] removeExpired: failed to delete \(fileURL.lastPathComponent): \(error)"
                    )
                }
            }

            if !expiredKeys.isEmpty {
                try? fileManager!.pruneEmptyDirectories()
                try? fileManager!.touchLock()
            }
        }

        for key in expiredKeys {
            core.notifyObservers(removed: key, in: self)
        }

        return expiredKeys.count
    }

    /// Asynchronously removes all expired values from the depot.
    @discardableResult
    public func removeExpired() async throws -> Int {
        try await withSemaphore { try self.removeExpired() }
    }
}
