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
        guard let configuration else { return }
        configuration.preferences.inactiveSchedulingPolicy = .none
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        view.load(URLRequest(url: url))
    }

    func send(event: String, args: [Any]) {
        let message: [String: Any] = ["__tuffEvent": event, "args": args]
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