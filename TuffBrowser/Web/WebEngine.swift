import AppKit
import WebKit

/// The web view used for every tab.
final class TuffWebView: WKWebView {
    weak var tab: Tab?

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // WebKit doesn't always report "no link" when the mouse leaves straight off a link.
        if tab?.hoveredLink != nil { tab?.hoveredLink = nil }
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // "New Window" requests land in `createWebViewWith`, which opens a tab — so say so.
        for item in menu.items {
            switch item.identifier?.rawValue {
            case "WKMenuItemIdentifierOpenLinkInNewWindow": item.title = "Open Link in New Tab"
            case "WKMenuItemIdentifierOpenImageInNewWindow": item.title = "Open Image in New Tab"
            case "WKMenuItemIdentifierOpenFrameInNewWindow": item.title = "Open Frame in New Tab"
            case "WKMenuItemIdentifierOpenMediaInNewWindow": item.title = "Open Video in New Tab"
            default: break
            }
        }
        if let tab {
            let extra = ExtensionManager.shared.contextMenuItems(for: tab)
            if !extra.isEmpty {
                menu.addItem(.separator())
                extra.forEach { menu.addItem($0) }
            }
        }
    }
}

enum WebEngine {
    /// We present as Safari: it is the same engine, and it is what sites (and FairPlay DRM
    /// players such as Netflix, Spotify, Disney+) expect from WebKit on a Mac.
    static let userAgentApplicationName: String = {
        var version = "18.6"
        let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        if let dict = NSDictionary(contentsOf: plist), let v = dict["CFBundleShortVersionString"] as? String, !v.isEmpty {
            version = v
        }
        return "Version/\(version) Safari/605.1.15"
    }()

    // MARK: Caches

    /// Tells WebKit this app is the user's main browser, once, before the first web view.
    ///
    /// WebKit sizes its caches by "cache model", and a third-party app gets the one meant for
    /// an app that shows the odd web page: a small disk cache, a small in-memory cache of
    /// decoded resources, and a short back / forward cache. Safari asks for the primary
    /// browser model instead (`WKContextSetCacheModel`, private but long-standing API), which
    /// keeps far more of the sites you revisit on hand. The setting is process-wide and the
    /// context argument is unused. Skipped if this version of WebKit doesn't have it.
    ///
    /// Two related switches were tried and deliberately left off: a spare web content process
    /// kept warm for the next tab, and a cache of the processes of sites just left. WebKit
    /// parks such processes suspended, and attaching a page to a suspended process blocks the
    /// main thread while it issues sandbox extensions to it: 0.3–0.6 s in about half the
    /// tries measured, and occasionally 5 s. A fresh process costs about 40 ms.
    private static let cacheModel: Void = {
        typealias SetCacheModel = @convention(c) (UnsafeRawPointer?, UInt32) -> Void
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "WKContextSetCacheModel") else { return }
        let primaryWebBrowser: UInt32 = 2
        unsafeBitCast(symbol, to: SetCacheModel.self)(nil, primaryWebBrowser)
    }()

    // MARK: Web views

    static func makeConfiguration(dataStore: WKWebsiteDataStore = DataStores.website) -> WKWebViewConfiguration {
        let settings = AppSettings.shared
        _ = cacheModel
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.applicationNameForUserAgent = userAgentApplicationName
        config.allowsAirPlayForMediaPlayback = true
        config.upgradeKnownHostsToHTTPS = settings.privacy.upgradeToHTTPS
        switch settings.privacy.autoplay {
        case .allow: config.mediaTypesRequiringUserActionForPlayback = []
        case .muted: config.mediaTypesRequiringUserActionForPlayback = .audio
        case .never: config.mediaTypesRequiringUserActionForPlayback = .all
        }
        config.preferences.isElementFullscreenEnabled = true
        PictureInPicture.enable(config.preferences)
        config.preferences.isFraudulentWebsiteWarningEnabled = settings.privacy.fraudWarnings
        config.preferences.minimumFontSize = settings.advanced.minimumFontSize
        if config.preferences.responds(to: NSSelectorFromString("setDeveloperExtrasEnabled:")) {
            config.preferences.setValue(settings.advanced.webInspector, forKey: "developerExtrasEnabled")
        }
        config.defaultWebpagePreferences.allowsContentJavaScript = settings.privacy.javaScript
        // Pages get the system's fonts, not ones the user installed themselves — as in Safari,
        // where it also stops sites fingerprinting you by your font list. It is here for
        // speed: giving each new web content process access to those font files blocks the
        // main thread (46 ms per new tab and per cross-site navigation with three Adobe fonts
        // installed, and seconds if the process had been parked). Private preference; skipped
        // if this version of WebKit doesn't have it.
        if config.preferences.responds(to: NSSelectorFromString("_setShouldAllowUserInstalledFonts:")) {
            config.preferences.setValue(false, forKey: "shouldAllowUserInstalledFonts")
        }
        config.webExtensionController = ExtensionManager.shared.controller
        ExtensionStoreBridge.install(into: config.userContentController)
        PictureInPicture.install(into: config.userContentController)
        #if DEBUG
        DebugHooks.installPageTracer(into: config.userContentController)
        #endif
        return config
    }

    static func makeWebView(configuration: WKWebViewConfiguration? = nil, dataStore: WKWebsiteDataStore = DataStores.website) -> TuffWebView {
        let config = configuration ?? makeConfiguration(dataStore: dataStore)
        let view = TuffWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        view.allowsMagnification = true
        view.autoresizingMask = [.width, .height]
        applyLiveSettings(to: view)
        return view
    }

    /// Settings a web view can take on without being rebuilt. Called for new web views and
    /// for every open one whenever these settings change.
    static func applyLiveSettings(to view: WKWebView) {
        let settings = AppSettings.shared
        view.customUserAgent = settings.advanced.resolvedUserAgent
        view.allowsBackForwardNavigationGestures = settings.advanced.swipeNavigation
        view.allowsLinkPreview = settings.advanced.linkPreviews
        view.isInspectable = settings.advanced.webInspector
        let preferences = view.configuration.preferences
        preferences.minimumFontSize = settings.advanced.minimumFontSize
        PictureInPicture.enable(preferences)
        preferences.isFraudulentWebsiteWarningEnabled = settings.privacy.fraudWarnings
        if preferences.responds(to: NSSelectorFromString("setDeveloperExtrasEnabled:")) {
            preferences.setValue(settings.advanced.webInspector, forKey: "developerExtrasEnabled")
        }
    }

    static func errorPage(for error: Error, url: URL?) -> String {
        let message = error.localizedDescription
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        let host = (url?.displayHost ?? "this page")
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Can’t open \(host)</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 15px -apple-system, system-ui; margin: 0; height: 100vh; display: grid; place-items: center;
                 background: Canvas; color: CanvasText; }
          main { max-width: 440px; padding: 32px; text-align: center; }
          h1 { font-size: 22px; font-weight: 650; margin: 0 0 10px; letter-spacing: -0.01em; }
          p { opacity: .62; line-height: 1.5; margin: 0 0 22px; }
          button { font: inherit; font-weight: 600; padding: 8px 18px; border-radius: 10px; border: 0;
                   background: color-mix(in srgb, CanvasText 10%, transparent); color: inherit; cursor: pointer; }
          button:hover { background: color-mix(in srgb, CanvasText 16%, transparent); }
        </style></head>
        <body><main>
          <h1>Can’t open \(host)</h1>
          <p>\(message)</p>
          <button onclick="location.reload()">Try Again</button>
        </main></body></html>
        """
    }
}
