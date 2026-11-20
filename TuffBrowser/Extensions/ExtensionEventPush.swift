import AppKit
import WebKit

/// Pushes native-API events (`history.onVisited`, `downloads.onCreated`, `notifications.onClicked`, …)
/// into extensions. WebKit has no public way to run script in an extension's background context, so
/// each listening extension gets a tiny always-alive relay page of its own; Tuff scripts that page to
/// call `chrome.runtime.sendMessage`, which is a wake event for the service worker. The compatibility
/// shim receives the message and dispatches it to the event's registered listeners.
///
/// Extensions subscribe (via the shim) when they add their first listener for an event, so Tuff only
/// creates relays and wakes workers for extensions that actually listen.
final class ExtensionEventPush {
    static let shared = ExtensionEventPush()

    /// extension id -> the events it has listeners for.
    private var subscriptions: [String: Set<String>] = [:]
    /// extension id -> its relay page.
    private var relays: [String: EventRelay] = [:]

    func subscribe(extensionID: String, event: String, context: WKWebExtensionContext) {
        subscriptions[extensionID, default: []].insert(event)
        if event == "idle.onStateChanged" { ExtensionSystem.shared.startIdleMonitoring() }
        // Bookmark events compare the tree before and after each change, from here on.
        if event.hasPrefix("bookmarks.") { _ = ExtensionBookmarks.shared }
        if relays[extensionID] == nil {
            let url = context.baseURL.appendingPathComponent(ExtensionCompat.eventRelayPage)
            relays[extensionID] = EventRelay(configuration: context.webViewConfiguration, url: url)
        }
        if event == ExtensionDeclarativeContent.applyEvent { ExtensionDeclarativeContent.shared.listenerAdded(extensionID: extensionID) }
    }

    func unsubscribe(extensionID: String, event: String) {
        subscriptions[extensionID]?.remove(event)
    }

    /// Whether any extension listens for one of `events`, so the work of producing them can be skipped.
    func isListening(to events: Set<String>) -> Bool {
        subscriptions.values.contains { !$0.isDisjoint(with: events) }
    }

    /// Sends an event to every extension listening for it. `extra` asks the shim to fill
    /// something in first (`groupWindow`: the window id of the tab group in the first argument).
    private func allows(_ id: String, _ event: String) -> Bool {
        guard let context = ExtensionManager.shared.contexts[id] else { return false }
        guard let permission = ExtensionAPIPermissions.event(event) else { return true }
        return context.currentPermissions.contains(WKWebExtension.Permission(rawValue: permission))
    }

    func emit(_ event: String, args: [Any], extra: [String: Any] = [:]) {
        for (id, events) in subscriptions where events.contains(event) && allows(id, event) {
            relays[id]?.send(event: event, args: args, extra: extra)
        }
    }

    /// Sends an event about a tab to the extensions that listen and that `allowed` lets see it.
    /// Extensions name tabs by WebKit's ids, which Tuff doesn't know, so the tabs are passed by
    /// their index in the window (`tabs`: field of the first argument → tab) and the shim fills
    /// in the matching ids. Incognito tabs never reach extensions.
    func emit(_ event: String, details: [String: Any], tabs: [String: Tab], allowed: (WKWebExtensionContext) -> Bool = { _ in true }) {
        guard tabs.values.allSatisfy({ $0.browser === BrowserState.shared && !($0.browser?.isPrivate ?? true) }) else { return }
        let all = BrowserState.shared.allTabs
        var indexes: [String: Int] = [:]
        for (field, tab) in tabs {
            guard let index = all.firstIndex(where: { $0 === tab }) else { return }
            indexes[field] = index
        }
        for (id, events) in subscriptions where events.contains(event) {
            guard allows(id, event), let context = ExtensionManager.shared.contexts[id], allowed(context) else { continue }
            relays[id]?.send(event: event, args: [details], extra: ["tabs": indexes])
        }
    }

    /// Sends a tab event to one extension, if it listens; returns whether it was sent. The tab
    /// travels as in `emit(_:details:tabs:allowed:)`.
    @discardableResult
    func emit(_ event: String, details: [String: Any], tab: Tab, to extensionID: String) -> Bool {
        guard tab.browser === BrowserState.shared, !(tab.browser?.isPrivate ?? true),
              let index = BrowserState.shared.allTabs.firstIndex(where: { $0 === tab }),
              subscriptions[extensionID]?.contains(event) == true, allows(extensionID, event),
              let relay = relays[extensionID] else { return false }
        relay.send(event: event, args: [details], extra: ["tabs": ["tabId": index]])
        return true
    }

    /// Sends a window event; the shim passes the listener the window as `windows.getLastFocused`
    /// reports it (Tuff has the one).
    func emitWindowEvent(_ event: String) {
        for (id, events) in subscriptions where events.contains(event) && allows(id, event) {
            relays[id]?.send(event: event, args: [], extra: ["window": true])
        }
    }

    /// Sends an event to one extension (e.g. a notification click to its owner), if it listens.
    func emit(_ event: String, args: [Any], extra: [String: Any] = [:], to extensionID: String) {
        guard subscriptions[extensionID]?.contains(event) == true, allows(extensionID, event) else { return }
        relays[extensionID]?.send(event: event, args: args, extra: extra)
    }

    func extensionUnloaded(_ id: String) {
        subscriptions.removeValue(forKey: id)
        relays.removeValue(forKey: id)?.stop()
    }
}

/// A hidden, never-throttled extension page used only as a place to run `chrome.runtime.sendMessage`.
private final class EventRelay: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private let url: URL
    private let relayID = UUID().uuidString
    private var nextMessageID = 1
    private var pending: [[String: Any]] = []
    private var ready = false
    private var sending = false
    private var generation = 0

    init(configuration: WKWebViewConfiguration?, url: URL) {
        self.url = url
        super.init()
        guard let configuration = configuration.map(ExtensionManager.hiddenPageConfiguration) else { return }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        view.load(URLRequest(url: url))
    }

    func send(event: String, args: [Any], extra: [String: Any] = [:]) {
        guard webView != nil else { return }
        var message: [String: Any] = [
            "__tuffEvent": event, "args": args, "__tuffDelivery": relayID + ":\(nextMessageID)",
        ]
        nextMessageID += 1
        message.merge(extra) { a, _ in a }
        pending.append(message)
        deliverNext()
    }

    private func deliverNext() {
        guard ready, !sending, let message = pending.first, let webView,
              let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        sending = true
        let generation = self.generation
        // Ends in `void 0`: the script's value would otherwise be sendMessage's promise, which
        // evaluateJavaScript can't return and reports as an error (resending the same event forever).
        webView.evaluateJavaScript("try { chrome.runtime.sendMessage(\(json)); } catch (e) {} void 0;") { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.sending = false
                guard error == nil else {
                    self.ready = false
                    self.webView?.reload()
                    return
                }
                if !self.pending.isEmpty { self.pending.removeFirst() }
                self.deliverNext()
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        sending = false
        deliverNext()
    }

    func stop() {
        generation += 1
        ready = false
        sending = false
        pending.removeAll()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        generation += 1
        ready = false
        sending = false
        webView.load(URLRequest(url: url))
    }
}