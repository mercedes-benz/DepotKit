// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation
import os

// MARK: - Logging

/// The severity levels used by DepotKit's logging infrastructure.
public enum DepotKitLogLevel: Equatable, Sendable {
    case info
    case debug
    case notice
    case error
}

/// Log sink for DepotKit.
///
/// To forward logging to your own system, set ``DepotKitLogging/sink`` (e.g. in app startup).
public protocol DepotKitLogSink: Sendable {
    func log(
        _ level: DepotKitLogLevel,
        _ message: () -> String,
        file: StaticString,
        function: StaticString,
        line: UInt,
    )
}

/// Global configuration for DepotKit logging.
///
/// Assign a ``DepotKitLogSink`` to ``sink`` to receive log output.
/// No messages are emitted until a sink is set.
public enum DepotKitLogging {
    private struct State: Sendable {
        var sink: (any DepotKitLogSink)?
    }

    private static let state = OSAllocatedUnfairLock(uncheckedState: State(sink: nil))

    /// The currently configured sink.
    ///
    /// Defaults to `nil`.
    public static var sink: (any DepotKitLogSink)? {
        get { state.withLock { $0.sink } }
        set { state.withLock { $0.sink = newValue } }
    }
}

/// Default sink using Apple's `os.Logger`.
public struct DepotKitOSLogSink: DepotKitLogSink {
    private let logger: Logger
    private let osLog: OSLog
    private let includeSourceLocation: Bool

    /// Creates a sink that logs to the unified OS logging system.
    ///
    /// - Parameters:
    ///   - subsystem: The subsystem identifier passed to `os.Logger`. Defaults to `"DepotKit"`.
    ///   - category: The category passed to `os.Logger`. Defaults to `"DepotKit"`.
    ///   - includeSourceLocation: When `true`, each message is prefixed with the file, line and function name. Defaults to `false`.
    public init(subsystem: String = "DepotKit", category: String = "DepotKit", includeSourceLocation: Bool = false) {
        logger = Logger(subsystem: subsystem, category: category)
        osLog = OSLog(subsystem: subsystem, category: category)
        self.includeSourceLocation = includeSourceLocation
    }

    /// Forwards the message to the underlying `os.Logger` at the corresponding log type.
    ///
    /// The message closure is only evaluated if the OS log level is enabled for the configured subsystem.
    public func log(
        _ level: DepotKitLogLevel,
        _ message: () -> String,
        file: StaticString,
        function: StaticString,
        line: UInt,
    ) {
        let type: OSLogType =
            switch level {
            case .info:
                .info
            case .debug:
                .debug
            case .notice:
                .default
            case .error:
                .error
            }

        // Avoid evaluating the message unless the system log is actually enabled.
        guard osLog.isEnabled(type: type) else {
            return
        }

        let prefix = includeSourceLocation ? "[\(file):\(line) \(function)] " : ""
        let finalMessage = "\(prefix)\(message())"

        switch level {
        case .info:
            logger.info("\(finalMessage, privacy: .public)")
        case .debug:
            logger.debug("\(finalMessage, privacy: .public)")
        case .notice:
            logger.notice("\(finalMessage, privacy: .public)")
        case .error:
            logger.error("\(finalMessage, privacy: .public)")
        }
    }
}

/// A sink backed by a single closure (useful for forwarding to another logging framework).
public struct DepotKitCallbackLogSink: DepotKitLogSink {
    /// The signature of the closure that receives log events.
    public typealias Handler =
        @Sendable (
            _ level: DepotKitLogLevel, _ message: () -> String, _ file: StaticString,
            _ function: StaticString, _ line: UInt
        ) -> Void

    @usableFromInline
    let handler: Handler

    /// Creates a callback sink with the given handler.
    public init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    /// Forwards the log event to the stored ``Handler``.
    @inlinable
    @inline(__always)
    public func log(
        _ level: DepotKitLogLevel,
        _ message: () -> String,
        file: StaticString,
        function: StaticString,
        line: UInt,
    ) {
        handler(level, message, file, function, line)
    }
}

// MARK: - Sink Factories

extension DepotKitLogSink where Self == DepotKitOSLogSink {
    /// A sink that forwards to Apple's unified logging system (`os.Logger`).
    ///
    /// Usage:
    /// ```swift
    /// DepotKitLogging.sink = .osLog()
    /// DepotKitLogging.sink = .osLog(subsystem: "com.example", category: "Storage")
    /// ```
    public static func osLog(
        subsystem: String = "DepotKit",
        category: String = "DepotKit",
        includeSourceLocation: Bool = false,
    ) -> DepotKitOSLogSink {
        DepotKitOSLogSink(subsystem: subsystem, category: category, includeSourceLocation: includeSourceLocation)
    }
}

extension DepotKitLogSink where Self == DepotKitCallbackLogSink {
    /// A sink backed by a closure — useful for bridging to another logging framework.
    ///
    /// Usage:
    /// ```swift
    /// DepotKitLogging.sink = .callback { level, message, file, function, line in
    ///     myLogger.log(level: level, "\(message())")
    /// }
    /// ```
    public static func callback(
        _ handler: @escaping DepotKitCallbackLogSink.Handler,
    ) -> DepotKitCallbackLogSink {
        DepotKitCallbackLogSink(handler)
    }
}

@inlinable
@inline(__always)
func LOG(
    level: DepotKitLogLevel,
    message: @autoclosure () -> String,
    functionName: StaticString = #function,
    fileName: StaticString = #file,
    line: UInt = #line,
) {
    DepotKitLogging.sink?.log(level, message, file: fileName, function: functionName, line: line)
}
