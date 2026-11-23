import AppKit
import WebKit

/// Firefox's `menus.onShown`, `menus.onHidden`, `menus.getTargetElement`, and
/// `menus.overrideContext` support.
///
/// Only installs its lightweight `contextmenu` capture script when at least one extension
/// subscribes to `menus.onShown` (zero cost on pages otherwise).
final class ExtensionMenus: NSObject {
    static let shared = ExtensionMenus()

    static let messageHandlerName = "__tuffMenus"

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    struct CapturedTarget {
        let timestamp: Date
        let targetElementID: Int
        let editable: Bool
        let linkURL: String?
        let linkText: String?
        let srcURL: String?
        let mediaType: String?
        let selectionText: String?
        let frameURL: String?
    }

    struct ContextOverride: Equatable {
        let extensionID: String
        let context: String?       // "bookmark" or "tab"
        let bookmarkID: String?
        let tabIndex: Int?
        let showDefaults: Bool
        let timestamp: Date
    }

    struct CustomMenuItem: Equatable {
        var id: String
        var title: String
        var contexts: [String]
        var enabled: Bool
        var type: String
    }

    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private var installedScript: WKUserScript?
    private var monitoring = false
    /// Most recent right-click hit test per web view.
    private var captures: [ObjectIdentifier: CapturedTarget] = [:]
    /// Pending `menus.overrideContext(...)` from a `contextmenu` handler in an extension page.
    private(set) var pendingOverride: ContextOverride?
    /// Custom extension menu items registered for `"tab"` or `"bookmark"` contexts (which WebKit doesn't show on its own).
    private var customItems: [String: [CustomMenuItem]] = [:]
    /// Whether an open context menu triggered `menus.onShown` (so `didCloseMenu` emits `onHidden`).
    private var menuShowing = false

    private override init() { super.init() }

    func attach(_ controller: WKUserContentController) {
        controllers.add(controller)
        if monitoring { install(into: controller) }
    }

    func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        let script = WKUserScript(source: Self.captureScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: WebEngine.scriptWorld)
        installedScript = script
        for controller in controllers.allObjects {
            install(into: controller)
        }
        for tab in BrowserState.shared.allTabs {
            guard let webView = tab.webView, tab.hostExtension == nil else { continue }
            webView.evaluateJavaScript(Self.captureScript, in: nil, in: WebEngine.scriptWorld) { _ in }
        }
    }

    private func install(into controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: Self.messageHandlerName, contentWorld: WebEngine.scriptWorld)
        controller.add(self, contentWorld: WebEngine.scriptWorld, name: Self.messageHandlerName)
        if let script = installedScript {
            controller.addUserScript(script)
        }
    }

    func extensionUnloaded(_ extensionID: String) {
        customItems.removeValue(forKey: extensionID)
        if pendingOverride?.extensionID == extensionID { pendingOverride = nil }
    }

    // MARK: menus.overrideContext & custom tab/bookmark item tracking

    func overrideContext(_ options: [String: Any], extensionID: String) throws {
        let context = options["context"] as? String
        let showDefaults = options["showDefaults"] as? Bool ?? false
        var bookmarkID: String?
        var tabIndex: Int?

        if let context {
            switch context {
            case "bookmark":
                guard let id = options["bookmarkId"] as? String, !id.isEmpty else {
                    throw Failure("menus.overrideContext with context 'bookmark' requires bookmarkId.")
                }
                bookmarkID = id
            case "tab":
                guard let index = options["tabIndex"] as? Int else {
                    throw Failure("menus.overrideContext with context 'tab' requires tabId.")
                }
                tabIndex = index
            default:
                throw Failure("Unsupported menus.overrideContext context '\(context)'.")
            }
        } else {
            if options["bookmarkId"] != nil || options["tabIndex"] != nil {
                throw Failure("context must be specified when bookmarkId or tabId is provided.")
            }
        }

        pendingOverride = ContextOverride(
            extensionID: extensionID,
            context: context,
            bookmarkID: bookmarkID,
            tabIndex: tabIndex,
            showDefaults: showDefaults,
            timestamp: Date()
        )
    }

    /// Consumes a fresh pending override for `extensionID` (within 2 seconds).
    func consumeOverride(for extensionID: String) -> ContextOverride? {
        guard let pending = pendingOverride,
              pending.extensionID == extensionID,
              Date().timeIntervalSince(pending.timestamp) < 2.0 else {
            return nil
        }
        pendingOverride = nil
        return pending
    }

    func registerItem(_ props: [String: Any], extensionID: String) {
        let contexts = props["contexts"] as? [String] ?? []
        guard contexts.contains("tab") || contexts.contains("bookmark") || contexts.contains("all") else { return }
        let id = (props["id"] as? String) ?? UUID().uuidString
        let item = CustomMenuItem(
            id: id,
            title: props["title"] as? String ?? "",
            contexts: contexts,
            enabled: props["enabled"] as? Bool ?? true,
            type: props["type"] as? String ?? "normal"
        )
        var list = customItems[extensionID] ?? []
        if let idx = list.firstIndex(where: { $0.id == id }) {
            list[idx] = item
        } else {
            list.append(item)
        }
        customItems[extensionID] = list
    }

    func removeItem(id: String?, extensionID: String) {
        if let id {
            customItems[extensionID]?.removeAll { $0.id == id }
        } else {
            customItems.removeValue(forKey: extensionID)
        }
    }

    func customItems(for context: String) -> [(extensionID: String, items: [CustomMenuItem])] {
        customItems.compactMap { extID, list in
            let matched = list.filter { $0.contexts.contains(context) }
            return matched.isEmpty ? nil : (extID, matched)
        }
    }

    /// Applies an active `menus.overrideContext` to `menu` before showing it.
    /// Returns the override that was applied (so `menuWillOpen` reports the overridden context to `menus.onShown`).
    @discardableResult
    func applyContextOverride(_ menu: NSMenu, in webView: WKWebView) -> ContextOverride? {
        guard let pageURL = webView.url,
              let extID = ExtensionManager.shared.context(forPage: pageURL)?.uniqueIdentifier,
              let override = consumeOverride(for: extID) else {
            return nil
        }
        if !override.showDefaults {
            menu.removeAllItems()
        }
        guard let ctx = override.context else { return override }

        if override.showDefaults {
            if ctx == "tab", let tabIndex = override.tabIndex, BrowserState.shared.allTabs.indices.contains(tabIndex) {
                let targetTab = BrowserState.shared.allTabs[tabIndex]
                addDefaultTabItems(to: menu, tab: targetTab)
            } else if ctx == "bookmark", let bookmarkID = override.bookmarkID {
                addDefaultBookmarkItems(to: menu, bookmarkID: bookmarkID)
            }
        }

        let extraGroups = customItems(for: ctx)
        if !extraGroups.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for (itemExtID, items) in extraGroups {
                for item in items {
                    if item.type == "separator" {
                        menu.addItem(.separator())
                        continue
                    }
                    let menuItem = NSMenuItem(title: item.title, action: #selector(handleCustomMenuItem(_:)), keyEquivalent: "")
                    menuItem.identifier = NSUserInterfaceItemIdentifier(item.id)
                    menuItem.isEnabled = item.enabled
                    menuItem.target = self
                    menuItem.representedObject = CustomClickPayload(
                        extensionID: itemExtID,
                        menuItemID: item.id,
                        tabIndex: override.tabIndex,
                        bookmarkID: override.bookmarkID
                    )
                    menu.addItem(menuItem)
                }
            }
        }
        return override
    }

    private final class CustomClickPayload: NSObject {
        let extensionID: String
        let menuItemID: String
        let tabIndex: Int?
        let bookmarkID: String?
        init(extensionID: String, menuItemID: String, tabIndex: Int?, bookmarkID: String?) {
            self.extensionID = extensionID
            self.menuItemID = menuItemID
            self.tabIndex = tabIndex
            self.bookmarkID = bookmarkID
        }
    }

    @objc private func handleCustomMenuItem(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? CustomClickPayload else { return }
        var info: [String: Any] = [
            "menuItemId": payload.menuItemID,
            "editable": false,
        ]
        var extra: [String: Any] = [:]
        if let tabIndex = payload.tabIndex, BrowserState.shared.allTabs.indices.contains(tabIndex) {
            let tab = BrowserState.shared.allTabs[tabIndex]
            if let url = tab.url?.absoluteString { info["pageUrl"] = url }
            extra["menuTabIndex"] = tabIndex
        }
        if let bookmarkID = payload.bookmarkID {
            info["bookmarkId"] = bookmarkID
            if let profile = BrowserState.shared.bookmarksProfileID,
               let uuid = UUID(uuidString: bookmarkID),
               let bm = BookmarkStore.shared.bookmark(withID: uuid, profile: profile),
               let url = bm.url?.absoluteString {
                info["linkUrl"] = url
            }
        }
        ExtensionEventPush.shared.emit("menus.onCustomClicked", args: [info], extra: extra, to: payload.extensionID)
    }

    private func addDefaultTabItems(to menu: NSMenu, tab: Tab) {
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let reload = NSMenuItem(title: "Reload Tab", action: #selector(overrideReloadTab(_:)), keyEquivalent: "")
        reload.target = self
        reload.representedObject = tab
        menu.addItem(reload)

        let dup = NSMenuItem(title: "Duplicate Tab", action: #selector(overrideDuplicateTab(_:)), keyEquivalent: "")
        dup.target = self
        dup.representedObject = tab
        menu.addItem(dup)

        let mute = NSMenuItem(title: tab.isMuted ? "Unmute Tab" : "Mute Tab", action: #selector(overrideMuteTab(_:)), keyEquivalent: "")
        mute.target = self
        mute.representedObject = tab
        menu.addItem(mute)

        let close = NSMenuItem(title: "Close Tab", action: #selector(overrideCloseTab(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = tab
        menu.addItem(close)
    }

    private func addDefaultBookmarkItems(to menu: NSMenu, bookmarkID: String) {
        guard let profile = BrowserState.shared.bookmarksProfileID,
              let uuid = UUID(uuidString: bookmarkID),
              let bm = BookmarkStore.shared.bookmark(withID: uuid, profile: profile) else { return }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        if let url = bm.url {
            let open = NSMenuItem(title: "Open in New Tab", action: #selector(overrideOpenBookmark(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = url
            menu.addItem(open)

            let copy = NSMenuItem(title: "Copy Link", action: #selector(overrideCopyURL(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = url
            menu.addItem(copy)
        }
        let remove = NSMenuItem(title: "Delete", action: #selector(overrideDeleteBookmark(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = uuid
        menu.addItem(remove)
    }

    @objc private func overrideReloadTab(_ sender: NSMenuItem) {
        (sender.representedObject as? Tab)?.reload()
    }

    @objc private func overrideDuplicateTab(_ sender: NSMenuItem) {
        guard let tab = sender.representedObject as? Tab else { return }
        _ = BrowserState.shared.duplicate(tab)
    }

    @objc private func overrideMuteTab(_ sender: NSMenuItem) {
        guard let tab = sender.representedObject as? Tab else { return }
        tab.setMuted(!tab.isMuted)
    }

    @objc private func overrideCloseTab(_ sender: NSMenuItem) {
        guard let tab = sender.representedObject as? Tab else { return }
        BrowserState.shared.close(tab, force: true)
    }

    @objc private func overrideOpenBookmark(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        BrowserState.shared.newTab(url: url)
    }

    @objc private func overrideCopyURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc private func overrideDeleteBookmark(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? UUID,
              let profile = BrowserState.shared.bookmarksProfileID else { return }
        BookmarkStore.shared.remove(uuid, profile: profile)
    }

    /// Called from `TuffWebView.willOpenMenu(_:with:)` right after extension menu items are appended.
    func menuWillOpen(
        _ menu: NSMenu, in webView: WKWebView, tab: Tab?,
        extensionItems: [(extensionID: String, items: [NSMenuItem])]
    ) {
        let override = applyContextOverride(menu, in: webView)

        let push = ExtensionEventPush.shared
        guard push.isListening(to: ["menus.onShown", "menus.onHidden"]) else { return }
        menuShowing = true
        guard push.isListening(to: ["menus.onShown"]) else { return }

        let capture = captures[ObjectIdentifier(webView)].flatMap { Date().timeIntervalSince($0.timestamp) < 1.5 ? $0 : nil }
        let contexts: [String]
        if let ctx = override?.context {
            contexts = ["all", ctx]
        } else {
            contexts = Self.contexts(from: menu, capture: capture)
        }
        let pageURL = webView.url?.absoluteString ?? tab?.url?.absoluteString

        var baseInfo: [String: Any] = [
            "contexts": contexts,
            "editable": override?.context != nil ? false : (capture?.editable ?? contexts.contains("editable")),
            "viewType": tab == nil ? "sidebar" : "tab",
        ]
        if let bookmarkID = override?.bookmarkID { baseInfo["bookmarkId"] = bookmarkID }
        if let pageURL { baseInfo["pageUrl"] = pageURL }
        if let frameURL = capture?.frameURL ?? pageURL { baseInfo["frameUrl"] = frameURL }
        if let linkURL = capture?.linkURL { baseInfo["linkUrl"] = linkURL }
        if let linkText = capture?.linkText { baseInfo["linkText"] = linkText }
        if let srcURL = capture?.srcURL { baseInfo["srcUrl"] = srcURL }
        if let mediaType = capture?.mediaType { baseInfo["mediaType"] = mediaType }
        if let selectionText = capture?.selectionText, !selectionText.isEmpty { baseInfo["selectionText"] = selectionText }
        if let targetID = capture?.targetElementID, targetID > 0 { baseInfo["targetElementId"] = targetID }

        let itemsByExtension = Dictionary(uniqueKeysWithValues: extensionItems.map { ($0.extensionID, $0.items) })
        let tabIndex = override?.tabIndex ?? tab.flatMap { t in BrowserState.shared.allTabs.firstIndex { $0 === t } }

        for extID in ExtensionManager.shared.contexts.keys {
            guard push.isListening(extensionID: extID, to: "menus.onShown") else { continue }
            var info = baseInfo
            var ownedIDs = (itemsByExtension[extID] ?? []).map { item -> String in
                if let id = item.identifier?.rawValue, !id.isEmpty { return id }
                return item.title
            }
            if let ctx = override?.context {
                ownedIDs += (customItems[extID] ?? []).filter { $0.contexts.contains(ctx) }.map(\.id)
            }
            info["menuIds"] = ownedIDs
            var extra: [String: Any] = [:]
            if let tabIndex { extra["menuTabIndex"] = tabIndex }
            push.emit("menus.onShown", args: [info], extra: extra, to: extID)
        }
    }

    /// Called from `TuffWebView.didCloseMenu(_:with:)`.
    func menuDidClose() {
        guard menuShowing else { return }
        menuShowing = false
        ExtensionEventPush.shared.emit("menus.onHidden", args: [])
    }

    static func contexts(from menu: NSMenu, capture: CapturedTarget?) -> [String] {
        var set = Set<String>()
        set.insert("all")
        let identifiers = Set(menu.items.compactMap { $0.identifier?.rawValue })
        if capture?.linkURL != nil || identifiers.contains("WKMenuItemIdentifierOpenLink") || identifiers.contains("WKMenuItemIdentifierCopyLink") {
            set.insert("link")
        }
        if let media = capture?.mediaType {
            set.insert(media)
        } else if identifiers.contains("WKMenuItemIdentifierDownloadImage") || identifiers.contains("WKMenuItemIdentifierCopyImage") {
            set.insert("image")
        } else if identifiers.contains("WKMenuItemIdentifierOpenMediaInNewWindow") {
            set.insert("video")
        }
        if (capture?.selectionText?.isEmpty == false) || identifiers.contains("WKMenuItemIdentifierSearchWeb") {
            set.insert("selection")
        }
        if capture?.editable == true || identifiers.contains("WKMenuItemIdentifierPaste") {
            set.insert("editable")
        }
        if set.count == 1 { set.insert("page") }
        return set.sorted()
    }

    /// Computes the same positive 30-bit integer ID from `(clientX, clientY)` as the content-script
    /// `menus.getTargetElement` tracker in `ExtensionCompat.swift`.
    private static let captureScript = #"""
    (() => {
      if (window.__tuffMenusCapture) return;
      window.__tuffMenusCapture = true;
      document.addEventListener('contextmenu', (e) => {
        try {
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.__tuffMenus;
          if (!handler) return;
          const el = e.target instanceof Element ? e.target : (e.target && e.target.parentElement) || null;
          const x = Math.max(0, Math.round(e.clientX || 0)) & 0x7FFF;
          const y = Math.max(0, Math.round(e.clientY || 0)) & 0x7FFF;
          const targetElementId = ((x << 15) | y) || 1;
          const link = el && el.closest ? el.closest('a[href], area[href]') : null;
          const tag = el && el.tagName ? el.tagName.toLowerCase() : '';
          let mediaType = null, srcUrl = null;
          if (tag === 'img') { mediaType = 'image'; srcUrl = el.currentSrc || el.src || null; }
          else if (tag === 'video') { mediaType = 'video'; srcUrl = el.currentSrc || el.src || null; }
          else if (tag === 'audio') { mediaType = 'audio'; srcUrl = el.currentSrc || el.src || null; }
          const editable = !!(el && (el.isContentEditable || tag === 'textarea' || (tag === 'input' && !/^(button|submit|reset|checkbox|radio|file|image)$/i.test(el.type || ''))));
          const sel = window.getSelection ? String(window.getSelection() || '').trim() : '';
          handler.postMessage({
            targetElementId,
            editable,
            linkUrl: link ? link.href : null,
            linkText: link ? (link.textContent || '').trim().slice(0, 500) : null,
            srcUrl,
            mediaType,
            selectionText: sel ? sel.slice(0, 2000) : null,
            frameUrl: location.href,
          });
        } catch (err) {}
      }, { capture: true, passive: true });
    })();
    """#
}

extension ExtensionMenus: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, let body = message.body as? [String: Any] else { return }
        captures[ObjectIdentifier(webView)] = CapturedTarget(
            timestamp: Date(),
            targetElementID: body["targetElementId"] as? Int ?? 0,
            editable: body["editable"] as? Bool ?? false,
            linkURL: body["linkUrl"] as? String,
            linkText: body["linkText"] as? String,
            srcURL: body["srcUrl"] as? String,
            mediaType: body["mediaType"] as? String,
            selectionText: body["selectionText"] as? String,
            frameURL: body["frameUrl"] as? String
        )
    }
}
