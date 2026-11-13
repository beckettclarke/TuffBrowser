import AppKit
import CryptoKit
import Observation
import WebKit

struct ExtensionRecord: Codable, Identifiable, Equatable {
    enum Source: String, Codable { case chrome, firefox, unpacked }

    /// Chrome Web Store ID for Chrome extensions; a stable generated ID otherwise.
    var id: String
    var source: Source
    /// Chrome ID or Firefox add-on slug — what we ask the store for when updating.
    var storeID: String?
    var name: String
    var version: String
    var enabled: Bool
    /// Only for unpacked extensions: the folder they are loaded from, in place.
    var path: String?
    var lastError: String?
    /// What the extension set through `chrome.sidePanel` that Chrome keeps across restarts.
    var sidePanel: SidePanelPrefs?
    /// Profiles and spaces (by ID) the extension is limited to. Nil or empty: every space.
    var linkedTo: [UUID]?
}

struct SidePanelPrefs: Codable, Equatable {
    var path: String?
    var enabled: Bool?
    var openOnActionClick: Bool?
}

struct ExtensionActionInfo: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    let badge: String
    let enabled: Bool
    /// Whether the extension has a side panel, and whether it is the one open now.
    let hasPanel: Bool
    let panelOpen: Bool
}

/// Hosts WebExtensions (Chrome MV2/MV3 and Firefox) on top of WebKit's `WKWebExtensionController`.
@Observable
final class ExtensionManager: NSObject {
    static let shared = ExtensionManager()

    var records: [ExtensionRecord] = []
    /// Bumped when toolbar actions change (icon, badge, enabled state) so the sidebar refreshes.
    var revision = 0
    /// Human readable progress for an install in flight, e.g. "Downloading…".
    var status: String?

    @ObservationIgnored let controller: WKWebExtensionController
    @ObservationIgnored let windowAdapter = BrowserWindowAdapter()
    @ObservationIgnored private(set) var contexts: [String: WKWebExtensionContext] = [:]
    @ObservationIgnored private let anchors = NSMapTable<NSString, NSView>.strongToWeakObjects()
    @ObservationIgnored private var nativePorts: [ObjectIdentifier: NativeMessagingHost] = [:]
    /// Hidden pages that open WebSockets for extensions' service workers (see ExtensionCompat).
    @ObservationIgnored private var socketRelays: [String: SocketRelay] = [:]
    @ObservationIgnored private var started = false
    /// Extensions whose `load` is in flight.
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private let linkDebouncer = Debouncer(delay: 0.25)
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]

    private let recordsFile = Paths.appSupport.appendingPathComponent("extensions.json")
    let extensionsDirectory = Paths.appSupport.appendingPathComponent("Extensions", isDirectory: true)

    private var browser: BrowserState { .shared }

    private override init() {
        WKWebExtension.MatchPattern.registerCustomURLScheme("chrome-extension")
        let configuration = DataStores.extensionControllerConfiguration()
        configuration.defaultWebsiteDataStore = DataStores.website
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
        try? FileManager.default.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
    }

    /// Debug-build hook for watching what extensions ask the browser to do.
    @ObservationIgnored var tracer: ((String) -> Void)?
    func trace(_ message: @autoclosure () -> String) {
        if let tracer { tracer(message()) }
    }

    // MARK: Startup

    func start() {
        guard !started else { return }
        started = true
        if let data = try? Data(contentsOf: recordsFile),
           let list = try? JSONDecoder().decode([ExtensionRecord].self, from: data) {
            records = list
        }
        controller.didOpenWindow(windowAdapter)
        controller.didFocusWindow(windowAdapter)
        // Before the session is restored there is no space yet, so only extensions that run
        // everywhere start here; `applyLinks()` starts the rest once it is.
        for record in records where shouldRun(record) {
            Task { @MainActor in await self.load(record) }
        }
    }

    // MARK: Profiles and spaces

    /// Whether the extension runs in `space`. Links to profiles or spaces that no longer exist
    /// are ignored, and an extension left with none runs everywhere.
    func isLinked(_ record: ExtensionRecord, to space: Space?) -> Bool {
        let live = liveLinks(record)
        guard !live.isEmpty else { return true }
        guard let space else { return false }
        return live.contains(space.id) || live.contains(space.profileID)
    }

    /// The record's links that still name a profile or space.
    func liveLinks(_ record: ExtensionRecord) -> Set<UUID> {
        guard let ids = record.linkedTo, !ids.isEmpty else { return [] }
        let known = Set(browser.profiles.map(\.id) + browser.spaces.map(\.id))
        return Set(ids).intersection(known)
    }

    private func shouldRun(_ record: ExtensionRecord) -> Bool {
        guard record.enabled else { return false }
        return isLinked(record, to: browser.spaces.isEmpty ? nil : browser.currentSpace)
    }

    private func shouldRun(id: String) -> Bool {
        records.first { $0.id == id }.map(shouldRun) ?? false
    }

    /// Starts extensions linked to the space now showing and stops ones that aren't.
    func applyLinks() {
        guard started else { return }
        for record in records {
            let running = contexts[record.id] != nil || loading.contains(record.id)
            if shouldRun(record), !running {
                Task { @MainActor in await self.load(record) }
            } else if !shouldRun(record), contexts[record.id] != nil {
                trace("unloading \(record.name): not linked to this space")
                unload(record.id)
            }
        }
    }

    /// Called whenever the space on screen (or its profile) changes. Waits a moment so
    /// flicking through several spaces doesn't start and stop extensions on each one.
    func spaceDidChange() {
        linkDebouncer.schedule { [weak self] in self?.applyLinks() }
    }

    /// Limits an extension to these profiles / spaces; nil or empty runs it everywhere.
    func setLinks(_ ids: [UUID]?, id: String) {
        update(id) { $0.linkedTo = (ids?.isEmpty ?? true) ? nil : ids }
        revision += 1
        applyLinks()
    }

    func toggleLink(_ target: UUID, id: String) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        var links = liveLinks(record)
        if links.contains(target) { links.remove(target) } else { links.insert(target) }
        setLinks(Array(links), id: id)
    }

    /// Drops links to a profile or space that was deleted.
    func forgetLinks(to target: UUID) {
        for record in records where record.linkedTo?.contains(target) ?? false {
            update(record.id) { r in
                r.linkedTo?.removeAll { $0 == target }
                if r.linkedTo?.isEmpty ?? false { r.linkedTo = nil }
            }
        }
        applyLinks()
    }

    func profileDeleted(_ id: UUID) { forgetLinks(to: id) }

    /// "Home, School" — where a linked extension runs; nil when it runs everywhere.
    func linkSummary(_ record: ExtensionRecord) -> String? {
        let live = liveLinks(record)
        guard !live.isEmpty else { return nil }
        let names = browser.profiles.filter { live.contains($0.id) }.map(\.name)
            + browser.spaces.filter { live.contains($0.id) }.map(\.name)
        return names.joined(separator: ", ")
    }

    /// The extension's icon, read from its manifest when it isn't loaded.
    func icon(for record: ExtensionRecord) -> NSImage? {
        if let icon = contexts[record.id]?.webExtension.icon(for: CGSize(width: 32, height: 32)) { return icon }
        if let icon = iconCache[record.id] { return icon }
        let folder = directory(for: record)
        guard let manifest = try? Self.readManifest(in: folder), let icon = Self.manifestIcon(manifest, in: folder) else { return nil }
        iconCache[record.id] = icon
        return icon
    }

    private func saveRecords() {
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: recordsFile, options: .atomic) }
    }

    /// Where the extension's files are: its own folder for unpacked extensions.
    func directory(for record: ExtensionRecord) -> URL {
        if let path = record.path { return URL(fileURLWithPath: path, isDirectory: true) }
        return extensionsDirectory.appendingPathComponent(record.id, isDirectory: true)
    }

    /// Copies of unpacked extensions, which is what actually gets loaded (see `stageUnpacked`).
    private var unpackedCopiesDirectory: URL { Paths.appSupport.appendingPathComponent("Unpacked", isDirectory: true) }

    /// Unpacked extensions are developed in place, so Tuff never writes into their folder.
    /// They are loaded from a copy instead, synced from the folder on every load (launch,
    /// enable, Reload), with the compatibility shim added like any other extension's. Without
    /// it they would miss everything the shim provides, `chrome.sidePanel` included.
    @MainActor
    private func stageUnpacked(_ record: ExtensionRecord) async throws -> URL {
        let source = directory(for: record)
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
            throw InstallError.noManifest
        }
        let copy = unpackedCopiesDirectory.appendingPathComponent(record.id, isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        // Only changed files are copied; the shim's edits from last time are undone (rsync sees
        // them as changed) and then made again by `patch`.
        try await Self.runTool("/usr/bin/rsync", ["-a", "--delete", "--exclude", ".git", source.path + "/", copy.path + "/"])
        ExtensionCompat.patch(extensionAt: copy)
        return copy
    }

    private static func runTool(_ path: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CocoaError(.fileWriteUnknown))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    func updateSidePanelPrefs(_ id: String, _ change: (inout SidePanelPrefs) -> Void) {
        update(id) { record in
            var prefs = record.sidePanel ?? SidePanelPrefs()
            change(&prefs)
            record.sidePanel = prefs
        }
    }

    private func update(_ id: String, _ change: (inout ExtensionRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        saveRecords()
    }

    // MARK: Loading

    @MainActor
    private func load(_ record: ExtensionRecord) async {
        guard contexts[record.id] == nil, !loading.contains(record.id) else { return }
        loading.insert(record.id)
        defer { loading.remove(record.id) }
        do {
            let resources: URL
            if record.path == nil {
                resources = directory(for: record)
                ExtensionCompat.refresh(extensionAt: resources)
            } else {
                resources = try await stageUnpacked(record)
            }
            let webExtension = try await WKWebExtension(resourceBaseURL: resources)
            let context = WKWebExtensionContext(for: webExtension)
            context.uniqueIdentifier = record.id
            // A fixed address per extension. Left to itself WebKit picks a random one on every
            // launch, which strands restored tabs and the extension's page storage
            // (localStorage, IndexedDB) under an origin that no longer exists.
            if let base = Self.baseURL(for: record) { context.baseURL = base }
            context.isInspectable = true

            // Like Chrome, permissions listed in the manifest are granted at install time
            // (the user already confirmed them in the install prompt).
            for permission in webExtension.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            // WebKit only delivers webRequest events to an extension that also holds
            // webRequestBlocking (it can't block either way). Chrome and Firefox deliver them with
            // webRequest alone, which is all a request-watching extension asks for.
            let blocking = WKWebExtension.Permission(rawValue: "webRequestBlocking")
            if webExtension.requestedPermissions.contains(.webRequest), !webExtension.requestedPermissions.contains(blocking) {
                context.setPermissionStatus(.grantedExplicitly, for: blocking)
            }
            for pattern in webExtension.allRequestedMatchPatterns {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }

            // The space changed while the files were being read.
            guard shouldRun(id: record.id) else { return }
            try controller.load(context)
            contexts[record.id] = context
            update(record.id) {
                $0.name = webExtension.displayName ?? $0.name
                $0.version = webExtension.displayVersion ?? webExtension.version ?? $0.version
                $0.lastError = nil
            }
            // Tabs restored on this extension's pages woke up before it was available.
            for tab in browser.allTabs where tab.isAwake && self.context(forPage: tab.url) === context {
                if tab.awaitingExtension || tab.webView?.url == nil { tab.rebuildForExtension() }
            }
            if webExtension.hasBackgroundContent {
                context.loadBackgroundContent { error in
                    if let error { NSLog("Tuff: background content failed for \(record.name): \(error.localizedDescription)") }
                }
            }
            SidePanelManager.shared.extensionLoaded(record.id)
            revision += 1
        } catch {
            NSLog("Tuff: failed to load extension \(record.name): \(error)")
            update(record.id) { $0.lastError = error.localizedDescription }
        }
    }

    private func unload(_ id: String) {
        socketRelays.removeValue(forKey: id)?.stop()
        ExtensionOffscreen.shared.extensionUnloaded(id)
        ExtensionEventPush.shared.extensionUnloaded(id)
        SidePanelManager.shared.extensionUnloaded(id)
        guard let context = contexts.removeValue(forKey: id) else { return }
        try? controller.unload(context)
        revision += 1
    }

    func setEnabled(_ enabled: Bool, id: String) {
        update(id) { $0.enabled = enabled }
        guard let record = records.first(where: { $0.id == id }) else { return }
        ExtensionEventPush.shared.emit(enabled ? "management.onEnabled" : "management.onDisabled", args: [ExtensionAPIBridge.shared.managementInfo(record)])
        if enabled {
            guard shouldRun(record) else { return }
            Task { @MainActor in await self.load(record) }
        } else {
            unload(id)
        }
    }

    func uninstall(id: String) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        ExtensionEventPush.shared.emit("management.onUninstalled", args: [id])
        unload(id)
        if record.path == nil {
            try? FileManager.default.removeItem(at: directory(for: record))
        } else {
            try? FileManager.default.removeItem(at: unpackedCopiesDirectory.appendingPathComponent(record.id, isDirectory: true))
        }
        records.removeAll { $0.id == id }
        saveRecords()
    }

    func reload(id: String) {
        guard let record = records.first(where: { $0.id == id }), record.enabled else { return }
        unload(id)
        guard shouldRun(record) else { return }
        Task { @MainActor in await self.load(record) }
    }

    /// `chrome-extension://<id>/` for Chrome and unpacked extensions (what they expect their
    /// origin to look like), `webkit-extension://<id>/` for Firefox ones. Firefox's own
    /// `moz-extension:` is avoided on purpose: extensions read it as "running in Firefox" and
    /// switch on Gecko-only code paths.
    static func baseURL(for record: ExtensionRecord) -> URL? {
        let scheme = record.source == .firefox ? "webkit-extension" : "chrome-extension"
        return URL(string: "\(scheme)://\(record.id)/")
    }

    static func isExtensionPage(_ url: URL?) -> Bool {
        url?.scheme?.hasSuffix("-extension") ?? false
    }

    /// The extension that owns an extension page URL, if it is loaded.
    func context(forPage url: URL?) -> WKWebExtensionContext? {
        guard let url, Self.isExtensionPage(url) else { return nil }
        return controller.extensionContext(for: url)
    }

    func displayName(forPage url: URL?) -> String? {
        if let context = context(forPage: url) { return context.webExtension.displayName }
        // Not loaded (yet): every extension's address uses its ID as the host, so fall back to our record.
        return records.first { $0.id == url?.host }?.name
    }

    func icon(forPage url: URL?) -> NSImage? {
        context(forPage: url)?.webExtension.icon(for: CGSize(width: 32, height: 32))
    }

    /// Web views that display an extension's own pages must use that extension's configuration.
    func configuration(forExtensionPage url: URL?) -> WKWebViewConfiguration? {
        guard let url, let scheme = url.scheme, scheme.hasSuffix("-extension") else { return nil }
        return controller.extensionContext(for: url)?.webViewConfiguration
    }

    // MARK: Installing

    enum InstallSource {
        case chrome(id: String)
        case firefox(slug: String)
        case archive(URL)
        case folder(URL)
    }

    enum InstallError: LocalizedError {
        case badResponse, badArchive, noManifest, theme, cancelled
        var errorDescription: String? {
            switch self {
            case .badResponse: "The store didn’t return an extension package."
            case .badArchive: "The extension package couldn’t be unpacked."
            case .noManifest: "No manifest.json was found in the extension."
            case .theme: "This is a browser theme, which Tuff can’t use. Tuff’s own look is set in Settings › Appearance."
            case .cancelled: "Cancelled."
            }
        }
    }

    static func chromeDownloadURL(id: String) -> URL {
        // prodversion must be at least the extension's minimum_chrome_version, so claim a recent Chrome.
        let x = "id%3D\(id)%26installsource%3Dondemand%26uc"
        return URL(string: "https://clients2.google.com/service/update2/crx?response=redirect&os=mac&arch=arm64&os_arch=arm64&prod=chromecrx&prodchannel=stable&prodversion=140.0.0.0&lang=en-US&acceptformat=crx2,crx3&x=\(x)")!
    }

    static func firefoxDownloadURL(slug: String) -> URL? {
        let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        return URL(string: "https://addons.mozilla.org/firefox/downloads/latest/\(encoded)/latest.xpi")
    }

    /// Accepts a Chrome Web Store / Firefox Add-ons URL, or a bare Chrome extension ID.
    static func source(from text: String) -> InstallSource? {
        let input = text.trimmed
        if input.range(of: "^[a-p]{32}$", options: .regularExpression) != nil { return .chrome(id: input) }
        guard let url = URL(string: input), let host = url.host else { return nil }
        if host.contains("chromewebstore.google.com") || host.contains("chrome.google.com") {
            if let id = url.pathComponents.last(where: { $0.range(of: "^[a-p]{32}$", options: .regularExpression) != nil }) {
                return .chrome(id: id)
            }
        }
        if host == "addons.mozilla.org", let i = url.pathComponents.firstIndex(of: "addon"), i + 1 < url.pathComponents.count {
            return .firefox(slug: url.pathComponents[i + 1])
        }
        return nil
    }

    func install(_ source: InstallSource, confirm: Bool = true) {
        Task { @MainActor in await self.installNow(source, confirm: confirm) }
    }

    /// Installs and reports whether the extension ended up installed (false if the user
    /// cancelled or it failed; failures are explained to the user here).
    @MainActor @discardableResult
    func installNow(_ source: InstallSource, confirm: Bool = true) async -> Bool {
        defer { status = nil }
        do {
            try await performInstall(source, confirm: confirm)
            return true
        } catch InstallError.cancelled {
            return false
        } catch {
            status = nil
            await PromptPresenter.present(Prompt(
                title: "Couldn’t add the extension", message: error.localizedDescription,
                confirmTitle: "OK", cancelTitle: nil
            ))
            return false
        }
    }

    /// The installed extension a store page is about, if any.
    func record(store: String, id: String) -> ExtensionRecord? {
        switch store {
        case "chrome": records.first { $0.source == .chrome && ($0.storeID == id || $0.id == id) }
        case "firefox": records.first { $0.source == .firefox && $0.storeID == id }
        default: nil
        }
    }

    /// Asks, then removes. Returns whether it was removed.
    @MainActor
    func confirmUninstall(id: String) async -> Bool {
        guard let record = records.first(where: { $0.id == id }) else { return true }
        let icon = contexts[id]?.webExtension.icon(for: CGSize(width: 64, height: 64))
        let confirmed = await PromptPresenter.present(Prompt(
            icon: icon, title: "Remove “\(record.name)”?", subtitle: "From Tuff",
            confirmTitle: "Remove", destructive: true
        ))
        guard confirmed else { return false }
        uninstall(id: id)
        browser.show(Toast(symbol: "trash", text: "Removed \(record.name)"))
        return true
    }

    @MainActor
    private func performInstall(_ source: InstallSource, confirm: Bool) async throws {
        let fm = FileManager.default

        if case .folder(let folder) = source {
            let manifest = try Self.readManifest(in: folder)
            let id = Self.generatedID(from: folder.path)
            if confirm, !(await confirmInstall(manifest: manifest, in: folder, origin: "a folder on this Mac")) {
                throw InstallError.cancelled
            }
            finishInstall(ExtensionRecord(
                id: id, source: .unpacked, storeID: nil, name: Self.rawName(manifest),
                version: manifest["version"] as? String ?? "", enabled: true, path: folder.path
            ))
            return
        }

        // 1. Get the package.
        let package: Data
        let recordSource: ExtensionRecord.Source
        let storeID: String?
        let id: String
        let origin: String
        switch source {
        case .chrome(let chromeID):
            status = "Downloading from the Chrome Web Store…"
            package = try await Self.download(Self.chromeDownloadURL(id: chromeID))
            recordSource = .chrome; storeID = chromeID; id = chromeID; origin = "the Chrome Web Store"
        case .firefox(let slug):
            status = "Downloading from Firefox Add-ons…"
            guard let url = Self.firefoxDownloadURL(slug: slug) else { throw InstallError.badResponse }
            package = try await Self.download(url)
            recordSource = .firefox; storeID = slug; id = Self.generatedID(from: "firefox:" + slug); origin = "Firefox Add-ons"
        case .archive(let file):
            package = try Data(contentsOf: file)
            let isFirefox = file.pathExtension.lowercased() == "xpi"
            recordSource = isFirefox ? .firefox : .chrome
            storeID = nil; id = Self.generatedID(from: file.lastPathComponent); origin = "a file on this Mac"
        case .folder:
            return
        }

        // 2. Unpack into a staging folder.
        status = "Unpacking…"
        guard let zip = Self.zipPayload(of: package) else { throw InstallError.badArchive }
        let staging = fm.temporaryDirectory.appendingPathComponent("tuff-ext-\(UUID().uuidString)", isDirectory: true)
        let zipFile = staging.appendingPathComponent("package.zip")
        let unpacked = staging.appendingPathComponent("contents", isDirectory: true)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try zip.write(to: zipFile)
        try await Self.unzip(zipFile, to: unpacked)

        var root = unpacked
        if !fm.fileExists(atPath: root.appendingPathComponent("manifest.json").path),
           let only = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter({ $0.hasDirectoryPath }),
           only.count == 1 {
            root = only[0]
        }
        let manifest = try Self.readManifest(in: root)
        if manifest["theme"] != nil { throw InstallError.theme }

        // 3. Ask, then move into place.
        status = nil
        let isUpdate = records.contains { $0.id == id }
        if confirm, !isUpdate, !(await confirmInstall(manifest: manifest, in: root, origin: origin)) {
            throw InstallError.cancelled
        }

        ExtensionCompat.patch(extensionAt: root)
        unload(id)
        let destination = extensionsDirectory.appendingPathComponent(id, isDirectory: true)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: root, to: destination)

        finishInstall(ExtensionRecord(
            id: id, source: recordSource, storeID: storeID, name: Self.rawName(manifest),
            version: manifest["version"] as? String ?? "", enabled: true, path: nil
        ))
    }

    @MainActor
    private func finishInstall(_ record: ExtensionRecord) {
        var record = record
        let existing = records.first { $0.id == record.id }
        let isUpdate = existing != nil
        // An update keeps the profiles / spaces the extension was linked to.
        record.linkedTo = existing?.linkedTo
        iconCache[record.id] = nil
        unload(record.id)
        records.removeAll { $0.id == record.id }
        records.append(record)
        saveRecords()
        Task { @MainActor in
            // When replacing a running extension, give WebKit a moment to tear the old
            // background worker down before the new files are loaded under the same origin.
            if isUpdate { try? await Task.sleep(nanoseconds: 800_000_000) }
            await self.load(record)
            if !isUpdate {
                SidePanelManager.shared.extensionInstalled(record.id)
                ExtensionEventPush.shared.emit("management.onInstalled", args: [ExtensionAPIBridge.shared.managementInfo(record)])
            }
            let name = self.records.first { $0.id == record.id }?.name ?? record.name
            self.browser.show(Toast(symbol: "puzzlepiece.extension.fill", text: isUpdate ? "Updated \(name)" : "Added \(name)"))
        }
    }

    func updateFromStore(id: String) {
        guard let record = records.first(where: { $0.id == id }), let storeID = record.storeID else { return }
        switch record.source {
        case .chrome: install(.chrome(id: storeID), confirm: false)
        case .firefox: install(.firefox(slug: storeID), confirm: false)
        case .unpacked: reload(id: id)
        }
    }

    @MainActor
    private func confirmInstall(manifest: [String: Any], in folder: URL, origin: String) async -> Bool {
        var wanted: [String] = []
        for key in ["permissions", "host_permissions"] {
            wanted += (manifest[key] as? [Any] ?? []).compactMap { $0 as? String }
        }

        // WebKit lets extensions observe requests but not block or rewrite them from script, so
        // an extension built on that (uBlock Origin, most Firefox blockers) installs and opens
        // but does not filter anything. Better to say so now than to look broken later.
        var note: String?
        if wanted.contains("webRequestBlocking") {
            note = "This extension blocks requests in a way Tuff’s engine (WebKit) doesn’t support, "
                + "so that part of it won’t work. If there’s a “Lite” or Manifest V3 edition, add that instead."
        }

        return await PromptPresenter.present(Prompt(
            icon: Self.manifestIcon(manifest, in: folder),
            title: "Add “\(Self.rawName(manifest))”?",
            subtitle: "From \(origin)",
            itemsHeading: "It can:",
            items: Self.permissionSummary(manifest),
            note: note,
            confirmTitle: "Add Extension"
        ))
    }

    private static let permissionDescriptions: [(permissions: [String], symbol: String, text: String)] = [
        (["history", "tabs", "webNavigation", "declarativeNetRequestFeedback"], "clock.arrow.circlepath", "Read your browsing history"),
        (["declarativeNetRequest"], "hand.raised", "Block content on any page"),
        (["bookmarks"], "bookmark", "Read and change your bookmarks"),
        (["downloads"], "arrow.down.circle", "Manage your downloads"),
        (["clipboardRead"], "doc.on.clipboard", "Read data you copy and paste"),
        (["clipboardWrite"], "doc.on.clipboard", "Change data you copy and paste"),
        (["notifications"], "bell", "Show notifications"),
        (["nativeMessaging"], "app.connected.to.app.below.fill", "Talk to apps installed on this Mac"),
        (["management"], "puzzlepiece.extension", "Manage your other extensions"),
        (["privacy", "contentSettings", "proxy"], "gearshape", "Change your privacy and site settings"),
        (["geolocation"], "location", "Know your location"),
        (["topSites"], "square.grid.2x2", "See the sites you visit most"),
        (["tabCapture", "desktopCapture"], "rectangle.dashed.badge.record", "Capture what’s on your screen"),
        (["cookies"], "lock.shield", "Read and change cookies on sites it can access"),
    ]

    /// Plain-language lines for what an extension asks to do, in the spirit of Chrome's install prompt.
    static func permissionSummary(_ manifest: [String: Any]) -> [Prompt.Item] {
        var wanted: [String] = []
        for key in ["permissions", "host_permissions"] {
            wanted += (manifest[key] as? [Any] ?? []).compactMap { $0 as? String }
        }
        let scripts = (manifest["content_scripts"] as? [[String: Any]] ?? []).flatMap { $0["matches"] as? [String] ?? [] }
        let patterns = (wanted + scripts).filter { $0 == "<all_urls>" || $0.contains("://") }

        var items: [Prompt.Item] = []
        let allSites = patterns.contains {
            $0 == "<all_urls>" || $0.hasPrefix("*://*/") || $0.hasPrefix("http://*/") || $0.hasPrefix("https://*/")
        }
        if allSites {
            items.append(.init(symbol: "globe", text: "Read and change your data on all websites"))
        } else {
            var hosts: [String] = []
            for pattern in patterns {
                guard let range = pattern.range(of: "://") else { continue }
                var host = String(pattern[range.upperBound...].prefix { $0 != "/" })
                if host.hasPrefix("*.") { host.removeFirst(2) }
                if !host.isEmpty, host != "*", !hosts.contains(host) { hosts.append(host) }
            }
            if hosts.count == 1 {
                items.append(.init(symbol: "globe", text: "Read and change your data on \(hosts[0])"))
            } else if hosts.count > 1, hosts.count <= 3 {
                items.append(.init(symbol: "globe", text: "Read and change your data on \(hosts.joined(separator: ", "))"))
            } else if hosts.count > 3 {
                items.append(.init(symbol: "globe", text: "Read and change your data on \(hosts.count) websites"))
            }
        }

        for entry in permissionDescriptions where entry.permissions.contains(where: wanted.contains) {
            // "Read your browsing history" covers several permissions; list each line once.
            if !items.contains(where: { $0.text == entry.text }) {
                items.append(.init(symbol: entry.symbol, text: entry.text))
            }
        }
        return items
    }

    /// The extension's own icon from its manifest, around 64 px if available.
    static func manifestIcon(_ manifest: [String: Any], in folder: URL) -> NSImage? {
        let icons = (manifest["icons"] as? [String: Any] ?? [:]).compactMap { key, value -> (Int, String)? in
            guard let size = Int(key), let path = value as? String else { return nil }
            return (size, path)
        }
        let sorted = icons.sorted { $0.0 < $1.0 }
        guard let pick = sorted.first(where: { $0.0 >= 64 }) ?? sorted.last else { return nil }
        let base = folder.standardizedFileURL
        let file = base.appendingPathComponent(pick.1.hasPrefix("/") ? String(pick.1.dropFirst()) : pick.1).standardizedFileURL
        guard file.path.hasPrefix(base.path + "/") else { return nil }
        return NSImage(contentsOf: file)
    }

    // MARK: Package helpers

    private static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count > 64 else {
            throw InstallError.badResponse
        }
        return data
    }

    /// A .crx is a zip with a signed header in front; .xpi and .zip are plain zips.
    static func zipPayload(of data: Data) -> Data? {
        func le32(_ offset: Int) -> Int {
            Int(data[data.startIndex + offset]) | Int(data[data.startIndex + offset + 1]) << 8
                | Int(data[data.startIndex + offset + 2]) << 16 | Int(data[data.startIndex + offset + 3]) << 24
        }
        guard data.count > 16 else { return nil }
        if data.prefix(2) == Data("PK".utf8) { return data }
        guard data.prefix(4) == Data("Cr24".utf8) else { return nil }
        let offset: Int
        switch le32(4) {
        case 2: offset = 16 + le32(8) + le32(12)
        case 3: offset = 12 + le32(8)
        default: return nil
        }
        guard offset < data.count else { return nil }
        return data.subdata(in: (data.startIndex + offset)..<data.endIndex)
    }

    private static func unzip(_ zip: URL, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zip.path, destination.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: InstallError.badArchive)
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private static func readManifest(in folder: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")) else { throw InstallError.noManifest }
        // Manifests in the wild contain comments and BOMs, which JSONSerialization rejects.
        let options: JSONSerialization.ReadingOptions = [.json5Allowed]
        guard let object = try? JSONSerialization.jsonObject(with: data, options: options) as? [String: Any] else {
            throw InstallError.noManifest
        }
        var manifest = object
        // Resolve "__MSG_name__" so the install prompt shows a real name.
        if let name = manifest["name"] as? String, name.hasPrefix("__MSG_"), name.hasSuffix("__") {
            let key = String(name.dropFirst(6).dropLast(2))
            let locale = manifest["default_locale"] as? String ?? "en"
            let file = folder.appendingPathComponent("_locales/\(locale)/messages.json")
            if let d = try? Data(contentsOf: file),
               let messages = try? JSONSerialization.jsonObject(with: d, options: options) as? [String: Any] {
                let match = messages.first { $0.key.lowercased() == key.lowercased() }?.value as? [String: Any]
                if let text = match?["message"] as? String { manifest["name"] = text }
            }
        }
        return manifest
    }

    private static func rawName(_ manifest: [String: Any]) -> String {
        (manifest["name"] as? String) ?? "Extension"
    }

    /// A Chrome-style ID (32 letters a–p) derived from a seed, for extensions that have no store ID.
    static func generatedID(from seed: String) -> String {
        let digest = SHA256.hash(data: Data(seed.utf8))
        let letters = Array("abcdefghijklmnop")
        return digest.prefix(16).map { "\(letters[Int($0 >> 4)])\(letters[Int($0 & 0x0F)])" }.joined()
    }

    // MARK: Toolbar actions

    func actions(for tab: Tab?) -> [ExtensionActionInfo] {
        let panels = SidePanelManager.shared
        return records.compactMap { record in
            guard record.enabled, let context = contexts[record.id] else { return nil }
            let manifest = context.webExtension.manifest
            let hasPanel = panels.hasPanel(record.id)
            // A Firefox extension whose only button is its sidebar still gets one here.
            guard hasPanel || manifest["action"] != nil || manifest["browser_action"] != nil || manifest["page_action"] != nil else { return nil }
            let action = context.action(for: tab)
            let size = CGSize(width: 18, height: 18)
            let icon = action?.icon(for: size) ?? context.webExtension.actionIcon(for: size) ?? context.webExtension.icon(for: size)
            return ExtensionActionInfo(
                id: record.id,
                name: action?.label.isEmpty == false ? action!.label : record.name,
                icon: icon,
                badge: action?.badgeText ?? "",
                enabled: action?.isEnabled ?? true,
                hasPanel: hasPanel,
                panelOpen: hasPanel && panels.openID == record.id && panels.isShowing
            )
        }
    }

    func setAnchor(_ view: NSView, for id: String) {
        anchors.setObject(view, forKey: id as NSString)
    }

    func performAction(id: String) {
        guard let context = contexts[id] else { return }
        if SidePanelManager.shared.actionTogglesPanel(id) {
            trace("performAction \(id) toggles side panel")
            SidePanelManager.shared.toggle(id)
            return
        }
        let tab = browser.selectedTab
        if let tab { context.userGesturePerformed(in: tab) }
        trace("performAction \(id) presentsPopup=\(context.action(for: tab)?.presentsPopup ?? false)")
        context.performAction(for: tab)
    }

    func openOptions(id: String) {
        guard let context = contexts[id], let url = context.optionsPageURL else { return }
        browser.newTab(url: url)
    }

    func hasOptions(id: String) -> Bool { contexts[id]?.optionsPageURL != nil }

    func contextMenuItems(for tab: Tab) -> [NSMenuItem] {
        contexts.values.flatMap { $0.menuItems(for: tab) }
    }

    /// Gives extensions a chance to handle a keyboard shortcut they registered.
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        for (id, context) in contexts {
            guard let command = context.command(for: event) else { continue }
            // WebKit would run the action itself, skipping the side panel; send it the same
            // way a click on the toolbar button goes.
            let panels = SidePanelManager.shared
            if ["_execute_action", "_execute_browser_action"].contains(command.id), panels.actionTogglesPanel(id) {
                panels.toggle(id)
                return true
            }
            if command.id == "_execute_sidebar_action", panels.hasPanel(id) {
                panels.toggle(id)
                return true
            }
            context.performCommand(command)
            return true
        }
        return false
    }

    // MARK: Tab events (browser → extensions)

    func didOpen(_ tab: Tab) { controller.didOpenTab(tab) }
    func didClose(_ tab: Tab) {
        controller.didCloseTab(tab, windowIsClosing: false)
        SidePanelManager.shared.tabClosed(tab)
    }
    func didActivate(_ tab: Tab, previous: Tab?) {
        controller.didActivateTab(tab, previousActiveTab: previous)
        SidePanelManager.shared.selectedTabChanged()
    }
    func didChange(_ tab: Tab, properties: WKWebExtension.TabChangedProperties) {
        controller.didChangeTabProperties(properties, for: tab)
        // The toolbar shows the selected tab's actions; a background tab navigating changes
        // nothing in it, and shouldn't make it rebuild every extension's button.
        if tab === browser.selectedTab, properties.contains(.URL) || properties.contains(.loading) { revision += 1 }
    }
}

extension ExtensionManager {
    /// Starts (once) the hidden page an extension's service worker uses to open WebSockets.
    fileprivate func startSocketRelay(for context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        guard socketRelays[id] == nil, contexts[id] === context else { return }
        let url = context.baseURL.appendingPathComponent(ExtensionCompat.socketRelayPage)
        trace("socket relay starting for \(context.webExtension.displayName ?? id)")
        socketRelays[id] = SocketRelay(configuration: context.webViewConfiguration, url: url)
    }
}

/// An off-screen web view showing an extension's socket relay page. It never sleeps, and comes
/// back if its web content process dies, since the extension's open sockets live in it.
final class SocketRelay: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private let url: URL

    init(configuration: WKWebViewConfiguration?, url: URL) {
        self.url = url
        super.init()
        guard let configuration else { return }
        configuration.preferences.inactiveSchedulingPolicy = .none
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        view.load(URLRequest(url: url))
    }

    func stop() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.load(URLRequest(url: url))
    }
}

// MARK: - WKWebExtensionControllerDelegate

extension ExtensionManager: WKWebExtensionControllerDelegate {
    func webExtensionController(
        _ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        [windowAdapter]
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        windowAdapter
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        // chrome.sidePanel / browser.sidebarAction calls from the compatibility shim.
        if let url = configuration.url, url.scheme == SidePanelManager.bridgeScheme {
            completionHandler(nil, SidePanelManager.shared.handleBridge(url, context: extensionContext))
            return
        }
        // Native API calls from the compatibility shim (history, topSites, browsingData, management).
        if let url = configuration.url, url.scheme == ExtensionAPIBridge.scheme {
            ExtensionAPIBridge.shared.handle(url, context: extensionContext) { error in
                completionHandler(nil, error)
            }
            return
        }
        trace("openNewTab \(configuration.url?.absoluteString ?? "-")")
        let tab = browser.newTab(url: configuration.url, select: configuration.shouldBeActive)
        if configuration.shouldBeMuted { tab.setMuted(true) }
        completionHandler(tab, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void
    ) {
        trace("openNewWindow type=\(configuration.windowType.rawValue) urls=\(configuration.tabURLs) tabs=\(configuration.tabs.count)")
        // Tuff has one window; extension "windows" become tabs in it.
        for url in configuration.tabURLs { browser.newTab(url: url) }
        completionHandler(windowAdapter, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        if let url = extensionContext.optionsPageURL { browser.newTab(url: url) }
        completionHandler(nil)
    }

    private func ask(_ context: WKWebExtensionContext, _ items: [Prompt.Item], answer: @escaping (Bool) -> Void) {
        let prompt = Prompt(
            icon: context.webExtension.icon(for: CGSize(width: 64, height: 64)),
            title: "“\(context.webExtension.displayName ?? "An extension")” wants additional access",
            itemsHeading: "It’s asking to:",
            items: items,
            confirmTitle: "Allow",
            cancelTitle: "Don’t Allow"
        )
        Task { @MainActor in answer(await PromptPresenter.present(prompt)) }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        var items = Self.permissionSummary(["permissions": permissions.map(\.rawValue)])
        let described = Set(Self.permissionDescriptions.flatMap(\.permissions))
        let others = permissions.map(\.rawValue).filter { !described.contains($0) }.sorted()
        if !others.isEmpty { items.append(.init(symbol: "puzzlepiece.extension", text: "Use " + others.joined(separator: ", "))) }
        ask(extensionContext, items) { completionHandler($0 ? permissions : [], nil) }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        let hosts = Set(urls.compactMap { $0.host }).sorted()
        let shown = hosts.prefix(4).joined(separator: ", ") + (hosts.count > 4 ? " and \(hosts.count - 4) more" : "")
        ask(extensionContext, [.init(symbol: "globe", text: "Read and change your data on \(shown)")]) {
            completionHandler($0 ? urls : [], nil)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        var items = Self.permissionSummary(["host_permissions": matchPatterns.map(\.string)])
        if items.isEmpty {
            items = [.init(symbol: "globe", text: "Read and change your data on " + matchPatterns.map(\.string).sorted().prefix(4).joined(separator: ", "))]
        }
        ask(extensionContext, items) { completionHandler($0 ? matchPatterns : [], nil) }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        revision += 1
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void
    ) {
        trace("presentActionPopup popover=\(action.popupPopover != nil)")
        guard let popover = action.popupPopover else {
            completionHandler(NSError(domain: "Tuff", code: 1, userInfo: [NSLocalizedDescriptionKey: "No popup"]))
            return
        }
        popover.behavior = .transient
        if let anchor = anchors.object(forKey: context.uniqueIdentifier as NSString), anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else if let content = browser.window?.contentView {
            let rect = NSRect(x: 24, y: content.bounds.maxY - 60, width: 1, height: 1)
            popover.show(relativeTo: rect, of: content, preferredEdge: .maxX)
        }
        completionHandler(nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void
    ) {
        if applicationIdentifier == "tuff.socketrelay" {
            startSocketRelay(for: extensionContext)
            replyHandler(["started": true], nil)
            return
        }
        #if DEBUG
        if applicationIdentifier == "tuff.debug" {
            if let body = message as? [String: Any] {
                trace("console[\(body["level"] as? String ?? "?")] \(body["text"] as? String ?? "")")
            }
            replyHandler(nil, nil)
            return
        }
        #endif
        trace("sendNativeMessage to \(applicationIdentifier ?? "-")")
        guard let name = applicationIdentifier,
              let host = NativeMessagingHost(application: name, context: extensionContext) else {
            replyHandler(nil, NativeMessagingHost.notFound(applicationIdentifier))
            return
        }
        var finished = false
        host.onMessage = { reply in
            guard !finished else { return }
            finished = true
            replyHandler(reply, nil)
            host.stop()
        }
        host.onExit = {
            guard !finished else { return }
            finished = true
            replyHandler(nil, NativeMessagingHost.notFound(name))
        }
        host.start()
        host.send(message)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void
    ) {
        trace("connectNative to \(port.applicationIdentifier ?? "-")")
        guard let name = port.applicationIdentifier,
              let host = NativeMessagingHost(application: name, context: extensionContext) else {
            completionHandler(NativeMessagingHost.notFound(port.applicationIdentifier))
            return
        }
        let key = ObjectIdentifier(port)
        nativePorts[key] = host
        host.onMessage = { [weak port] message in port?.sendMessage(message, completionHandler: nil) }
        host.onExit = { [weak self, weak port] in
            port?.disconnect()
            self?.nativePorts[key] = nil
        }
        port.messageHandler = { [weak host] message, _ in
            if let message { host?.send(message) }
        }
        port.disconnectHandler = { [weak self, weak host] _ in
            host?.stop()
            self?.nativePorts[key] = nil
        }
        host.start()
        completionHandler(nil)
    }
}
