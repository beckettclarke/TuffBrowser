import AppKit
import WebKit

/// Native `chrome.downloads` for extensions, backed by the same items as page downloads.
final class ExtensionDownloads {
    static let shared = ExtensionDownloads()

    private var initiators: [Int: DownloadInitiator] = [:]
    private var previous: [ObjectIdentifier: Snapshot] = [:]

    private struct Snapshot: Equatable {
        var state: String
        var filename: String
        var paused: Bool
        var totalBytes: Int64
        var url: String
        var error: String?

        init(_ item: DownloadItem) {
            state = ExtensionDownloads.chromeState(item)
            filename = item.destination?.path ?? ""
            paused = item.isPaused
            totalBytes = item.totalBytes
            url = item.url?.absoluteString ?? ""
            if case .failed(let reason) = item.state, !item.isPaused && !item.isQueued { error = reason }
        }
    }

    func observed(_ item: DownloadItem) {
        guard item.chromeID != nil, !item.isPrivate else { return }
        previous[ObjectIdentifier(item)] = Snapshot(item)
    }

    func created(_ item: DownloadItem) {
        guard item.chromeID != nil, !item.isPrivate else { return }
        observed(item)
        ExtensionEventPush.shared.emit("downloads.onCreated", args: [Self.chromeItem(item)])
    }

    func changed(_ item: DownloadItem) {
        guard item.chromeID != nil, !item.isPrivate else { return }
        let key = ObjectIdentifier(item)
        let now = Snapshot(item)
        if let id = item.chromeID, let old = previous[key] {
            var delta: [String: Any] = ["id": id]
            func change(_ name: String, _ old: Any?, _ now: Any?) {
                guard let now else { return }
                delta[name] = ["current": now, "previous": old ?? NSNull()]
            }
            if old.state != now.state { change("state", old.state, now.state) }
            if old.filename != now.filename { change("filename", old.filename, now.filename) }
            if old.paused != now.paused { change("paused", old.paused, now.paused) }
            if old.totalBytes != now.totalBytes { change("totalBytes", old.totalBytes, now.totalBytes) }
            if old.url != now.url { change("url", old.url, now.url) }
            if old.error != now.error { change("error", old.error, now.error) }
            if delta.count > 1 { ExtensionEventPush.shared.emit("downloads.onChanged", args: [delta]) }
        } else if item.chromeID != nil {
            previous[key] = now
            return
        }
        previous[key] = now
    }

    func erased(_ item: DownloadItem) {
        previous.removeValue(forKey: ObjectIdentifier(item))
        if let id = item.chromeID { ExtensionEventPush.shared.emit("downloads.onErased", args: [id]) }
    }

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
        let requested = options["filename"] as? String
        if let requested, !Self.isValidFilename(requested) {
            fail(error("filename must be a safe relative path."))
            return
        }
        let conflict = options["conflictAction"] as? String ?? "uniquify"
        guard let conflictAction = DownloadConflictAction(rawValue: conflict) else {
            fail(error("Unknown conflictAction '\(conflict)'."))
            return
        }
        let id = manager.reserveChromeID()
        let store = BrowserState.shared.currentProfile.dataStore
        let item = DownloadItem(filename: requested.map { ($0 as NSString).lastPathComponent } ?? (url.lastPathComponent.isEmpty ? (url.host ?? "Download") : url.lastPathComponent))
        item.chromeID = id
        item.url = url
        item.dataStore = store
        item.requestedFilename = requested
        item.conflictAction = conflictAction
        item.saveLocation = options["saveAs"] as? Bool == true ? .ask : .downloadsFolder
        manager.items.insert(item, at: 0)
        created(item)
        let initiator = DownloadInitiator(url: url, dataStore: store)
        initiator.onDownload = { [weak self, weak item] download in
            guard let self, let item, self.initiators.removeValue(forKey: id) != nil else { return }
            self.manager.attach(download, to: item)
        }
        initiator.onFail = { [weak self, weak item] error in
            guard let self, let item, self.initiators.removeValue(forKey: id) != nil else { return }
            item.state = .failed(error.localizedDescription)
            item.finishedAt = Date()
            self.changed(item)
            self.manager.saveNow()
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
        finish(items.map(Self.chromeItem))
    }

    func cancel(id: Int, finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) {
        guard let item = item(id: id) else { fail(error("No download with id \(id).")); return }
        initiators.removeValue(forKey: id)?.cancel()
        manager.cancel(item)
        finish(nil)
    }

    func erase(query: [String: Any], finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) {
        if let id = query["id"] as? Int {
            guard let item = item(id: id) else { fail(error("No download with id \(id).")); return }
            guard item.state != .running else { fail(error("Cannot erase an in-progress download.")); return }
            manager.items.removeAll { $0 === item }
            erased(item)
            manager.saveNow()
            finish([id])
        } else {
            let finished = manager.items.filter { $0.chromeID != nil && $0.state != .running }
            let erased = finished.compactMap { $0.chromeID }
            manager.items.removeAll { item in finished.contains { $0 === item } }
            finished.forEach { self.erased($0) }
            manager.saveNow()
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

    func pause(id: Int, finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) {
        guard let item = item(id: id) else { fail(error("No download with id \(id).")); return }
        guard item.state == .running || item.isQueued else { fail(error("Download \(id) is not running.")); return }
        guard item.download != nil || item.transfer != nil || item.isQueued else {
            fail(error("Download \(id) is still being started.")); return
        }
        manager.pause(item)
        finish(nil)
    }

    func resume(id: Int, finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) {
        guard let item = item(id: id) else { fail(error("No download with id \(id).")); return }
        guard item.isPaused else { fail(error("Download \(id) is not paused.")); return }
        manager.retry(item)
        finish(nil)
    }

    static func isValidFilename(_ filename: String) -> Bool {
        let trimmed = filename.trimmed
        guard !trimmed.isEmpty, trimmed == filename, !filename.hasPrefix("/"), !filename.contains("\0") else { return false }
        let parts = filename.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    // MARK: Chrome shapes

    static func chromeState(_ item: DownloadItem) -> String {
        if item.isPaused || item.isQueued { return "in_progress" }
        return switch item.state {
        case .running: "in_progress"
        case .finished: "complete"
        case .failed: "interrupted"
        }
    }

    static func chromeItem(_ item: DownloadItem) -> [String: Any] {
        var dict: [String: Any] = [
            "id": item.chromeID ?? 0,
            "url": item.url?.absoluteString ?? "",
            "filename": item.destination?.path ?? "",
            "state": chromeState(item),
            "bytesReceived": item.bytesReceived,
            "totalBytes": item.totalBytes,
            "exists": item.destination.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
            "paused": item.isPaused,
        ]
        if case .failed(let reason) = item.state, !item.isPaused && !item.isQueued { dict["error"] = reason }
        return dict
    }
}

/// Loads one URL off-screen and turns the response into a `WKDownload`, so an extension can start a
/// download with the profile's cookies. Redirects are followed; the final response is forced to
/// download even if it is a type the browser would normally render.
private final class DownloadInitiator: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private let url: URL
    private var delivered = false
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

    func cancel() {
        delivered = true
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
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

    private func deliver(_ download: WKDownload) {
        guard !delivered else { return }
        delivered = true
        onDownload?(download)
    }

    private func failed(_ error: Error) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.delivered else { return }
            self.delivered = true
            self.onFail?(error)
        }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        deliver(download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        deliver(download)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }
}