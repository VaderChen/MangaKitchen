import AppKit
import Foundation

// 由 run.sh 編譯實際 exporter；只建立合成圖，不讀取使用者專案或載入模型。
@main
enum OutputPerformanceBenchmark {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 3 else {
            fatalError("Usage: benchmark psd OUTPUT WIDTH HEIGHT LAYERS | copy SOURCE OUTPUT")
        }
        let start: Date
        let output: URL
        switch arguments[0] {
        case "psd":
            guard arguments.count == 5,
                  let width = Int(arguments[2]), width > 0,
                  let height = Int(arguments[3]), height > 0,
                  let count = Int(arguments[4]), count > 0 else {
                fatalError("PSD requires positive width, height and layer count")
            }
            output = URL(fileURLWithPath: arguments[1])
            let layers = try (0..<count).map { index in
                try autoreleasepool {
                    PSDLayer(name: index == 0 ? "底圖" : "Ink \(index)",
                        image: try makeImage(width: width, height: height, seed: index),
                        opacity: index == 0 ? 255 : 137, visible: index == 0)
                }
            }
            start = Date()
            try PSDExporter().write(layers: layers, mergedImage: layers[0].image, to: output)
        case "copy":
            let source = URL(fileURLWithPath: arguments[1])
            output = URL(fileURLWithPath: arguments[2])
            start = Date()
#if STREAMING_OUTPUT
            try AtomicFileWriter.copy(from: source, to: output)
#else
            try Data(contentsOf: source).write(to: output, options: .atomic)
#endif
        default:
            fatalError("Unknown benchmark mode")
        }
        let elapsed = Date().timeIntervalSince(start)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        print("mode=\(arguments[0]) seconds=\(elapsed) bytes=\(attributes[.size] ?? 0)")
    }

    static func makeImage(width: Int, height: Int, seed: Int) throws -> CGImage {
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    let alpha = [0, 64, 128, 255][(x + y + seed) % 4]
                    buffer[offset] = UInt8((x * 31 + y * 17 + seed * 47) % 256 * alpha / 255)
                    buffer[offset + 1] = UInt8((x * 11 + y * 43 + seed * 29) % 256 * alpha / 255)
                    buffer[offset + 2] = UInt8((x * 53 + y * 7 + seed * 13) % 256 * alpha / 255)
                    buffer[offset + 3] = UInt8(alpha)
                }
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw CocoaError(.coderInvalidValue)
        }
        return image
    }
}
