import AppKit

/// Connects the torrent client to the rest of Tuff: starts it at launch, saves its settings,
/// and turns magnet links and .torrent files (from pages, Finder or other apps) into an
/// "Add torrent" sheet on the downloads page.
enum TorrentBridge {
    private static let settingsKey = "tuff.torrentSettings"
    private static let enabledKey = "tuff.torrentsEnabled"
    private static let choiceKey = "tuff.torrentChoiceMade"

    /// Tuff downloads torrents itself. Off until someone says so (the first magnet link asks,
    /// or the switch on the downloads page).
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// The first-magnet question has been answered (Tuff or another app).
    private static var choiceMade: Bool {
        get { UserDefaults.standard.bool(forKey: choiceKey) }
        set { UserDefaults.standard.set(newValue, forKey: choiceKey) }
    }

    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
        if on { choiceMade = true }
        TorrentSession.shared.setEnabled(on)
    }

    /// Another app that opens this magnet link or torrent file (the default one if it isn't
    /// Tuff): its address and name.
    static func otherApp(for url: URL) -> (url: URL, name: String)? {
        let mine = Bundle.main.bundleIdentifier
        func isMine(_ app: URL) -> Bool { Bundle(url: app)?.bundleIdentifier == mine || app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL }
        let candidates = [NSWorkspace.shared.urlForApplication(toOpen: url)].compactMap { $0 } + NSWorkspace.shared.urlsForApplications(toOpen: url)
        guard let app = candidates.first(where: { !isMine($0) && !($0.lastPathComponent.hasPrefix("Tuff")) }) else { return nil }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        return (app, name)
    }

    /// Torrents go through here: straight to Tuff when torrenting is on; to the other app
    /// once that was chosen; otherwise a card asks which, the first time.
    private static func route(_ url: URL, useTuff: @escaping () -> Void) {
        if enabled { useTuff(); return }
        let other = otherApp(for: url)
        if choiceMade, let other {
            NSWorkspace.shared.open([url], withApplicationAt: other.url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            return
        }
        Task { @MainActor in
            var prompt = Prompt(
                symbol: "arrow.down.circle.fill",
                title: "Download torrents in Tuff?",
                message: other == nil
                    ? "Tuff can download magnet links and torrent files itself, on its downloads page. You can turn this off there at any time."
                    : "Tuff can download magnet links and torrent files itself, on its downloads page, or hand them to \(other!.name). You can change this on the downloads page.",
                confirmTitle: "Use Tuff"
            )
            prompt.symbolColor = BrowserState.active.baseTint.derivedAccent
            if let other { prompt.alternateTitle = "Use \(other.name)" }
            let result = await PromptPresenter.ask(prompt)
            if result.confirmed {
                setEnabled(true)
                useTuff()
            } else if result.alternate, let other {
                choiceMade = true
                NSWorkspace.shared.open([url], withApplicationAt: other.url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            }
        }
    }

    /// Torrents waiting for the add sheet, by token.
    private(set) static var pending: [String: TorrentSource] = [:]
    private static var pendingOrder: [String] = []

    static func setUp() {
        let session = TorrentSession.shared
        session.onSettingsChanged = { UserDefaults.standard.set($0, forKey: settingsKey) }
        session.onFinished = { name, path in
            let state = BrowserState.active
            state.show(Toast(symbol: "checkmark.circle.fill", text: "Downloaded \(name)"))
            DistributedNotificationCenter.default().post(name: Notification.Name("com.apple.DownloadFileFinished"), object: path)
            NSApp.requestUserAttention(.informationalRequest)
        }
        session.configure(
            directory: Paths.appSupport.appendingPathComponent("Torrents", isDirectory: true),
            savePath: AppSettings.shared.downloads.folder,
            settings: UserDefaults.standard.dictionary(forKey: settingsKey) ?? [:],
            enabled: enabled
        )
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            session.networkChanged()
        }
    }

    /// Opens what another app or Finder handed Tuff, if it's a torrent. False for anything else.
    static func open(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "magnet" { offer(magnet: url); return true }
        if url.isFileURL, url.pathExtension.lowercased() == "torrent" { offer(file: url, isPrivate: false); return true }
        return false
    }

    static func offer(magnet: URL, isPrivate: Bool = false) {
        guard !isPrivate else { declineIncognito(); return }
        route(magnet) {
            do { queue(try TorrentSource.load(magnet: magnet.absoluteString)) } catch { complain(error) }
        }
    }

    static func offer(file: URL, isPrivate: Bool) {
        guard !isPrivate else { declineIncognito(); return }
        route(file) {
            do { queue(try TorrentSource.load(torrent: Data(contentsOf: file))) } catch { complain(error) }
        }
    }

    /// A .torrent on the web: fetched first (with the torrent proxy, if any).
    static func offer(remote url: URL, isPrivate: Bool = false) {
        // With torrents off, it's just a file: download it, and the finished file asks.
        guard enabled else { DownloadManager.shared.addURL(url, isPrivate: isPrivate); return }
        guard !isPrivate else { declineIncognito(); return }
        route(url) {
            TorrentSession.shared.fetchTorrent(url) { result in
                switch result {
                case .success(let source): queue(source)
                case .failure(let error): complain(error)
                }
            }
        }
    }

    private static func declineIncognito() {
        Task { @MainActor in
            var prompt = Prompt(
                symbol: "magnet",
                title: "Torrents aren’t available in Incognito",
                message: "Tuff’s torrent list and resume data are saved on disk. Open this magnet link or torrent file in a regular window instead.",
                confirmTitle: "OK",
                cancelTitle: nil
            )
            prompt.browser = BrowserState.active
            _ = await PromptPresenter.present(prompt)
        }
    }

    private static func complain(_ error: Error) {
        BrowserState.active.show(Toast(symbol: "exclamationmark.triangle.fill", text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
    }

    private static func queue(_ source: TorrentSource) {
        let token = UUID().uuidString
        pending[token] = source
        pendingOrder.append(token)
        BrowserState.active.showDownloadsPage()
    }

    /// The sheets the page should show, oldest first.
    static func pendingSheets(defaultPath: String) -> [[String: Any]] {
        pendingOrder.compactMap { token in
            guard let s = pending[token] else { return nil }
            var d: [String: Any] = ["token": token, "name": s.name, "hash": s.infoHash.tHex, "magnet": s.info == nil, "path": defaultPath, "trackers": s.trackers.flatMap { $0 }.count]
            if let info = s.info {
                d["size"] = info.totalLength
                d["version"] = info.hasV1 && info.hasV2 ? "Hybrid" : info.hasV2 ? "v2" : "v1"
                d["private"] = info.isPrivate
                if let c = info.comment { d["comment"] = c }
                d["files"] = info.files.enumerated().compactMap { i, f -> [String: Any]? in
                    f.isPad ? nil : ["i": i, "path": f.path.joined(separator: "/"), "size": f.length, "on": s.selectOnly.map { $0.contains(i) } ?? true]
                }
            }
            return d
        }
    }

    static func finish(token: String, add: Bool, options: [String: Any], done: @escaping (String?) -> Void) {
        guard let source = pending.removeValue(forKey: token) else { done("It’s gone"); return }
        pendingOrder.removeAll { $0 == token }
        guard add else { done(nil); return }
        let path = (options["path"] as? String).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        var priorities: [Int]?
        if let info = source.info, let picked = options["files"] as? [NSNumber] {
            let on = Set(picked.map(\.intValue))
            priorities = info.files.indices.map { info.files[$0].isPad ? 0 : (on.contains($0) ? 1 : 0) }
        }
        TorrentSession.shared.add(source, savePath: path, paused: options["paused"] as? Bool ?? false, sequential: options["sequential"] as? Bool ?? false, priorities: priorities) { result in
            switch result {
            case .success(let id):
                if options["firstLast"] as? Bool == true { TorrentSession.shared.perform(.firstLast, on: [id], value: true) }
                done(nil)
            case .failure(let error): done(error.localizedDescription)
            }
        }
    }
}

extension BrowserState {
    /// Opens the downloads page in a new tab, or goes to the tab already showing it in this space.
    func showDownloadsPage() {
        let space = currentSpace
        if let showing = (space.tabs + space.allPinned + favorites).first(where: { InternalPage(url: $0.url) == .downloads }) {
            select(showing)
        } else {
            newTab(url: InternalPage.downloads.url)
        }
    }
}
