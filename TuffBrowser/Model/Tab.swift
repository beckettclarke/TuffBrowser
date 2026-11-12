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

    /// Where a pinned / favourite tab returns to when it is "closed".
    @ObservationIgnored var homeURL: URL?
    @ObservationIgnored private(set) var webView: TuffWebView?
    @ObservationIgnored var lastActive = Date()
    @ObservationIgnored weak var browser: BrowserState?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var savedInteractionState: Any?
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

    var displayTitle: String {
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

    /// Continues a navigation in a new web view of the right kind (back/forward history does
    /// not carry over).
    func moveToNewWebView(loading request: URLRequest) {
        guard let url = request.url else { return }
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
        browser?.tabDidChange(self, properties: .URL)
    }

    /// After the tab moved to a profile with other cookies: a web page showing now is
    /// reloaded under that profile's store (back / forward history does not carry over).
    func moveToDataStore(_ store: WKWebsiteDataStore) {
        guard let view = webView, hostExtension == nil, view.configuration.websiteDataStore !== store else { return }
        savedInteractionState = nil
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
                #if DEBUG
                if DebugHooks.bench("nokvo") { return }
                #endif
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
                self?.canGoBack = view.canGoBack
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

    func load(_ url: URL) {
        if needsNewWebView(for: url) {
            moveToNewWebView(loading: URLRequest(url: url))
            return
        }
        self.url = url
        savedInteractionState = nil
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
    func goBack() { webView?.goBack() }
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
