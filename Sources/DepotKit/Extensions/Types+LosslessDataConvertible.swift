// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import Foundation

// MARK: - LosslessDataConvertible conformances for Foundation and Swift standard library types

extension Data: LosslessDataConvertible {
    public var dataRepresentation: Data? {
        self
    }

    public init?(dataRepresentation: Data) {
        self.init(dataRepresentation)
    }
}

extension Bool: LosslessDataConvertible {
    public var dataRepresentation: Data? {
        switch self {
        case false:
            UInt8(0).bigEndianData
        case true:
            UInt8(1).bigEndianData
        }
    }

    public init?(dataRepresentation: Data) {
        guard let value = UInt8(bigEndianDataRepresentation: dataRepresentation) else {
            return nil
        }
        switch value {
        case 0:
            self = false
        default:
            self = true
        }
    }
}

extension Int: LosslessDataConvertible {
    public var dataRepresentation: Data? {
        bigEndianData
    }

    public init?(dataRepresentation: Data) {
        guard let value = Int(bigEndianDataRepresentation: dataRepresentation) else {
            return nil
        }
        self = value
    }
}

extension UInt: LosslessDataConvertible {
    public var dataRepresentation: Data? {
        bigEndianData
    }

    public init?(dataRepresentation: Data) {
        guard let value = UInt(bigEndianDataRepresentation: dataRepresentation) else {
            return nil
        }
        self = value
    }
}

extension Int8: LosslessDataConvertible {
    public var dataRepresentation: Data? {
        bigEndianData
    }

    public init?(dataRepresentation: Data) {
        guard let value = Int8(bigEndianDataRepresentation: dataRepresentation) else {
            return nil
        }
        self = value
    }
}

extension Int16: LosslessDataConvertible {
    public var dataRepresentation: Data? {
        bigEndianData
    }

    public init?(dataRepresentation: Data) {
        guard let value = Int16(bigEndianDataRepresentation: dataRepresentation) else {
            return nil
        }
        self = value
    }
}

extension Int32: LosslessDataConvertible {
    public var dataRepresentation: Data? {
        bigEndianData
    }

    public init?(dataRepresentation: Data) {
        guard let value = Int32(bigEndianDataRepresentation: dataRepresentation) else {
            return nil
        }
        self = value
    }
}

extension Int64: LosslessDataConvertible {
    public var dataRepresentation: Data? {
        bigEndianData
    }

    public init?(dataRepresentation: Data) {
        guard let value = Int64(bigEndianDataRepresentation: dataRepresentation) else {
            return nil
        }
        self = value
    }
}

extension UInt8: LosslessDataConvertible {
    public var dataRepresentation: Data? {
        bigEndianData
    }

    public init?(dataRepresentation: Data) {
        guard let value = UInt8(bigEndianDataRepresentation: dataRepresentation) else {
            return nil
        }
        self = value
    }
}

extension UInt16: LosslessDataConvertible {
    public var dataRepresentation: Data? {
        bigEndianData
    }

    public init?(dataRepresentation: Data) {
        guard let value = UInt16(bigEndianDataRepresentation: dataRepresentation) else {
            return nil
        }
        self = value
    }
}

extension UInt32: LosslessDataConvertible {
    public var dataRepresentation: Data? {
        bigEndianData
    }

    public init?(dataRepresentation: Data) {
        guard let value = UInt32(bigEndianDataRepresentation: dataRepresentation) else {
            return nil
        }
        self = value
    }
}

extension UInt64: LosslessDataConvertible {
    public var dataRepresentation: Data? {
        bigEndianData
    }

    public init?(dataRepresentation: Data) {
        guard let value = UInt64(bigEndianDataRepresentation: dataRepresentation) else {
            return nil
        }
        self = value
    }
}

// Float/Double are stored via their IEEE 754 bit pattern in big-endian byte order.
extension Float: LosslessDataConvertible {
    public var dataRepresentation: Data? {
        bitPattern.bigEndianData
    }

    public init?(dataRepresentation: Data) {
        guard let bitPattern = UInt32(bigEndianDataRepresentation: dataRepresentation) else {
            return nil
        }
        self.init(bitPattern: bitPattern)
    }
}

extension Double: LosslessDataConvertible {
    public var dataRepresentation: Data? {
        bitPattern.bigEndianData
    }

    public init?(dataRepresentation: Data) {
        guard let bitPattern = UInt64(bigEndianDataRepresentation: dataRepresentation) else {
            return nil
        }
        self.init(bitPattern: bitPattern)
    }
}

extension String: LosslessDataConvertible {
    public var dataRepresentation: Data? {
        data(using: .utf8)
    }

    public init?(dataRepresentation: Data) {
        self.init(data: dataRepresentation, encoding: .utf8)
    }
}

extension URL: LosslessDataConvertible {
    public var dataRepresentation: Data? {
        absoluteString.dataRepresentation
    }

    public init?(dataRepresentation: Data) {
        guard let string = String(dataRepresentation: dataRepresentation) else {
            return nil
        }

        self.init(string: string)
    }
}

extension UUID: LosslessDataConvertible {
    public var dataRepresentation: Data? {
        uuidString.dataRepresentation
    }

    public init?(dataRepresentation: Data) {
        guard let uuidString = String(dataRepresentation: dataRepresentation) else {
            return nil
        }

        self.init(uuidString: uuidString)
    }
}

extension Date: LosslessDataConvertible {
    public var dataRepresentation: Data? {
        timeIntervalSinceReferenceDate.dataRepresentation
    }

    public init?(dataRepresentation: Data) {
        guard let timeIntervalSinceReferenceDate = Double(dataRepresentation: dataRepresentation) else {
            return nil
        }

        self.init(timeIntervalSinceReferenceDate: timeIntervalSinceReferenceDate)
    }
}

extension RawRepresentable where RawValue: LosslessDataConvertible {
    public var dataRepresentation: Data? {
        rawValue.dataRepresentation
    }

    public init?(dataRepresentation: Data) {
        guard let rawValue = RawValue(dataRepresentation: dataRepresentation) else {
            return nil
        }

        self.init(rawValue: rawValue)
    }
}

// MARK: - Internal

extension FixedWidthInteger {
    var bigEndianData: Data {
        withUnsafeBytes(of: bigEndian) { Data($0) }
    }

    init(bigEndianData: Data) {
        precondition(
            bigEndianData.count >= MemoryLayout<Self>.size,
            "bigEndianData must be at least \(MemoryLayout<Self>.size) bytes for \(Self.self)",
        )
        self = bigEndianData.withUnsafeBytes { $0.loadUnaligned(as: Self.self).bigEndian }
    }

    init?(bigEndianDataRepresentation data: Data) {
        guard data.count >= MemoryLayout<Self>.size else {
            return nil
        }
        self = data.withUnsafeBytes { $0.loadUnaligned(as: Self.self).bigEndian }
    }
}
