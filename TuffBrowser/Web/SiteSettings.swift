import AppKit
import Observation
import SwiftUI
import WebKit

struct ContentSettingPattern {
    let scheme: String
    let host: String
    let port: String?

    var key: String { "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "") }
    var isGlobal: Bool { scheme == "*" && host == "*" && (port == nil || port == "*") }
    var specificity: Int {
        (host == "*" ? 0 : host.hasPrefix("*.") ? 100 + host.count : 1000 + host.count)
            + (scheme == "*" ? 0 : 100) + (port == nil || port == "*" ? 0 : 10)
    }

    init?(pattern: String) {
        let regex = try? NSRegularExpression(pattern: #"^(\*|https?)://(\*|(?:\*\.)?[^/:*]+)(?::([0-9]+|\*))?(?:/.*)?$"#)
        guard let match = regex?.firstMatch(in: pattern, range: NSRange(pattern.startIndex..., in: pattern)),
              let schemeRange = Range(match.range(at: 1), in: pattern),
              let hostRange = Range(match.range(at: 2), in: pattern) else { return nil }
        scheme = String(pattern[schemeRange]).lowercased()
        host = String(pattern[hostRange]).lowercased()
        port = Range(match.range(at: 3), in: pattern).map { String(pattern[$0]) }
    }

    func matches(_ url: URL?) -> Bool {
        guard let url, let pageScheme = url.scheme?.lowercased(), ["http", "https"].contains(pageScheme),
              let pageHost = url.host(percentEncoded: false)?.lowercased() else { return false }
        if scheme != "*" && scheme != pageScheme { return false }
        let hostMatches: Bool
        if host == "*" {
            hostMatches = true
        } else if host.hasPrefix("*.") {
            let bare = String(host.dropFirst(2))
            hostMatches = pageHost == bare || pageHost.hasSuffix("." + bare)
        } else {
            hostMatches = pageHost == host
        }
        guard hostMatches else { return false }
        guard let port, port != "*" else { return true }
        let defaultPort = pageScheme == "https" ? 443 : 80
        return Int(port) == (url.port ?? defaultPort)
    }

    func matches(origin: String) -> Bool { matches(URL(string: origin)) }
}

/// Per-site choices that override Settings → Privacy for one site: JavaScript, pop-ups and
/// autoplay, plus the cross-site cookie access sites ask for with the Storage Access API.
///
/// Sites are keyed by host without "www.". Choices made in an Incognito window stay in memory
/// and are dropped when the last Incognito window closes; Incognito reads the saved ones too.
@Observable
final class SiteSettings {
    struct Entry: Codable, Equatable {
        /// nil: as Settings says.
        var javaScript: Bool?
        var popups: Bool?
        var autoplay: AutoplayPolicy?
        var sound: Bool?
        var images: Bool?
        /// `"allow"`, `"block"`, or `"session_only"`.
        var cookies: String?
        /// `"allow"`, `"block"`, or `"ask"`.
        var automaticDownloads: String?
        /// `"allow"`, `"block"`, or `"ask"`.
        var clipboard: String?

        var isEmpty: Bool {
            javaScript == nil && popups == nil && autoplay == nil && sound == nil
                && images == nil && cookies == nil && automaticDownloads == nil && clipboard == nil
        }
    }

    static let shared = SiteSettings()

    private(set) var sites: [String: Entry] = [:]
    /// Storage Access answers, "embedded|top-level" → allowed.
    private(set) var storageAccess: [String: Bool] = [:]
    /// Default sound setting when a site has no entry of its own (nil = allow).
    var defaultSound: Bool? {
        didSet { save() }
    }
    /// Default images setting when a site has no entry of its own (nil = allow).
    var defaultImages: Bool? {
        didSet { save(); rebuildContentRules() }
    }
    /// Default cookies setting (`"allow"`, `"block"`, `"session_only"`; nil = `"allow"`).
    var defaultCookies: String? {
        didSet { save(); rebuildContentRules() }
    }
    /// Default automatic downloads setting (`"allow"`, `"block"`, `"ask"`; nil = `"ask"`).
    var defaultAutomaticDownloads: String? {
        didSet { save() }
    }
    /// Default clipboard read setting (`"allow"`, `"block"`, `"ask"`; nil = `"ask"`).
    var defaultClipboard: String? {
        didSet { save(); rebuildClipboardScript() }
    }
    @ObservationIgnored private var incognitoSites: [String: Entry] = [:]
    @ObservationIgnored private var incognitoStorageAccess: [String: Bool] = [:]
    @ObservationIgnored private let file = Paths.appSupport.appendingPathComponent("site-settings.json")
    @ObservationIgnored private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    @ObservationIgnored private var activeContentRules: WKContentRuleList?
    @ObservationIgnored private var activeClipboardScript: WKUserScript?
    @ObservationIgnored private var rulesGeneration = 0

    private struct Saved: Codable {
        var sites: [String: Entry]
        var storageAccess: [String: Bool]?
        var defaultSound: Bool?
        var defaultImages: Bool?
        var defaultCookies: String?
        var defaultAutomaticDownloads: String?
        var defaultClipboard: String?
    }

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            sites = saved.sites
            storageAccess = saved.storageAccess ?? [:]
            defaultSound = saved.defaultSound
            defaultImages = saved.defaultImages
            defaultCookies = saved.defaultCookies
            defaultAutomaticDownloads = saved.defaultAutomaticDownloads
            defaultClipboard = saved.defaultClipboard
        }
    }

    func soundAllowed(for url: URL?, incognito: Bool) -> Bool {
        entry(for: url, incognito: incognito).sound ?? defaultSound ?? true
    }

    func imagesAllowed(for url: URL?, incognito: Bool) -> Bool {
        entry(for: url, incognito: incognito).images ?? defaultImages ?? true
    }

    func cookiesSetting(for url: URL?, incognito: Bool) -> String {
        entry(for: url, incognito: incognito).cookies ?? defaultCookies ?? "allow"
    }

    func automaticDownloadsSetting(for url: URL?, incognito: Bool) -> String {
        entry(for: url, incognito: incognito).automaticDownloads ?? defaultAutomaticDownloads ?? "ask"
    }

    func clipboardSetting(for url: URL?, incognito: Bool) -> String {
        entry(for: url, incognito: incognito).clipboard ?? defaultClipboard ?? "ask"
    }

    func attachContentRules(to controller: WKUserContentController) {
        controllers.add(controller)
        if let activeContentRules {
            controller.add(activeContentRules)
        } else if !contentRulesJSON().isEmpty {
            rebuildContentRules()
        }
        if let activeClipboardScript {
            controller.addUserScript(activeClipboardScript)
        } else if hasBlockedClipboardRule {
            rebuildClipboardScript()
        }
    }

    private var hasBlockedClipboardRule: Bool {
        if defaultClipboard == "block" { return true }
        return sites.values.contains { $0.clipboard == "block" }
            || incognitoSites.values.contains { $0.clipboard == "block" }
    }

    /// Installs or removes a lightweight `.atDocumentStart` script enforcing `contentSettings.clipboard`
    /// `"block"` rules. Does nothing (zero page overhead) when no clipboard block rules exist.
    func rebuildClipboardScript() {
        let removeSel = NSSelectorFromString("_removeUserScript:")
        if let old = activeClipboardScript {
            for controller in controllers.allObjects where controller.responds(to: removeSel) {
                controller.perform(removeSel, with: old)
            }
            activeClipboardScript = nil
        }
        guard hasBlockedClipboardRule else { return }

        let allSites = sites.merging(incognitoSites) { _, overlay in overlay }
        func matchPatterns(for key: String) -> [String] {
            if let p = ContentSettingPattern(pattern: key) {
                let schemes = p.scheme == "*" ? ["http", "https"] : [p.scheme]
                return schemes.map { "\($0)://\(p.host)/*" }
            }
            return ["http://\(key)/*", "https://\(key)/*", "http://*.\(key)/*", "https://*.\(key)/*"]
        }

        let include: [String]
        let exclude: [String]
        if defaultClipboard == "block" {
            include = ["http://*/*", "https://*/*"]
            exclude = allSites.compactMap { $0.value.clipboard == "allow" || $0.value.clipboard == "ask" ? $0.key : nil }
                .flatMap(matchPatterns(for:))
        } else {
            include = allSites.compactMap { $0.value.clipboard == "block" ? $0.key : nil }
                .flatMap(matchPatterns(for:))
            exclude = []
        }
        guard !include.isEmpty else { return }

        let source = #"""
        (() => {
          const deny = () => Promise.reject(new DOMException('Clipboard read blocked by site setting.', 'NotAllowedError'));
          try {
            if (navigator.clipboard) {
              Object.defineProperty(navigator.clipboard, 'read', { value: deny, configurable: true });
              Object.defineProperty(navigator.clipboard, 'readText', { value: deny, configurable: true });
            }
          } catch (e) {}
          try {
            const orig = Document.prototype.execCommand;
            if (typeof orig === 'function') {
              Document.prototype.execCommand = function (cmd) {
                if (String(cmd || '').toLowerCase() === 'paste') return false;
                return orig.apply(this, arguments);
              };
            }
          } catch (e) {}
        })();
        """#
        let script = ExtensionContentScripts.makeScript(
            source: source, time: .atDocumentStart, mainFrameOnly: false,
            include: include, exclude: exclude, world: .page
        )
        activeClipboardScript = script
        for controller in controllers.allObjects {
            controller.addUserScript(script)
        }
    }

    /// Builds the `WKContentRuleList` rules enforcing per-site / global image and cookie blocking.
    /// Empty when nothing blocks images or cookies (so zero cost on pages).
    func contentRulesJSON() -> [[String: Any]] {
        var rules: [[String: Any]] = []

        func topURLRegex(for key: String) -> String? {
            if let pattern = ContentSettingPattern(pattern: key) {
                let scheme = pattern.scheme == "*" ? "https?" : NSRegularExpression.escapedPattern(for: pattern.scheme)
                let host: String
                if pattern.host == "*" {
                    host = "[^/]+"
                } else if pattern.host.hasPrefix("*.") {
                    let bare = NSRegularExpression.escapedPattern(for: String(pattern.host.dropFirst(2)))
                    host = "(?:[^/]+\\.)?" + bare
                } else {
                    host = NSRegularExpression.escapedPattern(for: pattern.host)
                }
                let port = (pattern.port != nil && pattern.port != "*") ? ":" + NSRegularExpression.escapedPattern(for: pattern.port!) : "(?::[0-9]+)?"
                return "^\(scheme)://\(host)\(port)(?:/|$)"
            }
            let escaped = NSRegularExpression.escapedPattern(for: key)
            return "^https?://(?:www\\.)?\(escaped)(?::[0-9]+)?(?:/|$)"
        }

        // Images rules.
        let allSites = sites.merging(incognitoSites) { _, overlay in overlay }
        let blockedImageURLs = allSites.compactMap { key, entry -> String? in
            entry.images == false ? topURLRegex(for: key) : nil
        }
        let allowedImageURLs = allSites.compactMap { key, entry -> String? in
            entry.images == true ? topURLRegex(for: key) : nil
        }
        if defaultImages == false {
            var trigger: [String: Any] = ["url-filter": ".*", "resource-type": ["image"]]
            if !allowedImageURLs.isEmpty { trigger["unless-top-url"] = allowedImageURLs }
            rules.append(["trigger": trigger, "action": ["type": "block"]])
        } else if !blockedImageURLs.isEmpty {
            rules.append([
                "trigger": ["url-filter": ".*", "resource-type": ["image"], "if-top-url": blockedImageURLs],
                "action": ["type": "block"],
            ])
        }

        // Cookies rules.
        let blockedCookieURLs = allSites.compactMap { key, entry -> String? in
            entry.cookies == "block" ? topURLRegex(for: key) : nil
        }
        let allowedCookieURLs = allSites.compactMap { key, entry -> String? in
            (entry.cookies == "allow" || entry.cookies == "session_only") ? topURLRegex(for: key) : nil
        }
        if defaultCookies == "block" {
            var trigger: [String: Any] = ["url-filter": ".*"]
            if !allowedCookieURLs.isEmpty { trigger["unless-top-url"] = allowedCookieURLs }
            rules.append(["trigger": trigger, "action": ["type": "block-cookies"]])
        } else if !blockedCookieURLs.isEmpty {
            rules.append([
                "trigger": ["url-filter": ".*", "if-top-url": blockedCookieURLs],
                "action": ["type": "block-cookies"],
            ])
        }

        return rules
    }

    func rebuildContentRules() {
        rulesGeneration += 1
        let generation = rulesGeneration
        let rules = contentRulesJSON()
        guard !rules.isEmpty else {
            if let old = activeContentRules {
                for controller in controllers.allObjects { controller.remove(old) }
                activeContentRules = nil
            }
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else { return }
        WKContentRuleListStore.default()?.compileContentRuleList(forIdentifier: "tuff-content-settings", encodedContentRuleList: json) { [weak self] list, _ in
            DispatchQueue.main.async {
                guard let self, self.rulesGeneration == generation, let list else { return }
                let old = self.activeContentRules
                self.activeContentRules = list
                for controller in self.controllers.allObjects {
                    if let old { controller.remove(old) }
                    controller.add(list)
                }
            }
        }
    }

    /// Clears cookies belonging to sites configured as `session_only` (called on quit).
    func clearSessionOnlyCookies() {
        let globalSessionOnly = defaultCookies == "session_only"
        let sessionOnlyPatterns: [ContentSettingPattern] = sites.compactMap { key, entry in
            guard entry.cookies == "session_only" else { return nil }
            return ContentSettingPattern(pattern: key) ?? ContentSettingPattern(pattern: "*://*.\(key)/*")
        }
        let allowedPatterns: [ContentSettingPattern] = sites.compactMap { key, entry in
            guard entry.cookies == "allow" else { return nil }
            return ContentSettingPattern(pattern: key) ?? ContentSettingPattern(pattern: "*://*.\(key)/*")
        }
        guard globalSessionOnly || !sessionOnlyPatterns.isEmpty else { return }
        for store in DataStores.all {
            let cookieStore = store.httpCookieStore
            cookieStore.getAllCookies { cookies in
                for cookie in cookies {
                    let host = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                    let probe = URL(string: "https://\(host)/")
                    let shouldClear: Bool
                    if globalSessionOnly {
                        shouldClear = !allowedPatterns.contains { $0.matches(probe) }
                    } else {
                        shouldClear = sessionOnlyPatterns.contains { $0.matches(probe) }
                    }
                    if shouldClear { cookieStore.delete(cookie) }
                }
            }
        }
    }

    /// The key a page's settings are kept under: its host, lowercased, without "www.".
    static func key(for url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    static func key(forDomain domain: String) -> String {
        var host = domain.lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    private func matchingEntry(in entries: [String: Entry], for url: URL?) -> (key: String, entry: Entry)? {
        entries.compactMap { key, entry -> (String, Entry, Int)? in
            guard key.contains("://"), let pattern = ContentSettingPattern(pattern: key), pattern.matches(url) else { return nil }
            return (key, entry, pattern.specificity)
        }.max { $0.2 < $1.2 }.map { ($0.0, $0.1) }
    }

    func entry(for url: URL?, incognito: Bool) -> Entry {
        guard let key = Self.key(for: url) else { return Entry() }
        if incognito, let overlay = incognitoSites[key] { return overlay }
        if let exact = sites[key] { return exact }
        let normal = matchingEntry(in: sites, for: url)
        guard incognito else { return normal?.entry ?? Entry() }
        let overlay = matchingEntry(in: incognitoSites, for: url)
        if let overlay, let normal {
            let overlayPattern = ContentSettingPattern(pattern: overlay.key)?.specificity ?? 0
            let normalPattern = ContentSettingPattern(pattern: normal.key)?.specificity ?? 0
            return overlayPattern >= normalPattern ? overlay.entry : normal.entry
        }
        return (overlay ?? normal)?.entry ?? Entry()
    }

    func update(_ url: URL?, incognito: Bool, _ change: (inout Entry) -> Void) {
        guard let key = Self.key(for: url) else { return }
        update(key: key, incognito: incognito, change)
    }

    func update(key: String, incognito: Bool, _ change: (inout Entry) -> Void) {
        if incognito {
            var entry = incognitoSites[key] ?? sites[key] ?? Entry()
            change(&entry)
            incognitoSites[key] = entry
            return
        }
        var entry = sites[key] ?? Entry()
        change(&entry)
        sites[key] = entry.isEmpty ? nil : entry
        save()
    }

    func remove(site key: String) {
        sites[key] = nil
        save()
    }

    /// Every site's own JavaScript, pop-up and autoplay settings (cross-site cookie answers stay).
    func removeSites() {
        sites.removeAll()
        save()
    }

    // MARK: Cross-site cookies (Storage Access API)

    func storageAccess(domain: String, under top: String, incognito: Bool) -> Bool? {
        let key = Self.key(forDomain: domain) + "|" + Self.key(forDomain: top)
        if incognito, let answer = incognitoStorageAccess[key] { return answer }
        return storageAccess[key]
    }

    func setStorageAccess(_ allowed: Bool, domain: String, under top: String, incognito: Bool) {
        let key = Self.key(forDomain: domain) + "|" + Self.key(forDomain: top)
        if incognito {
            incognitoStorageAccess[key] = allowed
        } else {
            storageAccess[key] = allowed
            save()
        }
    }

    func removeStorageAccess(_ key: String) {
        storageAccess[key] = nil
        save()
    }

    func removeAll() {
        sites.removeAll()
        storageAccess.removeAll()
        save()
    }

    /// Called when the last Incognito window closes.
    func forgetIncognito() {
        incognitoSites.removeAll()
        incognitoStorageAccess.removeAll()
    }

    private func save() {
        let payload = Saved(
            sites: sites, storageAccess: storageAccess,
            defaultSound: defaultSound, defaultImages: defaultImages,
            defaultCookies: defaultCookies, defaultAutomaticDownloads: defaultAutomaticDownloads,
            defaultClipboard: defaultClipboard
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: file, options: .atomic)
    }

    // MARK: Applying

    /// Sets a page load's JavaScript, pop-up and autoplay rules from Settings and the site's own
    /// choices. Called for every main-frame navigation; pop-up and autoplay use WebKit's
    /// per-page policies (`_setPopUpPolicy:`, `_setAutoplayPolicy:`; key-value coding finds the
    /// underscored setter from the plain key), so a site's choice doesn't leak
    /// into the pop-up tabs that share its preferences.
    static func apply(to preferences: WKWebpagePreferences, for url: URL?, incognito: Bool) {
        let privacy = AppSettings.shared.privacy
        let site = shared.entry(for: url, incognito: incognito)
        preferences.allowsContentJavaScript = site.javaScript ?? privacy.javaScript
        // _WKWebsitePopUpPolicy: 0 default (the global preference), 1 allow, 2 block.
        if let popups = site.popups, preferences.responds(to: NSSelectorFromString("_setPopUpPolicy:")) {
            preferences.setValue(popups ? 1 : 2, forKey: "popUpPolicy")
        }
        // _WKWebsiteAutoplayPolicy: 0 default (the configuration's), 1 allow, 2 without sound, 3 deny.
        if let autoplay = site.autoplay, preferences.responds(to: NSSelectorFromString("_setAutoplayPolicy:")) {
            let value = switch autoplay {
            case .allow: 1
            case .muted: 2
            case .never: 3
            }
            preferences.setValue(value, forKey: "autoplayPolicy")
        }
    }

    /// Turns WebKit's cross-site tracking prevention (which blocks third-party cookies) on or
    /// off for every website data store in use, as Settings → Privacy says.
    static func applyCookiePolicy(to stores: [WKWebsiteDataStore]) {
        let block = AppSettings.shared.privacy.blockCrossSiteCookies
        for store in stores where store.responds(to: NSSelectorFromString("_setResourceLoadStatisticsEnabled:")) {
            store.setValue(block, forKey: "resourceLoadStatisticsEnabled")
        }
    }
}

// MARK: - Page menu: Site Settings

/// The page menu's "Site Settings" page: this site's permissions (Ask, Allow or Deny), and its
/// JavaScript, pop-ups and autoplay, each "Default" (as Settings says), "Allow" or "Block".
/// Changing one of the last three reloads the page.
struct SiteSettingsPanel: View {
    @Environment(BrowserState.self) private var state
    let back: () -> Void
    private var store: SiteSettings { .shared }
    private var permissions: SitePermissions { .shared }

    var body: some View {
        let tab = state.selectedTab
        let url = tab?.url
        let incognito = state.isPrivate
        let entry = store.entry(for: url, incognito: incognito)
        let privacy = AppSettings.shared.privacy
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                IconButton(symbol: "chevron.left", size: 11, weight: .bold, side: 24, help: "Back", action: back)
                Text(SiteSettings.key(for: url) ?? "Site Settings")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            .padding(.leading, -4)

            if let origin = SitePermissions.origin(of: url) {
                VStack(spacing: 4) {
                    // Incognito windows never get notifications.
                    ForEach(SitePermissionKind.perSite.filter { !incognito || $0 != .notifications }, id: \.self) { kind in
                        permissionRow(kind, origin: origin, incognito: incognito)
                    }
                }
            }

            VStack(spacing: 4) {
                row("JavaScript", symbol: "curlybraces", value: entry.javaScript, fallback: privacy.javaScript) { value in
                    change(url, tab) { $0.javaScript = value }
                }
                row("Pop-ups", symbol: "macwindow.on.rectangle", value: entry.popups, fallback: !privacy.blockPopups) { value in
                    change(url, tab) { $0.popups = value }
                }
                autoplayRow(entry.autoplay, fallback: privacy.autoplay) { value in
                    change(url, tab) { $0.autoplay = value }
                }
            }

            if !incognito, let origin = SitePermissions.origin(of: url) {
                Button {
                    state.pageMenuVisible = false
                    state.toolbarMenuVisible = false
                    AppDelegate.shared?.showSettings(tab: .websites, site: origin)
                } label: {
                    Label("All Site Settings…", systemImage: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary.opacity(0.75))
                .padding(.leading, 2)
            }

            if !incognito, SiteSettings.key(for: url) != nil {
                Button {
                    clearData(for: url, tab: tab)
                } label: {
                    Label("Clear Website Data…", systemImage: "trash")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.red.opacity(0.85))
                .padding(.leading, 2)
            }

            Text(incognito ? "Kept until you close Incognito." : "Default follows Settings → Websites.")
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.45))
                .padding(.leading, 2)
        }
        .disabled(SiteSettings.key(for: url) == nil)
    }

    /// Removes this site's cookies and storage in every profile (after asking), then reloads.
    private func clearData(for url: URL?, tab: Tab?) {
        state.pageMenuVisible = false
        state.toolbarMenuVisible = false
        WebsiteData.siteName(for: url) { name in
            let site = name ?? SiteSettings.key(for: url) ?? "this site"
            Task { @MainActor in
                guard name != nil else {
                    state.show(Toast(symbol: "checkmark", text: "\(site) has no data stored"))
                    return
                }
                let confirmed = await PromptPresenter.present(Prompt(
                    browser: state, icon: tab?.favicon, symbol: "trash.fill", symbolColor: .red,
                    title: "Clear \(site)’s website data?",
                    message: "Its cookies and site storage are removed in every profile, and the page reloads. You may be signed out of \(site).",
                    confirmTitle: "Clear", destructive: true
                ))
                guard confirmed, let name else { return }
                WebsiteData.remove(site: name) {
                    tab?.reload()
                    state.show(Toast(symbol: "trash", text: "Cleared \(site)’s data"))
                }
            }
        }
    }

    private func change(_ url: URL?, _ tab: Tab?, _ edit: (inout SiteSettings.Entry) -> Void) {
        store.update(url, incognito: state.isPrivate, edit)
        tab?.reload()
    }

    private func permissionRow(_ kind: SitePermissionKind, origin: String, incognito: Bool) -> some View {
        let current = permissions.setting(origin: origin, kind: kind, incognito: incognito)
        return SiteSettingRow(title: kind.label, symbol: kind.symbols.first ?? "questionmark") {
            Menu {
                ForEach(PermissionSetting.allCases) { setting in
                    Button(setting.label) { permissions.set(setting, origin: origin, kind: kind, incognito: incognito) }
                }
            } label: {
                Text(current.label)
            }
        }
    }

    private func row(_ title: String, symbol: String, value: Bool?, fallback: Bool, set: @escaping (Bool?) -> Void) -> some View {
        SiteSettingRow(title: title, symbol: symbol) {
            Menu {
                Button("Default (\(fallback ? "Allow" : "Block"))") { set(nil) }
                Button("Allow") { set(true) }
                Button("Block") { set(false) }
            } label: {
                Text(value.map { $0 ? "Allow" : "Block" } ?? "Default")
            }
        }
    }

    private func autoplayRow(_ value: AutoplayPolicy?, fallback: AutoplayPolicy, set: @escaping (AutoplayPolicy?) -> Void) -> some View {
        SiteSettingRow(title: "Autoplay", symbol: "play.rectangle") {
            Menu {
                Button("Default (\(fallback.label))") { set(nil) }
                ForEach(AutoplayPolicy.allCases) { policy in
                    Button(policy.label) { set(policy) }
                }
            } label: {
                Text(value?.label ?? "Default")
            }
        }
    }
}

private struct SiteSettingRow<Control: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.6))
                .frame(width: 18)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
            Spacer(minLength: 6)
            control()
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
                .font(.system(size: 12))
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(0.07)))
    }
}

// MARK: - Storage Access prompt

extension Tab {
    /// A site embedded in this page (a comment widget, a sign-in frame) asked to use its own
    /// cookies here (`document.requestStorageAccess()`). Cross-site cookies are otherwise
    /// blocked, so this is how one site at a time gets them, like Safari's prompt. Remembered
    /// per pair of sites.
    @objc(_webView:requestStorageAccessPanelForDomain:underCurrentDomain:completionHandler:)
    func webView(
        _ webView: WKWebView, requestStorageAccessPanelForDomain domain: String,
        underCurrentDomain current: String, completionHandler: @escaping (Bool) -> Void
    ) {
        let incognito = browser?.isPrivate ?? false
        if let remembered = SiteSettings.shared.storageAccess(domain: domain, under: current, incognito: incognito) {
            completionHandler(remembered)
            return
        }
        let prompt = Prompt(
            icon: favicon,
            symbol: "lock.open.fill",
            title: "Let “\(domain)” use cookies on “\(current)”?",
            message: "This lets \(domain) see that you’ve used it before, and possibly track what you do on \(current).",
            confirmTitle: "Allow",
            cancelTitle: "Don’t Allow"
        )
        Task { @MainActor in
            guard let result = await askForPage(prompt) else { completionHandler(false); return }
            SiteSettings.shared.setStorageAccess(result.confirmed, domain: domain, under: current, incognito: incognito)
            completionHandler(result.confirmed)
        }
    }

    @objc(_webView:requestStorageAccessPanelForDomain:underCurrentDomain:forQuirkDomains:completionHandler:)
    func webView(
        _ webView: WKWebView, requestStorageAccessPanelForDomain domain: String,
        underCurrentDomain current: String, forQuirkDomains quirkDomains: NSDictionary?,
        completionHandler: @escaping (Bool) -> Void
    ) {
        self.webView(webView, requestStorageAccessPanelForDomain: domain, underCurrentDomain: current, completionHandler: completionHandler)
    }
}

// MARK: - Embeds that need their cookies

/// Google Docs, Slides, Sheets, Drive and Calendar embedded in another site need google.com's
/// cookies, but they never call `document.requestStorageAccess()` themselves, so with cross-site
/// cookies blocked they show "Can't access your Google Account" (Safari does the same). When
/// one of those frames loads without access, Tuff asks for it on the frame's behalf: WebKit then
/// raises the usual Storage Access card (above, remembered per pair of sites) and, once allowed,
/// the frame reloads with its cookies. WebKit only allows this for a site the user has used
/// directly before; otherwise the request quietly fails and nothing is shown.
enum EmbeddedSignIn {
    private static let world = WKContentWorld.world(name: "TuffEmbeddedSignIn")
    private static let handlerName = "tuffEmbeddedSignIn"
    private static let hosts: Set<String> = ["docs.google.com", "drive.google.com", "calendar.google.com", "sites.google.com"]

    private static let script = """
    (() => {
        if (window.top === window || !\(Array(hosts).description).includes(location.hostname)) return;
        if (!document.hasStorageAccess) return;
        document.hasStorageAccess().then(has => {
            if (!has) window.webkit.messageHandlers.\(handlerName).postMessage(location.hostname);
        });
    })();
    """

    static func install(into controller: WKUserContentController) {
        // Only into those hosts' frames: a script in a world of its own costs every other frame a
        // second JavaScript global object for nothing.
        controller.addUserScript(ExtensionContentScripts.makeScript(
            source: script, time: .atDocumentEnd, mainFrameOnly: false,
            include: hosts.sorted().map { "https://\($0)/*" }, exclude: [], world: world
        ))
        controller.add(MessageHandler(), contentWorld: world, name: handlerName)
    }

    private final class MessageHandler: NSObject, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            let frame = message.frameInfo
            guard !frame.isMainFrame, EmbeddedSignIn.hosts.contains(frame.securityOrigin.host.lowercased()),
                  AppSettings.shared.privacy.blockCrossSiteCookies,
                  let webView = message.webView as? TuffWebView, webView.tab != nil else { return }
            // Run as a user gesture, which the Storage Access API needs. If the answer is no
            // (or WebKit refuses), the frame is left as it is, so this can't loop.
            let request = "document.requestStorageAccess().then(() => location.reload(), () => {}); 0"
            webView.evaluateJavaScript(request, in: frame, in: EmbeddedSignIn.world) { _ in }
        }
    }
}
