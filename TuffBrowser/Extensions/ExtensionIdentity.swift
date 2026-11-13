import AppKit
import WebKit

/// Native `chrome.identity` for extensions: the OAuth `launchWebAuthFlow` flow. `getRedirectURL` is
/// computed in the shim (it is synchronous); the flow itself is a presented web view that watches for
/// the redirect back to the extension's `https://<id>.chromiumapp.org/` address and hands that URL to
/// the extension. Chrome-account APIs (`getAuthToken`, `removeCachedAuthToken`) are not supported.
final class ExtensionIdentity {
    static let shared = ExtensionIdentity()

    private var active: AuthFlow?

    private func error(_ message: String) -> Error {
        NSError(domain: "Tuff.Identity", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func launchWebAuthFlow(
        url: URL, interactive: Bool, extensionID: String,
        finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void
    ) {
        guard active == nil else {
            fail(error("An authorization flow is already in progress."))
            return
        }
        let flow = AuthFlow(
            url: url, redirectHost: "\(extensionID).chromiumapp.org",
            dataStore: BrowserState.shared.currentProfile.dataStore
        ) { [weak self] responseURL, error in
            self?.active = nil
            if let responseURL {
                finish(responseURL.absoluteString)
            } else {
                fail(error ?? self?.error("The authorization flow was cancelled.")
                     ?? NSError(domain: "Tuff.Identity", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cancelled."]))
            }
        }
        active = flow
        flow.show()
    }
}

/// A presented web view for one OAuth flow. Completes when the page redirects to the extension's
/// `chromiumapp.org` address (the response URL), or fails if the user closes the window first.
private final class AuthFlow: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private let window: NSWindow
    private let webView: WKWebView
    private let redirectHost: String
    private var onComplete: ((URL?, Error?) -> Void)?

    init(url: URL, redirectHost: String, dataStore: WKWebsiteDataStore, onComplete: @escaping (URL?, Error?) -> Void) {
        self.redirectHost = redirectHost
        self.onComplete = onComplete
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 720), configuration: configuration)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 720),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        super.init()
        window.title = "Sign in"
        window.contentView = webView
        window.delegate = self
        window.isReleasedWhenClosed = false
        webView.navigationDelegate = self
        webView.load(URLRequest(url: url))
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func complete(_ url: URL?, _ error: Error?) {
        guard let callback = onComplete else { return }
        onComplete = nil
        window.delegate = nil   // so closing here doesn't re-enter via windowWillClose
        window.close()
        callback(url, error)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url, url.host == redirectHost {
            decisionHandler(.cancel)
            complete(url, nil)
            return
        }
        decisionHandler(.allow)
    }

    func windowWillClose(_ notification: Notification) {
        complete(nil, NSError(domain: "Tuff.Identity", code: 2, userInfo: [NSLocalizedDescriptionKey: "The user cancelled the authorization flow."]))
    }
}