import Foundation
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
            let data = try Data(contentsOf: fileURL)
            let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
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
}
