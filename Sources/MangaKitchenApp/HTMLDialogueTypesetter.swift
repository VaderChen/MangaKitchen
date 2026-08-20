import AppKit
import Foundation
import ImageIO
import MangaKitchenCore
@preconcurrency import WebKit

struct HTMLRenderedDialogueLayer: Sendable {
    var regionID: UUID
    var name: String
    var outputURL: URL
    var visible: Bool
}

actor HTMLDialogueTypesetter: DialogueTypesetting {
    private struct RegionPayload: Encodable {
        var sourceText: String
        var translatedText: String
        var bounds: NormalizedRect
        var bubbleBounds: NormalizedRect?
        var bubbleLayoutBounds: NormalizedRect?
        var detectedWritingDirection: WritingDirection
        var translationAnchor: NormalizedPoint?
        var translationBounds: NormalizedRect?
        var style: DialogueStyle
    }

    private var renderer: HTMLTypesettingRenderer?
    private var rendererInUse = false
    private var rendererWaiters: [CheckedContinuation<Void, Never>] = []

    func renderTextLayers(
        canvasURL: URL,
        regions: [DialogueRegion],
        outputDirectory: URL,
        renderScale: Double
    ) async throws -> [HTMLRenderedDialogueLayer] {
        guard let source = CGImageSourceCreateWithURL(canvasURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw HTMLDialogueTypesetterError.invalidBackground(canvasURL)
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let transparentURL = outputDirectory.appendingPathComponent("transparent-canvas.png")
        try Self.writeTransparentCanvas(
            width: width.intValue,
            height: height.intValue,
            to: transparentURL
        )
        defer { try? FileManager.default.removeItem(at: transparentURL) }

        var rendered: [HTMLRenderedDialogueLayer] = []
        for (index, region) in regions.enumerated()
        where !region.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try Task.checkCancellation()
            var renderedRegion = region
            renderedRegion.style.isVisible = true
            let outputURL = outputDirectory.appendingPathComponent(
                String(format: "text-%04d-%@.png", index + 1, region.id.uuidString)
            )
            try await typeset(
                backgroundURL: transparentURL,
                regions: [renderedRegion],
                outputURL: outputURL,
                renderScale: renderScale
            )
            rendered.append(HTMLRenderedDialogueLayer(
                regionID: region.id,
                name: "Text \(index + 1)",
                outputURL: outputURL,
                visible: region.style.isVisible
            ))
        }
        return rendered
    }

    func typeset(
        backgroundURL: URL,
        regions: [DialogueRegion],
        outputURL: URL,
        renderScale: Double
    ) async throws {
        guard let source = CGImageSourceCreateWithURL(backgroundURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw HTMLDialogueTypesetterError.invalidBackground(backgroundURL)
        }

        let payload = regions
            .filter { $0.style.isVisible && !$0.translatedText.isEmpty }
            .map {
                RegionPayload(
                    sourceText: $0.sourceText,
                    translatedText: $0.translatedText,
                    bounds: $0.bounds,
                    bubbleBounds: $0.bubbleBounds,
                    bubbleLayoutBounds: $0.bubbleLayoutBounds,
                    detectedWritingDirection: $0.detectedWritingDirection,
                    translationAnchor: $0.translationAnchor,
                    translationBounds: $0.translationBounds,
                    style: $0.style
                )
            }
        let payloadData = try JSONEncoder().encode(payload)
        let normalizedScale = renderScale.isFinite ? max(1, renderScale) : 1
        let html = Self.document(
            regionsBase64: payloadData.base64EncodedString(),
            width: width.intValue,
            height: height.intValue,
            renderScale: normalizedScale
        )
        let temporaryURL = backgroundURL.deletingLastPathComponent()
            .appendingPathComponent(".mangakitchen-typesetting-\(UUID().uuidString)")
            .appendingPathExtension("html")
        let renderedLayerURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".mangakitchen-typesetting-layer-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try html.write(to: temporaryURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
            try? FileManager.default.removeItem(at: renderedLayerURL)
        }

        await acquireRenderer()
        defer { releaseRenderer() }
        try Task.checkCancellation()
        let renderer = await typesettingRenderer()
        try await renderer.render(
            htmlURL: temporaryURL,
            readAccessURL: backgroundURL.deletingLastPathComponent(),
            outputURL: renderedLayerURL,
            width: width.intValue,
            height: height.intValue
        )
        try Task.checkCancellation()
        try Self.composite(
            backgroundURL: backgroundURL,
            renderedLayerURL: renderedLayerURL,
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
        regionsBase64: String,
        width: Int,
        height: Int,
        renderScale: Double
    ) -> String {
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
            #canvas, #translation-layer {
              position: absolute;
              inset: 0;
              width: 100%;
              height: 100%;
            }
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
            .translation-text.vertical-korean {
              text-orientation: sideways;
            }
          </style>
        </head>
        <body>
          <div id="canvas">
            <div id="translation-layer"></div>
          </div>
          <script>
            const pixelWidth = \(width);
            const pixelHeight = \(height);
            const renderScale = \(renderScale);
            const logicalPixelWidth = pixelWidth / renderScale;
            const logicalPixelHeight = pixelHeight / renderScale;
            const encodedRegions = "\(regionsBase64)";
            const bytes = Uint8Array.from(atob(encodedRegions), character => character.charCodeAt(0));
            const regions = JSON.parse(new TextDecoder().decode(bytes));

            function clamp(value, minimum, maximum) {
              return Math.min(maximum, Math.max(minimum, value));
            }

            function translationLayoutBounds(region) {
              // bubbleLayoutBounds 是完全在氣泡形狀內的最大矩形；bubbleBounds 是外接
              // 矩形，圓形氣泡的四角在框外，拿它排版譯文會溢出到畫面上。
              return region.translationBounds
                ?? region.bubbleLayoutBounds
                ?? region.bubbleBounds
                ?? region.bounds;
            }

            function translationAnchor(region) {
              if (region.translationAnchor) return region.translationAnchor;
              const bounds = translationLayoutBounds(region);
              return { x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2 };
            }

            function resolvedTranslationDirection(region) {
              // 原文的直排方向不能直接套到英文譯文；拉丁文字在 CSS
              // vertical-rl 會被旋轉成側寫。自動排版先看譯文腳本。
              const translatedText = region.translatedText;
              const hasKoreanTranslation = /[\\u1100-\\u11ff\\u3130-\\u318f\\uac00-\\ud7af]/u.test(
                translatedText
              );
              const hasCJKTranslation = /[\\u3000-\\u30ff\\u3400-\\u9fff\\uf900-\\ufaff]/u.test(
                translatedText
              );
              const hasLatinTranslation = /[A-Za-z\\u00c0-\\u024f]/u.test(translatedText);
              let direction;
              if (region.style.writingDirection !== "automatic") {
                direction = region.style.writingDirection;
              } else if (hasKoreanTranslation) {
                direction = "horizontal";
              } else if (hasLatinTranslation && !hasCJKTranslation) {
                direction = "horizontal";
              } else if (region.detectedWritingDirection !== "automatic") {
                direction = region.detectedWritingDirection;
              } else {
                // 量不出來時（字太少、擬聲字斜排）才退回長寬比。它描述的是框的形狀
                // 而不是字的排列，只當最後手段。
                const hasCJK = /[\\u1100-\\u11ff\\u3000-\\u30ff\\u3130-\\u318f\\u3400-\\u9fff\\uac00-\\ud7af\\uf900-\\ufaff]/u.test(
                  `${region.sourceText}${region.translatedText}`
                );
                direction = hasCJK && (region.sourceText.includes("　")
                  || region.bounds.height > region.bounds.width * 0.8)
                  ? "vertical"
                  : "horizontal";
              }
              return hasKoreanTranslation && direction === "vertical"
                ? "vertical korean-vertical"
                : direction;
            }

            function translationSourceFontSize(region) {
              const sourceCount = Math.max(
                1,
                [...region.sourceText].filter(character => !/\\s/u.test(character)).length
              );
              const bounds = translationLayoutBounds(region);
              const sourceArea = Math.max(
                1,
                bounds.width * logicalPixelWidth * bounds.height * logicalPixelHeight
              );
              const minimum = Math.max(4, region.style.minimumFontSize ?? 9);
              const maximum = Math.min(
                512,
                Math.max(minimum, region.style.maximumFontSize ?? 40)
              );
              const sourceFontSize = region.style.fontSize
                ?? clamp(Math.sqrt(sourceArea / sourceCount) * 1.08, minimum, maximum);
              return sourceFontSize * renderScale;
            }

            function fitAutomaticTranslationText(element, region) {
              if (region.style.fontSize != null || !element.clientWidth || !element.clientHeight) return;
              let lower = Math.max(3, region.style.minimumFontSize ?? 4) * renderScale;
              let upper = Math.max(lower, region.style.maximumFontSize ?? 40) * renderScale;
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
                element.style.textAlign = region.style.textAlignment ?? "center";
                element.style.justifyContent = {
                  start: "flex-start",
                  end: "flex-end",
                  center: "center",
                }[region.style.textAlignment ?? "center"];
                element.style.webkitTextStroke = `${Math.max(0, region.style.strokeWidth ?? 0) * renderScale}px ${region.style.strokeColorHex ?? "#FFFFFF"}`;
                element.style.paintOrder = "stroke fill";
                element.style.opacity = String(Math.min(1, Math.max(0, region.style.opacity ?? 1)));
                element.style.transform = `translate(-50%, -50%) rotate(${region.style.rotationDegrees ?? 0}deg)`;
                layer.append(element);
                fitAutomaticTranslationText(element, region);
              }
            }

            window.mangaKitchenReady = (async () => {
              await document.fonts.ready;
              renderRegions();
              document.body.getBoundingClientRect();
              await new Promise(resolve => setTimeout(resolve, 50));
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

    private static func writeTransparentCanvas(width: Int, height: Int, to outputURL: URL) throws {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw HTMLDialogueTypesetterError.snapshotFailed
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
               outputURL as CFURL,
               "public.png" as CFString,
               1,
               nil
              ) else {
            throw HTMLDialogueTypesetterError.snapshotFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw HTMLDialogueTypesetterError.snapshotFailed
        }
    }

    private static func composite(
        backgroundURL: URL,
        renderedLayerURL: URL,
        outputURL: URL,
        width: Int,
        height: Int
    ) throws {
        guard let backgroundSource = CGImageSourceCreateWithURL(backgroundURL as CFURL, nil),
              let background = CGImageSourceCreateImageAtIndex(
                backgroundSource,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ),
              let layerSource = CGImageSourceCreateWithURL(renderedLayerURL as CFURL, nil),
              let layer = CGImageSourceCreateImageAtIndex(
                layerSource,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ),
              background.width == width,
              background.height == height,
              layer.width == width,
              layer.height == height else {
            throw HTMLDialogueTypesetterError.snapshotFailed
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw HTMLDialogueTypesetterError.snapshotFailed
        }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        context.setBlendMode(.copy)
        context.draw(background, in: canvas)
        context.setBlendMode(.normal)
        context.draw(layer, in: canvas)
        guard let image = context.makeImage() else {
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
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw HTMLDialogueTypesetterError.snapshotFailed
        }
        try (data as Data).write(to: outputURL, options: .atomic)
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
        webView.underPageBackgroundColor = .clear
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
        try await setSnapshotBackground("#000000", webView: webView)
        let blackBackgroundPNG = try await snapshot(
            webView,
            configuration: snapshotConfiguration,
            operationName: "建立黑底排版截圖"
        )
        try await setSnapshotBackground("#FFFFFF", webView: webView)
        let whiteBackgroundPNG = try await snapshot(
            webView,
            configuration: snapshotConfiguration,
            operationName: "建立白底排版截圖"
        )
        let pngData = try Self.transparentLayerPNG(
            blackBackgroundPNG: blackBackgroundPNG,
            whiteBackgroundPNG: whiteBackgroundPNG,
            width: width,
            height: height
        )
        try pngData.write(to: outputURL, options: .atomic)
    }

    private func setSnapshotBackground(_ color: String, webView: WKWebView) async throws {
        let applied: Bool = try await awaitWebKitOperation(
            named: "設定排版截圖背景",
            webView: webView
        ) { completion in
            webView.evaluateJavaScript(
                """
                (() => {
                  const color = "\(color)";
                  document.documentElement.style.backgroundColor = color;
                  document.body.style.backgroundColor = color;
                  document.querySelector("#canvas").style.backgroundColor = color;
                  document.body.getBoundingClientRect();
                  return true;
                })()
                """
            ) { value, error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(value as? Bool == true))
                }
            }
        }
        guard applied else {
            throw HTMLDialogueTypesetterError.invalidJavaScriptState
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    private func snapshot(
        _ webView: WKWebView,
        configuration: WKSnapshotConfiguration,
        operationName: String
    ) async throws -> Data {
        try await awaitWebKitOperation(named: operationName, webView: webView) { completion in
            webView.takeSnapshot(with: configuration) { image, error in
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
        return try pngData(from: cgImage)
    }

    private static func transparentLayerPNG(
        blackBackgroundPNG: Data,
        whiteBackgroundPNG: Data,
        width: Int,
        height: Int
    ) throws -> Data {
        guard let blackSource = CGImageSourceCreateWithData(blackBackgroundPNG as CFData, nil),
              let blackImage = CGImageSourceCreateImageAtIndex(blackSource, 0, nil),
              let whiteSource = CGImageSourceCreateWithData(whiteBackgroundPNG as CFData, nil),
              let whiteImage = CGImageSourceCreateImageAtIndex(whiteSource, 0, nil),
              blackImage.width == width,
              blackImage.height == height,
              whiteImage.width == width,
              whiteImage.height == height else {
            throw HTMLDialogueTypesetterError.snapshotFailed
        }
        var pixels = try rgbaBytes(from: blackImage, width: width, height: height)
        let whitePixels = try rgbaBytes(from: whiteImage, width: width, height: height)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let redDifference = max(0, Int(whitePixels[offset]) - Int(pixels[offset]))
            let greenDifference = max(
                0,
                Int(whitePixels[offset + 1]) - Int(pixels[offset + 1])
            )
            let blueDifference = max(
                0,
                Int(whitePixels[offset + 2]) - Int(pixels[offset + 2])
            )
            let minimumDifference = min(redDifference, greenDifference, blueDifference)
            let maximumDifference = max(redDifference, greenDifference, blueDifference)
            let medianDifference = redDifference + greenDifference + blueDifference
                - minimumDifference - maximumDifference
            let alpha = UInt8(clamping: 255 - medianDifference)
            pixels[offset] = min(pixels[offset], alpha)
            pixels[offset + 1] = min(pixels[offset + 1], alpha)
            pixels[offset + 2] = min(pixels[offset + 2], alpha)
            pixels[offset + 3] = alpha
        }
        let pixelData = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: pixelData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw HTMLDialogueTypesetterError.snapshotFailed
        }
        return try pngData(from: image)
    }

    private static func rgbaBytes(from image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                return false
            }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else {
            throw HTMLDialogueTypesetterError.snapshotFailed
        }
        return pixels
    }

    private static func pngData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw HTMLDialogueTypesetterError.snapshotFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
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
