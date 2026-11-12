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

    var activeCount: Int { items.filter { $0.state == .running }.count }

    var overallFraction: Double {
        let running = items.filter { $0.state == .running }
        guard !running.isEmpty else { return 0 }
        return running.map(\.fraction).reduce(0, +) / Double(running.count)
    }

    func track(_ download: WKDownload) {
        download.delegate = self
        let item = DownloadItem(filename: download.originalRequest?.url?.lastPathComponent ?? "Download")
        item.download = download
        item.observation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak item] progress, _ in
            let value = progress.fractionCompleted
            DispatchQueue.main.async { item?.fraction = value }
        }
        items.insert(item, at: 0)
        pulse += 1
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
        item.state = .finished
        item.download = nil
        item.observation = nil
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
    }
}
