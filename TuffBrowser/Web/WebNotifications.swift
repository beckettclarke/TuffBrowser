import AppKit
import UniformTypeIdentifiers
import UserNotifications
import WebKit

/// Website notifications (`new Notification(…)`, `Notification.requestPermission()`).
///
/// WebKit has no public API for them: in an app other than Safari, pages either find no
/// `Notification` at all or one that is always denied. So a script in every frame puts in its
/// own `Notification` (plus `navigator.permissions.query({name: 'notifications'})` and a
/// service worker registration's `showNotification`) that hands everything to Tuff:
///
/// - Asking goes through the permission card over the tab, like camera and location, and the
///   answer is kept in `SitePermissions`. As in Safari, a page can only ask from a click or
///   key press, so sites can't throw the card up on load.
/// - `Notification.permission` must answer synchronously, which a message to the app can't. The
///   script reads it with a `prompt()` carrying `permissionQuery`; `Tab` answers that one from
///   the saved choices without showing anything (see `runJavaScriptTextInputPanelWithPrompt`).
/// - Notifications are posted to Notification Center. Clicking one brings its tab forward and
///   fires the page's `click` event; dismissing it fires `close`.
///
/// Push messages (a site notifying you while it isn't open) still aren't possible: that needs
/// WebKit's Web Push, which is only available to Safari.
@MainActor
final class WebNotifications: NSObject {
    static let shared = WebNotifications()
    nonisolated static let handlerName = "tuffNotify"
    /// What the page script passes to `prompt()` to read its permission.
    nonisolated static let permissionQuery = "\u{1F}tuff:notification-permission"
    nonisolated private static let idPrefix = "tuff.web."
    nonisolated private static let category = "tuff.web"

    private let center = UNUserNotificationCenter.current()

    /// Where a notification on screen came from, so a click can find its page.
    private struct Route {
        weak var tab: Tab?
        weak var webView: WKWebView?
        let frame: WKFrameInfo
        let pageID: String
    }
    private var routes: [String: Route] = [:]
    private var warnedSystemOff = false

    private override init() {
        super.init()
        // `ExtensionNotifications` is the notification center's delegate; it hands our
        // notifications' clicks back to `handle(_:)`.
        _ = ExtensionNotifications.shared
        let id = Self.category
        let category = UNNotificationCategory(identifier: id, actions: [], intentIdentifiers: [], options: .customDismissAction)
        center.getNotificationCategories { existing in
            let others = existing.filter { $0.identifier != id }
            UNUserNotificationCenter.current().setNotificationCategories(others.union([category]))
        }
    }

    nonisolated static func install(into controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        controller.addScriptMessageHandler(MessageHandler(), contentWorld: .page, name: handlerName)
    }

    nonisolated static func isWebNotification(_ identifier: String) -> Bool { identifier.hasPrefix(idPrefix) }

    /// The page's `Notification.permission`: "granted", "denied" or "default".
    nonisolated static func permission(for frame: WKFrameInfo, in tab: Tab) -> String {
        // Like Safari and Chrome, Incognito windows don't get notifications.
        if tab.browser?.isPrivate == true { return "denied" }
        switch SitePermissions.shared.decision(origin: SitePermissions.origin(of: frame.securityOrigin), kind: .notifications, incognito: false) {
        case true?: return "granted"
        case false?: return "denied"
        case nil: return "default"
        }
    }

    // MARK: Page messages

    private final class MessageHandler: NSObject, WKScriptMessageHandlerWithReply {
        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
            replyHandler: @escaping (Any?, String?) -> Void
        ) {
            MainActor.assumeIsolated {
                WebNotifications.shared.receive(message) { replyHandler($0, nil) }
            }
        }
    }

    private func receive(_ message: WKScriptMessage, reply: @escaping (String) -> Void) {
        guard let tab = (message.webView as? TuffWebView)?.tab,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { reply("error"); return }
        let frame = message.frameInfo
        let host = frame.securityOrigin.host
        switch type {
        case "request":
            requestPermission(host: host, frame: frame, tab: tab, reply: reply)
        case "show":
            guard Self.permission(for: frame, in: tab) == "granted" else { reply("error"); return }
            Task { reply(await show(body, host: host, frame: frame, tab: tab, webView: message.webView) ? "shown" : "error") }
        case "close":
            if let pageID = body["id"] as? String {
                let ids = routes.filter { $0.value.frame.webView === message.webView && $0.value.pageID == pageID }.map(\.key)
                center.removeDeliveredNotifications(withIdentifiers: ids)
                ids.forEach { routes[$0] = nil }
            }
            reply("closed")
        default:
            reply("error")
        }
    }

    private func requestPermission(host: String, frame: WKFrameInfo, tab: Tab, reply: @escaping (String) -> Void) {
        let current = Self.permission(for: frame, in: tab)
        guard current == "default" else { reply(current); return }
        // A frame from another site can't ask (Chrome's rule too): the card names one site.
        guard !host.isEmpty, frame.isMainFrame || host == tab.url?.host(percentEncoded: false) else {
            reply("default")
            return
        }
        tab.askPermission(origin: frame.securityOrigin, kind: .notifications) { [weak self, weak tab] granted in
            guard let granted else { reply("default"); return }
            reply(granted ? "granted" : "denied")
            if granted, let self { Task { await self.checkSystemPermission(host: host, browser: tab?.browser) } }
        }
    }

    // MARK: Posting

    private func show(_ body: [String: Any], host: String, frame: WKFrameInfo, tab: Tab, webView: WKWebView?) async -> Bool {
        guard await systemAllows() else {
            ExtensionManager.shared.trace("web notification from \(host) dropped: macOS has Tuff's notifications off")
            return false
        }
        guard let pageID = body["id"] as? String else { return false }
        let content = UNMutableNotificationContent()
        content.title = (body["title"] as? String) ?? ""
        content.subtitle = host
        content.body = (body["body"] as? String) ?? ""
        content.threadIdentifier = host
        content.categoryIdentifier = Self.category
        if body["silent"] as? Bool != true { content.sound = .default }
        if let icon = (body["icon"] as? String).flatMap(URL.init(string:)), let attachment = await attachment(from: icon) {
            content.attachments = [attachment]
        }
        // Same site + same tag replaces the one already shown, as the spec asks.
        let tag = (body["tag"] as? String) ?? ""
        let identifier = Self.idPrefix + (tag.isEmpty ? UUID().uuidString : "\(host)|\(tag)")
        routes[identifier] = Route(tab: tab, webView: webView, frame: frame, pageID: pageID)
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            return true
        } catch {
            ExtensionManager.shared.trace("web notification from \(host) failed: \(error.localizedDescription)")
            routes[identifier] = nil
            return false
        }
    }

    /// The notification's icon, downloaded to a file Notification Center can show.
    private func attachment(from url: URL) async -> UNNotificationAttachment? {
        guard ["http", "https", "data"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.setValue(WebEngine.userAgentApplicationName, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              data.count < 2_000_000, NSImage(data: data) != nil else { return nil }
        let type = response.mimeType.flatMap { UTType(mimeType: $0) } ?? .png
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("tuff-notification-\(UUID().uuidString)")
            .appendingPathExtension(type.preferredFilenameExtension ?? "png")
        guard (try? data.write(to: file)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "icon", url: file, options: [UNNotificationAttachmentOptionsTypeHintKey: type.identifier])
    }

    // MARK: macOS permission

    /// Whether macOS lets Tuff post notifications at all, asking the first time.
    private func systemAllows() async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined:
            do { return try await center.requestAuthorization(options: [.alert, .sound]) } catch {
                ExtensionManager.shared.trace("notification authorization failed: \(error.localizedDescription)")
                return false
            }
        default: return false
        }
    }

    /// After a site is allowed: asks macOS too, and says so (once per launch) if it has
    /// Tuff's notifications turned off, since the site's would then go nowhere.
    private func checkSystemPermission(host: String, browser: BrowserState?) async {
        guard !(await systemAllows()), !warnedSystemOff else { return }
        warnedSystemOff = true
        let open = await PromptPresenter.present(Prompt(
            browser: browser,
            symbol: "bell.slash.fill",
            symbolColor: .systemOrange,
            title: "Notifications are off for Tuff",
            message: "\(host) is allowed to send you notifications, but macOS is blocking all of Tuff’s. Turn them on in System Settings › Notifications.",
            confirmTitle: "Open System Settings",
            cancelTitle: "Not Now"
        ))
        guard open else { return }
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Clicks

    /// A click on (or dismissal of) one of our notifications, from the notification center's delegate.
    func handle(_ response: UNNotificationResponse) {
        let identifier = response.notification.request.identifier
        let route = routes.removeValue(forKey: identifier)
        let dismissed = response.actionIdentifier == UNNotificationDismissActionIdentifier
        if !dismissed {
            NSApp.activate()
            if let tab = route?.tab, let browser = tab.browser {
                browser.select(tab)
                browser.window?.makeKeyAndOrderFront(nil)
            }
        }
        guard let route, let webView = route.webView else { return }
        webView.callAsyncJavaScript(
            "return window.__tuffNotify ? window.__tuffNotify(id, type) : false",
            arguments: ["id": route.pageID, "type": dismissed ? "close" : "click"],
            in: route.frame, in: .page
        ) { _ in }
    }

    // MARK: Page script

    nonisolated private static let script = """
    (function () {
      if (window.__tuffNotify) return;
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
      if (!bridge) return;
      var send = function (m) { return bridge.postMessage(m); };
      var ask = window.prompt;
      var QUERY = \(jsString(permissionQuery));
      var cached = null;
      function permission() {
        if (cached === null) {
          var answer = null;
          try { answer = ask.call(window, QUERY); } catch (e) {}
          cached = (answer === 'granted' || answer === 'denied') ? answer : 'default';
        }
        return cached;
      }

      var state = new WeakMap();
      var live = new Map();
      var nextID = 0;
      var TYPES = ['click', 'show', 'error', 'close'];
      function absolute(u) { try { return u ? new URL(String(u), location.href).href : ''; } catch (e) { return ''; } }
      function text(v) { return v == null ? '' : String(v); }
      function fire(n, type) { n.dispatchEvent(new Event(type, { cancelable: type === 'click' })); }

      class Notification extends EventTarget {
        constructor(title, options) {
          if (arguments.length < 1) throw new TypeError("Failed to construct 'Notification': 1 argument required, but only 0 present.");
          super();
          options = options || {};
          var s = {
            id: 'n' + (++nextID), title: String(title), body: text(options.body), tag: text(options.tag),
            lang: text(options.lang), dir: options.dir || 'auto', icon: absolute(options.icon),
            badge: absolute(options.badge), image: absolute(options.image),
            data: options.data === undefined ? null : options.data,
            silent: options.silent == null ? null : !!options.silent,
            requireInteraction: !!options.requireInteraction, renotify: !!options.renotify,
            timestamp: typeof options.timestamp === 'number' ? options.timestamp : Date.now(),
            actions: Object.freeze([]), handlers: {}
          };
          state.set(this, s);
          var self = this;
          TYPES.forEach(function (type) {
            self.addEventListener(type, function (e) {
              var h = s.handlers[type];
              if (typeof h === 'function') h.call(self, e);
            });
          });
          if (permission() !== 'granted') { setTimeout(function () { fire(self, 'error'); }, 0); return; }
          live.set(s.id, this);
          var failed = function () { live.delete(s.id); fire(self, 'error'); };
          send({ type: 'show', id: s.id, title: s.title, body: s.body, tag: s.tag, icon: s.icon || s.image, silent: s.silent === true })
            .then(function (r) { if (r === 'shown') fire(self, 'show'); else failed(); }, failed);
        }
        close() {
          var s = state.get(this);
          if (!s || !live.has(s.id)) return;
          live.delete(s.id);
          send({ type: 'close', id: s.id }).catch(function () {});
          fire(this, 'close');
        }
        static get permission() { return permission(); }
        static get maxActions() { return 0; }
        static requestPermission(callback) {
          var done = function (result) {
            cached = result;
            if (typeof callback === 'function') { try { callback(result); } catch (e) { setTimeout(function () { throw e; }, 0); } }
            return result;
          };
          var current = permission();
          if (current !== 'default') return Promise.resolve(done(current));
          // As in Safari: only from a click or key press.
          var activation = navigator.userActivation;
          if (activation && !activation.isActive) return Promise.resolve(done('default'));
          return send({ type: 'request' }).then(function (r) {
            return done(r === 'granted' || r === 'denied' ? r : 'default');
          }, function () { return done('default'); });
        }
      }
      ['title', 'body', 'tag', 'lang', 'dir', 'icon', 'badge', 'image', 'data', 'silent',
       'requireInteraction', 'renotify', 'timestamp', 'actions'].forEach(function (name) {
        Object.defineProperty(Notification.prototype, name, {
          get: function () { var s = state.get(this); return s ? s[name] : undefined; },
          enumerable: true, configurable: true
        });
      });
      TYPES.forEach(function (type) {
        Object.defineProperty(Notification.prototype, 'on' + type, {
          get: function () { var s = state.get(this); return (s && s.handlers[type]) || null; },
          set: function (v) { var s = state.get(this); if (s) s.handlers[type] = typeof v === 'function' ? v : null; },
          enumerable: true, configurable: true
        });
      });
      Object.defineProperty(window, 'Notification', { value: Notification, writable: true, configurable: true });

      // Called by Tuff when a notification is clicked or dismissed.
      Object.defineProperty(window, '__tuffNotify', {
        value: function (id, type) {
          var n = live.get(id);
          if (!n) return false;
          live.delete(id);
          fire(n, type === 'click' ? 'click' : 'close');
          return true;
        }
      });

      var perms = navigator.permissions;
      if (perms && perms.query) {
        var query = perms.query.bind(perms);
        perms.query = function (desc) {
          if (desc && desc.name === 'notifications') {
            var p = permission();
            var status = new EventTarget();
            Object.defineProperties(status, {
              name: { value: 'notifications', enumerable: true },
              state: { value: p === 'default' ? 'prompt' : p, enumerable: true },
              onchange: { value: null, writable: true, enumerable: true }
            });
            return Promise.resolve(status);
          }
          return query(desc);
        };
      }

      if (window.ServiceWorkerRegistration) {
        var proto = ServiceWorkerRegistration.prototype;
        proto.showNotification = function (title, options) {
          if (permission() !== 'granted') {
            return Promise.reject(new TypeError('No notification permission has been granted for this origin.'));
          }
          new Notification(title, options);
          return Promise.resolve();
        };
        proto.getNotifications = function (filter) {
          var tag = filter && filter.tag;
          var list = [];
          live.forEach(function (n) { if (!tag || n.tag === tag) list.push(n); });
          return Promise.resolve(list);
        };
      }
    })();
    """

    nonisolated private static func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}
