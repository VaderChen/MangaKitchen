import SwiftUI
@preconcurrency import WebKit

struct HybridWebView: NSViewRepresentable {
    let controller: HybridBridgeController

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        configuration.userContentController.add(controller, name: "mangakitchen")
        configuration.setURLSchemeHandler(controller.assetSchemeHandler, forURLScheme: "mangakitchen-asset")
        configuration.setURLSchemeHandler(
            controller.webUISchemeHandler,
            forURLScheme: WebUISchemeHandler.scheme
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = controller
        webView.setValue(false, forKey: "drawsBackground")
        controller.attach(webView: webView)

        if controller.webUISchemeHandler.canServeResources,
           let url = URL(string: "\(WebUISchemeHandler.scheme)://\(WebUISchemeHandler.host)/index.html") {
            webView.load(URLRequest(url: url))
        } else {
            webView.loadHTMLString("<h1>MangaKitchen WebUI resource missing</h1>", baseURL: nil)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Void) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "mangakitchen")
        webView.navigationDelegate = nil
    }
}
