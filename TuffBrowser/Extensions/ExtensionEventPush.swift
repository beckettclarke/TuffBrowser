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
        if relays[extensionID] == nil {
            let url = context.baseURL.appendingPathComponent(ExtensionCompat.eventRelayPage)
            relays[extensionID] = EventRelay(configuration: context.webViewConfiguration, url: url)
        }
    }

    func unsubscribe(extensionID: String, event: String) {
        subscriptions[extensionID]?.remove(event)
    }

    /// Sends an event to every extension listening for it.
    func emit(_ event: String, args: [Any]) {
        for (id, events) in subscriptions where events.contains(event) {
            relays[id]?.send(event: event, args: args)
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
            guard let context = ExtensionManager.shared.contexts[id], allowed(context) else { continue }
            relays[id]?.send(event: event, args: [details], extra: ["tabs": indexes])
        }
    }

    /// Sends a window event; the shim passes the listener the window as `windows.getLastFocused`
    /// reports it (Tuff has the one).
    func emitWindowEvent(_ event: String) {
        for (id, events) in subscriptions where events.contains(event) {
            relays[id]?.send(event: event, args: [], extra: ["window": true])
        }
    }

    /// Sends an event to one extension (e.g. a notification click to its owner), if it listens.
    func emit(_ event: String, args: [Any], to extensionID: String) {
        guard subscriptions[extensionID]?.contains(event) == true else { return }
        relays[extensionID]?.send(event: event, args: args)
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
        var message: [String: Any] = ["__tuffEvent": event, "args": args]
        message.merge(extra) { a, _ in a }
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("try { chrome.runtime.sendMessage(\(json)); } catch (e) {}", completionHandler: nil)
    }

    func stop() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.load(URLRequest(url: url))
    }
}