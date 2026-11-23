import AppKit
import Observation
import WebKit

/// Extension side panels: Chrome's `side_panel` manifest key and `chrome.sidePanel` API, and
/// Firefox's `sidebar_action` key and `browser.sidebarAction` API.
///
/// WebKit has neither, so Tuff hosts the panel page itself — in a web view built from the
/// extension's own configuration, docked to the right of the page — and the compatibility
/// shim (`ExtensionCompat`) supplies both APIs. The shim reaches this class through
/// `tabs.create` with a private URL scheme (`bridgeScheme`): `tabs.create` is the one browser
/// call every extension context, background service workers included, can make without
/// asking for a permission. `ExtensionManager` intercepts those URLs before a tab is made,
/// and the answer goes back as the call's error, which the shim unpacks.
///
/// One panel shows at a time, as in Chrome and Firefox. What it shows can differ per tab
/// (`setOptions({ tabId })`, `setPanel({ tabId })`), so it follows the selected tab.
@Observable
final class SidePanelManager {
    static let shared = SidePanelManager()

    static let bridgeScheme = "tuff-sidepanel"
    /// Prefix of the error message that carries a bridge reply back to the shim.
    static let replyMarker = "__tuff_sidepanel__:"

    /// The extension whose panel is open, if any. The panel can still be hidden while the
    /// selected tab has it turned off (`isShowing`).
    private(set) var openID: String?
    /// The web view showing the open panel, while it is visible.
    private(set) var host: SidePanelHost?
    /// Bumped when anything shown about a panel (title, availability) changes.
    private(set) var revision = 0

    /// The panel opened last, which ⌥⌘S brings back.
    @ObservationIgnored private var lastOpenedID: String?

    /// Options set at runtime. Chrome's global options and panel behaviour also live in the
    /// extension's record, since Chrome keeps them across restarts; Firefox's do not persist.
    private struct Options {
        var path: String?
        var enabled: Bool?
        var title: String?
    }
    @ObservationIgnored private var globalOptions: [String: Options] = [:]
    @ObservationIgnored private var tabOptions: [String: [UUID: Options]] = [:]

    private var extensions: ExtensionManager { .shared }
    private var browser: BrowserState { .shared }

    private init() {}

    var isShowing: Bool { host != nil }

    // MARK: What an extension declares

    /// The panel an extension declares in its manifest, if any.
    struct Declared {
        enum Kind { case chrome, firefox }
        let kind: Kind
        let path: String?
        let title: String?
        let openAtInstall: Bool
    }

    static func declared(by manifest: [String: Any]) -> Declared? {
        if let panel = manifest["sidebar_action"] as? [String: Any] {
            return Declared(
                kind: .firefox,
                path: panel["default_panel"] as? String,
                title: panel["default_title"] as? String,
                openAtInstall: panel["open_at_install"] as? Bool ?? true
            )
        }
        let permissions = (manifest["permissions"] as? [Any] ?? []).compactMap { $0 as? String }
        if let panel = manifest["side_panel"] as? [String: Any] {
            return Declared(kind: .chrome, path: panel["default_path"] as? String, title: nil, openAtInstall: false)
        }
        // `chrome.sidePanel.setOptions({ path })` alone is enough to have a panel.
        if permissions.contains("sidePanel") {
            return Declared(kind: .chrome, path: nil, title: nil, openAtInstall: false)
        }
        return nil
    }

    private func declared(_ id: String) -> Declared? {
        guard let context = extensions.contexts[id] else { return nil }
        return Self.declared(by: context.webExtension.manifest)
    }

    private func record(_ id: String) -> ExtensionRecord? {
        extensions.records.first { $0.id == id }
    }

    // MARK: Resolving options

    private func resolvedPath(_ id: String, for tab: Tab?) -> String? {
        if let tab, let path = tabOptions[id]?[tab.id]?.path { return path }
        return globalOptions[id]?.path ?? record(id)?.sidePanel?.path ?? declared(id)?.path
    }

    private func resolvedEnabled(_ id: String, for tab: Tab?) -> Bool {
        if let tab, let enabled = tabOptions[id]?[tab.id]?.enabled { return enabled }
        return globalOptions[id]?.enabled ?? record(id)?.sidePanel?.enabled ?? true
    }

    func title(for id: String, tab: Tab? = nil) -> String {
        let tab = tab ?? browser.selectedTab
        if let tab, let title = tabOptions[id]?[tab.id]?.title { return title }
        if let title = globalOptions[id]?.title { return title }
        if let title = declared(id)?.title, !title.isEmpty, !title.hasPrefix("__MSG_") { return title }
        return extensions.contexts[id]?.webExtension.displayName ?? record(id)?.name ?? "Extension"
    }

    func icon(for id: String) -> NSImage? {
        guard let webExtension = extensions.contexts[id]?.webExtension else { return nil }
        let size = CGSize(width: 16, height: 16)
        return webExtension.actionIcon(for: size) ?? webExtension.icon(for: size)
    }

    /// The panel page for a tab, or nil if the extension has none there.
    func url(for id: String, tab: Tab?) -> URL? {
        guard let context = extensions.contexts[id], resolvedEnabled(id, for: tab),
              let path = resolvedPath(id, for: tab), !path.isEmpty,
              let url = URL(string: path, relativeTo: context.baseURL)?.absoluteURL,
              extensions.context(forPage: url) === context else { return nil }
        return url
    }

    /// Whether the extension has a panel at all (on the selected tab).
    func hasPanel(_ id: String) -> Bool {
        url(for: id, tab: browser.selectedTab) != nil
    }

    /// Loaded extensions with a panel, in installation order.
    var panelExtensionIDs: [String] {
        _ = revision
        return extensions.records.filter { $0.enabled && hasPanel($0.id) }.map(\.id)
    }

    /// Whether clicking the extension's toolbar button should toggle its panel rather than
    /// run its action: Chrome's `openPanelOnActionClick`, or a Firefox extension whose only
    /// button is its sidebar.
    func actionTogglesPanel(_ id: String) -> Bool {
        guard hasPanel(id) else { return false }
        if record(id)?.sidePanel?.openOnActionClick == true { return true }
        guard let manifest = extensions.contexts[id]?.webExtension.manifest else { return false }
        return manifest["action"] == nil && manifest["browser_action"] == nil && manifest["page_action"] == nil
    }

    // MARK: Opening and closing

    @discardableResult
    func open(_ id: String) -> Bool {
        // Available on this tab, or set for some other open tab (Chrome lets a tab-specific panel
        // be opened; it shows when that tab is selected). Options left over for tabs that no
        // longer resolve to a page don't count.
        let elsewhere = browser.allTabs.contains { tabOptions[id]?[$0.id] != nil && url(for: id, tab: $0) != nil }
        guard url(for: id, tab: browser.selectedTab) != nil || elsewhere else { return false }
        if openID != id { host?.tearDown(); host = nil }
        openID = id
        lastOpenedID = id
        refresh()
        return true
    }

    func close(_ id: String? = nil) {
        guard let openID, id == nil || id == openID else { return }
        host?.tearDown()
        host = nil
        self.openID = nil
        browser.focusWebView()
    }

    func toggle(_ id: String) {
        if openID == id { close(id) } else { open(id) }
    }

    /// ⌥⌘S: closes the open panel, or reopens the last one (or the first available).
    func toggleLast() {
        if openID != nil { close(); return }
        let candidates = panelExtensionIDs
        if let last = lastOpenedID, candidates.contains(last) { open(last) } else if let first = candidates.first { open(first) }
    }

    func reload() {
        host?.webView.reload()
    }

    /// Shows, swaps or hides the panel page to match the selected tab.
    private func refresh() {
        defer { revision += 1 }
        guard let id = openID else { return }
        guard let url = url(for: id, tab: browser.selectedTab),
              let configuration = extensions.contexts[id]?.webViewConfiguration else {
            // Not available on this tab: hide it until a tab that has it comes back.
            host?.tearDown()
            host = nil
            return
        }
        if let host, host.extensionID == id {
            if host.requestedURL != url { host.load(url) }
        } else {
            host?.tearDown()
            host = SidePanelHost(extensionID: id, configuration: configuration, url: url)
        }
    }

    // MARK: Browser events

    func selectedTabChanged() {
        guard openID != nil else { return }
        refresh()
    }

    func tabClosed(_ tab: Tab) {
        for id in tabOptions.keys { tabOptions[id]?[tab.id] = nil }
    }

    func extensionLoaded(_ id: String) {
        revision += 1
    }

    /// Firefox opens a new extension's sidebar right away unless it says not to.
    func extensionInstalled(_ id: String) {
        if let declared = declared(id), declared.kind == .firefox, declared.openAtInstall { open(id) }
    }

    func extensionUnloaded(_ id: String) {
        close(id)
        globalOptions[id] = nil
        tabOptions[id] = nil
        revision += 1
    }

    // MARK: API bridge (chrome.sidePanel / browser.sidebarAction, see ExtensionCompat)

    /// Answers one call from the shim. The reply is always an error, whose message carries
    /// `{ value }` or `{ error }` as JSON after `replyMarker`.
    func handleBridge(_ url: URL, context: WKWebExtensionContext) -> Error {
        let id = context.uniqueIdentifier
        let op = url.host ?? ""
        var args: [String: Any] = [:]
        if let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "d" })?.value,
           let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            args = object
        }
        extensions.trace("sidepanel \(op) \(args.keys.sorted())")

        let reply: [String: Any]
        do {
            reply = ["value": try perform(op, args: args, id: id, context: context) ?? NSNull()]
        } catch {
            reply = ["error": error.localizedDescription]
        }
        let json = (try? JSONSerialization.data(withJSONObject: reply)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return NSError(domain: "Tuff.SidePanel", code: 0, userInfo: [NSLocalizedDescriptionKey: Self.replyMarker + json])
    }

    private struct BridgeError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// The tab a call names (the shim turns `tabId` into the tab's index), if any.
    private func tab(_ args: [String: Any]) throws -> Tab? {
        guard let index = args["tabIndex"] as? Int else { return nil }
        let tabs = browser.allTabs
        guard tabs.indices.contains(index) else { throw BridgeError("No tab with id: \(args["tabId"] ?? index).") }
        return tabs[index]
    }

    /// A panel can only show the extension's own pages.
    private func validate(_ path: String, context: WKWebExtensionContext) throws {
        guard !path.isEmpty, let url = URL(string: path, relativeTo: context.baseURL)?.absoluteURL,
              extensions.context(forPage: url) === context else {
            throw BridgeError("Invalid path: \(path). A side panel must be one of the extension’s own pages.")
        }
    }

    private func setOptions(_ id: String, tab: Tab?, _ change: (inout Options) -> Void) {
        if let tab {
            var options = tabOptions[id]?[tab.id] ?? Options()
            change(&options)
            tabOptions[id, default: [:]][tab.id] = options
        } else {
            var options = globalOptions[id] ?? Options()
            change(&options)
            globalOptions[id] = options
        }
        refresh()
    }

    private func perform(_ op: String, args: [String: Any], id: String, context: WKWebExtensionContext) throws -> Any? {
        let tab = try tab(args)
        switch op {
        // Both APIs.
        case "open":
            if let tab, tab !== browser.selectedTab { browser.select(tab) }
            guard open(id) else { throw BridgeError("No active side panel for this extension.") }
            return nil
        case "close":
            close(id)
            return nil

        // chrome.sidePanel
        case "setOptions":
            if let path = args["path"] as? String { try validate(path, context: context) }
            setOptions(id, tab: tab) { options in
                if let path = args["path"] as? String { options.path = path }
                if let enabled = args["enabled"] as? Bool { options.enabled = enabled }
            }
            if tab == nil {
                extensions.updateSidePanelPrefs(id) { prefs in
                    if let path = args["path"] as? String { prefs.path = path }
                    if let enabled = args["enabled"] as? Bool { prefs.enabled = enabled }
                }
            }
            if openID == id, !resolvedEnabled(id, for: browser.selectedTab), tab == nil { close(id) }
            return nil
        case "getOptions":
            var result: [String: Any] = ["enabled": resolvedEnabled(id, for: tab)]
            if let path = resolvedPath(id, for: tab) { result["path"] = path }
            if let tabID = args["tabId"] { result["tabId"] = tabID }
            return result
        case "setPanelBehavior":
            if let value = args["openPanelOnActionClick"] as? Bool {
                extensions.updateSidePanelPrefs(id) { $0.openOnActionClick = value }
                revision += 1
            }
            return nil
        case "getPanelBehavior":
            return ["openPanelOnActionClick": record(id)?.sidePanel?.openOnActionClick ?? false]

        // browser.sidebarAction
        case "toggle":
            toggle(id)
            return nil
        case "isOpen":
            return openID == id && isShowing
        case "setPanel":
            let panel = args["panel"] as? String
            if let panel { try validate(panel, context: context) }
            setOptions(id, tab: tab) { $0.path = panel }
            return nil
        case "getPanel":
            return url(for: id, tab: tab ?? browser.selectedTab)?.absoluteString ?? ""
        case "setTitle":
            setOptions(id, tab: tab) { $0.title = args["title"] as? String }
            return nil
        case "getTitle":
            return title(for: id, tab: tab)

        default:
            throw BridgeError("Unsupported side panel call: \(op)")
        }
    }
}

/// The web view showing an extension's panel page.
final class SidePanelHost: NSObject, WKNavigationDelegate, WKUIDelegate {
    let extensionID: String
    let webView: TuffWebView
    /// The panel URL last asked for (the page itself may have moved on since).
    private(set) var requestedURL: URL

    init(extensionID: String, configuration: WKWebViewConfiguration, url: URL) {
        self.extensionID = extensionID
        self.requestedURL = url
        webView = WebEngine.makeWebView(configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: url))
    }

    func load(_ url: URL) {
        requestedURL = url
        webView.load(URLRequest(url: url))
    }

    func tearDown() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    // Like Chrome, the panel only ever shows the extension's own pages; a link to a website
    // opens in a tab instead (WebKit would refuse the navigation in this web view anyway).
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        guard let url = navigationAction.request.url, navigationAction.targetFrame?.isMainFrame ?? true,
              !ExtensionManager.isExtensionPage(url),
              !["about", "blob", "data"].contains(url.scheme ?? "") else {
            decisionHandler(.allow)
            return
        }
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.option),
           ["http", "https"].contains(url.scheme ?? "") {
            decisionHandler(.download)
            return
        }
        decisionHandler(.cancel)
        if ["http", "https"].contains(url.scheme ?? "") { BrowserState.shared.newTab(url: url) }
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        if navigationResponse.canShowMIMEType || Tab.isRenderable(navigationResponse.response.mimeType) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.track(download)
    }

    @objc(_webView:contextMenuDidCreateDownload:)
    func webView(_ webView: WKWebView, contextMenuDidCreateDownload download: WKDownload) {
        let asks = (webView as? TuffWebView)?.takeContextSaveAsRequest() ?? false
        DownloadManager.shared.track(download, saveLocation: asks ? .ask : .downloadsFolder)
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let url = navigationAction.request.url
        if let url, url.scheme == "http" || url.scheme == "https" {
            BrowserState.shared.newTab(url: url)
            return nil
        }
        return BrowserState.shared.newTab(url: nil, configuration: configuration).webView
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.load(URLRequest(url: requestedURL))
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void
    ) {
        guard webView.window != nil else { completionHandler(); return }
        let prompt = panelPrompt(message, cancel: nil)
        Task { @MainActor in
            await PromptPresenter.present(prompt)
            completionHandler()
        }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
    ) {
        guard webView.window != nil else { completionHandler(false); return }
        let prompt = panelPrompt(message, cancel: "Cancel")
        Task { @MainActor in completionHandler(await PromptPresenter.present(prompt)) }
    }

    /// The card for the panel page's alert() / confirm().
    private func panelPrompt(_ message: String, cancel: String?) -> Prompt {
        let manager = SidePanelManager.shared
        return Prompt(
            icon: manager.icon(for: extensionID),
            title: "\(manager.title(for: extensionID)) says",
            message: message.trimmed.isEmpty ? nil : message,
            confirmTitle: "OK",
            cancelTitle: cancel
        )
    }
}
