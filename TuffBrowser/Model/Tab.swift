import AppKit
import Observation
import WebKit

/// One browser tab. The web view is created lazily and can be dropped again ("sleeping")
/// to give memory back while the tab stays in the sidebar.
@Observable
final class Tab: NSObject, Identifiable {
    let id: UUID
    var url: URL?
    var title: String = ""
    /// A name the user gave the tab in the sidebar; shown instead of the page's title.
    var customTitle: String?
    var favicon: NSImage?
    var isLoading = false
    var progress: Double = 0
    var canGoBack = false
    var canGoForward = false
    var isPlayingAudio = false
    var isMuted = false
    /// One of the page's videos is showing in a picture-in-picture window.
    var isInPictureInPicture = false
    /// False once an https page has loaded something over plain http (mixed content).
    var hasOnlySecureContent = true
    /// Mirrors `webView != nil` so views can react to wake / sleep.
    var isAwake = false
    /// A camera / microphone request waiting for an answer (shown as a card over the page).
    var permissionRequest: PermissionRequest?
    /// The link under the mouse, shown at the bottom of the page (see `LinkPreview`).
    var hoveredLink: URL?

    /// The page a pinned / favourite tab was pinned on: where it returns to when it is
    /// "closed", or when its icon is clicked after browsing away (see `isAwayFromHome`).
    var homeURL: URL? {
        didSet { if homeURL != oldValue { homeLandingURL = nil } }
    }
    /// Where loading `homeURL` last ended up, when the site redirected it (a sign-in hop, an
    /// added `/edit`…). Counts as being home, so a redirect alone doesn't look like browsing away.
    var homeLandingURL: URL?
    /// The navigation in flight was started by loading `homeURL`.
    @ObservationIgnored var loadingHome = false
    @ObservationIgnored private(set) var webView: TuffWebView?
    @ObservationIgnored var lastActive = Date()
    @ObservationIgnored weak var browser: BrowserState?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var savedInteractionState: Any?
    /// History of the web view the tab left when it crossed into or out of an extension page
    /// (see `moveToNewWebView`). WebKit can't carry history across that boundary, so Back at the
    /// start of the new view's history puts this back instead.
    @ObservationIgnored private var historyBeforeMove: (state: Any, url: URL?, skipCurrent: Bool)?
    @ObservationIgnored private var observingAudio = false
    @ObservationIgnored var pageZoom = CGFloat(AppSettings.shared.advanced.defaultZoom)
    /// Showing an extension page whose extension was not loaded yet when the tab woke up.
    @ObservationIgnored private(set) var awaitingExtension = false
    /// The extension whose configuration the web view was built from; nil for ordinary web
    /// content. WebKit confines such a web view to that extension's own pages, and keeps
    /// extension pages out of ordinary web views — see `needsNewWebView(for:)`.
    @ObservationIgnored private(set) weak var hostExtension: WKWebExtensionContext?
    /// The video in PiP went there when the tab was switched away from, so it comes back when
    /// the tab is shown again (one put there by hand stays out).
    @ObservationIgnored var enteredPictureInPictureAutomatically = false
    /// The frame holding the video in PiP, and the last subframe that played a video.
    @ObservationIgnored var pictureInPictureFrame: WKFrameInfo?
    @ObservationIgnored var mediaFrame: WKFrameInfo?

    private static let audioKeyPath = "_isPlayingAudio"

    /// `sessionState` is back / forward history from `sessionState` on an earlier tab (a saved
    /// session or a closed tab); it is put back when the tab wakes.
    init(id: UUID = UUID(), url: URL?, title: String = "", homeURL: URL? = nil, sessionState: Data? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.homeURL = homeURL
        self.savedInteractionState = sessionState
        super.init()
        if let url { favicon = FaviconStore.shared.cachedIcon(for: url) }
    }

    /// What the address pill shows: an extension's name for its own pages, else the URL's host.
    var isExtensionPage: Bool { ExtensionManager.isExtensionPage(url) }

    /// The page came over a connection that isn't encrypted: plain http (apart from this Mac's
    /// own servers), or an https page that pulled in http content.
    var isNotSecure: Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "http" { return !url.isLoopback }
        if scheme == "https" { return isAwake && !hasOnlySecureContent }
        return false
    }

    /// The tab's back / forward history (with scroll positions), in a form that can be saved
    /// and handed back to `init(sessionState:)`. Nil when there is nothing to keep.
    var sessionState: Data? {
        if let webView, !awaitingExtension, webView.backForwardList.currentItem != nil {
            return webView.interactionState as? Data
        }
        return savedInteractionState as? Data
    }

    /// What the sidebar, command bar and window title show: the user's name for the tab, if
    /// it has one, else the page's.
    var displayTitle: String { customTitle ?? pageTitle }

    /// A pinned tab that has been browsed away from the page it was pinned on.
    var isAwayFromHome: Bool {
        guard let homeURL, let url else { return false }
        if Self.samePage(url, homeURL) { return false }
        if let homeLandingURL, Self.samePage(url, homeLandingURL) { return false }
        return true
    }

    /// Two addresses for the same page: ignores the #fragment, a trailing slash, "www." and
    /// http vs https.
    static func samePage(_ a: URL, _ b: URL) -> Bool {
        func key(_ url: URL) -> String? {
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            parts.fragment = nil
            if parts.scheme?.lowercased() == "http" { parts.scheme = "https" }
            if let host = parts.host?.lowercased() { parts.host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
            while parts.path.count > 1, parts.path.hasSuffix("/") { parts.path.removeLast() }
            if parts.path == "/" { parts.path = "" }
            return parts.string
        }
        return key(a) ?? a.absoluteString == key(b) ?? b.absoluteString
    }

    /// Takes a pinned tab back to the page it was pinned on.
    func returnHome() {
        guard let homeURL else { return }
        load(homeURL)
    }

    /// The page's own title (falling back to its host); what extensions see.
    var pageTitle: String {
        if !title.isEmpty { return title }
        if let url { return url.displayHost }
        return "New Tab"
    }

    // MARK: Lifecycle

    /// Creates the web view if needed and starts loading. Pass a configuration only for
    /// `window.open` popups, where WebKit requires us to use the one it hands over.
    @discardableResult
    func wake(configuration: WKWebViewConfiguration? = nil, opener: Tab? = nil) -> TuffWebView {
        if let webView { return webView }
        // Extension pages (options, onboarding…) only load in a web view built from that
        // extension's own configuration.
        let owner = configuration == nil ? ExtensionManager.shared.context(forPage: url) : nil
        let extensionConfiguration = owner?.webViewConfiguration
        // Web pages use the cookies of the profile the tab belongs to.
        let store = browser?.dataStore(for: self) ?? DataStores.website
        let view = WebEngine.makeWebView(configuration: configuration ?? extensionConfiguration, dataStore: store)
        // A popup's configuration is derived from its opener's, restrictions included.
        hostExtension = configuration == nil ? owner : opener?.hostExtension
        view.tab = self
        view.navigationDelegate = self
        view.uiDelegate = self
        view.pageZoom = pageZoom
        webView = view
        observe(view)
        isAwake = true

        if configuration == nil {
            if ExtensionManager.isExtensionPage(url), extensionConfiguration == nil {
                // The extension that owns this page has not finished loading (typical right
                // after launch). Loading now would fail; `rebuildForExtension()` is called
                // once it is ready.
                awaitingExtension = true
            } else if let state = savedInteractionState {
                view.interactionState = state
                savedInteractionState = nil
                // History that WebKit couldn't read back (from an older version, say) leaves
                // the view empty; fall back to the page itself.
                if view.backForwardList.currentItem == nil, let url { view.load(URLRequest(url: url)) }
            } else if let url {
                loadingHome = homeURL.map { Self.samePage(url, $0) } ?? false
                view.load(URLRequest(url: url))
            }
        }
        return view
    }

    /// Recreates the web view with the owning extension's configuration, now that it exists.
    func rebuildForExtension() {
        guard isAwake else { return }
        // History waiting for the extension (restored at launch) is put back now.
        if !awaitingExtension { savedInteractionState = nil }
        awaitingExtension = false
        tearDownWebView()
        wake()
    }

    /// Whether `url` belongs in a different kind of web view than the current one.
    ///
    /// A web view built from an extension's configuration can only show that extension's
    /// pages: WebKit silently drops a navigation from one to a website, so a "Sign in" button
    /// on an extension's onboarding page that sends the tab to the vendor's site does nothing.
    /// The reverse holds too. Crossing that boundary takes a fresh web view.
    func needsNewWebView(for url: URL) -> Bool {
        guard webView != nil else { return false }
        if ExtensionManager.isExtensionPage(url) {
            // Not loaded (nil) is left to fail where it is, as before.
            guard let owner = ExtensionManager.shared.context(forPage: url) else { return false }
            return owner !== hostExtension
        }
        guard hostExtension != nil, let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "file"].contains(scheme)
    }

    /// Continues a navigation in a new web view of the right kind. The old view's history can't
    /// come along, so it is kept aside for Back (`goBack`). `byExtension`: an extension sent the
    /// tab here (tabs.update).
    func moveToNewWebView(loading request: URLRequest, byExtension: Bool = false) {
        guard let url = request.url else { return }
        if let old = webView, !awaitingExtension, old.backForwardList.currentItem != nil {
            // An extension that sends a loading tab elsewhere is replacing that load. Stop it
            // first: saved history includes a load still in progress, and putting it back would
            // start the load again (and uBlock Origin would block it again).
            let wasLoading = old.isLoading
            let committed = old.url == old.backForwardList.currentItem?.url
            if byExtension, wasLoading { old.stopLoading() }
            // Leaving a one-page extension view (uBlock Origin's "page blocked" screen after
            // "Proceed") keeps what was there before it, so Back skips the screen.
            let throwaway = hostExtension != nil && !old.canGoBack && historyBeforeMove != nil
            if !throwaway, let state = old.interactionState {
                // If the replaced load had already reached the history (WebKit can't block it, so
                // uBlock Origin's "page blocked" often comes after the page committed), Back skips
                // it, as if it had never happened.
                let superseded = byExtension && wasLoading && old.canGoBack && committed
                // The history's current page, not `old.url`: that can be an address still
                // being navigated to (the page that got blocked, say).
                historyBeforeMove = (state, old.backForwardList.currentItem?.url ?? self.url, superseded)
            }
        }
        self.url = url
        title = ""
        awaitingExtension = false
        savedInteractionState = nil
        tearDownWebView()
        let view = wake()
        // `wake` starts a plain GET; replace it when the request carries more than that.
        if request.httpMethod.map({ $0.uppercased() != "GET" }) ?? false || request.httpBody != nil {
            view.load(request)
        }
        canGoBack = view.canGoBack || historyBeforeMove != nil
        browser?.tabDidChange(self, properties: .URL)
    }

    /// After the tab moved to a profile with other cookies: a web page showing now is
    /// reloaded under that profile's store (back / forward history does not carry over).
    func moveToDataStore(_ store: WKWebsiteDataStore) {
        guard let view = webView, hostExtension == nil, view.configuration.websiteDataStore !== store else { return }
        savedInteractionState = nil
        historyBeforeMove = nil
        tearDownWebView()
        wake()
    }

    /// Drops the web view but keeps the tab. `resetToHome` is used when "closing" a pinned tab.
    func sleep(resetToHome: Bool = false) {
        guard let view = webView else {
            if resetToHome, let homeURL { url = homeURL }
            return
        }
        if resetToHome {
            savedInteractionState = nil
            historyBeforeMove = nil
            if let homeURL {
                url = homeURL
                title = ""
            }
        } else {
            savedInteractionState = view.interactionState
        }
        tearDownWebView()
    }

    /// Called when the tab is closed for good.
    func tearDown() {
        savedInteractionState = nil
        historyBeforeMove = nil
        tearDownWebView()
    }

    /// Answers the pending camera / microphone request.
    func resolvePermission(granted: Bool?, remember: Bool = false) {
        guard let request = permissionRequest else { return }
        permissionRequest = nil
        request.respond(granted, remember)
    }

    private func tearDownWebView() {
        resolvePermission(granted: nil)
        guard let view = webView else { return }
        observations.removeAll()
        if observingAudio {
            view.removeObserver(self, forKeyPath: Self.audioKeyPath)
            observingAudio = false
        }
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.removeFromSuperview()
        webView = nil
        isAwake = false
        isLoading = false
        progress = 0
        isPlayingAudio = false
        isInPictureInPicture = false
        hasOnlySecureContent = true
        enteredPictureInPictureAutomatically = false
        pictureInPictureFrame = nil
        mediaFrame = nil
        hoveredLink = nil
        canGoBack = false
        canGoForward = false
    }

    private func observe(_ view: TuffWebView) {
        observations = [
            view.observe(\.title, options: [.new]) { [weak self] view, _ in
                guard let self else { return }
                let t = view.title ?? ""
                if !t.isEmpty, t != self.title {
                    self.title = t
                    self.browser?.tabDidChange(self, properties: .title)
                }
            },
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                guard let self, let u = view.url else { return }
                if u != self.url {
                    self.url = u
                    self.browser?.tabDidChange(self, properties: .URL)
                }
            },
            view.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                self?.progress = view.estimatedProgress
            },
            view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                guard let self else { return }
                if self.isLoading != view.isLoading {
                    self.isLoading = view.isLoading
                    self.browser?.tabDidChange(self, properties: .loading)
                }
            },
            view.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                guard let self else { return }
                self.canGoBack = view.canGoBack || self.historyBeforeMove != nil
            },
            view.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                self?.canGoForward = view.canGoForward
            },
            view.observe(\.hasOnlySecureContent, options: [.initial, .new]) { [weak self] view, _ in
                self?.hasOnlySecureContent = view.hasOnlySecureContent
            },
        ]
        if view.responds(to: NSSelectorFromString(Self.audioKeyPath)) {
            view.addObserver(self, forKeyPath: Self.audioKeyPath, options: [.new], context: nil)
            observingAudio = true
        }
    }

    override func observeValue(
        forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == Self.audioKeyPath else { return }
        let playing = (change?[.newKey] as? Bool) ?? false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPlayingAudio != playing else { return }
            self.isPlayingAudio = playing
            self.browser?.tabDidChange(self, properties: .playingAudio)
        }
    }

    // MARK: Navigation

    func load(_ url: URL, byExtension: Bool = false) {
        if needsNewWebView(for: url) {
            moveToNewWebView(loading: URLRequest(url: url), byExtension: byExtension)
            return
        }
        self.url = url
        savedInteractionState = nil
        loadingHome = homeURL.map { Self.samePage(url, $0) } ?? false
        if let webView {
            webView.load(URLRequest(url: url))
        } else {
            wake()
        }
    }

    func reload(fromOrigin: Bool = false) {
        guard let webView else { wake(); return }
        if webView.url == nil, let url {
            webView.load(URLRequest(url: url))
        } else if fromOrigin {
            webView.reloadFromOrigin()
        } else {
            webView.reload()
        }
    }

    func stop() { webView?.stopLoading() }
    func goBack() {
        if let webView, webView.canGoBack {
            webView.goBack()
            return
        }
        // At the start of this web view's history: back to the one the tab came from.
        guard let previous = historyBeforeMove else { return }
        historyBeforeMove = nil
        if let url = previous.url { self.url = url }
        title = ""
        awaitingExtension = false
        savedInteractionState = previous.state
        tearDownWebView()
        let view = wake()
        if previous.skipCurrent, view.canGoBack { view.goBack() }
        browser?.tabDidChange(self, properties: .URL)
    }

    func goForward() { webView?.goForward() }

    func setZoom(_ zoom: CGFloat) {
        pageZoom = max(0.3, min(4, zoom))
        webView?.pageZoom = pageZoom
        browser?.tabDidChange(self, properties: .zoomFactor)
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        guard let webView else { return }
        // WebKit has no public per-page mute; `_setPageMuted:` takes a bitmask (1 = audio).
        let selector = NSSelectorFromString("_setPageMuted:")
        guard webView.responds(to: selector), let imp = webView.method(for: selector) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(imp, to: Fn.self)(webView, selector, muted ? 1 : 0)
        browser?.tabDidChange(self, properties: .muted)
    }

    func showInspector() {
        guard let webView else { return }
        let getter = NSSelectorFromString("_inspector")
        guard webView.responds(to: getter),
              let inspector = webView.perform(getter)?.takeUnretainedValue() as? NSObject else { return }
        let show = NSSelectorFromString("show")
        if inspector.responds(to: show) { inspector.perform(show) }
    }
}
