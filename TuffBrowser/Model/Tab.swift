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
    /// The site `favicon` came from, so moving within a site can keep it on show (`didCommit`).
    @ObservationIgnored var faviconHost: String?
    /// Counts icon lookups, so one that finishes late can't replace a newer icon (a page that
    /// redraws its icon, `LiveFavicon`) or land on the next page.
    @ObservationIgnored var faviconRequest = 0
    var isLoading = false
    var progress: Double = 0
    var canGoBack = false
    var canGoForward = false
    var isPlayingAudio = false
    var isMuted = false
    /// One of the page's videos is showing in a picture-in-picture window.
    var isInPictureInPicture = false
    /// The page is using the camera / microphone (shown on the tab, with a click to stop).
    /// Muted capture (`.muted`) still counts: the page holds the device.
    var cameraInUse = false
    var microphoneInUse = false
    /// Pop-ups the page tried to open that the pop-up blocker stopped (see `PopupBlocker`).
    /// Cleared when the page changes.
    var blockedPopups: [URL] = []
    /// The page is full screen (a video, the Fullscreen API).
    var isFullScreen = false
    /// False once an https page has loaded something over plain http (mixed content).
    var hasOnlySecureContent = true
    /// Mirrors `webView != nil` so views can react to wake / sleep.
    var isAwake = false
    /// A camera, microphone, location or notification request waiting for an answer (shown as a card over the page).
    var permissionRequest: PermissionRequest?
    /// The link under the mouse, shown at the bottom of the page (see `LinkPreview`).
    var hoveredLink: URL?
    /// The colour across the top of the page (its `theme-color`, or what its header is painted
    /// with). The Seamless background fills the window with it. Only kept up while Seamless is on.
    var headerColor: NSColor?
    /// Set while the tab shows a PDF: Tuff's own viewer (`PDFViewer`) covers the page.
    var pdf: PDFViewer?
    /// Set while the tab is in reader mode: the article, shown over the page (see `Reader`).
    var reader: Reader?

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
    /// The tab that opened this one (a link opened in a new tab, `window.open`, or
    /// `tabs.create({openerTabId})`). Surfaced to extensions as `openerTabId`. Weak, so it goes
    /// nil on its own if the opener is closed.
    @ObservationIgnored weak var openerTab: Tab?
    /// The address last reported to extensions for a same-document navigation (or the page's
    /// committed address), so WebKit's duplicate reports aren't sent twice.
    @ObservationIgnored var lastSameDocumentURL: URL?
    /// The URL of a navigation that has started but not committed yet; what extensions read as
    /// `pendingUrl` on a tab. Cleared when the load commits, fails, or the web view goes away.
    @ObservationIgnored var pendingURL: URL?
    /// Downloaded PDFs this tab has shown, by address (`PDFViewer.key`), so Back, Forward and
    /// waking reopen them without fetching again. Deleted when the tab closes.
    @ObservationIgnored var pdfFiles: [String: URL] = [:]
    /// The viewer is up but its placeholder page hasn't committed yet (still downloading).
    @ObservationIgnored var pdfAwaitingCommit = false
    /// The viewer stands in for the history entry the web view is on without a page committed
    /// for it (a restored session, or Back / Forward to a PDF; see `commitPDFPage`).
    @ObservationIgnored var pdfWithoutPage = false
    /// The viewer, not the web view, says what the address is (still downloading, or
    /// `pdfWithoutPage`).
    var pdfHoldsAddress: Bool { pdfAwaitingCommit || pdfWithoutPage }
    /// The PDF whose placeholder page is being committed (`commitPDFPage`).
    @ObservationIgnored var committingPDF: String?
    /// A real response arrived for the main frame since the last commit (so a commit isn't a
    /// page coming back from the back / forward cache).
    @ObservationIgnored var mainResponseSeen = false
    /// How the last main-frame navigation started (a Reload fetches a PDF again).
    @ObservationIgnored var lastMainNavigationType: WKNavigationType = .other
    /// Page dialogs (`alert`, sign-in…) asked for while the tab was in the background, waiting
    /// to be shown when it comes to the front. Resumed with false if the page goes away first.
    @ObservationIgnored var dialogWaiters: [CheckedContinuation<Bool, Never>] = []
    /// `alert` / `confirm` / `prompt` cards the current page has shown, and whether the user
    /// asked for no more of them. Both reset when the page changes.
    @ObservationIgnored var pageDialogCount = 0
    @ObservationIgnored var pageDialogsBlocked = false
    /// The content process crashed while the tab was in the background; it reloads when shown.
    @ObservationIgnored var crashedWhileHidden = false
    /// When the content process last crashed, to stop reloading a page that keeps crashing.
    @ObservationIgnored var recentCrashes: [Date] = []
    /// A close waiting on the page's `beforeunload` (see `requestClose`), and whether its
    /// "Leave this page?" card is up.
    @ObservationIgnored var pendingClose: (() -> Void)?
    /// Receives find-in-page results (`Tab.find`); WebKit holds its find delegate weakly.
    @ObservationIgnored var findReporter: FindReporter?
    /// The certificate problem the tab's error page is about (see `CertificateErrorHandler`).
    @ObservationIgnored var certificateFailure: CertificateFailure?
    @ObservationIgnored var beforeUnloadShowing = false
    /// The address an error page of Tuff's is being put up for (`showErrorPage`), until it commits.
    @ObservationIgnored var errorPageURL: URL?
    /// The page on show is one of Tuff's error pages (can't connect, bad certificate, crashed):
    /// it stays out of History, and its title doesn't replace the real page's there.
    @ObservationIgnored var showingErrorPage = false
    /// A `tuff://` page Tuff itself is opening in this tab (see `start(_:in:)`).
    @ObservationIgnored var internalPageLoad: URL?
    /// The "Open in another app?" card is up (see `openInOtherApp`).
    @ObservationIgnored var externalAppPromptShowing = false
    /// "Save Image As…" / "Save Linked File As…" was just picked from the page's context menu:
    /// the download WebKit creates next asks where to save.
    @ObservationIgnored var contextSaveAsRequested: Date?

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
        if let url {
            favicon = InternalPage.icon(for: url) ?? FaviconStore.shared.cachedIcon(for: url)
            faviconHost = url.host(percentEncoded: false)?.lowercased()
        }
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
        pageZoom = CGFloat(SiteZoom.shared.zoom(for: url, incognito: browser?.isPrivate ?? false))
        view.pageZoom = pageZoom
        if isMuted { Self.applyMute(true, to: view) }
        webView = view
        observe(view)
        isAwake = true

        if configuration == nil {
            if ExtensionManager.isExtensionPage(url), extensionConfiguration == nil {
                // The extension that owns this page has not finished loading (typical right
                // after launch). Loading now would fail; `rebuildForExtension()` is called
                // once it is ready.
                awaitingExtension = true
            } else if let state = savedInteractionState, !InternalPage.isInternal(url) {
                view.interactionState = state
                savedInteractionState = nil
                // History that WebKit couldn't read back (from an older version, say) leaves
                // the view empty; fall back to the page itself.
                if view.backForwardList.currentItem == nil, let url { start(URLRequest(url: url), in: view) }
            } else if let url {
                // Tuff's own pages (tuff://history) are built fresh each time rather than put
                // back from saved history: a restored copy could come back blank.
                savedInteractionState = nil
                loadingHome = homeURL.map { Self.samePage(url, $0) } ?? false
                start(URLRequest(url: url), in: view)
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
        return ["http", "https", "file", InternalPage.scheme].contains(scheme)
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
        pendingURL = url
        title = ""
        awaitingExtension = false
        savedInteractionState = nil
        tearDownWebView()
        let view = wake()
        // `wake` starts a plain GET; replace it when the request carries more than that.
        if request.httpMethod.map({ $0.uppercased() != "GET" }) ?? false || request.httpBody != nil {
            start(request, in: view)
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
        let oldURL = url
        defer {
            // Extensions (tabs.onUpdated) see a pinned tab go back to its page.
            if resetToHome, url != oldURL { browser?.tabDidChange(self, properties: [.URL, .title]) }
        }
        guard let view = webView else {
            if resetToHome, let homeURL {
                if url != homeURL { title = "" }
                url = homeURL
                savedInteractionState = nil
                historyBeforeMove = nil
            }
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
        PDFFiles.remove(pdfFiles.values)
        pdfFiles = [:]
    }

    /// Doing something that unloading or closing it in the background would cut short:
    /// playing sound, loading, in picture in picture, using the camera or microphone (a call
    /// with its sound off), or waiting on the user (a permission card, a page dialog, "Leave
    /// this page?").
    var isBusy: Bool {
        if isPlayingAudio || isLoading || isInPictureInPicture || permissionRequest != nil
            || !dialogWaiters.isEmpty || beforeUnloadShowing || pendingClose != nil { return true }
        if let webView, webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none { return true }
        return false
    }

    /// Whether the page has text typed into a field that hasn't been sent: a field whose value
    /// differs from what the page put there. Read in a world of Tuff's own, so the page can't
    /// change the answer. A page that never answers (hung) never calls back, so it isn't
    /// unloaded behind the user's back either.
    func checkUnsavedInput(_ completion: @escaping (Bool) -> Void) {
        guard let webView, !awaitingExtension else { completion(false); return }
        webView.evaluateJavaScript(Self.unsavedInputScript, in: nil, in: .defaultClient) { result in
            switch result {
            case .success(let value): completion((value as? Bool) ?? false)
            case .failure: completion(false)
            }
        }
    }

    private static let unsavedInputScript = """
    (() => {
      const skip = new Set(['hidden', 'submit', 'button', 'reset', 'image', 'file', 'checkbox', 'radio', 'range', 'color']);
      for (const el of document.querySelectorAll('textarea, input')) {
        if (skip.has((el.type || '').toLowerCase()) || el.disabled || el.readOnly) continue;
        if (el.value && el.value !== el.defaultValue) return true;
      }
      return false;
    })()
    """

    /// Answers the pending permission request.
    func resolvePermission(granted: Bool?, remember: Bool = false) {
        guard let request = permissionRequest else { return }
        permissionRequest = nil
        request.respond(granted, remember)
    }

    /// Asks the page whether it can close, then runs `close`. WebKit runs the page's
    /// `beforeunload` handlers (`_tryClose`); a page with unsaved changes shows the "Leave this
    /// page?" card, and `close` runs only if the user leaves. A page that doesn't answer quickly
    /// (a busy or hung process) is closed anyway.
    func requestClose(then close: @escaping () -> Void) {
        guard pendingClose == nil else { return }
        let selector = NSSelectorFromString("_tryClose")
        guard let webView, !awaitingExtension, webView.responds(to: selector),
              let imp = webView.method(for: selector) else { close(); return }
        pendingClose = close
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        if unsafeBitCast(imp, to: Fn.self)(webView, selector) {
            finishClose()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.pendingClose != nil, !self.beforeUnloadShowing else { return }
            self.finishClose()
        }
    }

    /// The page agreed to close (`webViewDidClose`), or didn't answer in time.
    func finishClose() {
        let close = pendingClose
        pendingClose = nil
        close?()
    }

    /// Called whenever the tab comes to the front: shows the dialogs its page asked for while it
    /// was in the background, and reloads a page whose process crashed meanwhile.
    func didBecomeVisible() {
        if crashedWhileHidden {
            crashedWhileHidden = false
            webView?.reload()
        }
        let waiters = dialogWaiters
        dialogWaiters.removeAll()
        waiters.forEach { $0.resume(returning: true) }
    }

    private func tearDownWebView() {
        resolvePermission(granted: nil)
        // Dialogs still waiting for the tab to be shown are answered "Cancel".
        let waiters = dialogWaiters
        dialogWaiters.removeAll()
        waiters.forEach { $0.resume(returning: false) }
        pageDialogCount = 0
        pageDialogsBlocked = false
        crashedWhileHidden = false
        closePDF()
        closeReader(focus: false)
        if isFullScreen { FullScreenBanner.shared.hide(for: self) }
        cameraInUse = false
        microphoneInUse = false
        isFullScreen = false
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
        pendingURL = nil
        headerColor = nil
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
                    if let u = self.url, let scheme = u.scheme, scheme == "http" || scheme == "https" {
                        // Incognito pages stay out of History, and extensions never hear of them.
                        if self.browser?.isPrivate == false, !self.showingErrorPage {
                            HistoryStore.shared.updateTitle(url: u, title: t)
                            ExtensionEventPush.shared.emit("history.onTitleChanged", args: [["url": u.absoluteString, "title": t]])
                        }
                    }
                }
            },
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                guard let self, let u = view.url else { return }
                // A PDF still downloading keeps its own address showing; the web view is
                // back on the page the link was on until the PDF's page commits.
                if self.pdfHoldsAddress { return }
                if u != self.url {
                    self.url = u
                    self.browser?.tabDidChange(self, properties: .URL)
                    // A single-page app changes its address without finishing a load.
                    if !view.isLoading { self.refreshHeaderColor(after: 0.4) }
                }
            },
            view.observe(\.themeColor, options: [.new]) { [weak self] _, _ in
                self?.refreshHeaderColor()
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
            view.observe(\.cameraCaptureState, options: [.initial, .new]) { [weak self] view, _ in
                let inUse = view.cameraCaptureState != .none
                DispatchQueue.main.async { if self?.cameraInUse != inUse { self?.cameraInUse = inUse } }
            },
            view.observe(\.microphoneCaptureState, options: [.initial, .new]) { [weak self] view, _ in
                let inUse = view.microphoneCaptureState != .none
                DispatchQueue.main.async { if self?.microphoneInUse != inUse { self?.microphoneInUse = inUse } }
            },
            view.observe(\.fullscreenState, options: [.new]) { [weak self] view, _ in
                let state = view.fullscreenState
                DispatchQueue.main.async { self?.fullscreenStateChanged(state, in: view) }
            },
        ]
        if view.responds(to: NSSelectorFromString(Self.audioKeyPath)) {
            view.addObserver(self, forKeyPath: Self.audioKeyPath, options: [.new], context: nil)
            observingAudio = true
        }
    }

    /// Shows "{site} is full screen" once the page has the screen, and takes it down when the
    /// page leaves (or the tab goes away while full screen).
    private func fullscreenStateChanged(_ state: WKWebView.FullscreenState, in view: WKWebView) {
        let full = state == .inFullscreen || state == .enteringFullscreen
        if isFullScreen != full { isFullScreen = full }
        switch state {
        case .inFullscreen:
            let site = (url ?? view.url).map { $0.displayHost } ?? "This page"
            FullScreenBanner.shared.show(for: self, site: site.isEmpty ? "This page" : site, on: view.window?.screen)
        case .exitingFullscreen, .notInFullscreen:
            FullScreenBanner.shared.hide(for: self)
        default:
            break
        }
    }

    /// What VoiceOver reads for the tab's row or tile: its name and anything going on in it.
    var accessibilityDescription: String {
        var parts = [displayTitle.isEmpty ? (url?.displayHost ?? "New Tab") : displayTitle]
        if cameraInUse || microphoneInUse { parts.append(cameraInUse ? "using camera" : "using microphone") }
        if isMuted { parts.append("muted") } else if isPlayingAudio { parts.append("playing audio") }
        if isLoading { parts.append("loading") }
        if !isAwake { parts.append("unloaded") }
        return parts.joined(separator: ", ")
    }

    /// Stops the page's camera and microphone (the indicator's click). The page sees its
    /// tracks end, as when the user stops sharing in Chrome or Safari.
    func stopCapture() {
        guard let webView else { return }
        if webView.cameraCaptureState != .none { webView.setCameraCaptureState(.none, completionHandler: nil) }
        if webView.microphoneCaptureState != .none { webView.setMicrophoneCaptureState(.none, completionHandler: nil) }
    }

    /// Pauses or resumes the camera and microphone without ending them (WebKit's `.muted`).
    func setCaptureMuted(_ muted: Bool) {
        guard let webView else { return }
        let state: WKMediaCaptureState = muted ? .muted : .active
        if webView.cameraCaptureState != .none { webView.setCameraCaptureState(state, completionHandler: nil) }
        if webView.microphoneCaptureState != .none { webView.setMicrophoneCaptureState(state, completionHandler: nil) }
    }

    var captureMuted: Bool {
        guard let webView else { return false }
        let states = [webView.cameraCaptureState, webView.microphoneCaptureState].filter { $0 != .none }
        return !states.isEmpty && states.allSatisfy { $0 == .muted }
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
        pendingURL = url
        savedInteractionState = nil
        loadingHome = homeURL.map { Self.samePage(url, $0) } ?? false
        if let webView {
            start(URLRequest(url: url), in: webView)
        } else {
            wake()
        }
    }

    /// Loads a request Tuff itself asked for. Tuff's own pages (`tuff://`) only open this way:
    /// the navigation policy turns away a website that sends a tab or pop-up to one.
    private func start(_ request: URLRequest, in view: WKWebView) {
        internalPageLoad = InternalPage.isInternal(request.url) ? request.url : nil
        view.load(request)
    }

    func reload(fromOrigin: Bool = false) {
        guard let webView else { wake(); return }
        // A PDF fetches itself again, without a new history entry.
        if let pdf {
            pdf.reload(using: webView)
            return
        }
        if webView.url == nil, let url {
            start(URLRequest(url: url), in: webView)
        } else if fromOrigin {
            webView.reloadFromOrigin()
        } else {
            webView.reload()
        }
    }

    func stop() {
        if let pdf, pdf.phase == .downloading {
            pdf.cancelDownload()
            if pdfAwaitingCommit { dropPendingPDF() } else { pdf.phase = .failed("Loading was stopped.") }
            return
        }
        webView?.stopLoading()
    }

    func goBack() {
        // Back while a PDF is still coming in: stay on the page the link was on.
        if pdfAwaitingCommit {
            dropPendingPDF()
            return
        }
        if let webView, webView.canGoBack {
            // Skips an extra entry for the same PDF (one restored with the session has two).
            if let pdf, let back = webView.backForwardList.backItem, PDFViewer.key(back.url) == PDFViewer.key(pdf.url),
               let earlier = webView.backForwardList.backList.last(where: { PDFViewer.key($0.url) != PDFViewer.key(pdf.url) }) {
                webView.go(to: earlier)
                return
            }
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

    func goForward() {
        guard let webView else { return }
        if let pdf, let next = webView.backForwardList.forwardItem, PDFViewer.key(next.url) == PDFViewer.key(pdf.url),
           let later = webView.backForwardList.forwardList.first(where: { PDFViewer.key($0.url) != PDFViewer.key(pdf.url) }) {
            webView.go(to: later)
            return
        }
        webView.goForward()
    }

    /// The page zoom levels ⌘+ / ⌘- step through, as in Safari and Chrome.
    static let zoomSteps: [CGFloat] = [0.3, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4]

    /// The next zoom level up or down from `zoom`. A level between steps (set by an extension,
    /// or saved by an older Tuff that multiplied by 1.1) goes to the nearest step that way.
    static func zoomStep(from zoom: CGFloat, up: Bool) -> CGFloat {
        if up { return zoomSteps.first { $0 > zoom + 0.005 } ?? zoomSteps[zoomSteps.count - 1] }
        return zoomSteps.last { $0 < zoom - 0.005 } ?? zoomSteps[0]
    }

    /// Zooms the page and remembers it for the site: other open tabs on the same site follow.
    func setZoom(_ zoom: CGFloat) {
        let level = max(0.3, min(4, zoom))
        let incognito = browser?.isPrivate ?? false
        SiteZoom.shared.set(Double(level), for: url, incognito: incognito)
        applyZoom(level)
        guard let key = SiteZoom.key(for: url) else { return }
        for state in BrowserState.all where state.isPrivate == incognito {
            for tab in state.allTabs where tab !== self && SiteZoom.key(for: tab.url) == key {
                tab.applyZoom(level)
            }
        }
    }

    /// Puts the page at its site's remembered zoom. Called on every committed navigation:
    /// a new site has its own level, and WebKit can drop the zoom when a load moves the page
    /// to a new web process.
    func applySiteZoom() {
        applyZoom(CGFloat(SiteZoom.shared.zoom(for: url, incognito: browser?.isPrivate ?? false)))
    }

    private func applyZoom(_ level: CGFloat) {
        let old = pageZoom
        let changed = level != pageZoom
        pageZoom = level
        if let webView, webView.pageZoom != level { webView.pageZoom = level }
        guard changed else { return }
        browser?.tabDidChange(self, properties: .zoomFactor)
        // WebKit has no tabs.onZoomChange; Tuff sends it (zoom is per site, automatic mode).
        ExtensionEventPush.shared.emit("tabs.onZoomChange", details: [
            "oldZoomFactor": Double(old), "newZoomFactor": Double(level),
            "zoomSettings": ["mode": "automatic", "scope": "per-origin", "defaultZoomFactor": 1.0],
        ], tabs: ["tabId": self])
    }

    /// Mutes or unmutes the tab. A sleeping tab remembers it and is muted again when it wakes.
    func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        if let webView { Self.applyMute(muted, to: webView) }
        browser?.tabDidChange(self, properties: .muted)
    }

    /// WebKit has no public per-page mute; `_setPageMuted:` takes a bitmask (1 = audio). The
    /// page keeps it across navigations, but a new web view (waking, a profile or extension-page
    /// move) starts unmuted.
    fileprivate static func applyMute(_ muted: Bool, to webView: WKWebView) {
        let selector = NSSelectorFromString("_setPageMuted:")
        guard webView.responds(to: selector), let imp = webView.method(for: selector) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(imp, to: Fn.self)(webView, selector, muted ? 1 : 0)
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
