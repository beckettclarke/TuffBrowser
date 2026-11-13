import AppKit
import Observation
import WebKit

// MARK: - History

struct HistoryEntry: Codable {
    var url: URL
    var title: String
    var lastVisit: Date
    var visits: Int
}

/// A small in-memory history index, persisted as JSON. Used for command bar suggestions.
final class HistoryStore {
    static let shared = HistoryStore()

    private var entries: [String: HistoryEntry] = [:]
    private let file = Paths.appSupport.appendingPathComponent("history.json")
    private let saver = Debouncer(delay: 3)
    private let limit = 8000

    private init() {
        if let data = try? Data(contentsOf: file),
           let list = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            for e in list { entries[e.url.absoluteString] = e }
        }
    }

    func record(url: URL, title: String) {
        guard AppSettings.shared.privacy.saveHistory else { return }
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }
        let key = url.absoluteString
        if var e = entries[key] {
            e.visits += 1
            e.lastVisit = Date()
            if !title.isEmpty { e.title = title }
            entries[key] = e
        } else {
            entries[key] = HistoryEntry(url: url, title: title, lastVisit: Date(), visits: 1)
        }
        saver.schedule { [weak self] in self?.saveNow() }
        if let e = entries[key] {
            ExtensionEventPush.shared.emit("history.onVisited", args: [[
                "id": e.url.absoluteString,
                "url": e.url.absoluteString,
                "title": e.title,
                "lastVisitTime": e.lastVisit.timeIntervalSince1970 * 1000,
                "visitCount": e.visits,
                "typedCount": 0,
            ]])
        }
    }

    func search(_ query: String, limit: Int = 4) -> [HistoryEntry] {
        let q = query.lowercased().trimmed
        guard !q.isEmpty else { return [] }
        let now = Date()
        var scored: [(Double, HistoryEntry)] = []
        for e in entries.values {
            let host = e.url.displayHost.lowercased()
            let full = e.url.absoluteString.lowercased()
            let title = e.title.lowercased()
            var score = 0.0
            if host.hasPrefix(q) { score += 60 } else if host.contains(q) { score += 30 }
            if title.hasPrefix(q) { score += 25 } else if title.contains(q) { score += 14 }
            if score == 0, full.contains(q) { score += 8 }
            guard score > 0 else { continue }
            score += min(20, Double(e.visits) * 2)
            let days = now.timeIntervalSince(e.lastVisit) / 86400
            score += max(0, 10 - days)
            // Prefer short, root-ish URLs so "git" suggests github.com before a deep link.
            score -= min(12, Double(e.url.path.count) / 6)
            scored.append((score, e))
        }
        return scored.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
    }

    var count: Int { entries.count }

    func clear(synchronously: Bool = false) {
        entries.removeAll()
        saveNow(synchronously: synchronously)
        ExtensionEventPush.shared.emit("history.onVisitRemoved", args: [["allHistory": true, "urls": [String]()]])
    }

    func saveNow(synchronously: Bool = false) {
        var list = Array(entries.values)
        if list.count > limit {
            list.sort { $0.lastVisit > $1.lastVisit }
            list = Array(list.prefix(limit))
            entries = Dictionary(uniqueKeysWithValues: list.map { ($0.url.absoluteString, $0) })
        }
        let file = self.file
        let write = { if let data = try? JSONEncoder().encode(list) { try? data.write(to: file, options: .atomic) } }
        // At quit the process may exit before a background write runs.
        if synchronously { write() } else { DispatchQueue.global(qos: .utility).async(execute: write) }
    }

    // MARK: WebExtension API shapes (chrome.history / chrome.topSites)

    /// Most-visited pages, for `chrome.topSites.get`.
    func topSites(limit: Int = 20) -> [[String: Any]] {
        entries.values.sorted { $0.visits > $1.visits }
            .prefix(limit)
            .map { ["url": $0.url.absoluteString, "title": $0.title] }
    }

    /// `chrome.history.search`: text match over url / title within a time range, newest first.
    func chromeSearch(text: String, startTime: Double?, endTime: Double?, maxResults: Int) -> [[String: Any]] {
        let q = text.lowercased().trimmed
        let start = startTime.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
        let end = endTime.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantFuture
        return entries.values
            .filter { e in
                guard e.lastVisit >= start, e.lastVisit <= end else { return false }
                if q.isEmpty { return true }
                return e.url.absoluteString.lowercased().contains(q) || e.title.lowercased().contains(q)
            }
            .sorted { $0.lastVisit > $1.lastVisit }
            .prefix(max(0, maxResults))
            .map(chromeItem)
    }

    /// `chrome.history.getVisits`. The store keeps aggregates, not a per-visit log, so report the
    /// last visit as a single entry.
    func chromeVisits(for url: URL) -> [[String: Any]] {
        guard let e = entries[url.absoluteString] else { return [] }
        return [[
            "id": e.url.absoluteString,
            "visitId": "0",
            "visitTime": e.lastVisit.timeIntervalSince1970 * 1000,
            "referringVisitId": "0",
            "transition": "link",
        ]]
    }

    private func chromeItem(_ e: HistoryEntry) -> [String: Any] {
        [
            "id": e.url.absoluteString,
            "url": e.url.absoluteString,
            "title": e.title,
            "lastVisitTime": e.lastVisit.timeIntervalSince1970 * 1000,
            "visitCount": e.visits,
            "typedCount": 0,
        ]
    }

    func deleteUrl(_ url: URL) {
        entries.removeValue(forKey: url.absoluteString)
        saver.schedule { [weak self] in self?.saveNow() }
        ExtensionEventPush.shared.emit("history.onVisitRemoved", args: [["allHistory": false, "urls": [url.absoluteString]]])
    }

    func deleteRange(startTime: Double, endTime: Double) {
        let start = Date(timeIntervalSince1970: startTime / 1000)
        let end = Date(timeIntervalSince1970: endTime / 1000)
        let removed = entries.filter { $0.value.lastVisit >= start && $0.value.lastVisit <= end }.map { $0.key }
        entries = entries.filter { !($0.value.lastVisit >= start && $0.value.lastVisit <= end) }
        saver.schedule { [weak self] in self?.saveNow() }
        if !removed.isEmpty {
            ExtensionEventPush.shared.emit("history.onVisitRemoved", args: [["allHistory": false, "urls": removed]])
        }
    }
}

// MARK: - Favicons

final class FaviconStore {
    static let shared = FaviconStore()

    private let memory = NSCache<NSString, NSImage>()
    private let dir: URL
    private let session: URLSession

    private init() {
        dir = Paths.caches.appendingPathComponent("favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
        memory.countLimit = 400
    }

    private func key(for url: URL) -> String? {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        return host.lowercased()
    }

    private func file(for key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return dir.appendingPathComponent(safe + ".png")
    }

    /// Synchronous lookup in the memory and disk caches only.
    func cachedIcon(for url: URL) -> NSImage? {
        guard let key = key(for: url) else { return nil }
        if let image = memory.object(forKey: key as NSString) { return image }
        if let image = NSImage(contentsOf: file(for: key)) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }
        return nil
    }

    private static let iconScript = """
    (function () {
      var links = [].slice.call(document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]'));
      var best = null, bestScore = -1;
      links.forEach(function (el) {
        if (!el.href) return;
        var size = 0, m = ((el.getAttribute('sizes') || '')).match(/(\\d+)x/);
        if (m) size = parseInt(m[1], 10);
        if (!size && /apple-touch-icon/.test(el.rel)) size = 180;
        if (!size) size = 16;
        var score = size > 256 ? 1 : size;
        if (/svg/.test(el.type || '') || /\\.svg(\\?|$)/.test(el.href)) score = 2;
        if (score > bestScore) { best = el.href; bestScore = score; }
      });
      return best;
    })()
    """

    /// Finds the page's declared icon (falling back to /favicon.ico), downloads and caches it.
    func fetchIcon(from webView: WKWebView, completion: @escaping (NSImage?) -> Void) {
        guard let pageURL = webView.url, let key = key(for: pageURL),
              pageURL.scheme == "http" || pageURL.scheme == "https" else {
            completion(nil)
            return
        }
        webView.evaluateJavaScript(Self.iconScript) { [weak self] result, _ in
            guard let self else { return }
            var candidates: [URL] = []
            if let s = result as? String, let u = URL(string: s) { candidates.append(u) }
            if let fallback = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL { candidates.append(fallback) }
            self.download(candidates, key: key, completion: completion)
        }
    }

    private func download(_ candidates: [URL], key: String, completion: @escaping (NSImage?) -> Void) {
        guard let url = candidates.first else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let rest = Array(candidates.dropFirst())
        if url.scheme == "data" {
            if let data = try? Data(contentsOf: url), let image = NSImage(data: data), image.isValid {
                store(image, key: key, completion: completion)
            } else {
                download(rest, key: key, completion: completion)
            }
            return
        }
        session.dataTask(with: url) { [weak self] data, response, _ in
            guard let self else { return }
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            if ok, let data, let image = NSImage(data: data), image.isValid, image.size.width > 0 {
                self.store(image, key: key, completion: completion)
            } else {
                self.download(rest, key: key, completion: completion)
            }
        }.resume()
    }

    private func store(_ image: NSImage, key: String, completion: @escaping (NSImage?) -> Void) {
        DispatchQueue.main.async {
            let small = image.resized(to: 64)
            small.size = NSSize(width: 32, height: 32)
            self.memory.setObject(small, forKey: key as NSString)
            if let png = small.pngData { try? png.write(to: self.file(for: key), options: .atomic) }
            completion(small)
        }
    }
}

// MARK: - Downloads

@Observable
final class DownloadItem: Identifiable {
    enum State: Equatable { case running, finished, failed(String) }

    let id = UUID()
    var filename: String
    var destination: URL?
    var fraction: Double = 0
    var state: State = .running
    /// `chrome.downloads` integer id, when an extension started this download.
    var chromeID: Int?
    var url: URL?
    var bytesReceived: Int64 = 0
    var totalBytes: Int64 = -1
    /// Smoothed transfer rate, sampled once a second while running. `nil` until the first sample.
    var bytesPerSecond: Double?
    /// When bytes started flowing (reset once the destination is chosen), and when it finished.
    var startedAt = Date()
    var finishedAt: Date?
    @ObservationIgnored var lastSampleBytes: Int64 = 0
    @ObservationIgnored var lastSampleTime: Date?
    @ObservationIgnored var download: WKDownload?
    @ObservationIgnored var observation: NSKeyValueObservation?

    init(filename: String) { self.filename = filename }
}

@Observable
final class DownloadManager: NSObject {
    static let shared = DownloadManager()

    var items: [DownloadItem] = []
    /// Bumped whenever a download starts, so the sidebar button can pulse.
    var pulse = 0
    /// chrome.downloads ids — every download gets one, page- or extension-initiated.
    private var nextChromeID = 1
    func reserveChromeID() -> Int { let id = nextChromeID; nextChromeID += 1; return id }

    var activeCount: Int { items.filter { $0.state == .running }.count }

    var overallFraction: Double {
        let running = items.filter { $0.state == .running }
        guard !running.isEmpty else { return 0 }
        return running.map(\.fraction).reduce(0, +) / Double(running.count)
    }

    /// Combined speed of everything in flight, for the popover header.
    var totalBytesPerSecond: Double? {
        let speeds = items.filter { $0.state == .running }.compactMap(\.bytesPerSecond)
        return speeds.isEmpty ? nil : speeds.reduce(0, +)
    }

    /// Samples every running download once a second. Runs only while something is downloading.
    @ObservationIgnored private var speedTimer: Timer?

    private func startSpeedSampling() {
        guard speedTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sampleSpeeds() }
        RunLoop.main.add(timer, forMode: .common)
        speedTimer = timer
    }

    private func sampleSpeeds() {
        let running = items.filter { $0.state == .running }
        guard !running.isEmpty else {
            speedTimer?.invalidate()
            speedTimer = nil
            return
        }
        let now = Date()
        for item in running {
            defer {
                item.lastSampleTime = now
                item.lastSampleBytes = item.bytesReceived
            }
            guard let last = item.lastSampleTime else { continue }
            let elapsed = now.timeIntervalSince(last)
            guard elapsed > 0 else { continue }
            let instant = Double(max(0, item.bytesReceived - item.lastSampleBytes)) / elapsed
            // Exponential smoothing so the number doesn't jump around every second.
            item.bytesPerSecond = item.bytesPerSecond.map { $0 * 0.6 + instant * 0.4 } ?? instant
        }
    }

    func track(_ download: WKDownload, chromeID: Int? = nil, url: URL? = nil) {
        download.delegate = self
        let item = DownloadItem(filename: download.originalRequest?.url?.lastPathComponent ?? "Download")
        item.download = download
        item.chromeID = chromeID ?? reserveChromeID()
        item.url = url ?? download.originalRequest?.url
        // Observe the byte count rather than the fraction: with no Content-Length the fraction
        // never moves, but bytes still arrive.
        item.observation = download.progress.observe(\.completedUnitCount, options: [.new]) { [weak item] progress, _ in
            let value = progress.fractionCompleted
            let received = progress.completedUnitCount
            let total = progress.totalUnitCount
            DispatchQueue.main.async {
                item?.fraction = value
                item?.bytesReceived = received
                item?.totalBytes = total
            }
        }
        items.insert(item, at: 0)
        ExtensionEventPush.shared.emit("downloads.onCreated", args: [[
            "id": item.chromeID ?? 0,
            "url": item.url?.absoluteString ?? "",
            "filename": item.filename,
            "state": "in_progress",
            "bytesReceived": 0,
            "totalBytes": -1,
            "paused": false,
        ]])
        pulse += 1
        startSpeedSampling()
        let state = BrowserState.shared
        if AppSettings.shared.downloads.showPanelOnStart, state.sidebarVisible || state.sidebarPeeking {
            state.downloadsVisible = true
        }
    }

    /// Files that are safe to open straight away, like Safari's "open safe files" list.
    private static let safeExtensions: Set<String> = [
        "pdf", "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "txt", "rtf", "csv", "md",
        "mp3", "m4a", "wav", "aac", "mp4", "mov", "m4v",
    ]

    private func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    func cancel(_ item: DownloadItem) {
        item.download?.cancel { _ in }
        item.state = .failed("Cancelled")
        item.download = nil
    }

    func clearFinished() {
        items.removeAll { $0.state != .running }
    }

    func reveal(_ item: DownloadItem) {
        guard let url = item.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func uniqueDestination(for filename: String) -> URL {
        var downloads = AppSettings.shared.downloads.folder
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: downloads.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        let clean = filename.replacingOccurrences(of: "/", with: "_")
        let base = (clean as NSString).deletingPathExtension
        let ext = (clean as NSString).pathExtension
        var candidate = downloads.appendingPathComponent(clean)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = downloads.appendingPathComponent(name)
            n += 1
        }
        return candidate
    }
}

extension DownloadManager: WKDownloadDelegate {
    func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let destination = Self.uniqueDestination(for: suggestedFilename)
        let item = item(for: download)
        let accept: (URL) -> Void = { url in
            item?.filename = url.lastPathComponent
            item?.destination = url
            // Time spent in the save panel isn't download time.
            item?.startedAt = Date()
            completionHandler(url)
        }
        guard AppSettings.shared.downloads.askWhereToSave else {
            accept(destination)
            return
        }
        let panel = NSSavePanel()
        panel.directoryURL = destination.deletingLastPathComponent()
        panel.nameFieldStringValue = destination.lastPathComponent
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url {
                // The save panel already asked about replacing; WebKit won't overwrite.
                try? FileManager.default.removeItem(at: url)
                accept(url)
            } else {
                item?.state = .failed("Cancelled")
                item?.download = nil
                item?.observation = nil
                completionHandler(nil)
            }
        }
        if let window = BrowserState.shared.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.fraction = 1
        item.finishedAt = Date()
        // The file on disk is the truth; fall back to what the progress counted.
        let onDisk = (try? item.destination?.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
        let size = onDisk.map(Int64.init) ?? max(download.progress.completedUnitCount, item.bytesReceived)
        item.bytesReceived = size
        item.totalBytes = size
        item.state = .finished
        item.download = nil
        item.observation = nil
        if let id = item.chromeID {
            ExtensionEventPush.shared.emit("downloads.onChanged", args: [["id": id, "state": ["current": "complete", "previous": "in_progress"]]])
        }
        if let path = item.destination?.path {
            // Makes the Downloads stack in the Dock bounce, like other browsers.
            DistributedNotificationCenter.default().post(
                name: Notification.Name("com.apple.DownloadFileFinished"), object: path
            )
        }
        if AppSettings.shared.downloads.openSafeFiles, let url = item.destination,
           Self.safeExtensions.contains(url.pathExtension.lowercased()) {
            NSWorkspace.shared.open(url)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download) else { return }
        item.state = .failed(error.localizedDescription)
        item.download = nil
        item.observation = nil
        if let id = item.chromeID {
            ExtensionEventPush.shared.emit("downloads.onChanged", args: [["id": id, "state": ["current": "interrupted", "previous": "in_progress"]]])
        }
    }
}
