import Foundation
import UniformTypeIdentifiers
@preconcurrency import WebKit

final class WebUISchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    static let scheme = "mangakitchen-ui"
    static let host = "app"

    private let resourceRoot: URL?

    override init() {
        self.resourceRoot = Self.locateResourceRoot()
        super.init()
    }

    var canServeResources: Bool { resourceRoot != nil }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              requestURL.scheme == Self.scheme,
              requestURL.host == Self.host,
              let resourceRoot,
              let relativePath = normalizedRelativePath(from: requestURL) else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        let fileURL = resourceRoot.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = resourceRoot.path.hasSuffix("/") ? resourceRoot.path : resourceRoot.path + "/"
        guard fileURL.path.hasPrefix(rootPath),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
                ?? fallbackMIMEType(for: fileURL.pathExtension)
            let response = URLResponse(
                url: requestURL,
                mimeType: mimeType,
                expectedContentLength: data.count,
                textEncodingName: isText(fileURL.pathExtension) ? "utf-8" : nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private static func locateResourceRoot() -> URL? {
        if let packaged = Bundle.main.resourceURL?
            .appendingPathComponent("WebUI", isDirectory: true),
           FileManager.default.fileExists(atPath: packaged.appendingPathComponent("index.html").path) {
            return packaged.standardizedFileURL
        }
        return Bundle.module.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "WebUI"
        )?.deletingLastPathComponent().standardizedFileURL
    }

    private func normalizedRelativePath(from url: URL) -> String? {
        let path = (url.path.removingPercentEncoding ?? url.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty, !path.split(separator: "/").contains("..") else { return nil }
        return path
    }

    private func fallbackMIMEType(for extensionName: String) -> String {
        switch extensionName.lowercased() {
        case "html": "text/html"
        case "js": "text/javascript"
        case "css": "text/css"
        case "json": "application/json"
        case "svg": "image/svg+xml"
        default: "application/octet-stream"
        }
    }

    private func isText(_ extensionName: String) -> Bool {
        ["html", "js", "css", "json", "svg"].contains(extensionName.lowercased())
    }
}
