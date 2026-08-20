import AppKit
import Foundation

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

        let layerInfo = makeLayerInfo(layers: layers, width: width, height: height)
        var layerAndMask = Data()
        appendUInt32(UInt32(layerInfo.count), to: &layerAndMask)
        layerAndMask.append(layerInfo)
        appendUInt32(0, to: &layerAndMask)

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
        appendUInt32(UInt32(layerAndMask.count), to: &data)
        data.append(layerAndMask)
        data.append(mergedImageData(mergedImage, width: width, height: height))
        try data.write(to: url, options: .atomic)
    }

    private func makeLayerInfo(layers: [PSDLayer], width: Int, height: Int) -> Data {
        var records = Data()
        var channels = Data()
        for layer in layers.reversed() {
            let pixels = rgbaBytes(layer.image, width: width, height: height)
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

            for channel in [0, 1, 2, 3] {
                appendUInt16(0, to: &channels)
                channels.append(contentsOf: channelBytes(pixels, channel: channel))
            }
        }
        var output = Data()
        appendInt16(Int16(layers.count), to: &output)
        output.append(records)
        output.append(channels)
        if output.count % 2 != 0 { output.append(0) }
        return output
    }

    private func mergedImageData(_ image: CGImage, width: Int, height: Int) -> Data {
        let pixels = rgbaBytes(image, width: width, height: height)
        var data = Data()
        appendUInt16(0, to: &data)
        for channel in [0, 1, 2, 3] {
            data.append(contentsOf: channelBytes(pixels, channel: channel))
        }
        return data
    }

    private func rgbaBytes(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var pixels = Array(repeating: UInt8(0), count: width * height * 4)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return pixels }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private func channelBytes(_ pixels: [UInt8], channel: Int) -> [UInt8] {
        stride(from: channel, to: pixels.count, by: 4).map { pixels[$0] }
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
