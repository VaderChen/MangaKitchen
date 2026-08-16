import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CGImageIO {
    static func load(from url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw ImageProcessingError.unreadableImage(url)
        }
        return image
    }

    static func dimensions(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        return (width.intValue, height.intValue)
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageProcessingError.cannotCreateOutput(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageProcessingError.cannotCreateOutput(url)
        }
    }
}

public enum ImageProcessingError: LocalizedError, Sendable {
    case unreadableImage(URL)
    case cannotCreateBitmap
    case cannotCreateOutput(URL)
    case metalLibraryCompilation(String)
    case metalPipelineCreation
    case metalTextureCreation
    case metalCommandFailed

    public var errorDescription: String? {
        switch self {
        case let .unreadableImage(url): "無法讀取圖片：\(url.path)"
        case .cannotCreateBitmap: "無法建立圖片 Bitmap Context。"
        case let .cannotCreateOutput(url): "無法輸出圖片：\(url.path)"
        case let .metalLibraryCompilation(message): "Metal Kernel 編譯失敗：\(message)"
        case .metalPipelineCreation: "無法建立 Metal Compute Pipeline。"
        case .metalTextureCreation: "無法建立 Metal Texture。"
        case .metalCommandFailed: "Metal Command Buffer 執行失敗。"
        }
    }
}
