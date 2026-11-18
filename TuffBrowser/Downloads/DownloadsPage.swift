import AppKit
import WebKit

/// The page at tuff://downloads: web downloads, plus the global torrent list in regular windows.
/// settings, an add sheet and a torrent maker. The page asks the app for everything through
/// `dl.*` messages (see `InternalPageHandler`); this answers them.
enum DownloadsWebPage {
    typealias Reply = (Any?, String?) -> Void

    static func html() -> String {
        let accent = BrowserState.active.baseTint.derivedAccent.hexString
        return DownloadsPageTemplate.html.replacingOccurrences(of: "__ACCENT__", with: accent)
    }

    // MARK: Messages

    static func handle(_ command: String, _ body: [String: Any], browser: BrowserState?, reply: @escaping Reply) {
        let manager = DownloadManager.shared
        let isPrivate = browser?.isPrivate ?? false
        let id = body["id"] as? String ?? ""
        let item = manager.items.first { $0.id.uuidString == id && $0.isPrivate == isPrivate }
        if isPrivate, ["dl.torrent", "dl.openTorrent", "dl.pending", "dl.torrents", "dl.create"].contains(command) {
            reply(nil, "Torrents aren’t available in Incognito")
            return
        }

        switch command {
        case "dl.state":
            let snap: (torrents: [[String: Any]], global: [String: Any], events: [[String: Any]]) = isPrivate ? ([], [:], []) : TorrentSession.shared.snapshot()
            var out: [String: Any] = [
                "http": manager.items(isPrivate: isPrivate).map(dict),
                "torrents": snap.torrents,
                "global": snap.global,
                "events": snap.events,
                "httpSpeed": manager.totalBytesPerSecond(isPrivate: isPrivate) ?? 0,
                "pending": isPrivate ? [] : TorrentBridge.pendingSheets(defaultPath: AppSettings.shared.downloads.folder.path),
                "private": isPrivate,
                "torrentsEnabled": isPrivate ? false : TorrentBridge.enabled,
                "advanced": DownloadManager.httpSettings.advanced,
            ]
            let detailID = body["detail"] as? String ?? ""
            if let item = manager.items.first(where: { $0.id.uuidString == detailID && $0.isPrivate == isPrivate }) {
                out["detail"] = detail(item)
                reply(out, nil)
            } else if !detailID.isEmpty, !isPrivate {
                TorrentSession.shared.detail(detailID) { d in
                    if let d { out["detail"] = d }
                    reply(out, nil)
                }
            } else {
                reply(out, nil)
            }

        case "dl.http":
            guard let item else { reply(false, nil); return }
            httpAction(body["action"] as? String ?? "", item, body: body, browser: browser, reply: reply)

        case "dl.torrent":
            torrentAction(body["action"] as? String ?? "", id: id, body: body, browser: browser, reply: reply)

        case "dl.add":
            // One address or magnet per line.
            let lines = (body["text"] as? String ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var added = 0
            for line in lines {
                if line.lowercased().hasPrefix("magnet:"), let url = URL(string: line) {
                    TorrentBridge.offer(magnet: url, isPrivate: isPrivate)
                    if !isPrivate { added += 1 }
                } else if line.count == 40, Data(tHex: line) != nil, let url = URL(string: "magnet:?xt=urn:btih:" + line) {
                    TorrentBridge.offer(magnet: url, isPrivate: isPrivate)
                    if !isPrivate { added += 1 }
                } else if let url = URL(string: line), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    if url.pathExtension.lowercased() == "torrent", DownloadManager.httpSettings.openTorrents {
                        TorrentBridge.offer(remote: url, isPrivate: isPrivate)
                        if isPrivate { continue }
                    } else {
                        manager.addURL(url, isPrivate: isPrivate)
                    }
                    added += 1
                }
            }
            reply(added, added == 0 ? "That isn’t a web address or magnet link" : nil)

        case "dl.openTorrent":
            choose(files: ["torrent"], folders: false, multiple: true, browser: browser) { urls in
                for url in urls { TorrentBridge.offer(file: url, isPrivate: isPrivate) }
                reply(urls.count, nil)
            }

        case "dl.pending":
            TorrentBridge.finish(token: body["token"] as? String ?? "", add: body["add"] as? Bool ?? false, options: body) { error in reply(error == nil, error) }

        case "dl.chooseFolder":
            choose(files: nil, folders: true, multiple: false, browser: browser) { urls in reply(urls.first?.path, nil) }

        case "dl.chooseSource":
            choose(files: [], folders: true, multiple: false, browser: browser) { urls in reply(urls.first?.path, nil) }

        case "dl.chooseFile":
            choose(files: [], folders: false, multiple: false, browser: browser) { urls in reply(urls.first?.path, nil) }

        case "dl.settings":
            TorrentSession.shared.currentSettings { torrent in
                reply(["torrent": isPrivate ? [:] : torrent, "http": DownloadManager.httpSettings.dict, "folder": AppSettings.shared.downloads.folder.path], nil)
            }

        case "dl.setting":
            guard let key = body["key"] as? String, let value = body["value"] else { reply(false, nil); return }
            if isPrivate, body["scope"] as? String != "http", key != "folder" {
                reply(false, "Torrents aren’t available in Incognito")
                return
            }
            if body["scope"] as? String == "http" {
                DownloadManager.httpSettings.apply([key: value])
                manager.runQueue()
            } else if key == "folder", let path = value as? String {
                AppSettings.shared.downloads.folderPath = path
                if !isPrivate { TorrentSession.shared.setDefaultSavePath(URL(fileURLWithPath: path, isDirectory: true)) }
            } else {
                TorrentSession.shared.updateSettings([key: value])
            }
            reply(true, nil)

        case "dl.pauseAll":
            manager.pauseAll(isPrivate: isPrivate)
            if !isPrivate { TorrentSession.shared.perform(.pause, on: TorrentSession.shared.snapshot().torrents.compactMap { $0["id"] as? String }) }
            reply(true, nil)

        case "dl.resumeAll":
            manager.resumeAll(isPrivate: isPrivate)
            if !isPrivate {
                let ids = TorrentSession.shared.snapshot().torrents.filter { ($0["state"] as? String) == "paused" }.compactMap { $0["id"] as? String }
                TorrentSession.shared.perform(.resume, on: ids)
            }
            reply(true, nil)

        case "dl.clear":
            manager.clearFinished(isPrivate: isPrivate)
            reply(true, nil)

        case "dl.torrents":
            TorrentBridge.setEnabled(body["enabled"] as? Bool ?? false)
            reply(TorrentBridge.enabled, nil)

        case "dl.create":
            create(body, browser: browser, reply: reply)

        default:
            reply(nil, "Unknown command")
        }
    }

    // MARK: Web downloads

    private static func stateName(_ item: DownloadItem) -> String {
        switch item.state {
        case .running: "running"
        case .finished: "finished"
        case .failed: item.isPaused ? "paused" : item.isQueued ? "queued" : "failed"
        }
    }

    static func dict(_ item: DownloadItem) -> [String: Any] {
        var d: [String: Any] = [
            "id": item.id.uuidString, "kind": "http", "name": item.filename, "state": stateName(item),
            "progress": item.state == .finished ? 1 : (item.totalBytes > 0 ? Double(item.bytesReceived) / Double(item.totalBytes) : item.fraction),
            "done": item.bytesReceived, "size": item.totalBytes, "speed": item.state == .running ? (item.bytesPerSecond ?? 0) : 0,
            "connections": item.connections, "url": item.url?.absoluteString ?? "", "path": item.destination?.path ?? "",
            "added": item.startedAt.timeIntervalSince1970 * 1000, "category": item.category,
            "resumable": DownloadManager.shared.canRetry(item), "turbo": item.transfer != nil || item.transferState != nil,
        ]
        if case .failed(let reason) = item.state { d["reason"] = reason }
        if let f = item.finishedAt { d["completed"] = f.timeIntervalSince1970 * 1000 }
        if item.state == .running, let speed = item.bytesPerSecond, speed > 0, item.totalBytes > 0 {
            d["eta"] = Double(item.totalBytes - item.bytesReceived) / speed
        }
        return d
    }

    private static func detail(_ item: DownloadItem) -> [String: Any] {
        var d = dict(item)
        d["segments"] = item.transfer?.segmentMap ?? item.transferState?.segments.map { [$0.start, $0.pos, $0.end == .max ? -1 : $0.end] } ?? []
        d["engine"] = item.transfer != nil || item.transferState != nil ? "Multi-connection" : "WebKit"
        if let state = item.transfer?.snapshot() ?? item.transferState {
            d["ranges"] = state.acceptsRanges
            if let e = state.etag { d["etag"] = e }
            if let m = state.lastModified { d["modified"] = m }
        }
        if let url = item.destination, item.state == .finished, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            d["exists"] = true
            d["fileSize"] = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        }
        return d
    }

    private static func httpAction(_ action: String, _ item: DownloadItem, body: [String: Any], browser: BrowserState?, reply: @escaping Reply) {
        let manager = DownloadManager.shared
        switch action {
        case "pause": manager.pause(item)
        case "resume", "retry": manager.retry(item)
        case "stop": manager.cancel(item)
        case "remove": manager.remove(item, deleteFile: false)
        case "removeFile":
            confirm(Prompt(
                symbol: "trash", title: "Move “\(item.filename)” to the Trash?",
                message: "The file goes to the Trash and leaves the downloads list.", confirmTitle: "Move to Trash", destructive: true
            ), browser: browser) { manager.remove(item, deleteFile: true) } reply: { reply($0, nil) }
            return
        case "open": if let url = item.destination { NSWorkspace.shared.open(url) }
        case "reveal": manager.reveal(item)
        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url?.absoluteString ?? "", forType: .string)
        case "again": if let url = item.url { manager.addURL(url, isPrivate: item.isPrivate) }
        case "checksum":
            guard let url = item.destination, item.state == .finished else { reply(nil, "Not downloaded yet"); return }
            DownloadManager.checksum(of: url, kind: body["hash"] as? String ?? "sha256") { reply($0, $0 == nil ? "Couldn’t read the file" : nil) }
            return
        default: reply(nil, "Unknown action"); return
        }
        reply(true, nil)
    }

    // MARK: Torrents

    private static func torrentAction(_ action: String, id: String, body: [String: Any], browser: BrowserState?, reply: @escaping Reply) {
        let session = TorrentSession.shared
        let value = body["value"] as? Bool ?? false
        let ids = (body["ids"] as? [String]) ?? [id]
        if let simple = TorrentSession.Action(rawValue: action), simple != .removeWithFiles {
            session.perform(simple, on: ids, value: value)
            reply(true, nil)
            return
        }
        let summary = session.snapshot().torrents.first { $0["id"] as? String == id }
        let path = summary?["path"] as? String ?? ""
        let name = summary?["name"] as? String ?? "this torrent"
        switch action {
        case "removeWithFiles":
            confirm(Prompt(
                symbol: "trash", title: ids.count > 1 ? "Remove \(ids.count) torrents and their files?" : "Remove “\(name)” and its files?",
                message: "The downloaded files go to the Trash.", confirmTitle: "Remove and Trash", destructive: true
            ), browser: browser) { session.perform(.removeWithFiles, on: ids) } reply: { reply($0, nil) }
        case "open":
            if FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            reply(true, nil)
        case "reveal", "openFile":
            // A file inside the torrent when the page names one, else the torrent itself.
            let target = (body["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? path
            let url = URL(fileURLWithPath: target)
            if action == "openFile", FileManager.default.fileExists(atPath: target) { NSWorkspace.shared.open(url) }
            else if FileManager.default.fileExists(atPath: target) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else { NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()]) }
            reply(true, nil)
        case "copyMagnet":
            session.detail(id) { d in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(d?["magnet"] as? String ?? "", forType: .string)
                reply(true, nil)
            }
        case "export":
            session.torrentFile(id) { data, name in
                guard let data else { reply(nil, "The torrent’s details haven’t arrived yet"); return }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = name + ".torrent"
                panel.allowedContentTypes = [.init(filenameExtension: "torrent") ?? .data]
                present(panel, browser: browser) { ok in
                    if ok, let url = panel.url { try? data.write(to: url, options: .atomic) }
                    reply(ok, nil)
                }
            }
        case "rename":
            let file = (body["file"] as? NSNumber)?.intValue
            Task { @MainActor in
                var prompt = Prompt(symbol: "pencil", title: file == nil ? "Rename “\(name)”" : "Rename file", message: "The name on disk changes too.", confirmTitle: "Rename")
                prompt.fields = [.init(placeholder: "Name", text: body["current"] as? String ?? name)]
                prompt.browser = browser
                let result = await PromptPresenter.ask(prompt)
                guard result.confirmed, let newName = result.fields.first, !newName.isEmpty else { reply(false, nil); return }
                session.rename(id, file: file, to: newName) { reply($0 == nil, $0) }
            }
        case "move":
            choose(files: nil, folders: true, multiple: false, browser: browser) { urls in
                guard let url = urls.first else { reply(false, nil); return }
                session.move(id, to: url) { reply($0 == nil, $0) }
            }
        case "limits":
            session.setLimits(id, download: (body["down"] as? NSNumber)?.intValue, upload: (body["up"] as? NSNumber)?.intValue)
            reply(true, nil)
        case "files":
            var changes: [Int: Int] = [:]
            for (k, v) in body["changes"] as? [String: NSNumber] ?? [:] { if let i = Int(k) { changes[i] = v.intValue } }
            session.setFilePriorities(id, changes)
            reply(true, nil)
        case "stream":
            session.stream(id, file: (body["file"] as? NSNumber)?.intValue ?? 0)
            reply(true, nil)
        case "addTrackers":
            session.addTrackers(id, (body["text"] as? String ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
            reply(true, nil)
        case "removeTracker":
            session.removeTracker(id, body["url"] as? String ?? "")
            reply(true, nil)
        case "addPeer":
            session.addPeer(id, body["addr"] as? String ?? "")
            reply(true, nil)
        default:
            reply(nil, "Unknown action")
        }
    }

    // MARK: Making torrents

    private static func create(_ body: [String: Any], browser: BrowserState?, reply: @escaping Reply) {
        guard let path = body["path"] as? String, !path.isEmpty else { reply(nil, "Choose a file or folder first"); return }
        var creator = TorrentCreator(path: URL(fileURLWithPath: path))
        creator.format = TorrentCreator.Format(rawValue: (body["format"] as? NSNumber)?.intValue ?? 3) ?? .hybrid
        creator.pieceLength = (body["pieceLength"] as? NSNumber)?.intValue ?? 0
        creator.isPrivate = body["private"] as? Bool ?? false
        creator.comment = body["comment"] as? String ?? ""
        creator.source = body["source"] as? String ?? ""
        // Blank lines separate tracker tiers.
        let trackerText = body["trackers"] as? String ?? ""
        creator.trackers = trackerText.components(separatedBy: "\n\n").map { $0.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter(TorrentSource.isTracker) }.filter { !$0.isEmpty }
        creator.webSeeds = (body["webSeeds"] as? String ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("http") }
        let seed = body["seed"] as? Bool ?? true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try creator.create(progress: { _ in }, cancelled: { false }) }
            DispatchQueue.main.async {
                switch result {
                case .failure(let error): reply(nil, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                case .success(let data):
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = creator.path.lastPathComponent + ".torrent"
                    panel.allowedContentTypes = [.init(filenameExtension: "torrent") ?? .data]
                    present(panel, browser: browser) { ok in
                        guard ok, let url = panel.url else { reply(false, nil); return }
                        try? data.write(to: url, options: .atomic)
                        // Seeding needs torrents on; otherwise the .torrent is just saved.
                        guard seed, TorrentBridge.enabled, let source = try? TorrentSource.load(torrent: data) else { reply(true, nil); return }
                        TorrentSession.shared.add(source, savePath: creator.path.deletingLastPathComponent()) { result in
                            if case .success(let id) = result { TorrentSession.shared.perform(.seed, on: [id]) }
                            reply(true, nil)
                        }
                    }
                }
            }
        }
    }

    // MARK: Panels and cards

    private static func choose(files: [String]?, folders: Bool, multiple: Bool, browser: BrowserState?, done: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folders
        panel.canChooseFiles = files != nil
        panel.allowsMultipleSelection = multiple
        panel.canCreateDirectories = folders
        if let files, !files.isEmpty { panel.allowedContentTypes = files.compactMap { .init(filenameExtension: $0) } }
        present(panel, browser: browser) { ok in done(ok ? panel.urls : []) }
    }

    private static func present(_ panel: NSSavePanel, browser: BrowserState?, done: @escaping (Bool) -> Void) {
        if let window = (browser ?? BrowserState.active).window {
            panel.beginSheetModal(for: window) { done($0 == .OK) }
        } else {
            done(panel.runModal() == .OK)
        }
    }

    private static func confirm(_ prompt: Prompt, browser: BrowserState?, then action: @escaping () -> Void, reply: @escaping (Bool) -> Void) {
        Task { @MainActor in
            var prompt = prompt
            prompt.browser = browser
            let ok = await PromptPresenter.present(prompt)
            if ok { action() }
            reply(ok)
        }
    }
}
