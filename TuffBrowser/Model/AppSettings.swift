import AppKit
import Observation
import SwiftUI

enum BackgroundStyle: String, Codable, CaseIterable, Identifiable {
    case glass, vibrancy, solid, seamless
    var id: String { rawValue }
    var label: String {
        switch self {
        case .glass: "Glass"
        case .vibrancy: "Vibrancy"
        case .solid: "Solid"
        case .seamless: "Seamless"
        }
    }

    /// What the style does, in a sentence (Settings shows it under the choices).
    var summary: String {
        switch self {
        case .glass: "See-through: the desktop shows blurred behind the tint."
        case .vibrancy: "The system’s frosted material, lightly tinted."
        case .solid: "A flat, opaque colour. Nothing shows through."
        case .seamless: "The window takes on the colour of the page’s header, so the tabs and the page run together, as in Safari."
        }
    }

    /// The window is filled with one flat colour (no blur shows through).
    var isOpaqueFill: Bool { self == .solid || self == .seamless }
}

/// Where a window's tabs go.
enum TabLayout: String, Codable, CaseIterable, Identifiable {
    case vertical, horizontal
    var id: String { rawValue }
    var label: String { self == .vertical ? "Vertical" : "Horizontal" }
    var symbol: String { self == .vertical ? "sidebar.left" : "rectangle.topthird.inset.filled" }
}

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Match Tint"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum SearchEngine: String, Codable, CaseIterable, Identifiable {
    case google, duckduckgo, bing, brave, ecosia, kagi, startpage, perplexity, custom
    var id: String { rawValue }

    var label: String {
        switch self {
        case .google: "Google"
        case .duckduckgo: "DuckDuckGo"
        case .bing: "Bing"
        case .brave: "Brave Search"
        case .ecosia: "Ecosia"
        case .kagi: "Kagi"
        case .startpage: "Startpage"
        case .perplexity: "Perplexity"
        case .custom: "Custom…"
        }
    }

    /// A search URL template from the user, with `%s` where the query goes.
    static func isValidTemplate(_ template: String) -> Bool {
        let t = template.trimmed
        guard t.contains("%s"), let url = URL(string: t.replacingOccurrences(of: "%s", with: "q")) else { return false }
        return url.scheme == "https" || url.scheme == "http"
    }

    private static func encode(_ q: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return q.addingPercentEncoding(withAllowedCharacters: allowed) ?? q
    }

    func searchURL(for query: String) -> URL {
        let q = Self.encode(query)
        let s: String
        switch self {
        case .google: s = "https://www.google.com/search?q=\(q)"
        case .duckduckgo: s = "https://duckduckgo.com/?q=\(q)"
        case .bing: s = "https://www.bing.com/search?q=\(q)"
        case .brave: s = "https://search.brave.com/search?q=\(q)"
        case .ecosia: s = "https://www.ecosia.org/search?q=\(q)"
        case .kagi: s = "https://kagi.com/search?q=\(q)"
        case .startpage: s = "https://www.startpage.com/do/search?q=\(q)"
        case .perplexity: s = "https://www.perplexity.ai/search?q=\(q)"
        case .custom:
            let template = AppSettings.shared.search.customTemplate.trimmed
            guard Self.isValidTemplate(template),
                  let url = URL(string: template.replacingOccurrences(of: "%s", with: q)) else {
                return SearchEngine.google.searchURL(for: query)
            }
            return url
        }
        return URL(string: s)!
    }

    /// OpenSearch-style suggestion endpoint: returns `[query, [suggestions…]]`.
    func suggestURL(for query: String) -> URL? {
        let q = Self.encode(query)
        switch self {
        case .google: return URL(string: "https://suggestqueries.google.com/complete/search?client=firefox&q=\(q)")
        case .duckduckgo: return URL(string: "https://duckduckgo.com/ac/?type=list&q=\(q)")
        case .bing: return URL(string: "https://api.bing.com/osjson.aspx?query=\(q)")
        case .brave: return URL(string: "https://search.brave.com/api/suggest?q=\(q)")
        case .ecosia: return URL(string: "https://ac.ecosia.org/autocomplete?type=list&q=\(q)")
        case .kagi: return URL(string: "https://kagi.com/api/autosuggest?q=\(q)")
        case .startpage: return URL(string: "https://www.startpage.com/suggestions?q=\(q)&format=opensearch")
        case .perplexity, .custom: return nil
        }
    }
}

enum NewTabPosition: String, Codable, CaseIterable, Identifiable {
    case top, bottom
    var id: String { rawValue }
    var label: String { self == .top ? "Top" : "Bottom" }
}

enum AfterCloseSelection: String, Codable, CaseIterable, Identifiable {
    case below, above, recent
    var id: String { rawValue }
    var label: String {
        switch self {
        case .below: "Tab below"
        case .above: "Tab above"
        case .recent: "Last used tab"
        }
    }
}

enum AutoplayPolicy: String, Codable, CaseIterable, Identifiable {
    case allow, muted, never
    var id: String { rawValue }
    var label: String {
        switch self {
        case .allow: "Allow"
        case .muted: "Muted only"
        case .never: "Never"
        }
    }
}

enum UserAgentMode: String, Codable, CaseIterable, Identifiable {
    case safari, chrome, firefox, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .firefox: "Firefox"
        case .custom: "Custom"
        }
    }
}

/// Behaviour of the app and window.
struct BehaviorSettings: Codable, Equatable {
    var confirmQuit = false
    /// Float the collapsed sidebar over the page when the pointer touches the window's left edge.
    var peekSidebarOnEdge = true
}

struct TabSettings: Codable, Equatable {
    /// Tabs down a sidebar (Arc-style) or across the top of the window, for regular windows.
    var layout: TabLayout = .vertical
    /// The same choice for Incognito windows.
    var incognitoLayout: TabLayout = .vertical
    var newTabPosition: NewTabPosition = .top
    var afterClose: AfterCloseSelection = .below
    /// ⌘-click opens links in the foreground (⇧ flips it either way).
    var foregroundLinks = false
    /// Close regular tabs that haven't been looked at for this many hours. 0 = never.
    var closeIdleAfterHours = 0
    var alwaysShowCloseButton = false
    var compactRows = false
    /// Pop a video that is playing with sound into picture in picture when its tab is left.
    var autoPictureInPicture = true
}

struct SearchSettings: Codable, Equatable {
    var customTemplate = ""
    var historySuggestions = true
    var openTabSuggestions = true
}

/// Optional extras ("mods") that change how Tuff behaves. Settings → Mods.
struct ModSettings: Codable, Equatable {
    /// DuckDuckGo-style `!bangs` in the command bar: `!yt cats` searches YouTube.
    var bangs = true
}

struct PrivacySettings: Codable, Equatable {
    var saveHistory = true
    var clearHistoryOnQuit = false
    var javaScript = true
    /// Pages can open new tabs / windows only in response to a click or key press.
    var blockPopups = true
    /// WebKit's cross-site tracking prevention: third-party cookies are blocked unless a site
    /// asks for them and you allow it (`SiteSettings`, Storage Access).
    var blockCrossSiteCookies = true
    var upgradeToHTTPS = true
    var fraudWarnings = true
    var autoplay: AutoplayPolicy = .allow
    var rememberMediaPermissions = true
    /// Tuff's built-in ad and tracker blocker (`ContentBlocker`).
    var blockAds = true
    /// Sites (and their subdomains) the blocker leaves alone.
    var adBlockAllowlist: [String] = []
}

extension PrivacySettings {
    // Settings saved before a field existed still load, with that field at its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PrivacySettings()
        saveHistory = try c.decodeIfPresent(Bool.self, forKey: .saveHistory) ?? d.saveHistory
        clearHistoryOnQuit = try c.decodeIfPresent(Bool.self, forKey: .clearHistoryOnQuit) ?? d.clearHistoryOnQuit
        javaScript = try c.decodeIfPresent(Bool.self, forKey: .javaScript) ?? d.javaScript
        blockPopups = try c.decodeIfPresent(Bool.self, forKey: .blockPopups) ?? d.blockPopups
        blockCrossSiteCookies = try c.decodeIfPresent(Bool.self, forKey: .blockCrossSiteCookies) ?? d.blockCrossSiteCookies
        upgradeToHTTPS = try c.decodeIfPresent(Bool.self, forKey: .upgradeToHTTPS) ?? d.upgradeToHTTPS
        fraudWarnings = try c.decodeIfPresent(Bool.self, forKey: .fraudWarnings) ?? d.fraudWarnings
        autoplay = try c.decodeIfPresent(AutoplayPolicy.self, forKey: .autoplay) ?? d.autoplay
        rememberMediaPermissions = try c.decodeIfPresent(Bool.self, forKey: .rememberMediaPermissions) ?? d.rememberMediaPermissions
        blockAds = try c.decodeIfPresent(Bool.self, forKey: .blockAds) ?? d.blockAds
        adBlockAllowlist = try c.decodeIfPresent([String].self, forKey: .adBlockAllowlist) ?? d.adBlockAllowlist
    }
}

struct DownloadSettings: Codable, Equatable {
    /// Empty means ~/Downloads.
    var folderPath = ""
    var askWhereToSave = false
    var showPanelOnStart = true
    var openSafeFiles = false

    var folder: URL {
        if !folderPath.isEmpty { return URL(fileURLWithPath: folderPath, isDirectory: true) }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }
}

struct AdvancedSettings: Codable, Equatable {
    var defaultZoom: Double = 1
    var minimumFontSize: Double = 0
    var userAgent: UserAgentMode = .safari
    var customUserAgent = ""
    var swipeNavigation = true
    var linkPreviews = true
    var webInspector = true

    static let chromeUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"
    static let firefoxUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:144.0) Gecko/20100101 Firefox/144.0"

    /// nil = WebKit's own (Safari) user agent.
    var resolvedUserAgent: String? {
        switch userAgent {
        case .safari: nil
        case .chrome: Self.chromeUserAgent
        case .firefox: Self.firefoxUserAgent
        case .custom: customUserAgent.trimmed.isEmpty ? nil : customUserAgent.trimmed
        }
    }
}

struct Theme: Codable, Equatable {
    var style: BackgroundStyle = .glass
    /// Window tint when "space colours" is off.
    var tintHex: String = "#0E1A1C"
    /// 0 = fully see-through, 1 = opaque tint.
    var tintOpacity: Double = 0.74
    /// Background blur radius in points (Glass style).
    var blurRadius: Double = 36
    /// Film grain strength, 0…1.
    var grain: Double = 0.22
    /// Corner radius of the web page card.
    var cardRadius: Double = 12
    /// Gap between the window edge and the web page card.
    var cardInset: Double = 8
    var appearance: AppearanceMode = .auto
    /// Each space tints the window with its own colour.
    var useSpaceColors: Bool = true
    /// A soft top-to-bottom sheen over the tint.
    var sheen: Double = 0.5
    /// Incognito windows use the Seamless background whatever `style` the others have.
    var incognitoSeamless: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Theme()
        style = try c.decodeIfPresent(BackgroundStyle.self, forKey: .style) ?? d.style
        tintHex = try c.decodeIfPresent(String.self, forKey: .tintHex) ?? d.tintHex
        tintOpacity = try c.decodeIfPresent(Double.self, forKey: .tintOpacity) ?? d.tintOpacity
        blurRadius = try c.decodeIfPresent(Double.self, forKey: .blurRadius) ?? d.blurRadius
        grain = try c.decodeIfPresent(Double.self, forKey: .grain) ?? d.grain
        cardRadius = try c.decodeIfPresent(Double.self, forKey: .cardRadius) ?? d.cardRadius
        cardInset = try c.decodeIfPresent(Double.self, forKey: .cardInset) ?? d.cardInset
        appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? d.appearance
        useSpaceColors = try c.decodeIfPresent(Bool.self, forKey: .useSpaceColors) ?? d.useSpaceColors
        sheen = try c.decodeIfPresent(Double.self, forKey: .sheen) ?? d.sheen
        incognitoSeamless = try c.decodeIfPresent(Bool.self, forKey: .incognitoSeamless) ?? d.incognitoSeamless
    }

    /// The theme as a window of this kind shows it.
    func forWindow(incognito: Bool) -> Theme {
        guard incognito, incognitoSeamless else { return self }
        var theme = self
        theme.style = .seamless
        return theme
    }
}

struct GeneralSettings: Codable, Equatable {
    var searchEngine: SearchEngine = .google
    var searchSuggestions: Bool = true
    /// Unload background tabs after this many minutes. 0 disables tab sleeping.
    var sleepAfterMinutes: Int = 30
    var sidebarWidth: Double = 256
    /// Width of an extension's side panel, right of the page.
    var sidePanelWidth: Double = 360
    var restoreSession: Bool = true
    var reduceMotion: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GeneralSettings()
        searchEngine = try c.decodeIfPresent(SearchEngine.self, forKey: .searchEngine) ?? d.searchEngine
        searchSuggestions = try c.decodeIfPresent(Bool.self, forKey: .searchSuggestions) ?? d.searchSuggestions
        sleepAfterMinutes = try c.decodeIfPresent(Int.self, forKey: .sleepAfterMinutes) ?? d.sleepAfterMinutes
        sidebarWidth = try c.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? d.sidebarWidth
        sidePanelWidth = try c.decodeIfPresent(Double.self, forKey: .sidePanelWidth) ?? d.sidePanelWidth
        restoreSession = try c.decodeIfPresent(Bool.self, forKey: .restoreSession) ?? d.restoreSession
        reduceMotion = try c.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? d.reduceMotion
    }
}

@Observable
final class AppSettings {
    static let shared = AppSettings()

    var theme: Theme { didSet { if theme != oldValue { persist(Self.themeKey) } } }
    var general: GeneralSettings { didSet { if general != oldValue { persist(Self.generalKey) } } }
    var behavior: BehaviorSettings { didSet { if behavior != oldValue { persist(Self.behaviorKey) } } }
    var tabs: TabSettings { didSet { if tabs != oldValue { persist(Self.tabsKey) } } }
    var search: SearchSettings { didSet { if search != oldValue { persist(Self.searchKey) } } }
    var privacy: PrivacySettings { didSet { if privacy != oldValue { persist(Self.privacyKey); webSettingsChanged() } } }
    var downloads: DownloadSettings { didSet { if downloads != oldValue { persist(Self.downloadsKey) } } }
    var advanced: AdvancedSettings { didSet { if advanced != oldValue { persist(Self.advancedKey); webSettingsChanged() } } }
    var mods: ModSettings { didSet { if mods != oldValue { persist(Self.modsKey) } } }

    /// Groups changed since the last write. Dragging a slider or the sidebar's edge changes a
    /// setting on every mouse event; they are written once, when the changes stop coming.
    @ObservationIgnored private var unsaved: Set<String> = []
    @ObservationIgnored private let saver = Debouncer(delay: 0.3)

    private static let themeKey = "tuff.theme"
    private static let generalKey = "tuff.general"
    private static let behaviorKey = "tuff.behavior"
    private static let tabsKey = "tuff.tabs"
    private static let searchKey = "tuff.search"
    private static let privacyKey = "tuff.privacy"
    private static let downloadsKey = "tuff.downloads"
    private static let advancedKey = "tuff.advanced"
    private static let modsKey = "tuff.mods"

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.themeKey), let t = try? JSONDecoder().decode(Theme.self, from: data) {
            theme = t
        } else {
            theme = Theme()
        }
        if let data = defaults.data(forKey: Self.generalKey), let g = try? JSONDecoder().decode(GeneralSettings.self, from: data) {
            general = g
        } else {
            general = GeneralSettings()
        }
        behavior = Self.load(Self.behaviorKey, BehaviorSettings())
        tabs = Self.load(Self.tabsKey, TabSettings())
        search = Self.load(Self.searchKey, SearchSettings())
        privacy = Self.load(Self.privacyKey, PrivacySettings())
        downloads = Self.load(Self.downloadsKey, DownloadSettings())
        advanced = Self.load(Self.advancedKey, AdvancedSettings())
        mods = Self.load(Self.modsKey, ModSettings())
    }

    /// Decodes a settings group, filling fields added since it was saved from `fallback`.
    private static func load<T: Codable>(_ key: String, _ fallback: T) -> T {
        guard let data = UserDefaults.standard.data(forKey: key) else { return fallback }
        return merged(data, over: fallback)
    }

    private static func merged<T: Codable>(_ data: Data, over fallback: T) -> T {
        if let value = try? JSONDecoder().decode(T.self, from: data) { return value }
        guard let baseData = try? JSONEncoder().encode(fallback),
              var base = (try? JSONSerialization.jsonObject(with: baseData)) as? [String: Any],
              let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return fallback }
        base.merge(stored) { _, new in new }
        // Drop stored values that no longer decode (e.g. a removed enum case), one at a time.
        for key in stored.keys {
            if let merged = try? JSONSerialization.data(withJSONObject: base),
               let value = try? JSONDecoder().decode(T.self, from: merged) { return value }
            if let original = (try? JSONSerialization.jsonObject(with: baseData)) as? [String: Any] {
                base[key] = original[key]
            }
        }
        guard let merged = try? JSONSerialization.data(withJSONObject: base) else { return fallback }
        return (try? JSONDecoder().decode(T.self, from: merged)) ?? fallback
    }

    private func persist(_ key: String) {
        #if DEBUG
        // Automated test runs must not rewrite the real preferences.
        if ProcessInfo.processInfo.environment["TUFF_DATA_DIR"] != nil { return }
        #endif
        unsaved.insert(key)
        saver.schedule { [weak self] in self?.saveNow() }
    }

    /// Writes whatever changed since the last write. Also called when the app quits.
    func saveNow() {
        saver.cancel()
        guard !unsaved.isEmpty else { return }
        let defaults = UserDefaults.standard
        func put<T: Encodable>(_ value: T, _ key: String) {
            guard unsaved.contains(key), let data = try? JSONEncoder().encode(value) else { return }
            defaults.set(data, forKey: key)
        }
        put(theme, Self.themeKey)
        put(general, Self.generalKey)
        put(behavior, Self.behaviorKey)
        put(tabs, Self.tabsKey)
        put(search, Self.searchKey)
        put(privacy, Self.privacyKey)
        put(downloads, Self.downloadsKey)
        put(advanced, Self.advancedKey)
        put(mods, Self.modsKey)
        unsaved.removeAll()
    }

    /// Pushes settings that live web views can pick up without being rebuilt.
    private func webSettingsChanged() {
        for tab in BrowserState.all.flatMap(\.allTabs) {
            if let view = tab.webView { WebEngine.applyLiveSettings(to: view) }
        }
        ContentBlocker.shared.settingsChanged()
    }

    func resetTheme() { theme = Theme() }

    func resetAll() {
        theme = Theme()
        general = GeneralSettings()
        behavior = BehaviorSettings()
        tabs = TabSettings()
        search = SearchSettings()
        privacy = PrivacySettings()
        downloads = DownloadSettings()
        advanced = AdvancedSettings()
        mods = ModSettings()
    }

    // MARK: Export / import

    private struct Bundle: Codable {
        var theme: Theme
        var general: GeneralSettings
        var behavior: BehaviorSettings?
        var tabs: TabSettings?
        var search: SearchSettings?
        var privacy: PrivacySettings?
        var downloads: DownloadSettings?
        var advanced: AdvancedSettings?
        var mods: ModSettings?
    }

    func exportData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(Bundle(
            theme: theme, general: general, behavior: behavior, tabs: tabs, search: search,
            privacy: privacy, downloads: downloads, advanced: advanced, mods: mods
        ))
    }

    @discardableResult
    func importData(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["theme"] != nil else { return false }
        func part<T: Codable>(_ key: String, _ current: T) -> T {
            guard let value = object[key], let data = try? JSONSerialization.data(withJSONObject: value) else { return current }
            return Self.merged(data, over: current)
        }
        theme = part("theme", theme)
        general = part("general", general)
        behavior = part("behavior", behavior)
        tabs = part("tabs", tabs)
        search = part("search", search)
        privacy = part("privacy", privacy)
        downloads = part("downloads", downloads)
        advanced = part("advanced", advanced)
        mods = part("mods", mods)
        return true
    }

    /// Colour scheme for the browser chrome given the tint that is currently showing.
    func chromeScheme(for tint: NSColor) -> ColorScheme {
        switch theme.appearance {
        case .light: return .light
        case .dark: return .dark
        case .auto: return tint.luminance < 0.55 ? .dark : .light
        }
    }

    var animationsEnabled: Bool { !general.reduceMotion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
