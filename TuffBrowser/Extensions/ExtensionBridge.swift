import AppKit
import NaturalLanguage
import WebKit

// MARK: - Tabs as seen by extensions (browser.tabs.*)

extension Tab: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        ExtensionManager.shared.windowAdapter
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        browser?.allTabs.firstIndex { $0 === self } ?? 0
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }

    func title(for context: WKWebExtensionContext) -> String? { pageTitle }

    func isPinned(for context: WKWebExtensionContext) -> Bool {
        guard let section = browser?.section(of: self) else { return false }
        return section != .tabs
    }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        browser?.move(self, to: pinned ? .pinned : .tabs)
        completionHandler(nil)
    }

    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { isPlayingAudio }

    func isMuted(for context: WKWebExtensionContext) -> Bool { isMuted }

    func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        setMuted(muted)
        completionHandler(nil)
    }

    func size(for context: WKWebExtensionContext) -> CGSize { webView?.bounds.size ?? .zero }

    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(pageZoom) }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        setZoom(CGFloat(zoomFactor))
        completionHandler(nil)
    }

    func url(for context: WKWebExtensionContext) -> URL? { webView?.url ?? url }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !isLoading }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        load(url, byExtension: true)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        reload(fromOrigin: fromOrigin)
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        browser?.select(self)
        completionHandler(nil)
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool { browser?.selectedTab === self }

    func setSelected(_ selected: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        // There is always one active tab; deselecting isn't meaningful, so only honour selection.
        if selected { browser?.select(self) }
        completionHandler(nil)
    }

    func pendingURL(for context: WKWebExtensionContext) -> URL? { pendingURL }

    func parentTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { openerTab }

    func setParentTab(_ parentTab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        openerTab = parentTab as? Tab
        completionHandler(nil)
    }

    func detectWebpageLocale(for context: WKWebExtensionContext, completionHandler: @escaping (Locale?, (any Error)?) -> Void) {
        guard let webView else { completionHandler(nil, nil); return }
        // WebKit has no public page-language detector: read a slice of the page's text and detect
        // its dominant language, falling back to the page's declared `lang`.
        let script = "(function(){var t=document.body?document.body.innerText:'';return{lang:document.documentElement.lang||'',text:t.slice(0,4000)};})()"
        webView.evaluateJavaScript(script) { result, _ in
            var identifier: String?
            if let info = result as? [String: Any] {
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(info["text"] as? String ?? "")
                identifier = recognizer.dominantLanguage?.rawValue
                if identifier == nil, let lang = info["lang"] as? String, !lang.isEmpty { identifier = lang }
            }
            completionHandler(identifier.map { Locale(identifier: $0) }, nil)
        }
    }

    func takeSnapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext, completionHandler: @escaping (NSImage?, (any Error)?) -> Void) {
        guard let webView else { completionHandler(nil, nil); return }
        webView.takeSnapshot(with: configuration) { image, error in
            completionHandler(image, error)
        }
    }

    func duplicate(
        using configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard let browser else { completionHandler(nil, nil); return }
        let parent = configuration.parentTab as? Tab
        let index = configuration.index == NSNotFound ? nil : configuration.index
        let copy = browser.duplicate(
            self, select: configuration.shouldBeActive, extensionIndex: index,
            pinned: configuration.shouldBePinned, opener: parent ?? self
        )
        copy?.readerModeRequested = configuration.shouldReaderModeBeActive
        if configuration.shouldBeMuted { copy?.setMuted(true) }
        completionHandler(copy, nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        browser?.close(self, force: true)
        completionHandler(nil)
    }

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    // Reader mode (`tabs.toggleReaderMode`, `isArticle`, `isInReaderMode`).
    func isReaderModeAvailable(for context: WKWebExtensionContext) -> Bool { reader != nil || canUseReader }

    func isReaderModeActive(for context: WKWebExtensionContext) -> Bool { reader != nil }

    func setReaderModeActive(_ active: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        readerModeRequested = active
        if active { openReader() } else { closeReader() }
        completionHandler(nil)
    }
}

// MARK: - The browser window as seen by extensions (browser.windows.*)

final class BrowserWindowAdapter: NSObject {
    var browser: BrowserState { .shared }
}

extension BrowserWindowAdapter: WKWebExtensionWindow {
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { browser.allTabs }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { browser.selectedTab }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = browser.window else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        if window.isMiniaturized { return .minimized }
        return .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        browser.window?.screen?.frame ?? NSScreen.main?.frame ?? .zero
    }

    func frame(for context: WKWebExtensionContext) -> CGRect { browser.window?.frame ?? .zero }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        browser.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        completionHandler(nil)
    }

    func setWindowState(_ state: WKWebExtension.WindowState, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let window = browser.window else { completionHandler(nil); return }
        switch state {
        case .minimized:
            window.miniaturize(nil)
        case .maximized:
            if !window.isZoomed { window.zoom(nil) }
        case .fullscreen:
            if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        case .normal:
            if window.isMiniaturized { window.deminiaturize(nil) }
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            else if window.isZoomed { window.zoom(nil) }
        @unknown default:
            break
        }
        completionHandler(nil)
    }

    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let window = browser.window, !frame.isNull, frame.width > 0, frame.height > 0 else {
            completionHandler(nil)
            return
        }
        // Same screen-coordinate convention as frame(for:) above, so a get/set round-trips.
        window.setFrame(frame, display: true)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        // Tuff has a single window: closing it closes the browser window. The session is kept and
        // the window returns from the Dock (the app doesn't quit on last-window-close), so no tabs
        // are destroyed.
        browser.window?.performClose(nil)
        completionHandler(nil)
    }
}

// MARK: - "Add to Tuff" on the extension stores

/// The Chrome Web Store and Firefox Add-ons only offer installs to their own browsers. On an
/// extension's page this swaps the store's own "Add to Chrome" / "Add to Firefox" button (which
/// is disabled, or replaced by a "get Firefox" link, in other browsers) for one that reads
/// "Add to Tuff" — or "Remove from Tuff" once installed — and forwards clicks to `ExtensionManager`.
///
/// The script runs in its own content world, so the store's scripts can't see or call the bridge.
enum ExtensionStoreBridge {
    static let handlerName = "tuffStore"
    private static let world = WKContentWorld.world(name: "TuffStore")
    private static let handler = StoreMessageHandler()

    static func install(into controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        controller.addScriptMessageHandler(handler, contentWorld: world, name: handlerName)
    }

    private static let script = #"""
    (function () {
      var host = location.hostname;
      var isChrome = host === 'chromewebstore.google.com';
      var isFirefox = host === 'addons.mozilla.org';
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tuffStore;
      if ((!isChrome && !isFirefox) || !bridge || window.__tuffStore) return;
      window.__tuffStore = true;

      var LABELS = { absent: 'Add to Tuff', installed: 'Remove from Tuff', adding: 'Adding…', removing: 'Removing…' };
      var states = {};     // "store:id" -> 'absent' | 'installed'
      var busy = {};       // "store:id" -> 'adding' | 'removing'
      var asking = {};
      var ours = null;     // our copy of the store's button
      var original = null; // the store's button, kept hidden while ours is shown

      function current() {
        if (isChrome) {
          var m = location.pathname.match(/\/detail\/(?:[^\/]+\/)?([a-p]{32})(?:[\/?#]|$)/);
          return m ? { store: 'chrome', id: m[1] } : null;
        }
        var f = location.pathname.match(/\/(?:firefox|android)\/addon\/([^\/]+)/);
        return f ? { store: 'firefox', id: decodeURIComponent(f[1]) } : null;
      }
      function keyOf(info) { return info.store + ':' + info.id; }

      // The store's install button for the extension on this page.
      function storeButton() {
        if (isChrome) {
          // "Add to Chrome" (disabled outside Chrome). The "Switch to Chrome" banner's button
          // carries an aria-label; the install button doesn't. "Chrome" isn't translated.
          var buttons = document.querySelectorAll('button');
          for (var i = 0; i < buttons.length; i++) {
            var b = buttons[i];
            if (b.hasAttribute('data-tuff') || b.hasAttribute('aria-label')) continue;
            var text = (b.textContent || '').trim();
            if (text.length < 40 && /Chrome/.test(text)) return b;
          }
          return null;
        }
        // Themes can't be used in Tuff, so leave their pages alone.
        if (document.querySelector('.Addon-statictheme, .Addon-theme')) return null;
        return document.querySelector('.GetFirefoxButton-button');
      }

      // Hide the "Switch to Chrome to install extensions" banner: the box around its button,
      // as far out as it stays small (so we never hide the section holding the install button).
      function hideChromeBanner() {
        var buttons = document.querySelectorAll('button[aria-label]');
        for (var i = 0; i < buttons.length; i++) {
          var b = buttons[i];
          if (!/Chrome/.test(b.getAttribute('aria-label')) || b.closest('[data-tuff-hidden]')) continue;
          var box = b;
          while (box.parentElement && box.parentElement !== document.body
                 && box.parentElement.offsetHeight < 120
                 && !(ours && box.parentElement.contains(ours))) {
            box = box.parentElement;
          }
          if (box !== b) { box.setAttribute('data-tuff-hidden', ''); box.style.display = 'none'; }
        }
      }

      // Deepest element that holds the button's text, so the store's styling stays intact.
      function labelNode(el) {
        var best = el;
        el.querySelectorAll('*').forEach(function (n) {
          if (n.children.length === 0 && (n.textContent || '').trim()) best = n;
        });
        return best;
      }

      function strip(el) {
        ['jscontroller', 'jsaction', 'jsname', 'jslog', 'soy-skip', 'ssk', 'disabled', 'aria-disabled',
         'aria-describedby', 'href', 'target'].forEach(function (a) { el.removeAttribute(a); });
        for (var i = 0; i < el.children.length; i++) strip(el.children[i]);
      }

      function build(from) {
        var copy = from.cloneNode(true);
        strip(copy);
        copy.setAttribute('data-tuff', '');
        copy.setAttribute('role', 'button');
        copy.setAttribute('tabindex', '0');
        copy.style.cursor = 'pointer';
        copy.addEventListener('click', onClick, true);
        copy.addEventListener('keydown', function (e) { if (e.key === 'Enter' || e.key === ' ') onClick(e); }, true);
        return copy;
      }

      function onClick(e) {
        e.preventDefault();
        e.stopPropagation();
        var info = current();
        if (!info) return;
        var key = keyOf(info);
        if (busy[key] || !states[key]) return;
        var removing = states[key] === 'installed';
        busy[key] = removing ? 'removing' : 'adding';
        render();
        bridge.postMessage({ action: removing ? 'remove' : 'install', store: info.store, id: info.id }).then(function (state) {
          if (state) states[key] = state;
        }, function () {}).then(function () { delete busy[key]; render(); });
      }

      // force: check again even if known (keeps showing the old label meanwhile).
      function ask(info, force) {
        var key = keyOf(info);
        if ((states[key] && !force) || asking[key]) return;
        asking[key] = true;
        bridge.postMessage({ action: 'state', store: info.store, id: info.id }).then(function (state) {
          states[key] = state || 'absent';
        }, function () {}).then(function () { delete asking[key]; render(); });
      }

      function render() {
        var info = current();
        var button = info && storeButton();
        if (!info || !button) {
          if (ours) { ours.remove(); ours = null; }
          if (original) { original.style.display = ''; original = null; }
          return;
        }
        if (isChrome) hideChromeBanner();
        if (isFirefox) {
          var download = document.querySelector('.InstallButtonWrapper-download');
          if (download) download.style.display = 'none';
        }
        var key = keyOf(info);
        ask(info);

        // The store re-renders its button now and then; follow it.
        if (!ours || !ours.isConnected || original !== button || ours.previousElementSibling !== button) {
          if (ours) ours.remove();
          ours = build(button);
          original = button;
          button.insertAdjacentElement('afterend', ours);
        }
        if (button.style.display !== 'none') button.style.display = 'none';

        var label = LABELS[busy[key] || states[key] || 'absent'];
        var node = labelNode(ours);
        if (node.textContent !== label) node.textContent = label;
        ours.style.opacity = (busy[key] || !states[key]) ? '0.6' : '';
        ours.setAttribute('aria-label', label);
      }

      // Installs and removals made elsewhere (Settings) show up when the page is looked at again.
      function recheck() { var info = current(); if (info) ask(info, true); }
      document.addEventListener('visibilitychange', function () {
        if (document.visibilityState === 'visible') recheck();
      });
      window.addEventListener('focus', recheck);

      render();
      new MutationObserver(function () { render(); }).observe(document.documentElement, { childList: true, subtree: true });
      setInterval(render, 1000);
    })();
    """#
}

final class StoreMessageHandler: NSObject {}

extension StoreMessageHandler: WKScriptMessageHandlerWithReply {
    @MainActor
    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        // Only the store pages themselves (top frame) may ask.
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let action = body["action"] as? String,
              let store = body["store"] as? String,
              let id = body["id"] as? String else { return (nil, "bad request") }
        let host = message.frameInfo.securityOrigin.host
        let manager = ExtensionManager.shared

        let source: ExtensionManager.InstallSource
        switch store {
        case "chrome" where host == "chromewebstore.google.com":
            guard id.range(of: "^[a-p]{32}$", options: .regularExpression) != nil else { return (nil, "bad id") }
            source = .chrome(id: id)
        case "firefox" where host == "addons.mozilla.org":
            guard id.count < 200, id.range(of: "^[A-Za-z0-9._@{}+-]+$", options: .regularExpression) != nil else { return (nil, "bad id") }
            source = .firefox(slug: id)
        default:
            return (nil, "not a store page")
        }

        func state() -> String { manager.record(store: store, id: id) == nil ? "absent" : "installed" }

        switch action {
        case "state":
            break
        case "install":
            if manager.record(store: store, id: id) == nil { await manager.installNow(source) }
        case "remove":
            if let record = manager.record(store: store, id: id) { _ = await manager.confirmUninstall(id: record.id) }
        default:
            return (nil, "unknown action")
        }
        return (state(), nil)
    }
}
