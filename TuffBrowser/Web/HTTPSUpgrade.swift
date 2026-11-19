import Foundation
import WebKit

/// HTTPS for every site, not only the ones WebKit knows support it (`upgradeKnownHostsToHTTPS`).
///
/// "Upgrade to HTTPS" tries https first and quietly falls back to http when the site has no
/// secure version, as Safari does. "Always use secure connections" doesn't fall back by
/// itself: a site without https gets a warning page (`warningPage`) whose "Continue to Site"
/// lets that site use http until Tuff quits.
///
/// Addresses that can't have a public certificate (localhost, IP addresses, `.local`, names
/// without a dot) are left as typed.
enum HTTPSUpgrade {
    /// Sites let through on http from the warning page, until Tuff quits.
    private static var allowedHTTP: Set<String> = []
    private static var incognitoAllowedHTTP: Set<String> = []

    /// How WebKit should treat a main-frame navigation to `url`. The address may already be the
    /// https one WebKit made of an http address; it gets the same policy, or the fallback to
    /// http wouldn't happen.
    static func policy(for url: URL, incognito: Bool) -> WKWebpagePreferences.UpgradeToHTTPSPolicy {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false)?.lowercased(), !isExempt(host),
              !allowsHTTP(host: host, incognito: incognito) else { return .keepAsRequested }
        let privacy = AppSettings.shared.privacy
        if privacy.httpsOnly { return .errorOnFailure }
        return privacy.upgradeToHTTPS ? .automaticFallbackToHTTP : .keepAsRequested
    }

    /// Names that can't get a certificate from a public authority: a local server, a router,
    /// a printer or an intranet name.
    static func isExempt(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if host.contains(":") || !host.contains(".") { return true }
        if host.split(separator: ".").allSatisfy({ Int($0) != nil }) { return true }
        return [".localhost", ".local", ".internal", ".lan", ".home.arpa", ".test"].contains { host.hasSuffix($0) }
    }

    static func allowsHTTP(host: String, incognito: Bool) -> Bool {
        let host = host.lowercased()
        return allowedHTTP.contains(host) || (incognito && incognitoAllowedHTTP.contains(host))
    }

    static func allowHTTP(host: String, incognito: Bool) {
        if incognito {
            incognitoAllowedHTTP.insert(host.lowercased())
        } else {
            allowedHTTP.insert(host.lowercased())
        }
    }

    /// Called when the last Incognito window closes.
    static func forgetIncognito() { incognitoAllowedHTTP.removeAll() }

    /// Failures that say nothing about https: the site can't be reached at all, so the usual
    /// error page fits better than a warning about an insecure connection.
    static func isUnreachable(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet,
            NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff,
        ].contains(error.code)
    }

    /// The page shown in place of an http site that has no secure version, with a "Continue to
    /// Site" button that talks to `HTTPSWarningHandler`.
    static func warningPage(for url: URL) -> String {
        let host = url.host(percentEncoded: false) ?? url.absoluteString
        return WebEngine.statusPage(
            title: "Not a secure connection",
            heading: "\(host) doesn’t support a secure connection",
            message: "Tuff tried to open it over HTTPS and couldn’t. If you continue, anyone on your network could see or change what you send to it, such as passwords or card numbers.",
            detail: url.absoluteString,
            icon: .shield,
            tone: .warning,
            buttons: [
                .init(label: "Go Back", primary: true, key: "↩", action: "history.length > 1 ? history.back() : location.replace('about:blank')"),
                .init(label: "Continue to Site", primary: false, key: nil, action: "tuffHTTPS()"),
            ],
            script: """
            function tuffHTTPS() {
              const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(HTTPSWarningHandler.name);
              if (h) h.postMessage('proceed');
            }
            """
        )
    }
}

/// The warning page's "Continue to Site". A message only counts from the main frame of a tab
/// showing the warning for that very site (`Tab.httpsWarningURL`), so no other page can use it.
final class HTTPSWarningHandler: NSObject, WKScriptMessageHandler {
    static let name = "tuffHTTPS"
    static let shared = HTTPSWarningHandler()

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let tab = (message.webView as? TuffWebView)?.tab, let url = tab.httpsWarningURL,
              let host = url.host(percentEncoded: false), message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host.lowercased() == host.lowercased(),
              message.body as? String == "proceed" else { return }
        HTTPSUpgrade.allowHTTP(host: host, incognito: tab.browser?.isPrivate ?? false)
        tab.httpsWarningURL = nil
        tab.load(url)
    }
}
