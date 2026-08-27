import Foundation

enum GGUFFixture {
    enum MetadataValue {
        case uint32(UInt32)
        case float32(Float)
        case boolean(Bool)
        case string(String)
        case arrayString([String])
        case arrayUInt32([UInt32])
        case arrayFloat32([Float])

        var type: UInt32 {
            switch self {
            case .uint32: 4
            case .float32: 6
            case .boolean: 7
            case .string: 8
            case .arrayString, .arrayUInt32, .arrayFloat32: 9
            }
        }
    }

    static func write(
        type: UInt32,
        payloadSize: Int,
        to url: URL,
        tensorName: String = "test.weight",
        dimensions: [UInt64] = [256],
        payload: Data? = nil,
        metadata: [(String, MetadataValue)] = []
    ) throws {
        var data = Data()
        appendUInt32(0x46554747, to: &data)
        appendUInt32(3, to: &data)
        appendUInt64(1, to: &data)
        appendUInt64(UInt64(metadata.count), to: &data)
        for (key, value) in metadata {
            appendString(key, to: &data)
            appendUInt32(value.type, to: &data)
            appendValue(value, to: &data)
        }
        appendString(tensorName, to: &data)
        appendUInt32(UInt32(dimensions.count), to: &data)
        for dimension in dimensions {
            appendUInt64(dimension, to: &data)
        }
        appendUInt32(type, to: &data)
        appendUInt64(0, to: &data)
        while data.count % 32 != 0 {
            data.append(0)
        }
        let payload = payload ?? Data(repeating: 0, count: payloadSize)
        precondition(payload.count == payloadSize)
        data.append(payload)
        try data.write(to: url, options: .atomic)
    }

    private static func appendString(_ value: String, to data: inout Data) {
        let bytes = Array(value.utf8)
        appendUInt64(UInt64(bytes.count), to: &data)
        data.append(contentsOf: bytes)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        for byteIndex in 0..<8 {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(byteIndex * 8)))
        }
    }

    private static func appendValue(_ value: MetadataValue, to data: inout Data) {
        switch value {
        case let .uint32(value):
            appendUInt32(value, to: &data)
        case let .float32(value):
            appendUInt32(value.bitPattern, to: &data)
        case let .boolean(value):
            data.append(value ? 1 : 0)
        case let .string(value):
            appendString(value, to: &data)
        case let .arrayString(values):
            appendUInt32(8, to: &data)
            appendUInt64(UInt64(values.count), to: &data)
            values.forEach { appendString($0, to: &data) }
        case let .arrayUInt32(values):
            appendUInt32(4, to: &data)
            appendUInt64(UInt64(values.count), to: &data)
            values.forEach { appendUInt32($0, to: &data) }
        case let .arrayFloat32(values):
            appendUInt32(6, to: &data)
            appendUInt64(UInt64(values.count), to: &data)
            values.forEach { appendUInt32($0.bitPattern, to: &data) }
        }
    }
}
