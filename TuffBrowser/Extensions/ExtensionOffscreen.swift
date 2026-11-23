import AppKit
import WebKit

/// Native `chrome.offscreen` (Manifest V3): a hidden page of the extension that stays alive so the
/// service worker can use DOM / audio / clipboard APIs it doesn't have itself. The page is a real
/// extension context (built from the extension's own configuration), so WebKit routes
/// `chrome.runtime` messages between it and the background worker — Tuff only hosts the view.
///
/// Chrome allows a single offscreen document per extension; it lives until `closeDocument` (or the
/// extension unloads). Modelled on the `SocketRelay` hidden page in `ExtensionManager`.
final class ExtensionOffscreen {
    static let shared = ExtensionOffscreen()

    private var documents: [String: OffscreenDocument] = [:]

    private func error(_ message: String) -> Error {
        NSError(domain: "Tuff.Offscreen", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func create(url: URL, context: WKWebExtensionContext, finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) {
        let id = context.uniqueIdentifier
        guard documents[id] == nil else {
            fail(error("Only one offscreen document may be open at a time. Close the existing one first."))
            return
        }
        // An offscreen document must be one of the extension's own pages.
        guard ExtensionManager.shared.context(forPage: url) === context else {
            fail(error("The offscreen document must be a page of this extension."))
            return
        }
        documents[id] = OffscreenDocument(configuration: context.webViewConfiguration, url: url)
        finish(nil)
    }

    /// The open offscreen document's address, if the extension has one.
    func url(id: String) -> URL? { documents[id]?.url }

    func has(id: String, finish: @escaping (Any?) -> Void) {
        finish(documents[id] != nil)
    }

    func close(id: String, finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) {
        guard let document = documents.removeValue(forKey: id) else {
            fail(error("No offscreen document is open."))
            return
        }
        document.tearDown()
        finish(nil)
    }

    /// Called when the extension unloads, so its hidden page doesn't outlive it.
    func extensionUnloaded(_ id: String) {
        documents.removeValue(forKey: id)?.tearDown()
    }
}

/// The hidden web view showing an extension's offscreen document. Never added to a window; kept from
/// being throttled, and reloaded if its content process dies, so it stays available to the worker.
private final class OffscreenDocument: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    let url: URL

    init(configuration: WKWebViewConfiguration?, url: URL) {
        self.url = url
        super.init()
        guard let configuration = configuration.map(ExtensionManager.hiddenPageConfiguration) else { return }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        view.load(URLRequest(url: url))
    }

    func tearDown() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.load(URLRequest(url: url))
    }
}