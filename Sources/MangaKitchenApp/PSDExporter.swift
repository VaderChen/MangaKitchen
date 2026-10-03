import AppKit
import Foundation
import MangaKitchenCore

struct PSDLayer {
    let name: String
    let image: CGImage
    let opacity: UInt8
    let visible: Bool
}

struct PSDExporter {
    func write(layers: [PSDLayer], mergedImage: CGImage, to url: URL) throws {
        guard !layers.isEmpty else { throw PSDExportError.noLayers }
        let width = mergedImage.width
        let height = mergedImage.height
        guard layers.allSatisfy({ $0.image.width == width && $0.image.height == height }) else {
            throw PSDExportError.inconsistentDimensions
        }

        let records = makeLayerRecords(layers: layers, width: width, height: height)
        let pixelCount = width * height
        let unpaddedLayerInfoSize = 2 + records.count + layers.count * 4 * (pixelCount + 2)
        let layerInfoSize = unpaddedLayerInfoSize + unpaddedLayerInfoSize % 2

        var data = Data()
        appendASCII("8BPS", to: &data)
        appendUInt16(1, to: &data)
        data.append(contentsOf: repeatElement(UInt8(0), count: 6))
        appendUInt16(4, to: &data)
        appendUInt32(UInt32(height), to: &data)
        appendUInt32(UInt32(width), to: &data)
        appendUInt16(8, to: &data)
        appendUInt16(3, to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(UInt32(layerInfoSize + 8), to: &data)
        appendUInt32(UInt32(layerInfoSize), to: &data)
        appendInt16(Int16(layers.count), to: &data)
        data.append(records)

        try AtomicFileWriter.write(to: url) { staged in
            try data.write(to: staged, options: .withoutOverwriting)
            let output = try FileHandle(forWritingTo: staged)
            defer { try? output.close() }
            try output.seekToEnd()
            // 只保留目前圖層的 RGBA 與 64 KiB 通道緩衝，不組裝整份 PSD。
            var channelBuffer = Data(count: min(pixelCount, 65_536))
            for layer in layers.reversed() {
                try autoreleasepool {
                    try writeChannels(layer.image, width: width, height: height,
                        layerCompression: true, buffer: &channelBuffer, to: output)
                }
            }
            if unpaddedLayerInfoSize != layerInfoSize {
                try output.write(contentsOf: Data([0]))
            }
            // 空的 global layer mask，以及 merged image 的 raw compression 標記。
            try output.write(contentsOf: Data(repeating: 0, count: 6))
            try writeChannels(mergedImage, width: width, height: height,
                layerCompression: false, buffer: &channelBuffer, to: output)
            try output.close()
        }
    }

    private func makeLayerRecords(layers: [PSDLayer], width: Int, height: Int) -> Data {
        var records = Data()
        for layer in layers.reversed() {
            appendInt32(0, to: &records)
            appendInt32(0, to: &records)
            appendInt32(Int32(height), to: &records)
            appendInt32(Int32(width), to: &records)
            appendUInt16(4, to: &records)
            for channelID in [Int16(0), 1, 2, -1] {
                appendInt16(channelID, to: &records)
                appendUInt32(UInt32(width * height + 2), to: &records)
            }
            appendASCII("8BIM", to: &records)
            appendASCII("norm", to: &records)
            records.append(layer.opacity)
            records.append(0)
            records.append(layer.visible ? 0 : 2)
            records.append(0)

            var extra = Data()
            appendUInt32(0, to: &extra)
            appendUInt32(0, to: &extra)
            let name = Array(layer.name.prefix(255).utf8)
            extra.append(UInt8(name.count))
            extra.append(contentsOf: name)
            while extra.count % 4 != 0 { extra.append(0) }
            appendUInt32(UInt32(extra.count), to: &records)
            records.append(extra)
        }
        return records
    }

    private func writeChannels(
        _ image: CGImage,
        width: Int,
        height: Int,
        layerCompression: Bool,
        buffer: inout Data,
        to output: FileHandle
    ) throws {
        try Task.checkCancellation()
        let pixels = rgbaBytes(image, width: width, height: height)
        let pixelCount = width * height
        try pixels.withUnsafeBufferPointer { source in
            for channel in 0..<4 {
                if layerCompression { try output.write(contentsOf: Data([0, 0])) }
                var start = 0
                while start < pixelCount {
                    try Task.checkCancellation()
                    let count = min(buffer.count, pixelCount - start)
                    buffer.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
                        for index in 0..<count {
                            destination[index] = source[(start + index) * 4 + channel]
                        }
                    }
                    try output.write(contentsOf: buffer.prefix(count))
                    start += count
                }
            }
        }
    }

    private func rgbaBytes(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var pixels = Array(repeating: UInt8(0), count: width * height * 4)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else { return }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    private func appendASCII(_ value: String, to data: inout Data) {
        data.append(contentsOf: value.utf8)
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private func appendInt16(_ value: Int16, to data: inout Data) {
        appendUInt16(UInt16(bitPattern: value), to: &data)
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private func appendInt32(_ value: Int32, to data: inout Data) {
        appendUInt32(UInt32(bitPattern: value), to: &data)
    }
}

enum PSDExportError: LocalizedError {
    case noLayers
    case inconsistentDimensions

    var errorDescription: String? {
        switch self {
        case .noLayers: "沒有可輸出的 PSD 圖層。"
        case .inconsistentDimensions: "PSD 圖層尺寸不一致。"
        }
    }
}
