import AppKit
import CoreText
import Network
import WebKit

/// Browser settings extensions can read and change through Chrome's `types.ChromeSetting`
/// shape (`get` / `set` / `clear` / `onChange`): `chrome.privacy.*`, `chrome.proxy.settings`,
/// Firefox's `browser.browserSettings.*`, and the font preferences behind `chrome.fontSettings`.
///
/// Each setting is either backed by one of Tuff's own (Settings → Privacy, say), in which case
/// an extension that sets it changes it there too, or is reported as not controllable with the
/// value Tuff actually uses. Like Chrome, one extension at a time controls a setting; `clear`
/// (or the extension being removed or turned off) puts back the value from before it took over.
final class ExtensionSettings {
    static let shared = ExtensionSettings()

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// One setting: how to read it, and how to change it if extensions may.
    struct Setting {
        var get: () -> Any
        var set: ((Any) throws -> Void)?
    }

    private var settings: [String: Setting] = [:]

    /// Saved across launches: who controls what, what to put back, and the values Tuff keeps
    /// only for extensions (proxy, fonts).
    private struct Saved: Codable {
        var controllers: [String: String] = [:]
        var originals: [String: String] = [:]
        var values: [String: String] = [:]
    }

    private var saved = Saved()
    private let file = Paths.appSupport.appendingPathComponent("extension-settings.json")

    private init() {
        if let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = decoded
        }
        registerPrivacy()
        registerBrowserSettings()
        registerProxy()
        registerFonts()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private func register(_ path: String, get: @escaping () -> Any, set: ((Any) throws -> Void)? = nil) {
        settings[path] = Setting(get: get, set: set)
    }

    /// A setting that is always `value` and can't be changed.
    private func fixed(_ path: String, _ value: Any) {
        register(path, get: { value })
    }

    // MARK: ChromeSetting

    func get(_ path: String, extensionID: String) throws -> [String: Any] {
        guard let setting = settings[path] else { throw Failure("Unknown setting: \(path).") }
        return ["value": setting.get(), "levelOfControl": levelOfControl(path, extensionID: extensionID)]
    }

    private func levelOfControl(_ path: String, extensionID: String) -> String {
        guard settings[path]?.set != nil else { return "not_controllable" }
        switch saved.controllers[path] {
        case nil: return "controllable_by_this_extension"
        case extensionID: return "controlled_by_this_extension"
        default: return "controlled_by_other_extensions"
        }
    }

    func set(_ path: String, value: Any, extensionID: String) throws {
        guard let setting = settings[path] else { throw Failure("Unknown setting: \(path).") }
        guard let apply = setting.set else { throw Failure("\(path) can’t be changed in Tuff.") }
        if let other = saved.controllers[path], other != extensionID {
            throw Failure("\(path) is controlled by another extension.")
        }
        if saved.controllers[path] == nil { saved.originals[path] = Self.encode(setting.get()) }
        try apply(value)
        saved.controllers[path] = extensionID
        save()
        changed(path)
    }

    func clear(_ path: String, extensionID: String) throws {
        guard settings[path] != nil else { throw Failure("Unknown setting: \(path).") }
        guard saved.controllers[path] == extensionID else { return }
        restore(path)
        save()
        changed(path)
    }

    /// The extension was removed or turned off: what it changed goes back.
    func extensionRemoved(_ extensionID: String) {
        let paths = saved.controllers.filter { $0.value == extensionID }.map(\.key)
        guard !paths.isEmpty else { return }
        for path in paths { restore(path) }
        save()
        paths.forEach(changed)
    }

    private func restore(_ path: String) {
        if let original = saved.originals[path].flatMap(Self.decode), let apply = settings[path]?.set {
            try? apply(original)
        }
        saved.controllers[path] = nil
        saved.originals[path] = nil
    }

    /// Tells each listening extension, with the level of control as it sees it.
    private func changed(_ path: String) {
        guard let setting = settings[path] else { return }
        let value = setting.get()
        for id in ExtensionManager.shared.contexts.keys {
            ExtensionEventPush.shared.emit(
                "settings.onChange." + path,
                args: [["value": value, "levelOfControl": levelOfControl(path, extensionID: id)]],
                to: id
            )
        }
    }

    private static func encode(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: ["v": value], options: [.fragmentsAllowed]) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
    }

    private static func decode(_ text: String) -> Any? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["v"]
    }

    private static func bool(_ value: Any) throws -> Bool {
        guard let bool = value as? Bool else { throw Failure("The value must be a boolean.") }
        return bool
    }

    // MARK: chrome.privacy

    private var app: AppSettings { .shared }

    private func registerPrivacy() {
        register("privacy.services.safeBrowsingEnabled", get: { self.app.privacy.fraudWarnings }) {
            self.app.privacy.fraudWarnings = try Self.bool($0)
        }
        register("privacy.services.searchSuggestEnabled", get: { self.app.general.searchSuggestions }) {
            self.app.general.searchSuggestions = try Self.bool($0)
        }
        register("privacy.websites.thirdPartyCookiesAllowed", get: { !self.app.privacy.blockCrossSiteCookies }) {
            self.app.privacy.blockCrossSiteCookies = !(try Self.bool($0))
        }
        // What WebKit does, which Tuff has no switch for.
        fixed("privacy.network.networkPredictionEnabled", true)
        fixed("privacy.network.webRTCIPHandlingPolicy", "default")
        fixed("privacy.network.peerConnectionEnabled", true)
        for name in ["alternateErrorPagesEnabled", "autofillEnabled", "autofillAddressEnabled", "autofillCreditCardEnabled",
                     "passwordSavingEnabled", "safeBrowsingExtendedReportingEnabled", "spellingServiceEnabled",
                     "translationServiceEnabled"] {
            fixed("privacy.services." + name, false)
        }
        fixed("privacy.websites.hyperlinkAuditingEnabled", true)
        fixed("privacy.websites.referrersEnabled", true)
        fixed("privacy.websites.doNotTrackEnabled", false)
        fixed("privacy.websites.protectedContentEnabled", true)
        fixed("privacy.websites.topicsEnabled", false)
        fixed("privacy.websites.fledgeEnabled", false)
        fixed("privacy.websites.adMeasurementEnabled", false)
        fixed("privacy.websites.relatedWebsiteSetsEnabled", false)
        // Firefox.
        register("privacy.websites.cookieConfig", get: {
            ["behavior": self.app.privacy.blockCrossSiteCookies ? "reject_trackers" : "allow_all", "nonPersistentCookies": false]
        }) { value in
            guard let behavior = (value as? [String: Any])?["behavior"] as? String else { throw Failure("behavior is required.") }
            switch behavior {
            case "allow_all": self.app.privacy.blockCrossSiteCookies = false
            case "reject_trackers", "reject_third_party", "allow_visited", "reject_trackers_and_partition_foreign":
                self.app.privacy.blockCrossSiteCookies = true
            default: throw Failure("Tuff can’t use the cookie behaviour “\(behavior)”.")
            }
        }
        register("privacy.websites.trackingProtectionMode", get: { self.app.privacy.blockAds ? "always" : "never" })
        register("privacy.network.httpsOnlyMode", get: { "never" })
        fixed("privacy.websites.firstPartyIsolate", false)
        fixed("privacy.websites.resistFingerprinting", false)
        fixed("privacy.network.globalPrivacyControl", false)
    }

    // MARK: browser.browserSettings (Firefox)

    private func registerBrowserSettings() {
        fixed("browserSettings.allowPopupsForUserEvents", true)
        fixed("browserSettings.cacheEnabled", true)
        fixed("browserSettings.closeTabsByDoubleClick", false)
        fixed("browserSettings.contextMenuShowEvent", "mousedown")
        fixed("browserSettings.ftpProtocolEnabled", false)
        fixed("browserSettings.homepageOverride", "about:blank")
        fixed("browserSettings.imageAnimationBehavior", "normal")
        fixed("browserSettings.newTabPageOverride", "about:newtab")
        register("browserSettings.newTabPosition", get: {
            self.app.tabs.newTabPosition == .bottom ? "atEnd" : "relatedAfterCurrent"
        })
        fixed("browserSettings.openBookmarksInNewTabs", false)
        fixed("browserSettings.openSearchResultsInNewTabs", false)
        fixed("browserSettings.openUrlbarResultsInNewTabs", false)
        fixed("browserSettings.webNotificationsDisabled", false)
        fixed("browserSettings.overrideDocumentColors", "never")
        fixed("browserSettings.overrideContentColorScheme", "auto")
        fixed("browserSettings.useDocumentFonts", true)
        fixed("browserSettings.zoomFullPage", true)
        fixed("browserSettings.zoomSiteSpecific", true)
        fixed("browserSettings.tlsMinimumVersion", "TLSv1.2")
        fixed("browserSettings.tlsMaximumVersion", "TLSv1.3")
        register("browserSettings.verticalTabs", get: { self.app.tabs.layout == .vertical }) {
            self.app.tabs.layout = try Self.bool($0) ? .vertical : .horizontal
        }
    }

    // MARK: chrome.proxy

    /// The proxy an extension set, as Chrome's `ProxyConfig`; nil means none (the system's).
    private var proxyConfig: [String: Any]? {
        saved.values["proxy.settings"].flatMap(Self.decode) as? [String: Any]
    }

    private func registerProxy() {
        if let config = proxyConfig,
           (config["mode"] as? String == "direct" || config["proxyType"] as? String == "none") {
            saved.values["proxy.settings"] = nil
            saved.controllers["proxy.settings"] = nil
            saved.originals["proxy.settings"] = nil
            save()
        }
        // Chrome's ProxyConfig ({mode, rules}) or Firefox's ({proxyType, http, ssl, socks, …}).
        register("proxy.settings", get: { self.proxyConfig ?? ["mode": "system", "proxyType": "system"] }) { value in
            guard let config = value as? [String: Any], config["mode"] is String || config["proxyType"] is String else {
                throw Failure("A proxy config with a mode is required.")
            }
            let proxies = try Self.proxyConfigurations(for: config)  // refuse what Tuff can't do before keeping it
            self.saved.values["proxy.settings"] = proxies == nil ? nil : Self.encode(config)
            self.save()
            self.applyProxy(to: DataStores.all)
        }
    }

    /// Network's proxy configurations for a Chrome `ProxyConfig`, or nil for the system's.
    /// Built with Network's C API: the Swift `ProxyConfiguration.excludedDomains` doesn't keep
    /// (or report) its domains in this SDK.
    static func proxyConfigurations(for config: [String: Any]) throws -> [nw_proxy_config_t]? {
        if let type = config["proxyType"] as? String { return try firefoxProxyConfigurations(type: type, config: config) }
        switch config["mode"] as? String {
        case "system", nil:
            return nil
        case "direct":
            throw Failure("Tuff can’t force direct connections while system proxies are configured.")
        case "fixed_servers":
            let rules = config["rules"] as? [String: Any] ?? [:]
            let server = (rules["singleProxy"] ?? rules["proxyForHttps"] ?? rules["proxyForHttp"] ?? rules["fallbackProxy"]) as? [String: Any]
            guard let server, let host = server["host"] as? String, !host.isEmpty else {
                throw Failure("fixed_servers needs a proxy server.")
            }
            let scheme = (server["scheme"] as? String ?? "http").lowercased()
            let defaultPort = scheme.hasPrefix("socks") ? 1080 : scheme == "https" ? 443 : 80
            let port = server["port"] as? Int ?? defaultPort
            guard (1...65535).contains(port) else { throw Failure("Invalid proxy port.") }
            let endpoint = nw_endpoint_create_host(host, String(port))
            let proxy: nw_proxy_config_t
            switch scheme {
            case "http": proxy = nw_proxy_config_create_http_connect(endpoint, nil)
            case "https": proxy = nw_proxy_config_create_http_connect(endpoint, nw_tls_create_options())
            case "socks5": proxy = nw_proxy_config_create_socksv5(endpoint)
            default: throw Failure("Tuff can’t use \(scheme) proxies (HTTP, HTTPS and SOCKS5 work).")
            }
            for domain in rules["bypassList"] as? [String] ?? [] {
                let trimmed = domain.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed != "<local>" else { continue }
                nw_proxy_config_add_excluded_domain(proxy, trimmed.hasPrefix("*.") ? String(trimmed.dropFirst(2)) : trimmed)
            }
            return [proxy]
        case let mode?:
            throw Failure("Tuff can’t use the proxy mode “\(mode)” (fixed_servers and system work).")
        }
    }

    /// Firefox's `proxy.settings` value: `manual` with "host:port" servers.
    private static func firefoxProxyConfigurations(type: String, config: [String: Any]) throws -> [nw_proxy_config_t]? {
        switch type {
        case "system":
            return nil
        case "none":
            throw Failure("Tuff can’t force direct connections while system proxies are configured.")
        case "manual":
            func server(_ key: String) -> (host: String, port: Int?)? {
                guard var text = config[key] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                text = text.trimmingCharacters(in: .whitespaces)
                if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
                let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
                return (parts[0], parts.count > 1 ? Int(parts[1]) : nil)
            }
            var rules: [String: Any] = [:]
            if let socks = server("socks") {
                guard (config["socksVersion"] as? Int ?? 5) == 5 else { throw Failure("Tuff can’t use SOCKS4 proxies.") }
                rules["singleProxy"] = ["scheme": "socks5", "host": socks.host, "port": socks.port ?? 1080] as [String: Any]
            } else if let web = server("ssl") ?? server("http") {
                rules["singleProxy"] = ["scheme": "http", "host": web.host, "port": web.port ?? 80] as [String: Any]
            } else {
                throw Failure("A manual proxy needs a server.")
            }
            let passthrough = (config["passthrough"] as? String ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            rules["bypassList"] = passthrough
            return try proxyConfigurations(for: ["mode": "fixed_servers", "rules": rules])
        default:
            throw Failure("Tuff can’t use the proxy type “\(type)” (manual and system work).")
        }
    }

    /// Puts the extension-set proxy (or none) on website data stores; new ones get it as their
    /// first web view is configured.
    func applyProxy(to stores: [WKWebsiteDataStore]) {
        let configurations = proxyConfig.flatMap { try? Self.proxyConfigurations(for: $0) } ?? []
        for store in stores {
            if configurations.isEmpty, (store.__proxyConfigurations ?? []).isEmpty { continue }
            store.__proxyConfigurations = configurations
        }
    }

    /// Whether an extension has set a proxy (so the common case does nothing per web view).
    var hasProxy: Bool { saved.values["proxy.settings"] != nil }

    // MARK: Fonts (chrome.fontSettings)

    static let genericFamilies = ["standard", "sansserif", "serif", "fixed", "cursive", "fantasy", "math"]
    /// The WebKit preference behind each generic family (private, read and set by key-value
    /// coding from the underscored accessors). Only the standard family has one in the WebKit
    /// this was written against; the others report WebKit's macOS default and can't be changed,
    /// unless a later WebKit adds their accessors.
    private static let fontKeys: [String: String] = [
        "standard": "standardFontFamily", "sansserif": "sansSerifFontFamily", "serif": "serifFontFamily",
        "fixed": "fixedFontFamily", "cursive": "cursiveFontFamily", "fantasy": "fantasyFontFamily",
    ]
    private static let defaultFamilies: [String: String] = [
        "standard": "Times", "serif": "Times", "sansserif": "Helvetica", "fixed": "Courier",
        "cursive": "Apple Chancery", "fantasy": "Papyrus", "math": "STIX Two Math",
    ]

    private static func canSet(_ key: String) -> Bool {
        webKitDefaults.responds(to: NSSelectorFromString("_set" + key.prefix(1).uppercased() + key.dropFirst() + ":"))
    }

    private static let webKitDefaults = WKPreferences()

    private static func defaultValue(forKey key: String) -> Any? {
        guard webKitDefaults.responds(to: NSSelectorFromString("_" + key)) else { return nil }
        return webKitDefaults.value(forKey: key)
    }

    private func registerFonts() {
        for family in Self.genericFamilies {
            let path = "fontSettings.font." + family
            let fallback = Self.defaultFamilies[family] ?? ""
            guard let key = Self.fontKeys[family], Self.canSet(key) else { fixed(path, fallback); continue }
            register(path, get: {
                self.saved.values[path].flatMap(Self.decode) as? String ?? Self.defaultValue(forKey: key) as? String ?? fallback
            }) { value in
                guard let name = value as? String else { throw Failure("fontId must be a string.") }
                self.saved.values[path] = name.isEmpty ? nil : Self.encode(name)
                self.save()
                self.applyFontsToOpenPages()
            }
        }
        for (name, key, fallback) in [("defaultFontSize", "defaultFontSize", 16), ("defaultFixedFontSize", "defaultFixedPitchFontSize", 13)] {
            let path = "fontSettings." + name
            guard Self.canSet(key) else { fixed(path, fallback); continue }
            register(path, get: {
                self.saved.values[path].flatMap(Self.decode) as? Int ?? (Self.defaultValue(forKey: key) as? NSNumber)?.intValue ?? fallback
            }) { value in
                guard let size = value as? Int, (6...72).contains(size) else { throw Failure("pixelSize must be between 6 and 72.") }
                self.saved.values[path] = Self.encode(size)
                self.save()
                self.applyFontsToOpenPages()
            }
        }
        register("fontSettings.minimumFontSize", get: { Int(self.app.advanced.minimumFontSize) }) { value in
            guard let size = value as? Int, (0...24).contains(size) else { throw Failure("pixelSize must be between 0 and 24.") }
            self.app.advanced.minimumFontSize = Double(size)
        }
    }

    /// The families pages can use: the system's (pages don't get fonts the user installed).
    func fontList() -> [[String: Any]] {
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        var families = Set<String>()
        for descriptor in descriptors {
            guard let url = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL,
                  url.path.hasPrefix("/System/"),
                  let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
                  !family.hasPrefix(".") else { continue }
            families.insert(family)
        }
        return families.sorted().map { ["fontId": $0, "displayName": $0] }
    }

    /// The font choices extensions made, on a web view's preferences.
    func applyFonts(to preferences: WKPreferences) {
        for (family, key) in Self.fontKeys {
            guard let name = saved.values["fontSettings.font." + family].flatMap(Self.decode) as? String,
                  preferences.responds(to: NSSelectorFromString("_set" + key.prefix(1).uppercased() + key.dropFirst() + ":")) else { continue }
            preferences.setValue(name, forKey: key)
        }
        for (path, key) in [("fontSettings.defaultFontSize", "defaultFontSize"), ("fontSettings.defaultFixedFontSize", "defaultFixedPitchFontSize")] {
            guard let size = saved.values[path].flatMap(Self.decode) as? Int,
                  preferences.responds(to: NSSelectorFromString("_set" + key.prefix(1).uppercased() + key.dropFirst() + ":")) else { continue }
            preferences.setValue(size, forKey: key)
        }
    }

    /// Whether any font choice is in effect (so the common case touches no private API).
    var hasFontChoices: Bool { saved.values.keys.contains { $0.hasPrefix("fontSettings.") } }

    private func applyFontsToOpenPages() {
        for state in [BrowserState.shared] {
            for tab in state.allTabs { if let view = tab.webView { applyFonts(to: view.configuration.preferences) } }
        }
    }
}
