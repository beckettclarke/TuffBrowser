import AppKit
import WebKit

/// The web view used for every tab.
final class TuffWebView: WKWebView {
    weak var tab: Tab?

    /// While Tuff's PDF viewer covers the page, the keyboard belongs to it, not to the empty
    /// placeholder page underneath (WebKit takes focus on its own when a page comes back from
    /// the back / forward cache).
    override var acceptsFirstResponder: Bool {
        if tab?.pdf?.isReady == true { return false }
        return super.acceptsFirstResponder
    }

    // A click in the other side of a split makes it the selected tab (see `pageWasClicked`).
    override func mouseDown(with event: NSEvent) {
        if let tab { tab.browser?.pageWasClicked(tab) }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if let tab { tab.browser?.pageWasClicked(tab) }
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        if let tab { tab.browser?.pageWasClicked(tab) }
        super.otherMouseDown(with: event)
    }

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
        // "Download Image" / "Download Linked File" save straight to the downloads folder; each
        // gets a "Save … As…" beside it that asks for a name and place.
        for (identifier, title) in [
            ("WKMenuItemIdentifierDownloadImage", "Save Image As…"),
            ("WKMenuItemIdentifierDownloadLinkedFile", "Save Linked File As…"),
        ] {
            guard let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == identifier }) else { continue }
            let saveAs = NSMenuItem(title: title, action: #selector(saveContextDownloadAs(_:)), keyEquivalent: "")
            saveAs.target = self
            saveAs.representedObject = menu.items[index]
            menu.insertItem(saveAs, at: index + 1)
        }
        if let tab {
            let extra = ExtensionManager.shared.contextMenuItems(for: tab)
            if !extra.isEmpty {
                menu.addItem(.separator())
                extra.forEach { menu.addItem($0) }
            }
        }
        #if DEBUG
        DebugHooks.pickFromContextMenu(menu)
        #endif
    }

    /// Runs WebKit's own Download Image / Download Linked File (which handles blob: and data:
    /// images, and the page's cookies), marking the download it creates as one to ask about
    /// (`Tab.webView(_:contextMenuDidCreateDownload:)`).
    @objc private func saveContextDownloadAs(_ sender: NSMenuItem) {
        guard let original = sender.representedObject as? NSMenuItem, let action = original.action else { return }
        tab?.contextSaveAsRequested = Date()
        NSApp.sendAction(action, to: original.target, from: original)
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
        SiteSettings.applyCookiePolicy(to: [dataStore])
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
        config.preferences.javaScriptCanOpenWindowsAutomatically = !settings.privacy.blockPopups
        if config.preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) {
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
        // Fonts and a proxy set by extensions (chrome.fontSettings, chrome.proxy).
        let extensionSettings = ExtensionSettings.shared
        if extensionSettings.hasFontChoices { extensionSettings.applyFonts(to: config.preferences) }
        if extensionSettings.hasProxy { extensionSettings.applyProxy(to: [dataStore]) }
        config.webExtensionController = ExtensionManager.shared.controller
        ExtensionStoreBridge.install(into: config.userContentController)
        PictureInPicture.install(into: config.userContentController)
        LiveFavicon.install(into: config.userContentController)
        PopupBlocker.install(into: config.userContentController)
        WebNotifications.install(into: config.userContentController)
        EmbeddedSignIn.install(into: config.userContentController)
        // Scripts extensions register at run time; Incognito windows don't run extensions.
        if dataStore.isPersistent { ExtensionContentScripts.shared.attach(config.userContentController) }
        ContentBlocker.shared.attach(config.userContentController)
        InternalPageHandler.shared.install(into: config)
        config.userContentController.add(CertificateErrorHandler.shared, contentWorld: .page, name: CertificateErrorHandler.name)
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
        // WebKit's own pop-up blocker: off by default on macOS, where any script could open
        // tabs (and take the window over) without a click. With it on, `window.open` still
        // works from a click or key handler, and target=_blank links are unaffected.
        preferences.javaScriptCanOpenWindowsAutomatically = !settings.privacy.blockPopups
        SiteSettings.applyCookiePolicy(to: [view.configuration.websiteDataStore])
        preferences.minimumFontSize = settings.advanced.minimumFontSize
        PictureInPicture.enable(preferences)
        preferences.isFraudulentWebsiteWarningEnabled = settings.privacy.fraudWarnings
        if preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) {
            preferences.setValue(settings.advanced.webInspector, forKey: "developerExtrasEnabled")
        }
    }

    static func errorPage(for error: Error, url: URL?) -> String {
        let ns = error as NSError
        let host = url?.displayHost ?? "this page"
        let (icon, title, message) = describe(ns, host: host)
        let code = ns.domain == NSURLErrorDomain ? "NSURLError \(ns.code)" : "\(ns.domain) \(ns.code)"
        return statusPage(
            title: title,
            heading: title,
            message: message,
            detail: [url?.absoluteString, code].compactMap { $0 }.joined(separator: "  ·  "),
            icon: icon,
            tone: .neutral,
            buttons: [
                .init(label: "Try Again", primary: true, key: "↩", action: "location.reload()"),
                .init(label: "Go Back", primary: false, key: nil, action: "history.back()", needsHistory: true),
            ]
        )
    }

    /// A friendlier title, message and icon for the errors people actually hit.
    private static func describe(_ error: NSError, host: String) -> (StatusIcon, String, String) {
        guard error.domain == NSURLErrorDomain else {
            return (.warning, "Can’t open \(host)", error.localizedDescription)
        }
        switch URLError.Code(rawValue: error.code) {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return (.offline, "You’re offline", "Tuff couldn’t reach \(host) because this Mac isn’t connected to the internet. Check Wi-Fi or your network cable, then try again.")
        case .cannotFindHost, .dnsLookupFailed:
            return (.notFound, "Can’t find \(host)", "No server answers to that address. Check the spelling, or the site may be down or no longer exist.")
        case .timedOut:
            return (.clock, "\(host) took too long to respond", "The site may be busy or down. Try again in a moment.")
        case .cannotConnectToHost:
            return (.unplugged, "\(host) refused to connect", "The server is there but isn’t accepting connections right now.")
        case .fileDoesNotExist, .noPermissionsToReadFile:
            return (.document, "This page doesn’t exist", "There’s nothing at this address.")
        case .badURL, .unsupportedURL:
            return (.warning, "Can’t open this address", "Tuff doesn’t know how to open it. Check that it’s typed correctly.")
        default:
            return (.warning, "Can’t open \(host)", error.localizedDescription)
        }
    }

    enum StatusIcon {
        case offline, notFound, clock, unplugged, document, warning, shield

        /// 24×24 stroke paths, drawn in the page's icon tile.
        var path: String {
            switch self {
            case .offline: return #"<path d="M2 8.8a15 15 0 0 1 20 0M5 12.6a10 10 0 0 1 9.5-2.4M8.5 16.1a5 5 0 0 1 4.6-1.3"/><path d="M12 20h.01"/><path d="m3 3 18 18"/>"#
            case .notFound: return #"<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/><path d="M9.2 9.2a2 2 0 1 1 2.6 2.1c-.5.2-.8.6-.8 1.1v.4"/><path d="M11 15h.01"/>"#
            case .clock: return #"<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>"#
            case .unplugged: return #"<path d="m19 5 3-3M2 22l3-3"/><path d="M6.3 20.3a2.4 2.4 0 0 0 3.4 0L12 18l-6-6-2.3 2.3a2.4 2.4 0 0 0 0 3.4z"/><path d="M7.5 13.5 10 11M10.5 16.5 13 14"/><path d="m12 6 6 6 2.3-2.3a2.4 2.4 0 0 0 0-3.4l-2.6-2.6a2.4 2.4 0 0 0-3.4 0z"/>"#
            case .document: return #"<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/><path d="m9.5 12.5 5 5M14.5 12.5l-5 5"/>"#
            case .warning: return #"<path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/><path d="M12 9v4M12 17h.01"/>"#
            case .shield: return #"<path d="M12 3 4 6v6c0 4.5 3.4 8.2 8 9 4.6-.8 8-4.5 8-9V6z"/><path d="M12 8v4M12 16h.01"/>"#
            }
        }
    }

    enum StatusTone { case neutral, warning }

    struct StatusButton {
        var label: String
        var primary: Bool
        /// A key chip shown inside the button; ↩ also presses it from the keyboard.
        var key: String?
        /// JavaScript run on click.
        var action: String
        /// Hidden when there's no page to go back to.
        var needsHistory = false
    }

    /// The shared look of Tuff's error pages: an icon tile, a heading, a message, an optional
    /// small detail line (address, error code) and a row of buttons. Takes the accent of the
    /// space in front, like `tuff://history`.
    static func statusPage(
        title: String, heading: String, message: String, detail: String?,
        icon: StatusIcon, tone: StatusTone, buttons: [StatusButton], script: String = ""
    ) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let accent = BrowserState.active.baseTint.derivedAccent.hexString
        let iconColor = tone == .warning ? "var(--warn)" : "var(--accent)"
        let buttonHTML = buttons.map { b in
            let classes = [b.primary ? "primary" : "quiet", b.needsHistory ? "needs-history" : nil].compactMap { $0 }.joined(separator: " ")
            let key = b.key.map { "<kbd>\(escape($0))</kbd>" } ?? ""
            let enter = b.key == "↩" ? " data-enter" : ""
            return "<button class=\"\(classes)\"\(enter) onclick=\"\(escape(b.action))\">\(escape(b.label))\(key)</button>"
        }.joined(separator: "\n      ")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
          :root {
            color-scheme: light dark;
            --accent: \(accent); --warn: #d9822b;
            --fg: #1d1d1f; --dim: rgba(0,0,0,.56); --faint: rgba(0,0,0,.36);
            --bg: #f6f5f3; --field: rgba(0,0,0,.055); --hover: rgba(0,0,0,.08); --line: rgba(0,0,0,.08);
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --warn: #f0a04b;
              --fg: #f2f2f4; --dim: rgba(255,255,255,.58); --faint: rgba(255,255,255,.34);
              --bg: #1b1b1e; --field: rgba(255,255,255,.07); --hover: rgba(255,255,255,.11); --line: rgba(255,255,255,.08);
            }
          }
          * { box-sizing: border-box; }
          html, body { height: 100%; }
          body { margin: 0; display: grid; place-items: center; padding: 24px;
                 font: 14px/1.5 -apple-system, system-ui; background: var(--bg); color: var(--fg);
                 -webkit-font-smoothing: antialiased; }
          main { width: 100%; max-width: 460px; text-align: center; animation: in .35s cubic-bezier(.2,.8,.2,1) both; }
          @keyframes in { from { opacity: 0; transform: translateY(6px); } }
          @media (prefers-reduced-motion: reduce) { main { animation: none; } }
          .tile { width: 64px; height: 64px; margin: 0 auto 22px; border-radius: 18px; display: grid; place-items: center;
                  color: \(iconColor); background: color-mix(in srgb, \(iconColor) 14%, transparent);
                  box-shadow: inset 0 0 0 1px color-mix(in srgb, \(iconColor) 22%, transparent); }
          .tile svg { width: 30px; height: 30px; }
          h1 { font-size: 21px; font-weight: 650; letter-spacing: -0.015em; line-height: 1.25; margin: 0 0 8px;
               overflow-wrap: anywhere; }
          p { color: var(--dim); margin: 0 auto; max-width: 400px; }
          .detail { margin: 14px auto 0; max-width: 100%; color: var(--faint); font: 11.5px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace;
                    white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
          .buttons { display: flex; gap: 8px; justify-content: center; flex-wrap: wrap; margin-top: 26px; }
          button { font: 600 13px -apple-system, system-ui; height: 32px; padding: 0 14px; border-radius: 9px; border: 0;
                   display: inline-flex; align-items: center; gap: 8px; cursor: pointer; color: var(--fg); background: var(--field);
                   transition: background .12s, transform .12s, filter .12s; }
          button:hover { background: var(--hover); }
          button:active { transform: scale(.97); }
          button.primary { background: var(--accent); color: #fff; }
          button.primary:hover { filter: brightness(1.08); background: var(--accent); }
          button.quiet { background: none; color: var(--dim); }
          button.quiet:hover { background: var(--field); color: var(--fg); }
          button:focus-visible { outline: 2px solid color-mix(in srgb, var(--accent) 70%, transparent); outline-offset: 2px; }
          kbd { font: 600 11px -apple-system, system-ui; padding: 1px 5px; border-radius: 5px; background: rgba(255,255,255,.22); }
          button:not(.primary) kbd { background: var(--field); }
          body.no-history .needs-history { display: none; }
        </style></head>
        <body><main>
          <div class="tile"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round">\(icon.path)</svg></div>
          <h1>\(escape(heading))</h1>
          <p>\(escape(message))</p>
          \(detail.map { "<div class=\"detail\" title=\"\(escape($0))\">\(escape($0))</div>" } ?? "")
          <div class="buttons">
            \(buttonHTML)
          </div>
        </main>
        <script>
          if (history.length <= 1) document.body.classList.add('no-history');
          addEventListener('keydown', e => {
            if (e.key === 'Enter' && !e.metaKey && !e.ctrlKey && !e.altKey && document.activeElement === document.body) {
              const b = document.querySelector('button[data-enter]'); if (b) { e.preventDefault(); b.click(); }
            }
          });
          \(script)
        </script>
        </body></html>
        """
    }
}
