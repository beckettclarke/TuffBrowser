import CryptoKit
import Foundation
import WebKit

/// Tuff's built-in ad and tracker blocker.
///
/// WebKit can only block a request before it goes out through a content rule list: extension
/// `webRequest` listeners hear about requests after they've been sent, so blockers built on them
/// (full uBlock Origin, most Firefox blockers) can't stop anything. This downloads the standard
/// filter lists, translates them (`FilterListParser`), compiles them with `WKContentRuleListStore`
/// and adds them to every tab. `AdvancedContentBlocker` supplies the maintained uBO Lite scriptlet
/// and procedural-cosmetic rulesets that WebKit's rule lists cannot express. Everything is cached;
/// the lists and advanced rules are refreshed twice a day and recompiled when they change.
final class ContentBlocker {
    static let shared = ContentBlocker()

    struct FilterList {
        let id: String
        let name: String
        let url: URL
    }

    /// Roughly uBlock Origin's default selection.
    static let lists: [FilterList] = [
        FilterList(id: "easylist", name: "EasyList", url: URL(string: "https://easylist.to/easylist/easylist.txt")!),
        FilterList(id: "easyprivacy", name: "EasyPrivacy", url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!),
        FilterList(id: "ublock-filters", name: "uBlock filters – Ads", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/filters.txt")!),
        FilterList(id: "ublock-privacy", name: "uBlock filters – Privacy", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/privacy.txt")!),
        FilterList(id: "ublock-badware", name: "uBlock filters – Badware risks", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/badware.txt")!),
        FilterList(id: "ublock-unbreak", name: "uBlock filters – Unbreak", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/unbreak.txt")!),
        FilterList(id: "ublock-quick-fixes", name: "uBlock filters – Quick fixes", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/quick-fixes.txt")!),
        FilterList(id: "plowe", name: "Peter Lowe’s Ad and tracking server list",
                   url: URL(string: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=1&mimetype=plaintext")!),
    ]

    private static let refreshInterval: TimeInterval = 12 * 3600

    private struct Saved: Codable {
        var fingerprint: String
        var identifiers: [String]
        var updated: Date
        var parserVersion: Int?
    }

    private var active: [WKContentRuleList] = []
    private let advanced = AdvancedContentBlocker()
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    /// Controllers whose tab is showing a site the user allowed ads on (lists taken out).
    private let skipped = NSHashTable<WKUserContentController>.weakObjects()
    private var started = false
    private var building = false
    private var timer: Timer?

    private var enabled: Bool { AppSettings.shared.privacy.blockAds }

    private var folder: URL {
        let url = Paths.appSupport.appendingPathComponent("ContentBlocker", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private var listsFolder: URL {
        let url = folder.appendingPathComponent("Lists", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private var advancedFolder: URL { folder.appendingPathComponent("Advanced", isDirectory: true) }
    private var savedURL: URL { folder.appendingPathComponent("compiled.json") }
    private lazy var store: WKContentRuleListStore? = WKContentRuleListStore(url: folder.appendingPathComponent("Compiled", isDirectory: true))

    private var saved: Saved? {
        (try? Data(contentsOf: savedURL)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
    }

    // MARK: Tabs

    /// Every web view configuration (Incognito ones too) gets the lists.
    func attach(_ controller: WKUserContentController) {
        start()
        controllers.add(controller)
        advanced.attach(controller)
        if enabled { active.forEach(controller.add) }
    }

    /// Before a tab's main frame navigates: lists off on sites the user allowed ads on.
    func prepare(_ controller: WKUserContentController, for url: URL) {
        guard enabled else { return }
        advanced.prepare(controller, for: url)
        let allowed = isAllowed(host: url.host)
        if allowed, !skipped.contains(controller) {
            active.forEach(controller.remove)
            skipped.add(controller)
        } else if !allowed, skipped.contains(controller) {
            active.forEach(controller.add)
            skipped.remove(controller)
        }
    }

    func isSkipping(_ controller: WKUserContentController) -> Bool { skipped.contains(controller) }

    // MARK: Sites the user allows ads on

    func isAllowed(host: String?) -> Bool {
        guard var candidate = host?.lowercased(), !candidate.isEmpty else { return false }
        let hosts = Set(AppSettings.shared.privacy.adBlockAllowlist)
        while true {
            if hosts.contains(candidate) { return true }
            guard let dot = candidate.firstIndex(of: ".") else { return false }
            candidate = String(candidate[candidate.index(after: dot)...])
        }
    }

    /// Flips blocking for `host` (and its subdomains) and reloads the tab showing it.
    func toggleAllowed(host: String, reloading tab: Tab?) {
        let host = host.lowercased().replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
        var list = AppSettings.shared.privacy.adBlockAllowlist
        if isAllowed(host: host) {
            list.removeAll { host == $0 || host.hasSuffix("." + $0) }
        } else {
            list.append(host)
        }
        AppSettings.shared.privacy.adBlockAllowlist = list.sorted()
        if let view = tab?.webView, let url = view.url {
            prepare(view.configuration.userContentController, for: url)
            view.reload()
        }
    }

    // MARK: On / off

    func settingsChanged() {
        advanced.settingsChanged()
        if enabled {
            for controller in controllers.allObjects where !skipped.contains(controller) {
                active.forEach(controller.remove)
                active.forEach(controller.add)
            }
            refreshIfNeeded()
        } else {
            for controller in controllers.allObjects { active.forEach(controller.remove) }
            skipped.removeAllObjects()
        }
    }

    private func activate(_ lists: [WKContentRuleList]) {
        let old = active
        active = lists
        guard enabled else { return }
        for controller in controllers.allObjects {
            old.forEach(controller.remove)
            if !skipped.contains(controller) { lists.forEach(controller.add) }
        }
    }

    // MARK: Startup and updates

    func start() {
        guard !started else { return }
        started = true
        advanced.start(in: advancedFolder)
        if let saved, saved.parserVersion == FilterListParser.version, let store {
            lookUp(saved.identifiers, in: store) { [weak self] lists in
                guard let self else { return }
                if let lists { self.activate(lists) }
                self.refreshIfNeeded()
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refreshIfNeeded() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.refreshIfNeeded() }
    }

    /// Downloads the lists when they're missing or older than `refreshInterval`, and rebuilds
    /// when the compiled lists don't match them.
    func refreshIfNeeded(force: Bool = false) {
        guard enabled, !building else { return }
        let stale = force || active.isEmpty || saved.map {
            $0.fingerprint.isEmpty || $0.parserVersion != FilterListParser.version
                || Date().timeIntervalSince($0.updated) > Self.refreshInterval
        } ?? true
        guard stale else { return }
        building = true
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            async let advancedSources = AdvancedContentBlocker.download()
            let texts = await self.download()
            if let sources = await advancedSources {
                await MainActor.run { self.advanced.activate(sources) }
            }
            await MainActor.run { self.build(from: texts) }
        }
    }

    /// The lists' text, from the network when it can be had and the cached copy otherwise.
    private func download() async -> [String] {
        var texts: [String] = []
        for list in Self.lists {
            let file = listsFolder.appendingPathComponent(list.id + ".txt")
            if let text = await fetch(list.url, depth: 0) {
                try? text.write(to: file, atomically: true, encoding: .utf8)
                texts.append(text)
            } else if let cached = try? String(contentsOf: file, encoding: .utf8) {
                texts.append(cached)
            }
        }
        return texts
    }

    /// One list, with uBO's `!#include file` lines replaced by the files they name.
    private func fetch(_ url: URL, depth: Int) async -> String? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Tuff", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { return nil }
        guard depth < 2, text.contains("!#include ") else { return text }
        var out: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("!#include "), let included = URL(string: String(line.dropFirst(10)).trimmingCharacters(in: .whitespaces), relativeTo: url),
               included.host == url.host, let body = await fetch(included.absoluteURL, depth: depth + 1) {
                out.append(body)
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    @MainActor
    private func build(from texts: [String]) {
        guard !texts.isEmpty, let store else { building = false; return }
        let fingerprint = Self.fingerprint(texts)
        if let saved, saved.fingerprint == fingerprint, !active.isEmpty {
            // Unchanged: just note that it was checked.
            save(Saved(fingerprint: fingerprint, identifiers: saved.identifiers, updated: Date(), parserVersion: FilterListParser.version))
            building = false
            return
        }
        let started = Date()
        SelectorValidator.shared.prepare { [weak self] in
            Task.detached(priority: .utility) {
                let result = FilterListParser.parse(texts) { selectors in
                    SelectorValidator.shared.validSync(selectors)
                }
                await MainActor.run {
                    guard let self else { return }
                    let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                    NSLog("Tuff: content blocker translated \(result.networkFilters) network and \(result.cosmeticFilters) cosmetic filters (\(result.skipped) skipped) into \(result.webkitRules) rules in \(result.lists.count) lists (\(seconds)s)")
                    ExtensionManager.shared.trace("blocker: \(result.networkFilters) network + \(result.cosmeticFilters) cosmetic filters, \(result.skipped) skipped, \(result.webkitRules) rules in \(result.lists.count) lists (\(seconds)s)")
                    self.compile(result.lists, fingerprint: fingerprint, in: store)
                }
            }
        }
    }

    private func compile(_ sources: [String], fingerprint: String, in store: WKContentRuleListStore) {
        let started = Date()
        let prefix = "tuff.blocker.\(fingerprint.prefix(12))."
        var compiled: [WKContentRuleList?] = Array(repeating: nil, count: sources.count)
        var failures: [String] = []
        var remaining = sources.count
        guard remaining > 0 else { building = false; return }
        for (index, source) in sources.enumerated() {
            store.compileContentRuleList(forIdentifier: prefix + String(index), encodedContentRuleList: source) { [weak self] list, error in
                compiled[index] = list
                if let error { failures.append("list \(index + 1): \(error.localizedDescription)") }
                remaining -= 1
                guard remaining == 0, let self else { return }
                self.building = false
                let lists = compiled.compactMap { $0 }
                let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                ExtensionManager.shared.trace("blocker: compiled \(lists.count) of \(sources.count) lists in \(seconds)s \(failures)")
                if !failures.isEmpty { NSLog("Tuff: some filter rules did not compile: \(failures)") }
                guard !lists.isEmpty else { return }
                let old = self.saved
                self.activate(lists)
                let identifiers = compiled.enumerated().compactMap { $0.element == nil ? nil : prefix + String($0.offset) }
                // With a failure the fingerprint isn't kept, so the next check tries again.
                self.save(Saved(fingerprint: failures.isEmpty ? fingerprint : "", identifiers: identifiers, updated: Date(), parserVersion: FilterListParser.version))
                for identifier in old?.identifiers ?? [] where !identifiers.contains(identifier) {
                    store.removeContentRuleList(forIdentifier: identifier) { _ in }
                }
            }
        }
    }

    private func save(_ record: Saved) {
        if let data = try? JSONEncoder().encode(record) { try? data.write(to: savedURL, options: .atomic) }
    }

    private func lookUp(_ identifiers: [String], in store: WKContentRuleListStore, completion: @escaping ([WKContentRuleList]?) -> Void) {
        guard !identifiers.isEmpty else { completion(nil); return }
        var found: [WKContentRuleList?] = Array(repeating: nil, count: identifiers.count)
        var remaining = identifiers.count
        for (index, identifier) in identifiers.enumerated() {
            store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                found[index] = list
                remaining -= 1
                if remaining == 0 { completion(found.contains { $0 == nil } ? nil : found.compactMap { $0 }) }
            }
        }
    }

    private static func fingerprint(_ texts: [String]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("v\(FilterListParser.version)".utf8))
        for text in texts { hasher.update(data: Data(text.utf8)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Checks element-hiding selectors with WebKit's own CSS parser: one invalid selector would
/// make WebKit drop the whole batch it was grouped with.
final class SelectorValidator {
    static let shared = SelectorValidator()
    private var webView: WKWebView?

    /// Creates the (main-thread) web view used for checking.
    func prepare(_ then: @escaping () -> Void) {
        DispatchQueue.main.async {
            if self.webView == nil {
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                self.webView = WKWebView(frame: .zero, configuration: configuration)
                self.webView?.loadHTMLString("<!doctype html><title>selectors</title>", baseURL: nil)
            }
            then()
        }
    }

    /// Called off the main thread; waits for the main thread to check them.
    func validSync(_ selectors: [String]) -> Set<String> {
        guard !selectors.isEmpty else { return [] }
        let semaphore = DispatchSemaphore(value: 0)
        var valid = Set(selectors)
        DispatchQueue.main.async {
            guard let webView = self.webView else { semaphore.signal(); return }
            let script = """
            const ok = [];
            for (const s of list) { try { document.querySelector(s); ok.push(s); } catch (e) {} }
            return ok;
            """
            webView.callAsyncJavaScript(script, arguments: ["list": selectors], in: nil, in: .page) { result in
                if case .success(let value) = result, let ok = value as? [String] { valid = Set(ok) }
                semaphore.signal()
            }
        }
        _ = semaphore.wait(timeout: .now() + 60)
        // Done with it until the next build.
        DispatchQueue.main.async { self.webView = nil }
        return valid
    }
}
