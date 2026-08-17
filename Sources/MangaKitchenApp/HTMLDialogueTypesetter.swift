import AppKit
import Foundation
import ImageIO
import MangaKitchenCore
@preconcurrency import WebKit

actor HTMLDialogueTypesetter: DialogueTypesetting {
    private struct RegionPayload: Encodable {
        var sourceText: String
        var translatedText: String
        var bounds: NormalizedRect
        var bubbleBounds: NormalizedRect?
        var translationAnchor: NormalizedPoint?
        var translationBounds: NormalizedRect?
        var style: DialogueStyle
    }

    private var renderer: HTMLTypesettingRenderer?
    private var rendererInUse = false
    private var rendererWaiters: [CheckedContinuation<Void, Never>] = []

    func typeset(
        backgroundURL: URL,
        regions: [DialogueRegion],
        outputURL: URL
    ) async throws {
        guard let source = CGImageSourceCreateWithURL(backgroundURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw HTMLDialogueTypesetterError.invalidBackground(backgroundURL)
        }

        let payload = regions
            .filter { !$0.translatedText.isEmpty }
            .map {
                RegionPayload(
                    sourceText: $0.sourceText,
                    translatedText: $0.translatedText,
                    bounds: $0.bounds,
                    bubbleBounds: $0.bubbleBounds,
                    translationAnchor: $0.translationAnchor,
                    translationBounds: $0.translationBounds,
                    style: $0.style
                )
            }
        let payloadData = try JSONEncoder().encode(payload)
        let html = Self.document(
            backgroundURL: backgroundURL,
            regionsBase64: payloadData.base64EncodedString(),
            width: width.intValue,
            height: height.intValue
        )
        let temporaryURL = backgroundURL.deletingLastPathComponent()
            .appendingPathComponent(".mangakitchen-typesetting-\(UUID().uuidString)")
            .appendingPathExtension("html")
        try html.write(to: temporaryURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        await acquireRenderer()
        defer { releaseRenderer() }
        try Task.checkCancellation()
        let renderer = await typesettingRenderer()
        try await renderer.render(
            htmlURL: temporaryURL,
            readAccessURL: backgroundURL.deletingLastPathComponent(),
            outputURL: outputURL,
            width: width.intValue,
            height: height.intValue
        )
    }

    private func typesettingRenderer() async -> HTMLTypesettingRenderer {
        if let renderer { return renderer }
        let renderer = await HTMLTypesettingRenderer()
        self.renderer = renderer
        return renderer
    }

    private func acquireRenderer() async {
        guard rendererInUse else {
            rendererInUse = true
            return
        }
        await withCheckedContinuation { continuation in
            rendererWaiters.append(continuation)
        }
    }

    private func releaseRenderer() {
        guard !rendererWaiters.isEmpty else {
            rendererInUse = false
            return
        }
        rendererWaiters.removeFirst().resume()
    }

    private static func document(
        backgroundURL: URL,
        regionsBase64: String,
        width: Int,
        height: Int
    ) -> String {
        let backgroundSource = htmlEscaped(backgroundURL.absoluteString)
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            * { box-sizing: border-box; }
            html, body {
              width: \(width)px;
              height: \(height)px;
              margin: 0;
              overflow: hidden;
              background: transparent;
            }
            #canvas, #background, #translation-layer {
              position: absolute;
              inset: 0;
              width: 100%;
              height: 100%;
            }
            #background { object-fit: fill; }
            #translation-layer { line-height: normal; pointer-events: none; }
            .translation-text {
              position: absolute;
              display: flex;
              align-items: center;
              justify-content: center;
              padding: 3px;
              color: #111;
              line-height: 1.16;
              text-align: center;
              white-space: pre-wrap;
              overflow-wrap: anywhere;
              overflow: hidden;
              transform: translate(-50%, -50%);
            }
            .translation-text.vertical {
              writing-mode: vertical-rl;
              text-orientation: mixed;
            }
          </style>
        </head>
        <body>
          <div id="canvas">
            <img id="background" src="\(backgroundSource)" alt="">
            <div id="translation-layer"></div>
          </div>
          <script>
            const pixelWidth = \(width);
            const pixelHeight = \(height);
            const encodedRegions = "\(regionsBase64)";
            const bytes = Uint8Array.from(atob(encodedRegions), character => character.charCodeAt(0));
            const regions = JSON.parse(new TextDecoder().decode(bytes));

            function clamp(value, minimum, maximum) {
              return Math.min(maximum, Math.max(minimum, value));
            }

            function translationLayoutBounds(region) {
              return region.translationBounds ?? region.bubbleBounds ?? region.bounds;
            }

            function translationAnchor(region) {
              if (region.translationAnchor) return region.translationAnchor;
              const bounds = translationLayoutBounds(region);
              return { x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2 };
            }

            function resolvedTranslationDirection(region) {
              if (region.style.writingDirection !== "automatic") return region.style.writingDirection;
              const hasCJK = /[\\u3000-\\u30ff\\u3400-\\u9fff\\uf900-\\ufaff]/u.test(
                `${region.sourceText}${region.translatedText}`
              );
              return hasCJK && (region.sourceText.includes("　")
                || region.bounds.height > region.bounds.width * 0.8)
                ? "vertical"
                : "horizontal";
            }

            function translationSourceFontSize(region) {
              const sourceCount = Math.max(
                1,
                [...region.sourceText].filter(character => !/\\s/u.test(character)).length
              );
              const bounds = translationLayoutBounds(region);
              const sourceArea = Math.max(
                1,
                bounds.width * pixelWidth * bounds.height * pixelHeight
              );
              const minimum = Math.max(4, region.style.minimumFontSize ?? 9);
              const maximum = Math.min(
                512,
                Math.max(minimum, region.style.maximumFontSize ?? 40)
              );
              return region.style.fontSize
                ?? clamp(Math.sqrt(sourceArea / sourceCount) * 1.08, minimum, maximum);
            }

            function fitAutomaticTranslationText(element, region) {
              if (region.style.fontSize != null || !element.clientWidth || !element.clientHeight) return;
              let lower = Math.max(3, region.style.minimumFontSize ?? 4);
              let upper = Math.max(lower, region.style.maximumFontSize ?? 40);
              for (let index = 0; index < 10; index += 1) {
                const candidate = (lower + upper) / 2;
                element.style.fontSize = `${candidate}px`;
                if (element.scrollWidth <= element.clientWidth + 1
                    && element.scrollHeight <= element.clientHeight + 1) {
                  lower = candidate;
                } else {
                  upper = candidate;
                }
              }
              element.style.fontSize = `${lower}px`;
            }

            function renderRegions() {
              const layer = document.querySelector("#translation-layer");
              for (const region of regions) {
                const bounds = translationLayoutBounds(region);
                const anchor = translationAnchor(region);
                const element = document.createElement("div");
                element.className = `translation-text ${resolvedTranslationDirection(region)}`;
                element.textContent = region.translatedText;
                element.style.left = `${anchor.x * 100}%`;
                element.style.top = `${anchor.y * 100}%`;
                element.style.width = `${Math.max(0.01, bounds.width) * 100}%`;
                element.style.height = `${Math.max(0.01, bounds.height) * 100}%`;
                element.style.fontFamily = region.style.fontName;
                element.style.fontSize = `${translationSourceFontSize(region)}px`;
                element.style.fontWeight = region.style.fontWeight === "bold" ? "700" : "400";
                element.style.color = region.style.textColorHex;
                layer.append(element);
                fitAutomaticTranslationText(element, region);
              }
            }

            window.mangaKitchenReady = (async () => {
              const background = document.querySelector("#background");
              if (!background.complete) {
                await new Promise((resolve, reject) => {
                  background.addEventListener("load", resolve, { once: true });
                  background.addEventListener("error", reject, { once: true });
                });
              } else if (!background.naturalWidth) {
                throw new Error("Background image failed to load.");
              }
              await document.fonts.ready;
              renderRegions();
              document.body.getBoundingClientRect();
              return true;
            })();
            window.mangaKitchenTypesettingState = { status: "pending", error: "" };
            window.mangaKitchenReady.then(
              () => { window.mangaKitchenTypesettingState.status = "ready"; },
              error => {
                window.mangaKitchenTypesettingState.status = "failed";
                window.mangaKitchenTypesettingState.error = String(error?.message ?? error);
              }
            );
          </script>
        </body>
        </html>
        """
    }

    private static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

@MainActor
private final class HTMLTypesettingRenderer: NSObject, WKNavigationDelegate {
    private static let operationTimeoutNanoseconds: UInt64 = 30_000_000_000
    private let webView: WKWebView
    private let window: NSWindow
    private var activeNavigation: WKNavigation?
    private var navigationCompletion: ((Result<Void, Error>) -> Void)?
    private var activeOperationFailure: ((Error) -> Void)?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let initialFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
        webView = WKWebView(frame: initialFrame, configuration: configuration)
        window = NSWindow(
            contentRect: initialFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        super.init()
        webView.navigationDelegate = self
        window.contentView = webView
        window.isExcludedFromWindowsMenu = true
        window.orderOut(nil)
    }

    func render(
        htmlURL: URL,
        readAccessURL: URL,
        outputURL: URL,
        width: Int,
        height: Int
    ) async throws {
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        webView.frame = frame
        window.setContentSize(frame.size)

        try await load(webView, htmlURL: htmlURL, readAccessURL: readAccessURL)
        try await waitUntilReady(webView)

        let snapshotConfiguration = WKSnapshotConfiguration()
        snapshotConfiguration.rect = frame
        snapshotConfiguration.snapshotWidth = NSNumber(value: width)
        let pngData: Data = try await awaitWebKitOperation(
            named: "建立排版截圖",
            webView: webView
        ) { completion in
            webView.takeSnapshot(with: snapshotConfiguration) { image, error in
                if let error {
                    completion(.failure(error))
                } else if let image {
                    let result: Result<Data, Error> = autoreleasepool {
                        Result { try Self.pngData(from: image) }
                    }
                    completion(result)
                } else {
                    completion(.failure(HTMLDialogueTypesetterError.snapshotFailed))
                }
            }
        }
        try pngData.write(to: outputURL, options: .atomic)
    }

    private func load(_ webView: WKWebView, htmlURL: URL, readAccessURL: URL) async throws {
        defer {
            activeNavigation = nil
            navigationCompletion = nil
        }
        try await awaitWebKitOperation(named: "載入 HTML 排版頁面", webView: webView) {
            completion in
            navigationCompletion = completion
            activeNavigation = webView.loadFileURL(
                htmlURL,
                allowingReadAccessTo: readAccessURL
            )
        }
    }

    private func waitUntilReady(_ webView: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try Task.checkCancellation()
            let state: String = try await awaitWebKitOperation(
                named: "讀取 HTML 排版狀態",
                webView: webView
            ) { completion in
                webView.evaluateJavaScript(
                    """
                    (() => {
                      const state = window.mangaKitchenTypesettingState;
                      return state ? `${state.status}\\n${state.error ?? ""}` : "pending\\n";
                    })()
                    """
                ) { value, error in
                    if let error {
                        let details = (error as NSError).userInfo["WKJavaScriptExceptionMessage"]
                            as? String ?? error.localizedDescription
                        completion(.failure(HTMLDialogueTypesetterError.javaScriptFailed(details)))
                    } else if let value = value as? String {
                        completion(.success(value))
                    } else {
                        completion(.failure(HTMLDialogueTypesetterError.invalidJavaScriptState))
                    }
                }
            }
            let components = state.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            switch components.first {
            case "ready":
                return
            case "failed":
                let message = components.count > 1 ? String(components[1]) : "未知錯誤"
                throw HTMLDialogueTypesetterError.javaScriptFailed(message)
            default:
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        webView.stopLoading()
        throw HTMLDialogueTypesetterError.operationTimedOut("等待 HTML 排版完成")
    }

    private func awaitWebKitOperation<Value: Sendable>(
        named operationName: String,
        webView: WKWebView,
        start: (_ completion: @escaping (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        let gate = ContinuationGate<Value>()
        activeOperationFailure = { error in
            gate.resume(.failure(error))
        }
        let timeoutTask = Task { @MainActor [weak webView] in
            do {
                try await Task.sleep(nanoseconds: Self.operationTimeoutNanoseconds)
            } catch {
                return
            }
            webView?.stopLoading()
            gate.resume(.failure(HTMLDialogueTypesetterError.operationTimedOut(operationName)))
        }
        defer {
            timeoutTask.cancel()
            activeOperationFailure = nil
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                start { result in
                    gate.resume(result)
                }
            }
        } onCancel: {
            gate.resume(.failure(CancellationError()))
            Task { @MainActor [weak webView] in
                webView?.stopLoading()
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === activeNavigation else { return }
        navigationCompletion?(.success(()))
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        guard navigation === activeNavigation else { return }
        navigationCompletion?(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        guard navigation === activeNavigation else { return }
        navigationCompletion?(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        activeOperationFailure?(HTMLDialogueTypesetterError.webContentProcessTerminated)
    }

    private static func pngData(from image: NSImage) throws -> Data {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            throw HTMLDialogueTypesetterError.snapshotFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw HTMLDialogueTypesetterError.snapshotFailed
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw HTMLDialogueTypesetterError.snapshotFailed
        }
        return data as Data
    }
}

private final class ContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var isResolved = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let result: Result<Value, Error>?
        lock.lock()
        if let pendingResult {
            result = pendingResult
            self.pendingResult = nil
        } else {
            self.continuation = continuation
            result = nil
        }
        lock.unlock()
        if let result {
            continuation.resume(with: result)
        }
    }

    func resume(_ result: Result<Value, Error>) {
        let continuation: CheckedContinuation<Value, Error>?
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        if let installed = self.continuation {
            continuation = installed
            self.continuation = nil
        } else {
            continuation = nil
            pendingResult = result
        }
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private enum HTMLDialogueTypesetterError: LocalizedError, Sendable {
    case invalidBackground(URL)
    case snapshotFailed
    case invalidJavaScriptState
    case javaScriptFailed(String)
    case operationTimedOut(String)
    case webContentProcessTerminated

    var errorDescription: String? {
        switch self {
        case let .invalidBackground(url):
            "HTML 排版器無法讀取背景圖片：\(url.path)"
        case .snapshotFailed:
            "HTML 排版器無法建立輸出圖片。"
        case .invalidJavaScriptState:
            "HTML 排版器無法讀取 JavaScript 排版狀態。"
        case let .javaScriptFailed(message):
            "HTML 排版器執行排版時發生錯誤：\(message)"
        case let .operationTimedOut(operation):
            "HTML 排版器在「\(operation)」等待超過 30 秒，已中止本次排版。"
        case .webContentProcessTerminated:
            "HTML 排版器的 WebKit 處理程序已意外終止。"
        }
    }
}
