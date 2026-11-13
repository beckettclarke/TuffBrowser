import AppKit
import WebKit

/// Native `chrome.downloads` for extensions. A download is started by loading the URL in a hidden web
/// view on the current profile's store (so its cookies apply) and forcing the response to become a
/// `WKDownload`, which the existing `DownloadManager` then tracks like any page download.
///
/// Limits of the engine: `WKDownload` has no pause/resume, so those report an error. `filename`,
/// `saveAs` and `conflictAction` options are not honoured yet (the URL's own filename is used, and the
/// app's "ask where to save" setting applies).
final class ExtensionDownloads {
    static let shared = ExtensionDownloads()

    private var initiators: [Int: DownloadInitiator] = [:]

    private var manager: DownloadManager { .shared }

    private func error(_ message: String) -> Error {
        NSError(domain: "Tuff.Downloads", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func item(id: Int) -> DownloadItem? {
        manager.items.first { $0.chromeID == id }
    }

    // MARK: Methods

    func download(options: [String: Any], finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) {
        guard let urlString = options["url"] as? String, let url = URL(string: urlString) else {
            fail(error("url is required."))
            return
        }
        let id = manager.reserveChromeID()
        let initiator = DownloadInitiator(url: url, dataStore: BrowserState.shared.currentProfile.dataStore)
        initiator.onDownload = { [weak self] download in
            self?.manager.track(download, chromeID: id, url: url)
            self?.initiators.removeValue(forKey: id)
        }
        initiator.onFail = { [weak self] _ in
            self?.initiators.removeValue(forKey: id)
        }
        initiators[id] = initiator
        initiator.start()
        // Chrome answers with the id as soon as the download is created, not when it finishes.
        finish(id)
    }

    func search(query: [String: Any], finish: @escaping (Any?) -> Void) {
        var items = manager.items.filter { $0.chromeID != nil }
        if let id = query["id"] as? Int { items = items.filter { $0.chromeID == id } }
        if let state = query["state"] as? String { items = items.filter { Self.chromeState($0) == state } }
        if let terms = query["query"] as? [String], !terms.isEmpty {
            items = items.filter { item in
                let haystack = (item.url?.absoluteString ?? "") + " " + item.filename
                return terms.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
            }
        }
        if let limit = query["limit"] as? Int, limit > 0 { items = Array(items.prefix(limit)) }
        finish(items.map(chromeItem))
    }

    func cancel(id: Int, finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) {
        guard let item = item(id: id) else { fail(error("No download with id \(id).")); return }
        manager.cancel(item)
        finish(nil)
    }

    func erase(query: [String: Any], finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) {
        if let id = query["id"] as? Int {
            guard let item = item(id: id) else { fail(error("No download with id \(id).")); return }
            guard item.state != .running else { fail(error("Cannot erase an in-progress download.")); return }
            manager.items.removeAll { $0 === item }
            ExtensionEventPush.shared.emit("downloads.onErased", args: [id])
            finish([id])
        } else {
            let finished = manager.items.filter { $0.chromeID != nil && $0.state != .running }
            let erased = finished.compactMap { $0.chromeID }
            manager.items.removeAll { item in finished.contains { $0 === item } }
            for id in erased { ExtensionEventPush.shared.emit("downloads.onErased", args: [id]) }
            finish(erased)
        }
    }

    func open(id: Int, finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) {
        guard let item = item(id: id), let url = item.destination else {
            fail(error("No downloaded file for id \(id)."))
            return
        }
        NSWorkspace.shared.open(url)
        finish(nil)
    }

    func show(id: Int, finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) {
        guard let item = item(id: id), let url = item.destination else {
            fail(error("No downloaded file for id \(id)."))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        finish(true)
    }

    func pauseResume(id: Int, fail: @escaping (Error) -> Void) {
        fail(error("Pausing and resuming downloads isn’t supported by Tuff’s engine (WebKit)."))
    }

    // MARK: Chrome shapes

    private static func chromeState(_ item: DownloadItem) -> String {
        switch item.state {
        case .running: "in_progress"
        case .finished: "complete"
        case .failed: "interrupted"
        }
    }

    private func chromeItem(_ item: DownloadItem) -> [String: Any] {
        var dict: [String: Any] = [
            "id": item.chromeID ?? 0,
            "url": item.url?.absoluteString ?? "",
            "filename": item.destination?.path ?? "",
            "state": Self.chromeState(item),
            "bytesReceived": item.bytesReceived,
            "totalBytes": item.totalBytes,
            "exists": item.destination.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
            "paused": false,
        ]
        if case .failed(let reason) = item.state { dict["error"] = reason }
        return dict
    }
}

/// Loads one URL off-screen and turns the response into a `WKDownload`, so an extension can start a
/// download with the profile's cookies. Redirects are followed; the final response is forced to
/// download even if it is a type the browser would normally render.
private final class DownloadInitiator: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private let url: URL
    var onDownload: ((WKDownload) -> Void)?
    var onFail: ((Error) -> Void)?

    init(url: URL, dataStore: WKWebsiteDataStore) {
        self.url = url
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), configuration: configuration)
        view.navigationDelegate = self
        webView = view
    }

    func start() {
        webView?.load(URLRequest(url: url))
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let http = navigationResponse.response as? HTTPURLResponse, (300..<400).contains(http.statusCode) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(navigationResponse.isForMainFrame ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        onDownload?(download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        onDownload?(download)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onFail?(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onFail?(error)
    }
}