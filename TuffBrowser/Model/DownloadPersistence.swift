import AppKit
import WebKit

/// The downloads list survives relaunches, and a stopped or failed download can be retried —
/// resumed from where it stopped when WebKit kept the data to do so.
extension DownloadManager {
    private struct Saved: Codable {
        var filename: String
        var destination: URL?
        var url: URL?
        var finished: Bool
        var reason: String?
        var bytesReceived: Int64
        var totalBytes: Int64
        var startedAt: Date
        var finishedAt: Date?
        var resumeData: Data?
    }

    private static let file = Paths.appSupport.appendingPathComponent("downloads.json")
    private static let saveLimit = 100
    private static let saver = Debouncer(delay: 1)

    /// The list is kept only while history is: not with "Save history" off, and not past a
    /// quit when history is cleared on quit.
    private static var keepsList: Bool {
        let privacy = AppSettings.shared.privacy
        return privacy.saveHistory && !privacy.clearHistoryOnQuit
    }

    func loadSaved() {
        guard Self.keepsList, let data = try? Data(contentsOf: Self.file),
              let saved = try? JSONDecoder().decode([Saved].self, from: data) else { return }
        items = saved.map { entry in
            let item = DownloadItem(filename: entry.filename)
            item.destination = entry.destination
            item.url = entry.url
            item.bytesReceived = entry.bytesReceived
            item.totalBytes = entry.totalBytes
            item.startedAt = entry.startedAt
            item.finishedAt = entry.finishedAt
            item.resumeData = entry.resumeData
            item.chromeID = reserveChromeID()
            if entry.finished {
                let exists = entry.destination.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                item.state = exists ? .finished : .failed("Moved or deleted")
                item.fraction = exists ? 1 : 0
            } else {
                item.state = .failed(entry.reason ?? "Failed")
            }
            return item
        }
    }

    func scheduleSave() {
        Self.saver.schedule { [weak self] in self?.saveNow() }
    }

    /// Writes the list. At quit, downloads still running are kept as stopped, to retry later.
    func saveNow(quitting: Bool = false) {
        Self.saver.cancel()
        guard Self.keepsList else {
            try? FileManager.default.removeItem(at: Self.file)
            return
        }
        let list: [Saved] = items.filter { !$0.isPrivate }.prefix(Self.saveLimit).compactMap { item in
            switch item.state {
            case .running:
                guard quitting else { return nil }
                return Saved(
                    filename: item.filename, destination: item.destination, url: item.url, finished: false,
                    reason: "Stopped when Tuff quit", bytesReceived: item.bytesReceived, totalBytes: item.totalBytes,
                    startedAt: item.startedAt, finishedAt: nil, resumeData: nil
                )
            case .finished, .failed:
                var reason: String?
                if case .failed(let why) = item.state { reason = why }
                return Saved(
                    filename: item.filename, destination: item.destination, url: item.url, finished: item.state == .finished,
                    reason: reason, bytesReceived: item.bytesReceived, totalBytes: item.totalBytes,
                    startedAt: item.startedAt, finishedAt: item.finishedAt, resumeData: item.resumeData
                )
            }
        }
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }

    // MARK: Retry / resume

    /// Starts a stopped or failed download again: from where it stopped if WebKit kept resume
    /// data, else from the start (with the website data it was first made with).
    func retry(_ item: DownloadItem) {
        guard item.state != .running else { return }
        let store = item.dataStore ?? (item.isPrivate ? nil : BrowserState.shared.currentProfile.dataStore) ?? DataStores.website
        let view = Self.helperWebView(for: store)
        if let data = item.resumeData {
            item.state = .running
            view.resumeDownload(fromResumeData: data) { [weak self, weak item] download in
                guard let self, let item else { return }
                self.attach(download, to: item)
            }
        } else if let url = item.url {
            Self.discardIncompleteFile(item)
            item.destination = nil
            item.fraction = 0
            item.bytesReceived = 0
            item.state = .running
            item.startedAt = Date()
            view.startDownload(using: URLRequest(url: url)) { [weak self, weak item] download in
                guard let self, let item else { return }
                self.attach(download, to: item)
            }
        }
        pulse += 1
    }

    /// Whether Retry can do anything for this item.
    func canRetry(_ item: DownloadItem) -> Bool {
        guard case .failed = item.state else { return false }
        return item.resumeData != nil || item.url.map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") } == true
    }

    /// Hidden web views that start retried downloads, one per website data store.
    private static var helpers: [ObjectIdentifier: WKWebView] = [:]

    private static func helperWebView(for store: WKWebsiteDataStore) -> WKWebView {
        if let view = helpers[ObjectIdentifier(store)] { return view }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.applicationNameForUserAgent = WebEngine.userAgentApplicationName
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), configuration: configuration)
        helpers[ObjectIdentifier(store)] = view
        return view
    }

    /// Deletes the part-downloaded file a stopped download left behind for Resume (the list
    /// entry is being cleared, so nothing will resume it).
    static func discardIncompleteFile(_ item: DownloadItem) {
        guard case .failed = item.state, item.resumeData != nil else { return }
        if let partial = item.partialFile {
            try? FileManager.default.removeItem(at: partial)
            item.partialFile = nil
        } else if let destination = item.destination {
            try? FileManager.default.removeItem(at: destination)
        }
        item.resumeData = nil
    }
}
