import AppKit
import SwiftUI
import WebKit

/// Tells the tab when WebKit's pop-up blocker turns a `window.open` away, so the address bar
/// can say so ("Pop-up blocked") and offer to open it or allow the site's pop-ups.
///
/// WebKit blocks silently: with `javaScriptCanOpenWindowsAutomatically` off, a `window.open`
/// without a click just returns null and no delegate hears of it. A small script in each frame
/// notices that null and reports it. It only reports; WebKit still does the blocking.
enum PopupBlocker {
    static let handlerName = "tuffPopupBlocked"
    private static let handler = MessageHandler()

    static func install(into controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        controller.add(handler, contentWorld: .page, name: handlerName)
    }

    /// At most this many blocked addresses are kept per page.
    static let limit = 10

    private static let script = #"""
    (function () {
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tuffPopupBlocked;
      if (!bridge || typeof window.open !== 'function') return;
      var open = window.open;
      var wrapped = function (url, target, features) {
        var result = open.apply(this, arguments);
        if (result === null) {
          var href = '';
          try { href = url === undefined || url === null || url === '' ? 'about:blank' : new URL(String(url), document.baseURI).href; } catch (e) { href = String(url); }
          try { bridge.postMessage(href); } catch (e) {}
        }
        return result;
      };
      try { Object.defineProperty(wrapped, 'name', { value: 'open' }); } catch (e) {}
      try { Object.defineProperty(wrapped, 'length', { value: open.length }); } catch (e) {}
      try { wrapped.toString = function () { return 'function open() {\n    [native code]\n}'; }; } catch (e) {}
      try { window.open = wrapped; } catch (e) {}
    })();
    """#

    private final class MessageHandler: NSObject, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let tab = (message.webView as? TuffWebView)?.tab,
                  let text = message.body as? String,
                  let url = URL(string: text),
                  // Only the blocker's real refusals count: when pop-ups are allowed, a null
                  // window means something else (a sandboxed frame), not a blocked pop-up.
                  !tab.popupsAllowed else { return }
            tab.popupWasBlocked(url)
        }
    }
}

extension Tab {
    /// Whether pop-ups are allowed on the page now (the site's own choice, else Settings).
    var popupsAllowed: Bool {
        let incognito = browser?.isPrivate ?? false
        return SiteSettings.shared.entry(for: url, incognito: incognito).popups ?? !AppSettings.shared.privacy.blockPopups
    }

    func popupWasBlocked(_ url: URL) {
        guard !blockedPopups.contains(url) else { return }
        blockedPopups.append(url)
        if blockedPopups.count > PopupBlocker.limit { blockedPopups.removeFirst() }
    }

    /// Opens a blocked pop-up as a tab next to this one.
    func openBlockedPopup(_ url: URL) {
        blockedPopups.removeAll { $0 == url }
        browser?.newTab(url: url, after: self)
    }

    /// "Always Allow Pop-ups from {site}": saves the site's choice, opens what was blocked.
    func allowPopups() {
        let incognito = browser?.isPrivate ?? false
        SiteSettings.shared.update(url, incognito: incognito) { $0.popups = true }
        let waiting = blockedPopups
        blockedPopups.removeAll()
        for url in waiting { browser?.newTab(url: url, select: false, after: self) }
        reload()
    }
}

/// The address bar's "Pop-up blocked" button: lists what was blocked, opens any of it, or
/// allows the site's pop-ups from now on.
struct BlockedPopupsButton: View {
    let tab: Tab
    var side: CGFloat = 24

    var body: some View {
        let site = SiteSettings.key(for: tab.url) ?? "this site"
        Menu {
            Section(tab.blockedPopups.count == 1 ? "Pop-up blocked" : "\(tab.blockedPopups.count) pop-ups blocked") {
                ForEach(tab.blockedPopups, id: \.self) { url in
                    Button(Self.label(url)) { tab.openBlockedPopup(url) }
                }
            }
            Divider()
            Button("Always Allow Pop-ups from \(site)") { tab.allowPopups() }
            Button("Dismiss") { tab.blockedPopups.removeAll() }
        } label: {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.75))
                .frame(width: side, height: side)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(0.11)))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Pop-up blocked")
        .accessibilityLabel("Pop-up blocked")
    }

    private static func label(_ url: URL) -> String {
        let text = url.absoluteString
        return text.count > 70 ? String(text.prefix(67)) + "…" : text
    }
}
