import AppKit
import CryptoKit
import Observation
import WebKit

// MARK: - History

struct HistoryEntry: Codable {
    var url: URL
    var title: String
    var lastVisit: Date
    var visits: Int
}

/// A small in-memory history index, persisted as JSON. Used for command bar suggestions and
/// the History page (tuff://history), and filled by imports from other browsers.
///
/// The file is read on a background queue at launch, so a long history (an import can bring
/// tens of thousands of pages) doesn't block the first page. Visits recorded before it is in
/// are merged with it; anything that needs the whole history first calls `ensureLoaded()`.
final class HistoryStore {
    static let shared = HistoryStore()

    private var entries: [String: HistoryEntry] = [:]
    private let file = Paths.appSupport.appendingPathComponent("history.json")
    private let saver = Debouncer(delay: 3)
    private let limit = 20000
    private var loaded = false

    private init() {
        let file = self.file
        DispatchQueue.global(qos: .userInitiated).async {
            let list = Self.read(file)
            DispatchQueue.main.async { self.absorb(list) }
        }
    }

    private static func read(_ file: URL) -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    /// Reads the file now if the background read hasn't finished yet.
    private func ensureLoaded() {
        guard !loaded else { return }
        absorb(Self.read(file))
    }

    /// Takes in the history read from disk, keeping what was recorded in the meantime.
    private func absorb(_ list: [HistoryEntry]) {
        guard !loaded else { return }
        loaded = true
        for old in list {
            let key = old.url.absoluteString
            if var e = entries[key] {
                e.visits += old.visits
                if e.title.isEmpty { e.title = old.title }
                entries[key] = e
            } else {
                entries[key] = old
            }
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

    /// Gives a page already in history the title it settled on. Single-page apps change their
    /// title after their address, so the visit is recorded with the old one first.
    func updateTitle(url: URL, title: String) {
        let key = url.absoluteString
        guard !title.isEmpty, var e = entries[key], e.title != title else { return }
        e.title = title
        entries[key] = e
        saver.schedule { [weak self] in self?.saveNow() }
    }

    /// Adds history brought over from another browser. A page already here keeps the later
    /// visit and the higher count, so importing the same browser twice doesn't double anything.
    /// Returns how many pages were new.
    @discardableResult
    func merge(_ imported: [HistoryEntry]) -> Int {
        ensureLoaded()
        var added = 0
        for item in imported {
            guard let scheme = item.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            let key = item.url.absoluteString
            if var e = entries[key] {
                if item.lastVisit > e.lastVisit {
                    e.lastVisit = item.lastVisit
                    if !item.title.isEmpty { e.title = item.title }
                }
                e.visits = max(e.visits, item.visits)
                if e.title.isEmpty { e.title = item.title }
                entries[key] = e
            } else {
                entries[key] = item
                added += 1
            }
        }
        saveNow()
        return added
    }

    /// What the History page is showing: a search, one site, a stretch of time, or all of them.
    struct Filter {
        var query = ""
        /// A site as `URL.displayHost` gives it (no "www.").
        var host: String?
        var start: Date?
        var end: Date?

        func matches(_ e: HistoryEntry, words: [String]) -> Bool {
            if let start, e.lastVisit < start { return false }
            if let end, e.lastVisit > end { return false }
            if let host, e.url.displayHost.lowercased() != host { return false }
            guard !words.isEmpty else { return true }
            let haystack = e.title.lowercased() + " " + e.url.absoluteString.lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// One page of the History page's list: newest first, filtered. Every word of the query has
    /// to appear in the title or the address.
    func browse(_ filter: Filter, offset: Int, limit: Int) -> (items: [HistoryEntry], total: Int) {
        ensureLoaded()
        let words = filter.query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        var list = entries.values.filter { filter.matches($0, words: words) }
        list.sort { $0.lastVisit > $1.lastVisit }
        let start = min(max(0, offset), list.count)
        let end = min(list.count, start + max(0, limit))
        return (Array(list[start..<end]), list.count)
    }

    /// For the History page's sidebar: how many pages fall in each named stretch of time, and
    /// the sites visited most.
    func overview(ranges: [String: (start: Date, end: Date)], siteLimit: Int) -> (total: Int, counts: [String: Int], sites: [(host: String, pages: Int, visits: Int)]) {
        ensureLoaded()
        var counts = ranges.mapValues { _ in 0 }
        var sites: [String: (pages: Int, visits: Int)] = [:]
        for e in entries.values {
            for (name, range) in ranges where e.lastVisit >= range.start && e.lastVisit <= range.end {
                counts[name, default: 0] += 1
            }
            let host = e.url.displayHost.lowercased()
            let old = sites[host] ?? (0, 0)
            sites[host] = (old.pages + 1, old.visits + e.visits)
        }
        let top = sites.sorted { $0.value.visits != $1.value.visits ? $0.value.visits > $1.value.visits : $0.key < $1.key }
            .prefix(siteLimit)
            .map { (host: $0.key, pages: $0.value.pages, visits: $0.value.visits) }
        return (entries.count, counts, Array(top))
    }

    /// Removes every page from one site (`URL.displayHost`). Returns how many went.
    @discardableResult
    func deleteHost(_ host: String) -> Int {
        ensureLoaded()
        let host = host.lowercased()
        let urls = entries.values.filter { $0.url.displayHost.lowercased() == host }.map(\.url)
        delete(urls)
        return urls.count
    }

    /// Removes these pages, for the History page's delete buttons.
    func delete(_ urls: [URL]) {
        ensureLoaded()
        let keys = urls.map(\.absoluteString).filter { entries[$0] != nil }
        guard !keys.isEmpty else { return }
        keys.forEach { entries.removeValue(forKey: $0) }
        saver.schedule { [weak self] in self?.saveNow() }
        ExtensionEventPush.shared.emit("history.onVisitRemoved", args: [["allHistory": false, "urls": keys]])
    }

    /// The site to complete a partly typed address to, inline in the command bar: the most
    /// visited host (without "www.") that starts with what was typed. Only for something that
    /// could be the start of a host (no spaces or slashes).
    func hostCompletion(for typed: String) -> String? {
        let prefix = typed.lowercased()
        guard !prefix.isEmpty, !prefix.contains(" "), !prefix.contains("/"), !prefix.contains(":") else { return nil }
        var visits: [String: Int] = [:]
        for e in entries.values {
            let host = e.url.displayHost.lowercased()
            guard host.count > prefix.count, host.hasPrefix(prefix) else { continue }
            visits[host, default: 0] += e.visits
        }
        return visits.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
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

    var count: Int {
        ensureLoaded()
        return entries.count
    }

    func clear(synchronously: Bool = false) {
        // Whatever is still on disk is about to go anyway.
        loaded = true
        entries.removeAll()
        saveNow(synchronously: synchronously)
        ExtensionEventPush.shared.emit("history.onVisitRemoved", args: [["allHistory": true, "urls": [String]()]])
    }

    func saveNow(synchronously: Bool = false) {
        // Writing before the file was read would replace it with only this run's visits.
        ensureLoaded()
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
        ensureLoaded()
        return entries.values.sorted { $0.visits > $1.visits }
            .prefix(limit)
            .map { ["url": $0.url.absoluteString, "title": $0.title] }
    }

    /// `chrome.history.search`: text match over url / title within a time range, newest first.
    func chromeSearch(text: String, startTime: Double?, endTime: Double?, maxResults: Int) -> [[String: Any]] {
        ensureLoaded()
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
        ensureLoaded()
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
        ensureLoaded()
        entries.removeValue(forKey: url.absoluteString)
        saver.schedule { [weak self] in self?.saveNow() }
        ExtensionEventPush.shared.emit("history.onVisitRemoved", args: [["allHistory": false, "urls": [url.absoluteString]]])
    }

    func deleteRange(startTime: Double, endTime: Double) {
        ensureLoaded()
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

/// Site icons, cached in memory and on disk.
///
/// An icon is kept under the address it was downloaded from, since one host can serve pages
/// with different icons (Google Docs, Sheets and Slides all live on docs.google.com), and also
/// under its host, as the site's most recent icon: that one is what shows before a page has
/// loaded (a restored tab, a History row, a suggestion).
final class FaviconStore {
    static let shared = FaviconStore()

    private let memory = NSCache<NSString, NSImage>()
    /// When each icon was last fetched this run, so every page load on a site doesn't
    /// download its icon again.
    private var fetched: [String: Date] = [:]
    /// How long an icon is trusted before a page load checks for a new one.
    private static let refreshAfter: TimeInterval = 24 * 3600
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

    /// The cache key for one icon file, by its address.
    private func key(forIcon url: URL) -> String { "icon:" + url.absoluteString }

    private func file(for key: String) -> URL {
        // Icon addresses can be long and full of query strings: named by their hash.
        if key.hasPrefix("icon:") {
            let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            return dir.appendingPathComponent("icon-" + digest + ".png")
        }
        let safe = key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return dir.appendingPathComponent(safe + ".png")
    }

    /// The cached icon file for a host, if there is one: already a PNG, so it can be served as is.
    func cachedIconFile(forHost host: String) -> URL? {
        let key = host.lowercased()
        guard !key.isEmpty else { return nil }
        let file = file(for: key)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Synchronous lookup in the memory and disk caches only: the host's latest icon.
    func cachedIcon(for url: URL) -> NSImage? {
        key(for: url).flatMap(image(forKey:))
    }

    private func image(forKey key: String) -> NSImage? {
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
    /// `persist: false` (Incognito) keeps the icon in memory only, for this run of the app.
    func fetchIcon(from webView: WKWebView, persist: Bool = true, completion: @escaping (NSImage?) -> Void) {
        guard let pageURL = webView.url, let hostKey = key(for: pageURL),
              pageURL.scheme == "http" || pageURL.scheme == "https" else {
            completion(nil)
            return
        }
        // Which icon the page declares is asked every time (it's cheap); the download is what
        // the cache saves.
        webView.evaluateJavaScript(Self.iconScript) { [weak self] result, _ in
            guard let self else { return }
            var candidates: [URL] = []
            if let s = result as? String, let u = URL(string: s) { candidates.append(u) }
            if let fallback = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL { candidates.append(fallback) }
            guard let first = candidates.first else { return completion(nil) }
            let iconKey = self.key(forIcon: first)
            if let image = self.freshIcon(for: iconKey, persist: persist) {
                self.remember(image, as: hostKey, persist: persist)
                completion(image)
                return
            }
            self.download(candidates, key: iconKey, hostKey: hostKey, persist: persist, completion: completion)
        }
    }

    /// An icon a page switched to after loading (`LiveFavicon`). A data: icon is drawn by the
    /// page, often many times a second (a game, an unread count), so it's shown as it is and
    /// not cached; one at an address goes through the cache like a load-time icon.
    func icon(at iconURL: URL, pageURL: URL, persist: Bool, completion: @escaping (NSImage?) -> Void) {
        guard let hostKey = key(for: pageURL) else { return completion(nil) }
        switch iconURL.scheme?.lowercased() {
        case "data":
            guard let data = try? Data(contentsOf: iconURL), let image = NSImage(data: data),
                  image.isValid, image.size.width > 0 else { return completion(nil) }
            // Pixel art (a 16×16 canvas) stays crisp instead of being smoothed into a blur.
            let pixels = image.representations.first.map { CGFloat($0.pixelsWide) } ?? image.size.width
            let small = image.resized(to: 64, smooth: pixels <= 0 || pixels >= 64)
            small.size = NSSize(width: 32, height: 32)
            completion(small)
        case "http", "https":
            let iconKey = key(forIcon: iconURL)
            if let image = freshIcon(for: iconKey, persist: persist) {
                remember(image, as: hostKey, persist: persist)
                return completion(image)
            }
            download([iconURL], key: iconKey, hostKey: hostKey, persist: persist, completion: completion)
        default:
            completion(nil)
        }
    }

    /// The cached icon for a site not open in any tab, else its /favicon.ico, downloaded and
    /// cached (the command bar's bang chip uses it).
    func icon(forHost host: String, completion: @escaping (NSImage?) -> Void) {
        let key = host.lowercased()
        guard !key.isEmpty, let site = URL(string: "https://" + key) else { return completion(nil) }
        if let image = cachedIcon(for: site) { return completion(image) }
        guard let url = URL(string: "https://\(key)/favicon.ico") else { return completion(nil) }
        download([url], key: key, hostKey: nil, persist: true, completion: completion)
    }

    /// The cached icon when it is recent enough not to fetch again: fetched earlier this run,
    /// or (outside Incognito) saved to disk within `refreshAfter`.
    private func freshIcon(for key: String, persist: Bool) -> NSImage? {
        let now = Date()
        if let date = fetched[key], now.timeIntervalSince(date) < Self.refreshAfter {
            return memory.object(forKey: key as NSString)
        }
        guard persist,
              let modified = try? file(for: key).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              now.timeIntervalSince(modified) < Self.refreshAfter else { return nil }
        return image(forKey: key)
    }

    private func download(_ candidates: [URL], key: String, hostKey: String?, persist: Bool, completion: @escaping (NSImage?) -> Void) {
        guard let url = candidates.first else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let rest = Array(candidates.dropFirst())
        if url.scheme == "data" {
            if let data = try? Data(contentsOf: url), let image = NSImage(data: data), image.isValid {
                store(image, key: key, hostKey: hostKey, persist: persist, completion: completion)
            } else {
                download(rest, key: key, hostKey: hostKey, persist: persist, completion: completion)
            }
            return
        }
        session.dataTask(with: url) { [weak self] data, response, _ in
            guard let self else { return }
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            if ok, let data, let image = NSImage(data: data), image.isValid, image.size.width > 0 {
                self.store(image, key: key, hostKey: hostKey, persist: persist, completion: completion)
            } else {
                self.download(rest, key: key, hostKey: hostKey, persist: persist, completion: completion)
            }
        }.resume()
    }

    private func store(_ image: NSImage, key: String, hostKey: String?, persist: Bool, completion: @escaping (NSImage?) -> Void) {
        DispatchQueue.main.async {
            let small = image.resized(to: 64)
            small.size = NSSize(width: 32, height: 32)
            self.memory.setObject(small, forKey: key as NSString)
            self.fetched[key] = Date()
            if persist, let png = small.pngData { try? png.write(to: self.file(for: key), options: .atomic) }
            if let hostKey { self.remember(small, as: hostKey, persist: persist) }
            completion(small)
        }
    }

    /// Makes an icon its host's latest, unless it already is.
    private func remember(_ image: NSImage, as hostKey: String, persist: Bool) {
        if memory.object(forKey: hostKey as NSString) === image { return }
        memory.setObject(image, forKey: hostKey as NSString)
        if persist, let png = image.pngData { try? png.write(to: file(for: hostKey), options: .atomic) }
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
    /// Where this download goes: the Settings choice, or what the context menu item said.
    @ObservationIgnored var saveLocation: DownloadManager.SaveLocation = .settings
    /// The temporary file WebKit writes while replacing a file that is already there (WebKit
    /// won't overwrite); it takes the destination's place once the download has finished.
    @ObservationIgnored var partialFile: URL?
    /// What WebKit kept of a stopped or failed download, so it can carry on where it left off.
    var resumeData: Data?
    /// From an Incognito window: never written to the saved downloads list.
    @ObservationIgnored var isPrivate = false
    /// The website data (cookies) the download was made with, for Retry.
    @ObservationIgnored weak var dataStore: WKWebsiteDataStore?
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
    /// Bumped whenever a download starts, so the sidebar button can pulse. Incognito windows
    /// have their own, so a normal window's button doesn't react to an Incognito download.
    var pulse = 0
    var privatePulse = 0
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

    // MARK: Per window

    /// What one kind of window lists: a normal window its own downloads, an Incognito window
    /// only Incognito ones (which never show in a normal window).
    func items(isPrivate: Bool) -> [DownloadItem] { items.filter { $0.isPrivate == isPrivate } }

    func activeCount(isPrivate: Bool) -> Int {
        items.filter { $0.isPrivate == isPrivate && $0.state == .running }.count
    }

    func overallFraction(isPrivate: Bool) -> Double {
        let running = items.filter { $0.isPrivate == isPrivate && $0.state == .running }
        guard !running.isEmpty else { return 0 }
        return running.map(\.fraction).reduce(0, +) / Double(running.count)
    }

    func totalBytesPerSecond(isPrivate: Bool) -> Double? {
        let speeds = items.filter { $0.isPrivate == isPrivate && $0.state == .running }.compactMap(\.bytesPerSecond)
        return speeds.isEmpty ? nil : speeds.reduce(0, +)
    }

    func pulse(isPrivate: Bool) -> Int { isPrivate ? privatePulse : pulse }

    func bumpPulse(isPrivate: Bool) {
        if isPrivate { privatePulse += 1 } else { pulse += 1 }
    }

    /// The browser window a download of this kind belongs to: the one in front if it is of
    /// that kind, else the main window (or, for Incognito, the front window anyway).
    static func window(isPrivate: Bool) -> BrowserState {
        let front = BrowserState.active
        if front.isPrivate == isPrivate { return front }
        return isPrivate ? (BrowserState.all.last { $0.isPrivate } ?? front) : .shared
    }

    /// Takes finished Incognito downloads off the list once the last Incognito window has
    /// closed (the files stay where they were saved). Ones still running stay until they end.
    func forgetPrivateItems() {
        items.removeAll { $0.isPrivate && $0.state != .running }
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

    /// Where a download is saved.
    enum SaveLocation {
        /// As Settings → Downloads says (ask, or the downloads folder).
        case settings
        /// Straight to the downloads folder, without asking (context menu "Download Image").
        case downloadsFolder
        /// Always asks for a name and place ("Save Image As…").
        case ask
    }

    override init() {
        super.init()
        loadSaved()
    }

    func track(
        _ download: WKDownload, chromeID: Int? = nil, url: URL? = nil, saveLocation: SaveLocation = .settings,
        isPrivate: Bool = false
    ) {
        let item = DownloadItem(filename: download.originalRequest?.url?.lastPathComponent ?? "Download")
        item.saveLocation = saveLocation
        // Extensions (`chrome.downloads`, its events) never see an Incognito window's downloads:
        // without an id an item is left out of both.
        item.chromeID = isPrivate ? nil : (chromeID ?? reserveChromeID())
        item.url = url ?? download.originalRequest?.url
        item.isPrivate = isPrivate
        attach(download, to: item)
        items.insert(item, at: 0)
        if let id = item.chromeID {
            ExtensionEventPush.shared.emit("downloads.onCreated", args: [[
                "id": id,
                "url": item.url?.absoluteString ?? "",
                "filename": item.filename,
                "state": "in_progress",
                "bytesReceived": 0,
                "totalBytes": -1,
                "paused": false,
            ]])
        }
        bumpPulse(isPrivate: isPrivate)
        let state = Self.window(isPrivate: isPrivate)
        if AppSettings.shared.downloads.showPanelOnStart, state.downloadsButtonShowing {
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

    /// Hands a WebKit download to an item (a new one, or one being retried / resumed) and
    /// follows its progress.
    func attach(_ download: WKDownload, to item: DownloadItem) {
        download.delegate = self
        item.download = download
        item.dataStore = download.webView?.configuration.websiteDataStore ?? item.dataStore
        item.state = .running
        item.resumeData = nil
        item.lastSampleTime = nil
        item.bytesPerSecond = nil
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
        startSpeedSampling()
    }

    /// Stops a download, keeping what has arrived when the server allows it, so Resume can carry on.
    func cancel(_ item: DownloadItem) {
        let download = item.download
        item.state = .failed("Cancelled")
        item.download = nil
        item.observation = nil
        guard let download else { Self.discardPartialFile(of: item); scheduleSave(); return }
        download.cancel { [weak self, weak item] data in
            DispatchQueue.main.async {
                guard let item else { return }
                item.resumeData = data
                if data == nil { Self.discardPartialFile(of: item) }
                self?.scheduleSave()
            }
        }
    }

    /// Takes everything that isn't running off the list: one kind of window's downloads, or
    /// (nil) all of them.
    func clearFinished(isPrivate: Bool? = nil) {
        let gone = items.filter { $0.state != .running && (isPrivate == nil || $0.isPrivate == isPrivate) }
        gone.forEach(Self.discardIncompleteFile)
        items.removeAll { item in gone.contains { $0 === item } }
        scheduleSave()
    }

    func reveal(_ item: DownloadItem) {
        guard let url = item.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Deletes what a download that was replacing a file had written so far.
    fileprivate static func discardPartialFile(of item: DownloadItem) {
        guard let temp = item.partialFile else { return }
        item.partialFile = nil
        try? FileManager.default.removeItem(at: temp)
    }

    /// Gives a finished download Gatekeeper's "downloaded from the internet" flag, so macOS
    /// checks an app, installer or disk image from it before it first opens, as with Safari.
    /// Tuff isn't sandboxed, so nothing adds the flag for it; one WebKit already set is kept.
    static func markQuarantined(_ file: URL, source: URL?) {
        var url = file
        if let existing = try? url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties,
           !existing.isEmpty { return }
        var properties: [String: Any] = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: "Tuff",
        ]
        if let source, ["http", "https"].contains(source.scheme?.lowercased() ?? "") {
            properties[kLSQuarantineDataURLKey as String] = source
        }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        do {
            try url.setResourceValues(values)
        } catch {
            NSLog("Tuff: couldn’t mark \(file.lastPathComponent) as downloaded: \(error.localizedDescription)")
        }
    }

    static func uniqueDestination(for filename: String) -> URL {
        var downloads = AppSettings.shared.downloads.folder
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: downloads.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        var clean = filename.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        // No name (or only dots and spaces, which would make a hidden or empty one): "Download".
        while clean.first == "." || clean.first?.isWhitespace == true { clean.removeFirst() }
        clean = clean.trimmed
        if clean.isEmpty { clean = "Download" }
        let base = (clean as NSString).deletingPathExtension
        let ext = (clean as NSString).pathExtension
        var candidate = downloads.appendingPathComponent(clean)
        var n = 2
        // Downloads still running hold their names too: their files may not exist yet.
        let taken = Set(shared.items.filter { $0.state == .running }.compactMap { $0.destination?.standardizedFileURL.path })
        while FileManager.default.fileExists(atPath: candidate.path) || taken.contains(candidate.standardizedFileURL.path) {
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
            // Replacing a file (the save panel asked first): WebKit won't overwrite one, so the
            // download goes to a temporary name beside it and replaces it only once it has
            // finished. A download that fails or is cancelled leaves the old file as it was.
            if FileManager.default.fileExists(atPath: url.path) {
                let temp = url.deletingLastPathComponent()
                    .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).download")
                item?.partialFile = temp
                completionHandler(temp)
            } else {
                completionHandler(url)
            }
        }
        let asks = switch item?.saveLocation ?? .settings {
        case .settings: AppSettings.shared.downloads.askWhereToSave
        case .downloadsFolder: false
        case .ask: true
        }
        guard asks else {
            accept(destination)
            return
        }
        let panel = NSSavePanel()
        panel.directoryURL = destination.deletingLastPathComponent()
        panel.nameFieldStringValue = destination.lastPathComponent
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url {
                accept(url)
            } else {
                item?.state = .failed("Cancelled")
                item?.download = nil
                item?.observation = nil
                completionHandler(nil)
            }
        }
        if let window = BrowserState.active.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        if let temp = item.partialFile, let destination = item.destination {
            item.partialFile = nil
            do {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                item.state = .failed("Couldn’t replace \(destination.lastPathComponent)")
                item.download = nil
                item.observation = nil
                return
            }
        }
        if let destination = item.destination { Self.markQuarantined(destination, source: item.url) }
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
        item.resumeData = nil
        scheduleSave()
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
        // With resume data the partial file is what Resume carries on from.
        if resumeData == nil { Self.discardPartialFile(of: item) }
        item.resumeData = resumeData
        item.state = .failed(error.localizedDescription)
        item.download = nil
        item.observation = nil
        scheduleSave()
        if let id = item.chromeID {
            ExtensionEventPush.shared.emit("downloads.onChanged", args: [["id": id, "state": ["current": "interrupted", "previous": "in_progress"]]])
        }
    }
}
