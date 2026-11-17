import AppKit
import WebKit

/// Keeps a tab's icon in step with the page after it has loaded.
///
/// `FaviconStore.fetchIcon` looks for the page's icon once, when it finishes loading. Pages
/// that change it later — an unread count, a build status, a game drawn into the favicon with
/// a canvas — swap the `href` of their `<link rel=icon>` (or replace the link), which that never
/// sees. A script in the main frame (in its own content world) watches for those changes and
/// reports the icon that changed last.
enum LiveFavicon {
    static let handlerName = "tuffFavicon"
    static let world = WKContentWorld.world(name: "TuffFavicon")
    private static let handler = LiveFaviconMessageHandler()

    static func install(into controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        controller.add(handler, contentWorld: world, name: handlerName)
    }

    // Links the parser adds while the page loads are left to the load-time lookup; only an
    // `href` or `rel` changed by script before then is passed on at `load`. Afterwards any icon
    // link added or changed counts. Changes are batched to at most one report per 100 ms.
    // blob: addresses only mean something inside the page, so they're sent as data: ones.
    private static let script = #"""
    (function () {
      if (window.__tuffLiveIcon) return;
      window.__tuffLiveIcon = true;
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tuffFavicon;
      if (!bridge) return;

      var loaded = false, pending = null, last = null, timer = 0;

      function post(href) { try { bridge.postMessage(href); } catch (e) {} }

      function isIcon(node) {
        return node && node.nodeType === 1 && node.tagName === 'LINK' && /(^|\s)icon(\s|$)/i.test(node.rel || '');
      }

      function flush() {
        timer = 0;
        var href = pending;
        pending = null;
        if (!href || href === last) return;
        last = href;
        if (/^blob:/i.test(href)) {
          fetch(href).then(function (r) { return r.blob(); }).then(function (blob) {
            var reader = new FileReader();
            reader.onload = function () { if (typeof reader.result === 'string') post(reader.result); };
            reader.readAsDataURL(blob);
          }).catch(function () {});
          return;
        }
        post(href);
      }

      function changed(link) {
        if (!isIcon(link) || !link.href) return;
        pending = link.href;
        if (loaded && !timer) timer = setTimeout(flush, 100);
      }

      new MutationObserver(function (records) {
        for (var i = 0; i < records.length; i++) {
          var r = records[i];
          if (r.type === 'attributes') { changed(r.target); continue; }
          if (!loaded) continue;
          for (var j = 0; j < r.addedNodes.length; j++) {
            var n = r.addedNodes[j];
            if (isIcon(n)) changed(n);
            else if (n.nodeType === 1 && n.querySelectorAll) {
              var inner = n.querySelectorAll('link');
              for (var k = 0; k < inner.length; k++) changed(inner[k]);
            }
          }
        }
      }).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['href', 'rel'] });

      window.addEventListener('load', function () {
        loaded = true;
        if (pending && !timer) timer = setTimeout(flush, 100);
      });
    })();
    """#
}

final class LiveFaviconMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let tab = (message.webView as? TuffWebView)?.tab,
              let href = message.body as? String,
              let url = URL(string: href) else { return }
        tab.pageIconDidChange(to: url)
    }
}

extension Tab {
    /// The page changed its icon after loading (`LiveFavicon`).
    func pageIconDidChange(to iconURL: URL) {
        guard pdf == nil, !showingErrorPage, let page = webView?.url,
              page.scheme == "http" || page.scheme == "https" else { return }
        faviconRequest += 1
        let request = faviconRequest
        FaviconStore.shared.icon(at: iconURL, pageURL: page, persist: !(browser?.isPrivate ?? false)) { [weak self] image in
            guard let self, let image, request == self.faviconRequest else { return }
            self.favicon = image
            self.faviconHost = page.host(percentEncoded: false)?.lowercased()
        }
    }
}
