import CoreGraphics
import Foundation
import ImageIO
import MangaKitchenCore
import UniformTypeIdentifiers
@preconcurrency import WebKit

final class AssetSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var assetURLs: [String: URL] = [:]

    func updatePages(_ pages: [ComicPage]) {
        var values: [String: URL] = [:]
        for page in pages {
            let id = page.id.uuidString.lowercased()
            values["\(id)/source"] = page.sourceURL
            if let maskURL = page.maskURL {
                values["\(id)/mask"] = maskURL
            }
            if let backgroundURL = page.backgroundURL {
                values["\(id)/background"] = backgroundURL
            }
            if let translationPreviewURL = page.translationPreviewURL {
                values["\(id)/translation-preview"] = translationPreviewURL
            }
            if let outputURL = page.outputURL {
                values["\(id)/output"] = outputURL
            }
        }
        lock.withLock {
            assetURLs = values
        }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let host = requestURL.host?.lowercased() else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let path = requestURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let key = "\(host)/\(path)"
        let fileURL = lock.withLock { assetURLs[key] }
        guard let fileURL else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        do {
            let didAccess = fileURL.startAccessingSecurityScopedResource()
            defer { if didAccess { fileURL.stopAccessingSecurityScopedResource() } }
            let isMaskPreview = path == "mask"
            let data = isMaskPreview
                ? try Self.makeMaskPreviewData(from: fileURL)
                : try Data(contentsOf: fileURL)
            let mimeType = isMaskPreview
                ? "image/png"
                : UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
                    ?? "application/octet-stream"
            let response = URLResponse(
                url: requestURL,
                mimeType: mimeType,
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private static func makeMaskPreviewData(from fileURL: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let mask = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw URLError(.cannotDecodeContentData)
        }

        let width = mask.width
        let height = mask.height
        let grayscaleBytesPerRow = ((width + 15) / 16) * 16
        guard let grayscaleContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: grayscaleBytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw URLError(.cannotDecodeContentData)
        }
        grayscaleContext.interpolationQuality = .none
        grayscaleContext.setShouldAntialias(false)
        grayscaleContext.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let grayscaleData = grayscaleContext.data else {
            throw URLError(.cannotDecodeContentData)
        }

        let maskPixels = grayscaleData.assumingMemoryBound(to: UInt8.self)
        var previewPixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let alpha = maskPixels[row * grayscaleContext.bytesPerRow + column]
                let destination = (row * width + column) * 4
                previewPixels[destination] = UInt8(Int(alpha) * 239 / 255)
                previewPixels[destination + 1] = UInt8(Int(alpha) * 68 / 255)
                previewPixels[destination + 2] = UInt8(Int(alpha) * 68 / 255)
                previewPixels[destination + 3] = alpha
            }
        }

        guard let provider = CGDataProvider(data: Data(previewPixels) as CFData),
              let preview = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw URLError(.cannotDecodeContentData)
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw URLError(.cannotCreateFile)
        }
        CGImageDestinationAddImage(destination, preview, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw URLError(.cannotCreateFile)
        }
        return output as Data
    }
}
