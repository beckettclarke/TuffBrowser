import AppKit
import WebKit

/// How web downloads behave: the multi-connection engine and its limits. Saved apart from
/// AppSettings so the downloads page can change them directly.
struct HTTPDownloadSettings {
    /// Large downloads from servers that allow ranges use several connections.
    var turbo = true
    var connections = 8
    /// How many web downloads run at once; the rest wait their turn.
    var maxActive = 5
    /// Bytes per second for all web downloads together; 0 is no limit.
    var speedLimit = 0
    /// .torrent files downloaded from a page open in Tuff's torrent client.
    var openTorrents = true
    /// The downloads page shows everything (peers, trackers, pieces, every setting). Off: just
    /// what most people need.
    var advanced = false

    private static let key = "tuff.httpDownloads"

    static func load() -> HTTPDownloadSettings {
        var s = HTTPDownloadSettings()
        s.apply(UserDefaults.standard.dictionary(forKey: key) ?? [:])
        return s
    }

    var dict: [String: Any] { ["turbo": turbo, "connections": connections, "maxActive": maxActive, "speedLimit": speedLimit, "openTorrents": openTorrents, "advanced": advanced] }

    mutating func apply(_ d: [String: Any]) {
        if let v = d["turbo"] as? Bool { turbo = v }
        if let v = (d["connections"] as? NSNumber)?.intValue { connections = max(1, min(v, 32)) }
        if let v = (d["maxActive"] as? NSNumber)?.intValue { maxActive = max(1, min(v, 50)) }
        if let v = (d["speedLimit"] as? NSNumber)?.intValue { speedLimit = max(0, v) }
        if let v = d["openTorrents"] as? Bool { openTorrents = v }
        if let v = d["advanced"] as? Bool { advanced = v }
    }

    func save() { UserDefaults.standard.set(dict, forKey: Self.key) }
}

extension DownloadItem {
    static let pausedReason = "Paused"
    static let queuedReason = "Queued"

    var isPaused: Bool { if case .failed(let r) = state { return r == Self.pausedReason || r == "Paused when Tuff quit" }; return false }
    var isQueued: Bool { if case .failed(let r) = state { return r == Self.queuedReason }; return false }

    /// What sort of file it is, for the downloads page's filters and icons.
    var category: String {
        let ext = (destination?.pathExtension ?? (filename as NSString).pathExtension).lowercased()
        switch ext {
        case "mp4", "mkv", "mov", "avi", "webm", "m4v", "wmv", "flv", "ts": return "video"
        case "mp3", "m4a", "flac", "wav", "aac", "ogg", "opus", "aiff": return "audio"
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "tiff", "bmp", "avif", "raw": return "image"
        case "zip", "rar", "7z", "gz", "tgz", "bz2", "xz", "tar", "zst": return "archive"
        case "dmg", "pkg", "app", "iso", "exe", "msi", "apk", "ipa": return "app"
        case "pdf", "doc", "docx", "txt", "rtf", "md", "pages", "xls", "xlsx", "csv", "ppt", "pptx", "key", "numbers", "epub": return "document"
        case "torrent": return "torrent"
        default: return "other"
        }
    }
}

extension DownloadManager {
    static var httpSettings = HTTPDownloadSettings.load() {
        didSet {
            httpSettings.save()
            limiter.limit = httpSettings.speedLimit
        }
    }
    static let limiter: SharedLimiter = {
        let l = SharedLimiter()
        l.limit = HTTPDownloadSettings.load().speedLimit
        return l
    }()

    /// WebKit's own user agent with Tuff's application name, as pages see it.
    static var userAgent: String {
        if let custom = AppSettings.shared.advanced.resolvedUserAgent, !custom.isEmpty { return custom }
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) " + WebEngine.userAgentApplicationName
    }

    /// The cookies a request to `url` would carry, from that website data.
    static func cookieHeader(for url: URL, store: WKWebsiteDataStore, done: @escaping (String?) -> Void) {
        store.httpCookieStore.getAllCookies { cookies in
            let host = url.host(percentEncoded: false)?.lowercased() ?? ""
            let secure = url.scheme?.lowercased() == "https"
            let matching = cookies.filter { cookie in
                let domain = cookie.domain.lowercased()
                let domainMatches = domain.hasPrefix(".") ? (host == domain.dropFirst() || host.hasSuffix(domain)) : host == domain
                return domainMatches && url.path.hasPrefix(cookie.path) && (!cookie.isSecure || secure)
            }
            done(HTTPCookie.requestHeaderFields(with: matching)["Cookie"])
        }
    }

    // MARK: Taking over from WebKit

    /// A download WebKit has started that the multi-connection engine can do faster: a plain
    /// GET of a big file from a server that takes ranges. WebKit's is called off and ours
    /// starts at the same place. Returns false to leave it to WebKit.
    func takeOver(_ download: WKDownload, item: DownloadItem, response: URLResponse, destination: URL) -> Bool {
        guard Self.httpSettings.turbo, let http = response as? HTTPURLResponse, http.statusCode == 200,
              let url = http.url ?? download.originalRequest?.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              (download.originalRequest?.httpMethod ?? "GET") == "GET", http.expectedContentLength >= 2 << 20,
              http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") == true,
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.isEmpty || $0 == "identity" }) ?? true
        else { return false }
        item.download = nil
        item.observation = nil
        item.url = url
        var headers = ["User-Agent": download.webView?.customUserAgent.flatMap { $0.isEmpty ? nil : $0 } ?? Self.userAgent]
        if let referer = download.originalRequest?.value(forHTTPHeaderField: "Referer") ?? download.webView?.url?.absoluteString { headers["Referer"] = referer }
        var state = HTTPTransfer.State(url: url)
        state.total = http.expectedContentLength
        state.etag = http.value(forHTTPHeaderField: "ETag")
        state.lastModified = http.value(forHTTPHeaderField: "Last-Modified")
        state.destination = destination.path
        state.partPath = destination.path + ".tuffpart"
        state.headers = headers
        item.totalBytes = state.total
        let store = item.dataStore ?? DataStores.website
        Self.cookieHeader(for: url, store: store) { [weak self, weak item] cookie in
            guard let self, let item else { return }
            if let cookie { state.headers["Cookie"] = cookie }
            self.start(item, state)
        }
        return true
    }

    // MARK: Adding by address

    /// Downloads an address typed into the downloads page, with the window's cookies.
    @discardableResult
    func addURL(_ url: URL, isPrivate: Bool) -> DownloadItem {
        let item = DownloadItem(filename: url.lastPathComponent.isEmpty ? (url.host ?? "Download") : url.lastPathComponent)
        item.url = url
        item.isPrivate = isPrivate
        item.chromeID = isPrivate ? nil : reserveChromeID()
        item.saveLocation = .settings
        let store = isPrivate ? (BrowserState.all.last { $0.isPrivate }?.currentProfile.dataStore ?? DataStores.website) : BrowserState.shared.currentProfile.dataStore
        item.dataStore = store
        items.insert(item, at: 0)
        bumpPulse(isPrivate: isPrivate)
        var state = HTTPTransfer.State(url: url)
        state.headers = ["User-Agent": Self.userAgent]
        Self.cookieHeader(for: url, store: store) { [weak self, weak item] cookie in
            guard let self, let item else { return }
            if let cookie { state.headers["Cookie"] = cookie }
            self.start(item, state)
        }
        return item
    }

    // MARK: Running

    var runningTransfers: Int { items.filter { $0.transfer != nil && $0.state == .running }.count }

    /// Starts (or queues) the multi-connection engine for an item.
    func start(_ item: DownloadItem, _ state: HTTPTransfer.State) {
        item.transferState = state
        item.resumeData = nil
        guard runningTransfers < Self.httpSettings.maxActive else {
            item.state = .failed(DownloadItem.queuedReason)
            scheduleSave()
            return
        }
        let transfer = HTTPTransfer(state: state, connections: Self.httpSettings.connections, limiter: Self.limiter)
        item.transfer = transfer
        item.state = .running
        item.lastSampleTime = nil
        item.bytesPerSecond = nil
        item.bytesReceived = transfer.received
        item.totalBytes = state.total
        if item.startedAt.timeIntervalSinceNow < -1, state.segments.isEmpty { item.startedAt = Date() }
        transfer.decideDestination = { [weak self, weak item] response, suggested in
            guard let self, let item else { return nil }
            return self.chooseDestination(for: item, suggested: suggested)
        }
        transfer.onProgress = { [weak item] got, total in
            guard let item else { return }
            item.bytesReceived = got
            item.totalBytes = total
            item.fraction = total > 0 ? Double(got) / Double(total) : 0
            item.connections = item.transfer?.activeConnections ?? 0
        }
        transfer.onFinish = { [weak self, weak item] result in
            guard let self, let item, item.transfer === transfer else { return }
            item.transferState = transfer.snapshot()
            item.transfer = nil
            item.connections = 0
            switch result {
            case .success(let url): self.transferFinished(item, at: url)
            case .failure(let error):
                let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                item.state = .failed(why)
                if why == "Cancelled" { item.transferState = nil }
                self.scheduleSave()
            }
            self.runQueue()
        }
        transfer.start()
        startSpeedSamplingIfNeeded()
        scheduleSave()
    }

    /// Where an added-by-address download goes, once its name is known.
    private func chooseDestination(for item: DownloadItem, suggested: String) -> URL? {
        let destination = Self.uniqueDestination(for: suggested)
        item.filename = destination.lastPathComponent
        item.destination = destination
        guard AppSettings.shared.downloads.askWhereToSave else { return destination }
        let panel = NSSavePanel()
        panel.directoryURL = destination.deletingLastPathComponent()
        panel.nameFieldStringValue = destination.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        item.filename = url.lastPathComponent
        item.destination = url
        return url
    }

    private func transferFinished(_ item: DownloadItem, at url: URL) {
        Self.markQuarantined(url, source: item.url)
        item.destination = url
        item.filename = url.lastPathComponent
        item.fraction = 1
        item.finishedAt = Date()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? item.bytesReceived
        item.bytesReceived = size
        item.totalBytes = size
        item.state = .finished
        item.transferState = nil
        scheduleSave()
        if let id = item.chromeID {
            ExtensionEventPush.shared.emit("downloads.onChanged", args: [["id": id, "state": ["current": "complete", "previous": "in_progress"]]])
        }
        DistributedNotificationCenter.default().post(name: Notification.Name("com.apple.DownloadFileFinished"), object: url.path)
        fileDidFinish(item)
    }

    /// After any download finishes: torrent files go to the torrent client.
    func fileDidFinish(_ item: DownloadItem) {
        guard let url = item.destination, Self.httpSettings.openTorrents, url.pathExtension.lowercased() == "torrent" else { return }
        TorrentBridge.offer(file: url, isPrivate: item.isPrivate)
    }

    /// Lets queued downloads start as others finish or pause.
    func runQueue() {
        for item in items.reversed() where item.isQueued {
            guard runningTransfers < Self.httpSettings.maxActive, let state = item.transferState else { break }
            start(item, state)
        }
    }

    // MARK: Pause / resume

    func pause(_ item: DownloadItem) {
        if let transfer = item.transfer {
            transfer.pause()
            item.transferState = transfer.snapshot()
            item.transfer = nil
            item.connections = 0
            item.state = .failed(DownloadItem.pausedReason)
            item.bytesPerSecond = nil
            scheduleSave()
            runQueue()
        } else if item.state == .running, let download = item.download {
            item.download = nil
            item.observation = nil
            item.state = .failed(DownloadItem.pausedReason)
            download.cancel { [weak self, weak item] data in
                DispatchQueue.main.async {
                    item?.resumeData = data
                    if data == nil, let item { item.state = .failed("Stopped (this site can’t resume)") }
                    self?.scheduleSave()
                }
            }
        } else if item.isQueued {
            item.state = .failed(DownloadItem.pausedReason)
        }
    }

    /// Resumes a paused, queued or failed item: the engine carries on from its ranges.
    func resumeTransfer(_ item: DownloadItem) -> Bool {
        guard var state = item.transferState, item.transfer == nil else { return false }
        // Cookies may have changed (signed in again): take today's.
        let store = item.dataStore ?? (item.isPrivate ? DataStores.website : BrowserState.shared.currentProfile.dataStore)
        Self.cookieHeader(for: state.url, store: store) { [weak self, weak item] cookie in
            guard let self, let item else { return }
            if let cookie { state.headers["Cookie"] = cookie }
            self.start(item, state)
        }
        return true
    }

    func pauseAll(isPrivate: Bool) {
        for item in items where item.isPrivate == isPrivate && (item.state == .running || item.isQueued) { pause(item) }
    }

    func resumeAll(isPrivate: Bool) {
        for item in items where item.isPrivate == isPrivate && item.isPaused { retry(item) }
    }

    /// Takes an item off the list, optionally moving its file to the Trash.
    func remove(_ item: DownloadItem, deleteFile: Bool) {
        if let transfer = item.transfer { transfer.cancel(); item.transfer = nil }
        if item.state == .running, item.download != nil { item.download?.cancel(); item.download = nil }
        if let part = item.transferState?.partPath { try? FileManager.default.removeItem(atPath: part) }
        if deleteFile, let url = item.destination, item.state == .finished {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } else if item.state != .finished {
            Self.discardIncompleteFile(item)
        }
        items.removeAll { $0 === item }
        scheduleSave()
        runQueue()
    }

    // MARK: Checksums

    /// SHA-256 (or SHA-1 / MD5 by length of `expected`) of a finished file, off the main thread.
    static func checksum(of url: URL, kind: String, done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let handle = try? FileHandle(forReadingFrom: url) else { DispatchQueue.main.async { done(nil) }; return }
            defer { try? handle.close() }
            var sha256 = CryptoHash.SHA256(), sha1 = CryptoHash.SHA1(), md5 = CryptoHash.MD5()
            while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                switch kind {
                case "sha1": sha1.update(data: chunk)
                case "md5": md5.update(data: chunk)
                default: sha256.update(data: chunk)
                }
            }
            let digest: String = switch kind {
            case "sha1": sha1.finalize().map { String(format: "%02x", $0) }.joined()
            case "md5": md5.finalize().map { String(format: "%02x", $0) }.joined()
            default: sha256.finalize().map { String(format: "%02x", $0) }.joined()
            }
            DispatchQueue.main.async { done(digest) }
        }
    }
}

import CryptoKit

enum CryptoHash {
    typealias SHA256 = CryptoKit.SHA256
    typealias SHA1 = Insecure.SHA1
    typealias MD5 = Insecure.MD5
}
