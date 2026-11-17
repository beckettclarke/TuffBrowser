import AppKit
import WebKit

/// Links that open another app (`zoommtg:`, `vscode:`, `x-apple.systempreferences:`…). A page
/// may only hand one to an app after the user says yes on a card, as in Safari and Chrome:
/// otherwise any page, or a redirect, could launch apps (and feed them a payload) by itself.
/// "Always allow" is kept per site and app link type; Incognito's choices stay in memory.
enum ExternalAppLinks {
    private static let defaultsKey = "externalAppLinksAllowed"
    /// Remembered "always allow" answers, as "origin|scheme".
    private static var allowed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    private static var incognitoAllowed: Set<String> = []

    /// A clicked mail or phone link does what it looks like; no card for those.
    private static let quietWhenClicked: Set<String> = ["mailto", "tel", "sms", "facetime", "facetime-audio"]

    static func isAllowed(origin: String, scheme: String, incognito: Bool) -> Bool {
        let key = "\(origin)|\(scheme)"
        return allowed.contains(key) || (incognito && incognitoAllowed.contains(key))
    }

    static func allow(origin: String, scheme: String, incognito: Bool) {
        let key = "\(origin)|\(scheme)"
        if incognito {
            incognitoAllowed.insert(key)
        } else {
            allowed.insert(key)
            UserDefaults.standard.set(allowed.sorted(), forKey: defaultsKey)
        }
    }

    /// Forgets every "always allow" (Settings, or with the other site permissions).
    static func removeAll() {
        allowed.removeAll()
        incognitoAllowed.removeAll()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// Called when the last Incognito window closes.
    static func forgetIncognito() { incognitoAllowed.removeAll() }

    static func opensWithoutAsking(scheme: String, navigationType: WKNavigationType) -> Bool {
        navigationType == .linkActivated && quietWhenClicked.contains(scheme)
    }
}

extension Tab {
    /// A page wants to open a link in another app. Typed into the command bar (no page asked),
    /// or a clicked mail / phone link, it just opens; anything else asks on a card first.
    func openInOtherApp(_ url: URL, action: WKNavigationAction) {
        guard let scheme = url.scheme?.lowercased() else { return }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            browser?.show(Toast(symbol: "questionmark.app", text: "No app on this Mac opens “\(scheme):” links"))
            return
        }
        let source: WKFrameInfo? = action.sourceFrame
        let incognito = browser?.isPrivate ?? false
        // Loads Tuff started itself (the command bar, a link from another app) have no page behind them.
        guard let source else { NSWorkspace.shared.open(url); return }
        let host = source.securityOrigin.host
        let origin = host.isEmpty ? "" : SitePermissions.origin(of: source.securityOrigin)
        if ExternalAppLinks.opensWithoutAsking(scheme: scheme, navigationType: action.navigationType)
            || (!origin.isEmpty && ExternalAppLinks.isAllowed(origin: origin, scheme: scheme, incognito: incognito)) {
            NSWorkspace.shared.open(url)
            return
        }
        // One card at a time: a page that keeps trying doesn't stack up a queue of them.
        guard !externalAppPromptShowing else { return }
        externalAppPromptShowing = true
        let appName = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let site = host.isEmpty ? "This page" : host
        let prompt = Prompt(
            icon: NSWorkspace.shared.icon(forFile: app.path),
            symbol: "arrow.up.forward.app",
            title: "Open “\(appName)”?",
            subtitle: site,
            message: "\(site) wants to open a link in \(appName).",
            confirmTitle: "Open \(appName)",
            checkbox: origin.isEmpty ? nil : "Always allow \(host) to open \(appName) links"
        )
        Task { @MainActor in
            let result = await askForPage(prompt)
            externalAppPromptShowing = false
            guard let result, result.confirmed else { return }
            if result.checked, !origin.isEmpty {
                ExternalAppLinks.allow(origin: origin, scheme: scheme, incognito: incognito)
            }
            NSWorkspace.shared.open(url)
        }
    }
}
