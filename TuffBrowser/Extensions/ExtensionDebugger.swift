import AppKit
import WebKit

/// `chrome.debugger`: the part of Chrome's DevTools protocol that extensions drive pages with
/// (browser agents such as TuffAgent, test recorders, automation). WebKit has no DevTools protocol
/// for extensions, so Tuff answers the commands itself, for tabs:
///
/// - `Input.*`: real AppKit mouse and key events handed to the tab's web view, so the page gets
///   trusted events as it does from Chrome. Text and editing commands (`insertText`, a key's
///   `commands`) go through WebKit's own editing commands.
/// - `Runtime.evaluate`: runs in the page's world. Script from the browser isn't bound by the
///   page's CSP, as in Chrome.
/// - `Page.*`: the page's dialogs (`javascriptDialogOpening`, `handleJavaScriptDialog`), load
///   events, navigation and screenshots.
/// - `Network.*`: requests as WebKit's resource-load delegate reports them (private API, the one
///   Safari's own tools use), only while an extension has the domain enabled.
/// - Drags: with `Input.setInterceptDrags`, a drag the page starts is handed to the extension
///   (`Input.dragIntercepted`) and played back with `Input.dispatchDragEvent`. Without it, a drag
///   begun by synthetic input is called off, as CDP mouse events never start a native drag in Chrome.
///
/// Typing needs the keyboard, so while an extension sends input the tab's page is the window's
/// first responder; the keyboard goes back where it was when the extension detaches. Anything
/// else is answered as Chrome answers an unknown method.
final class ExtensionDebugger {
    static let shared = ExtensionDebugger()

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }

        /// A protocol error, which Chrome reports as JSON with a code.
        static func protocolError(_ code: Int, _ message: String, data: String? = nil) -> Failure {
            var object: [String: Any] = ["code": code, "message": message]
            if let data { object["data"] = data }
            let json = (try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)).map { String(decoding: $0, as: UTF8.self) }
            return Failure(json ?? message)
        }
        static func notFound(_ method: String) -> Failure { protocolError(-32601, "'\(method)' wasn't found") }
        static func invalid(_ detail: String) -> Failure { protocolError(-32602, "Invalid parameters", data: detail) }
        static func server(_ message: String) -> Failure { protocolError(-32000, message) }
    }

    final class Session {
        let extensionID: String
        /// The extension's id for the tab (WebKit's), which events carry.
        let tabID: Int
        weak var tab: Tab?
        var pageEvents = false
        var network: NetworkObserver?
        var interceptDrags = false
        /// Whether `Emulation.setFocusEmulationEnabled` is turned on for this session.
        var focusEmulation = false
        /// Off-screen window keeping a background tab's web view alive, unthrottled and able to
        /// take real AppKit mouse / key / drag events without activating the tab or stealing focus.
        var backingWindow: DebuggerBackingWindow?
        /// The keyboard's owner before the page took it, to give it back on detach.
        weak var keyboardBefore: NSResponder?
        var tookKeyboard = false
        /// Answers the page's open dialog (`Page.handleJavaScriptDialog`).
        var answerDialog: ((Bool, String?) -> Void)?

        init(extensionID: String, tabID: Int, tab: Tab) {
            self.extensionID = extensionID
            self.tabID = tabID
            self.tab = tab
        }
    }

    private var sessions: [Session] = []
    /// Extensions whose control of tabs was shown this launch.
    private var announced: Set<String> = []
    /// Most recently observed full content-area size of the main browser window, used to size
    /// off-screen backing windows so CSS viewport coordinates match 1:1.
    private var lastViewportSize: NSSize = .zero

    // MARK: Synthetic events

    /// Key-downs Tuff made, until WebKit is done with them. WebKit hands a key the page didn't
    /// handle back to the app (`NSApp.sendEvent`); those are kept from Tuff's menus and noted here.
    private static var pendingKeys: [NSEvent] = []
    private static var unhandledKeys: [NSEvent] = []
    /// The latest mouse-downs Tuff made, to tell its own clicks from the user's.
    private static var recentMouseDowns: [NSEvent] = []
    private static var eventNumber = 1

    /// From `TuffApplication.sendEvent`: true for a synthetic key the page didn't handle, which
    /// must not reach Tuff's menus (⌘T, ⌘W…) as Chrome's CDP keys never reach Chrome's.
    static func swallowsReturnedKey(_ event: NSEvent) -> Bool {
        guard !pendingKeys.isEmpty, event.type == .keyDown, let index = pendingKeys.firstIndex(where: { $0 === event }) else { return false }
        unhandledKeys.append(pendingKeys.remove(at: index))
        return true
    }

    /// When the context menu a synthetic right-click asks for is expected by (WebKit opens it a
    /// moment later, with an event of its own).
    private static var contextMenuDue: TimeInterval = 0

    /// From `TuffWebView.willOpenMenu`: true for the menu of an extension's right-click, which
    /// isn't shown (the page still gets its `contextmenu` event); it would wait on screen for the
    /// user and hold up every event after it.
    static func takesContextMenu() -> Bool {
        guard contextMenuDue > ProcessInfo.processInfo.systemUptime else { return false }
        contextMenuDue = 0
        return true
    }

    /// Whether `event` is a mouse-down Tuff made for an extension (a native drag it starts goes
    /// to the extension or is called off).
    static func isSynthetic(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return recentMouseDowns.contains { $0 === event }
    }

    var isActive: Bool { !sessions.isEmpty }
    func isDebugging(_ tab: Tab) -> Bool { sessions.contains { $0.tab === tab } }
    var backingWindowCount: Int { sessions.compactMap(\.backingWindow).count }

    // MARK: attach / detach / getTargets

    func attach(_ args: [String: Any], context: WKWebExtensionContext) throws {
        let extensionID = context.uniqueIdentifier
        guard let tabID = args["tabId"] as? Int else { throw Failure("A tab id is required.") }
        if let version = args["version"] as? String, version.split(separator: ".").first != "1" {
            throw Failure("Requested protocol version is not supported: \(version).")
        }
        let tab = try ExtensionFind.tab(args["tabIndex"] ?? -1)
        guard tab.browser === BrowserState.shared, !(tab.browser?.isPrivate ?? true) else { throw Failure("No tab with given id \(tabID).") }
        if sessions.contains(where: { $0.tab === tab }) {
            throw Failure("Another debugger is already attached to the tab with id: \(tabID).")
        }
        let url = tab.url
        if InternalPage.isInternal(url) || (ExtensionManager.isExtensionPage(url) && ExtensionManager.shared.context(forPage: url) !== context) {
            throw Failure("Cannot access a \(url?.scheme ?? "browser")://  URL.")
        }
        if let url, !ExtensionManager.isExtensionPage(url), url.scheme != "about", !context.hasAccess(to: url, in: tab) {
            throw Failure("Cannot access contents of url \"\(url.absoluteString)\". Extension manifest must request permission to access this host.")
        }
        let session = Session(extensionID: extensionID, tabID: tabID, tab: tab)
        sessions.append(session)
        if let webView = tab.webView { ensureHosted(session, webView: webView) }
        if announced.insert(extensionID).inserted {
            let name = ExtensionManager.shared.records.first { $0.id == extensionID }?.name ?? "An extension"
            BrowserState.shared.show(Toast(symbol: "cursorarrow.rays", text: "\(name) is controlling this tab"))
        }
    }

    func detach(_ args: [String: Any], context: WKWebExtensionContext) throws {
        let session = try session(args, context: context)
        end(session)
    }

    func targets() -> [[String: Any]] {
        BrowserState.shared.allTabs.enumerated().map { index, tab in
            [
                "type": "page", "id": tab.id.uuidString, "tabIndex": index, "title": tab.title,
                "url": tab.url?.absoluteString ?? "", "attached": sessions.contains { $0.tab === tab },
            ]
        }
    }

    private func session(_ args: [String: Any], context: WKWebExtensionContext) throws -> Session {
        let tabID = args["tabId"] as? Int ?? -1
        return try session(tabID: tabID, extensionID: context.uniqueIdentifier)
    }

    private func session(tabID: Int, extensionID: String) throws -> Session {
        guard let session = sessions.first(where: { $0.extensionID == extensionID && $0.tabID == tabID }) else {
            throw Failure("Debugger is not attached to the tab with id: \(tabID).")
        }
        return session
    }

    private func session(for webView: WKWebView) -> Session? {
        sessions.first { $0.tab?.webView === webView }
    }

    private func end(_ session: Session, reason: String? = nil) {
        sessions.removeAll { $0 === session }
        session.answerDialog = nil
        let webView = session.tab?.webView
        if let webView, session.network != nil { Self.setResourceLoadDelegate(nil, on: webView) }
        session.network = nil
        session.focusEmulation = false
        releaseBackingWindow(for: session, webView: webView, restoreOcclusion: true)
        if let webView { giveKeyboardBack(session, webView) }
        if let reason {
            ExtensionEventPush.shared.emit("debugger.onDetach", args: [["tabId": session.tabID], reason], to: session.extensionID)
        }
    }

    func tabClosed(_ tab: Tab) {
        for session in sessions where session.tab === tab || session.tab == nil { end(session, reason: "target_closed") }
    }

    func extensionUnloaded(_ id: String) {
        for session in sessions where session.extensionID == id { end(session) }
        announced.remove(id)
    }

    /// Test-only entrypoints so unit tests can drive `ExtensionDebugger` without a live
    /// `WKWebExtensionContext`.
    func attachForTesting(tab: Tab, tabID: Int, extensionID: String = "test-ext") throws {
        if sessions.contains(where: { $0.tab === tab }) {
            throw Failure("Another debugger is already attached to the tab with id: \(tabID).")
        }
        let session = Session(extensionID: extensionID, tabID: tabID, tab: tab)
        sessions.append(session)
        if let webView = tab.webView { ensureHosted(session, webView: webView) }
    }

    func detachForTesting(tabID: Int, extensionID: String = "test-ext") throws {
        let session = try session(tabID: tabID, extensionID: extensionID)
        end(session)
    }

    func sendCommandForTesting(
        tabID: Int, extensionID: String = "test-ext", method: String, params: [String: Any] = [:],
        finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void
    ) throws {
        let session = try session(tabID: tabID, extensionID: extensionID)
        try executeCommand(method: method, params: params, session: session, finish: finish, fail: fail)
    }

    // MARK: Background tab hosting

    /// True when `webView` belongs to a debugger-attached tab that is not currently showing on
    /// screen in its browser window and therefore should live in an off-screen backing window.
    func needsBackgroundHost(_ webView: WKWebView) -> Bool {
        guard let session = session(for: webView), let tab = session.tab else { return false }
        return !(tab.browser?.isOnScreen(tab) ?? false)
    }

    /// Called by `WebStackView` when an outgoing debugger-attached web view leaves the browser
    /// window, moving it straight into its off-screen backing window without going windowless.
    func hostInBackground(_ webView: WKWebView, viewportSize: NSSize? = nil) {
        guard let session = session(for: webView) else { return }
        hostInBackground(session, webView: webView, viewportSize: viewportSize)
    }

    /// Called by `WebStackView` when a tab comes back onto screen: brackets reparenting into the
    /// browser window so WebKit doesn't report a transient windowless state, then tears down the
    /// temporary backing window.
    func returningToScreen(_ webView: WKWebView, attach: () -> Void) {
        guard let session = session(for: webView), let backing = session.backingWindow else {
            attach()
            return
        }
        session.backingWindow = nil
        if webView.window === backing {
            Self.deferWindowChange(webView) {
                attach()
            }
            if !session.focusEmulation {
                Self.setWindowOcclusionDetectionEnabled(true, on: webView)
            }
            backing.tearDown(detaching: nil)
        } else {
            attach()
            backing.tearDown(detaching: webView)
        }
    }

    /// Called from `Tab.tearDownWebView()` so a tab sleeping or recreating its web view never
    /// leaves an orphaned backing window behind.
    func webViewWillTearDown(_ webView: WKWebView) {
        for session in sessions where session.backingWindow != nil && (session.tab?.webView === webView || webView.window === session.backingWindow) {
            releaseBackingWindow(for: session, webView: webView, restoreOcclusion: true)
        }
    }

    /// Keeps background backing windows matched to the main browser window's content area size.
    func updateViewportSize(_ size: NSSize) {
        guard size.width > 0, size.height > 0 else { return }
        lastViewportSize = size
        for session in sessions {
            guard let backing = session.backingWindow else { continue }
            backing.resize(to: size)
            if let webView = session.tab?.webView, webView.superview === backing.contentView {
                webView.frame = NSRect(origin: .zero, size: size)
            }
        }
    }

    private func ensureHosted(_ session: Session, webView: WKWebView) {
        guard let tab = session.tab else { return }
        let onScreen = tab.browser?.isOnScreen(tab) ?? false
        if !onScreen || webView.window == nil {
            hostInBackground(session, webView: webView)
        }
    }

    private func hostInBackground(_ session: Session, webView: WKWebView, viewportSize: NSSize? = nil) {
        let size = resolvedViewportSize(explicit: viewportSize, webView: webView, tab: session.tab)
        let backing: DebuggerBackingWindow
        if let existing = session.backingWindow {
            backing = existing
            backing.resize(to: size)
        } else {
            backing = DebuggerBackingWindow(size: size)
            session.backingWindow = backing
        }
        // Any saved main-window responder belonged to the browser window before the tab left it.
        if session.tookKeyboard {
            session.tookKeyboard = false
            session.keyboardBefore = nil
        }
        Self.setWindowOcclusionDetectionEnabled(false, on: webView)
        if webView.superview !== backing.contentView {
            Self.deferWindowChange(webView) {
                webView.frame = NSRect(origin: .zero, size: size)
                webView.autoresizingMask = [.width, .height]
                webView.appearance = NSApp.effectiveAppearance
                webView.isHidden = false
                webView.alphaValue = 1
                backing.contentView?.addSubview(webView)
                backing.pretendKey = true
                backing.makeFirstResponder(session.focusEmulation ? webView : nil)
            }
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: backing)
            backing.needsActivitySync = true
        } else {
            if webView.frame.size != size { webView.frame = NSRect(origin: .zero, size: size) }
            webView.isHidden = false
            webView.alphaValue = 1
            if !backing.pretendKey {
                backing.pretendKey = true
                NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: backing)
                backing.needsActivitySync = true
            }
            if session.focusEmulation, backing.firstResponder !== webView {
                backing.makeFirstResponder(webView)
                backing.needsActivitySync = true
            }
        }
    }

    private func releaseBackingWindow(for session: Session, webView: WKWebView?, restoreOcclusion: Bool) {
        if restoreOcclusion, let webView {
            Self.setWindowOcclusionDetectionEnabled(true, on: webView)
        }
        guard let backing = session.backingWindow else { return }
        session.backingWindow = nil
        backing.tearDown(detaching: webView)
    }

    private func resolvedViewportSize(explicit: NSSize?, webView: WKWebView, tab: Tab?) -> NSSize {
        if let explicit, explicit.width > 0, explicit.height > 0 { return explicit }
        if let live = WebStackView.viewportSize(for: tab?.browser) { return live }
        if lastViewportSize.width > 0, lastViewportSize.height > 0 { return lastViewportSize }
        if webView.bounds.width > 0, webView.bounds.height > 0 { return webView.bounds.size }
        return NSSize(width: 1024, height: 768)
    }

    private static func backingScaleFactor(for webView: WKWebView, tab: Tab?) -> Double {
        if webView.window is DebuggerBackingWindow {
            return Double(tab?.browser?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        }
        return Double(webView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
    }

    private func withSyncedActivity(_ webView: WKWebView, _ body: @escaping () -> Void) {
        if let backing = webView.window as? DebuggerBackingWindow, backing.needsActivitySync {
            backing.needsActivitySync = false
            Self.afterActivityStateUpdate(webView, body)
        } else {
            body()
        }
    }

    private func send(_ session: Session, _ method: String, _ params: [String: Any]) {
        ExtensionEventPush.shared.emit("debugger.onEvent", args: [["tabId": session.tabID], method, params], to: session.extensionID)
    }

    // MARK: sendCommand

    func sendCommand(_ args: [String: Any], context: WKWebExtensionContext, finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) throws {
        let session = try session(args, context: context)
        let method = args["method"] as? String ?? ""
        let params = args["params"] as? [String: Any] ?? [:]
        try executeCommand(method: method, params: params, session: session, finish: finish, fail: fail)
    }

    private func executeCommand(
        method: String, params: [String: Any], session: Session,
        finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void
    ) throws {
        guard let tab = session.tab, let webView = tab.webView else { throw Failure.server("The tab isn’t loaded.") }
        if method != "Page.bringToFront" {
            ensureHosted(session, webView: webView)
        }
        let done: () -> Void = { finish([String: Any]()) }
        switch method {
        case "Input.dispatchMouseEvent":
            try dispatchMouse(params, session: session, webView: webView, done: done)
        case "Input.dispatchKeyEvent":
            try dispatchKey(params, session: session, webView: webView, done: done)
        case "Input.insertText":
            guard let text = params["text"] as? String else { throw Failure.invalid("text: string value expected") }
            takeKeyboard(session, webView)
            Self.editCommand(webView, "InsertText", text, done)
        case "Input.setInterceptDrags":
            session.interceptDrags = params["enabled"] as? Bool ?? false
            done()
        case "Input.dispatchDragEvent":
            try dispatchDrag(params, webView: webView, done: done)
        case "Input.setIgnoreInputEvents":
            done()

        case "Runtime.evaluate":
            try evaluate(params, webView: webView, finish: finish)
        case "Runtime.enable", "Runtime.disable", "Runtime.runIfWaitingForDebugger", "Log.enable", "Log.disable",
             "DOM.enable", "DOM.disable", "Page.setLifecycleEventsEnabled":
            done()

        case "Emulation.setFocusEmulationEnabled":
            setFocusEmulation(params["enabled"] as? Bool ?? false, session: session, webView: webView, done: done)

        case "Page.enable":
            session.pageEvents = true
            done()
        case "Page.disable":
            session.pageEvents = false
            done()
        case "Page.handleJavaScriptDialog":
            guard let answer = session.answerDialog else { throw Failure.server("No dialog is showing") }
            session.answerDialog = nil
            answer(params["accept"] as? Bool ?? false, params["promptText"] as? String)
            done()
        case "Page.navigate":
            guard let string = params["url"] as? String, let url = URL(string: string), url.scheme != nil else {
                throw Failure.invalid("url: a URL is required")
            }
            tab.load(url, byExtension: true)
            finish(["frameId": Self.mainFrameID, "loaderId": UUID().uuidString])
        case "Page.reload":
            if params["ignoreCache"] as? Bool == true { webView.reloadFromOrigin() } else { webView.reload() }
            done()
        case "Page.bringToFront":
            (tab.browser ?? BrowserState.shared).select(tab)
            done()
        case "Page.captureScreenshot":
            captureScreenshot(params, session: session, webView: webView, finish: finish, fail: fail)
        case "Page.getLayoutMetrics":
            layoutMetrics(webView, finish: finish, fail: fail)

        case "Network.enable":
            if session.network == nil {
                let observer = NetworkObserver { [weak self, weak session] method, params in
                    guard let self, let session else { return }
                    self.send(session, method, params)
                }
                session.network = observer
                Self.setResourceLoadDelegate(observer, on: webView)
            }
            done()
        case "Network.disable":
            if session.network != nil { Self.setResourceLoadDelegate(nil, on: webView) }
            session.network = nil
            done()

        case "Browser.getVersion":
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            finish([
                "protocolVersion": "1.3", "product": "Tuff/\(version)", "revision": "",
                "userAgent": webView.customUserAgent ?? "", "jsVersion": "",
            ])

        default:
            throw Failure.notFound(method)
        }
    }

    static let mainFrameID = "main"

    // MARK: Focus & keyboard

    private func setFocusEmulation(_ enabled: Bool, session: Session, webView: WKWebView, done: @escaping () -> Void) {
        session.focusEmulation = enabled
        if enabled { Self.setWindowOcclusionDetectionEnabled(false, on: webView) }
        if let backing = session.backingWindow, webView.window === backing {
            if !backing.pretendKey {
                backing.pretendKey = true
                NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: backing)
            }
            backing.makeFirstResponder(enabled ? webView : nil)
            backing.needsActivitySync = false
            Self.afterActivityStateUpdate(webView, done)
            return
        }
        if enabled {
            takeKeyboard(session, webView)
        } else {
            Self.setWindowOcclusionDetectionEnabled(true, on: webView)
            giveKeyboardBack(session, webView)
        }
        Self.afterActivityStateUpdate(webView, done)
    }

    /// The page takes the keyboard, as a click on it would. For a background tab in a backing
    /// window, only the backing window's first responder changes — the user's browser window and
    /// active tab keep their keyboard focus untouched.
    private func takeKeyboard(_ session: Session, _ webView: WKWebView) {
        guard let window = webView.window else { return }
        if let backing = window as? DebuggerBackingWindow {
            let responder = backing.firstResponder
            if let view = responder as? NSView, view === webView || view.isDescendant(of: webView) { return }
            backing.makeFirstResponder(webView)
            return
        }
        // In a split view, never steal the browser window's first responder from the user's active side.
        if let tab = session.tab, let browser = tab.browser, window === browser.window, tab !== browser.selectedTab {
            return
        }
        let responder = window.firstResponder
        if let view = responder as? NSView, view === webView || view.isDescendant(of: webView) { return }
        if !session.tookKeyboard {
            session.keyboardBefore = responder
            session.tookKeyboard = true
        }
        window.makeFirstResponder(webView)
    }

    /// On detach: the keyboard goes back where it was, unless the user has moved it since.
    private func giveKeyboardBack(_ session: Session, _ webView: WKWebView) {
        guard session.tookKeyboard, let window = webView.window, !(window is DebuggerBackingWindow),
              let before = session.keyboardBefore,
              let view = window.firstResponder as? NSView, view === webView || view.isDescendant(of: webView) else {
            session.tookKeyboard = false
            session.keyboardBefore = nil
            return
        }
        session.tookKeyboard = false
        session.keyboardBefore = nil
        window.makeFirstResponder(before)
    }

    private func dispatchKey(_ params: [String: Any], session: Session, webView: WKWebView, done: @escaping () -> Void) throws {
        guard let window = webView.window else { throw Failure.server("The tab isn’t showing, so it can’t take input.") }
        let type = params["type"] as? String ?? ""
        guard ["keyDown", "rawKeyDown", "keyUp", "char"].contains(type) else { throw Failure.invalid("type: unknown key event type \(type)") }
        takeKeyboard(session, webView)
        let key = params["key"] as? String ?? ""
        let text = (params["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if type == "char" {
            guard let text else { return done() }
            return Self.editCommand(webView, "InsertText", text, done)
        }
        let code = (params["code"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? CDPKeys.code(forKey: key)
        let keyCode = CDPKeys.macKeyCodes[code] ?? 0
        var flags = CDPKeys.modifierFlags(params["modifiers"])

        // A modifier key on its own changes the flags.
        if let modifier = CDPKeys.modifierKeys[key] {
            if type == "keyUp" { flags.remove(modifier) } else { flags.insert(modifier) }
            guard let event = NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode
            ) else { return done() }
            webView.flagsChanged(with: event)
            return Self.afterEvents(webView, keys: true, done)
        }

        let characters = text ?? CDPKeys.characters(forKey: key)
        let unmodified = (params["unmodifiedText"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? characters
        guard let event = NSEvent.keyEvent(
            with: type == "keyUp" ? .keyUp : .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: unmodified,
            isARepeat: params["autoRepeat"] as? Bool ?? false, keyCode: keyCode
        ) else { throw Failure.invalid("key: no key event could be made") }

        if type == "keyUp" {
            webView.keyUp(with: event)
            return Self.afterEvents(webView, keys: true, done)
        }
        Self.pendingKeys.append(event)
        webView.keyDown(with: event)
        let commands = params["commands"] as? [String] ?? []
        Self.afterEvents(webView, keys: true) {
            Self.pendingKeys.removeAll { $0 === event }
            let unhandled = Self.unhandledKeys.contains { $0 === event }
            Self.unhandledKeys.removeAll { $0 === event }
            // Chrome runs a key's editing commands (⌘A's selectAll on a Mac) unless the page
            // handled the key itself.
            guard unhandled, !commands.isEmpty else { return done() }
            Self.editCommands(webView, commands.map { $0.prefix(1).uppercased() + $0.dropFirst() }, done)
        }
    }

    // MARK: Mouse

    private func dispatchMouse(_ params: [String: Any], session: Session, webView: WKWebView, done: @escaping () -> Void) throws {
        guard let window = webView.window else { throw Failure.server("The tab isn’t showing, so it can’t take input.") }
        guard let x = (params["x"] as? NSNumber)?.doubleValue, let y = (params["y"] as? NSNumber)?.doubleValue else {
            throw Failure.invalid("x, y: numbers are required")
        }
        let type = params["type"] as? String ?? ""
        let button = params["button"] as? String ?? "none"
        let buttons = params["buttons"] as? Int ?? 0
        let flags = CDPKeys.modifierFlags(params["modifiers"])
        let clickCount = max(params["clickCount"] as? Int ?? 1, 1)
        let location = Self.windowPoint(x: x, y: y, in: webView)
        let make = { (kind: NSEvent.EventType, pressure: Float) -> NSEvent? in
            Self.eventNumber += 1
            return NSEvent.mouseEvent(
                with: kind, location: location, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: Self.eventNumber,
                clickCount: kind == .mouseMoved || kind.isDrag ? 0 : clickCount, pressure: pressure
            )
        }
        switch type {
        case "mousePressed":
            takeKeyboard(session, webView)
            let kind: NSEvent.EventType = button == "right" ? .rightMouseDown : button == "left" ? .leftMouseDown : .otherMouseDown
            guard let event = make(kind, 1) else { break }
            if kind == .rightMouseDown || flags.contains(.control) { Self.contextMenuDue = ProcessInfo.processInfo.systemUptime + 2 }
            Self.recentMouseDowns.append(event)
            if Self.recentMouseDowns.count > 4 { Self.recentMouseDowns.removeFirst() }
            switch kind {
            case .rightMouseDown: webView.rightMouseDown(with: event)
            case .leftMouseDown: webView.mouseDown(with: event)
            default: webView.otherMouseDown(with: event)
            }
        case "mouseReleased":
            // A drag the page began and the extension didn't play back ends here, dropped nowhere.
            if let drag = pendingDrag, drag.webView === webView { endDrag(operation: []) }
            let kind: NSEvent.EventType = button == "right" ? .rightMouseUp : button == "left" ? .leftMouseUp : .otherMouseUp
            guard let event = make(kind, 0) else { break }
            switch kind {
            case .rightMouseUp: webView.rightMouseUp(with: event)
            case .leftMouseUp: webView.mouseUp(with: event)
            default: webView.otherMouseUp(with: event)
            }
        case "mouseMoved":
            let left = buttons & 1 != 0 || (buttons == 0 && button == "left")
            let right = buttons & 2 != 0 || (buttons == 0 && button == "right")
            let other = buttons & 4 != 0 || (buttons == 0 && button == "middle")
            let kind: NSEvent.EventType = left ? .leftMouseDragged : right ? .rightMouseDragged : other ? .otherMouseDragged : .mouseMoved
            guard let event = make(kind, left || right || other ? 1 : 0) else { break }
            switch kind {
            case .leftMouseDragged: webView.mouseDragged(with: event)
            case .rightMouseDragged: webView.rightMouseDragged(with: event)
            case .otherMouseDragged: webView.otherMouseDragged(with: event)
            default:
                withSyncedActivity(webView) {
                    Self.simulateMouseMove(event, in: webView)
                    Self.settled(webView, done)
                }
                return
            }
        case "mouseWheel":
            let deltaX = (params["deltaX"] as? NSNumber)?.doubleValue ?? 0, deltaY = (params["deltaY"] as? NSNumber)?.doubleValue ?? 0
            guard let event = Self.wheelEvent(deltaX: deltaX, deltaY: deltaY, modifiers: flags, at: location) else { break }
            webView.scrollWheel(with: event)
        default:
            throw Failure.invalid("type: unknown mouse event type \(type)")
        }
        Self.settled(webView, done)
    }

    /// CSS pixels in the page's viewport to the window's coordinates.
    static func windowPoint(x: Double, y: Double, in webView: WKWebView) -> NSPoint {
        let zoom = webView.pageZoom * webView.magnification
        let inView = NSPoint(x: x * zoom, y: webView.isFlipped ? y * zoom : webView.bounds.height - y * zoom)
        return webView.convert(inView, to: nil)
    }

    /// A pixel-precise scroll (what a trackpad sends), as CDP's `mouseWheel` deltas are pixels.
    private static func wheelEvent(deltaX: Double, deltaY: Double, modifiers: NSEvent.ModifierFlags, at location: NSPoint) -> NSEvent? {
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(-deltaY.rounded()), wheel2: Int32(-deltaX.rounded()), wheel3: 0
        ) else { return nil }
        // With no target window number on the CGEvent, AppKit derives `locationInWindow` directly
        // from `cgEvent.location` flipped against the primary screen's height — giving WKWebView
        // the exact window-local point for both on-screen and off-screen windows.
        let height = NSScreen.screens.first?.frame.height ?? 0
        cgEvent.location = CGPoint(x: location.x, y: height - location.y)
        var cgFlags: CGEventFlags = []
        if modifiers.contains(.option) { cgFlags.insert(.maskAlternate) }
        if modifiers.contains(.control) { cgFlags.insert(.maskControl) }
        if modifiers.contains(.command) { cgFlags.insert(.maskCommand) }
        if modifiers.contains(.shift) { cgFlags.insert(.maskShift) }
        if !cgFlags.isEmpty { cgEvent.flags = cgFlags }
        return NSEvent(cgEvent: cgEvent)
    }

    // MARK: Drags

    /// A native drag the page began from synthetic input, held until the extension drops or
    /// cancels it (or the mouse is let go).
    private var pendingDrag: (webView: WKWebView, source: NSDraggingSource, session: NSDraggingSession, location: NSPoint)?

    /// From `TuffWebView.beginDraggingSession`, for a drag begun by an extension's synthetic
    /// mouse. AppKit would track the real mouse (whose button is up) and drop wherever the pointer
    /// happens to be, so no native drag is started: with `Input.setInterceptDrags` the extension is
    /// handed the data to play the drag back, otherwise the drag is called off.
    func syntheticDragBegan(in tab: Tab, webView: WKWebView, event: NSEvent, source: NSDraggingSource) -> NSDraggingSession {
        let session = ExtensionDebuggerDrag.placeholderSession()
        if let drag = pendingDrag { pendingDrag = nil; ExtensionDebuggerDrag.end(drag.source, drag.session, at: drag.location, operation: []) }
        let screen = event.window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
        guard let debugging = sessions.first(where: { $0.tab === tab && $0.interceptDrags }) else {
            DispatchQueue.main.async { ExtensionDebuggerDrag.end(source, session, at: screen, operation: []) }
            return session
        }
        pendingDrag = (webView, source, session, screen)
        let mask = source.draggingSession(session, sourceOperationMaskFor: .withinApplication)
        send(debugging, "Input.dragIntercepted", ["data": ExtensionDebuggerDrag.dragData(from: NSPasteboard(name: .drag), mask: mask)])
        return session
    }

    private func endDrag(operation: NSDragOperation) {
        guard let drag = pendingDrag else { return }
        pendingDrag = nil
        ExtensionDebuggerDrag.end(drag.source, drag.session, at: drag.location, operation: operation)
    }

    private func dispatchDrag(_ params: [String: Any], webView: WKWebView, done: @escaping () -> Void) throws {
        guard let window = webView.window else { throw Failure.server("The tab isn’t showing, so it can’t take input.") }
        guard let x = (params["x"] as? NSNumber)?.doubleValue, let y = (params["y"] as? NSNumber)?.doubleValue,
              let data = params["data"] as? [String: Any] else { throw Failure.invalid("x, y and data are required") }
        let info = ExtensionDebuggerDrag.DraggingInfo(
            pasteboard: ExtensionDebuggerDrag.pasteboard(with: data), location: Self.windowPoint(x: x, y: y, in: webView),
            window: window, mask: NSDragOperation(rawValue: UInt(data["dragOperationsMask"] as? Int ?? 1))
        )
        switch params["type"] as? String ?? "" {
        case "dragEnter":
            _ = webView.draggingEntered(info)
        case "dragOver":
            _ = webView.draggingUpdated(info)
        case "drop":
            let accepted = webView.prepareForDragOperation(info) && webView.performDragOperation(info)
            webView.concludeDragOperation(info)
            let mask = info.draggingSourceOperationMask
            endDrag(operation: accepted ? (mask.contains(.move) ? .move : mask.contains(.copy) ? .copy : mask) : [])
        case "dragCancel":
            webView.draggingExited(info)
            endDrag(operation: [])
        default:
            throw Failure.invalid("type: unknown drag event type")
        }
        Self.settled(webView, done)
    }

    // MARK: Runtime.evaluate

    private func evaluate(_ params: [String: Any], webView: WKWebView, finish: @escaping (Any?) -> Void) throws {
        guard let expression = params["expression"] as? String else { throw Failure.invalid("expression: string value expected") }
        let answer = { (result: Result<Any?, Error>) in
            switch result {
            case .success(let value): finish(["result": Self.remoteObject(value)])
            case .failure(let error): finish(["exceptionDetails": Self.exceptionDetails(error)])
            }
        }
        // As an expression first, so a promise it gives is awaited (`awaitPromise`); a script with
        // statements doesn't parse that way and runs as a script instead.
        webView.callAsyncJavaScript("return (\n\(expression)\n);", arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value): answer(.success(value))
            case .failure(let error) where Self.exceptionMessage(error).hasPrefix("SyntaxError"):
                webView.evaluateJavaScript(expression, in: nil, in: .page) { result in
                    switch result {
                    case .success(let value): answer(.success(value))
                    case .failure(let error): answer(.failure(error))
                    }
                }
            case .failure(let error): answer(.failure(error))
            }
        }
    }

    private static func exceptionMessage(_ error: Error) -> String {
        (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
    }

    private static func exceptionDetails(_ error: Error) -> [String: Any] {
        let message = exceptionMessage(error)
        let info = (error as NSError).userInfo
        return [
            "exceptionId": 1, "text": "Uncaught",
            "lineNumber": info["WKJavaScriptExceptionLineNumber"] as? Int ?? 0,
            "columnNumber": info["WKJavaScriptExceptionColumnNumber"] as? Int ?? 0,
            "exception": [
                "type": "object", "subtype": "error",
                "className": message.split(separator: ":").first.map(String.init) ?? "Error", "description": message,
            ],
        ]
    }

    /// A CDP RemoteObject. Values always come by value: WebKit hands back no object handles.
    static func remoteObject(_ value: Any?) -> [String: Any] {
        switch value {
        case nil: return ["type": "undefined"]
        case is NSNull: return ["type": "object", "subtype": "null", "value": NSNull()]
        case let string as String: return ["type": "string", "value": string]
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return ["type": "boolean", "value": number.boolValue]
        case let number as NSNumber: return ["type": "number", "value": number, "description": number.stringValue]
        case let list as [Any]:
            return ["type": "object", "subtype": "array", "className": "Array", "description": "Array(\(list.count))", "value": plain(list)]
        case let date as Date:
            return ["type": "object", "subtype": "date", "className": "Date", "description": "\(date)"]
        case let object as [String: Any]:
            return ["type": "object", "className": "Object", "description": "Object", "value": plain(object)]
        default: return ["type": "object", "className": "Object", "description": "\(value!)"]
        }
    }

    /// Only what JSON can carry (dates as ISO strings).
    private static func plain(_ value: Any) -> Any {
        switch value {
        case let list as [Any]: return list.map(plain)
        case let object as [String: Any]: return object.mapValues(plain)
        case let date as Date: return ISO8601DateFormatter().string(from: date)
        case is String, is NSNumber, is NSNull: return value
        default: return "\(value)"
        }
    }

    // MARK: Page

    private func captureScreenshot(_ params: [String: Any], session: Session, webView: WKWebView, finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) {
        withSyncedActivity(webView) {
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            var scale = Self.backingScaleFactor(for: webView, tab: session.tab)
            if let clip = params["clip"] as? [String: Any] {
                let number = { (key: String) in (clip[key] as? NSNumber)?.doubleValue ?? 0 }
                let zoom = webView.pageZoom * webView.magnification
                configuration.rect = CGRect(x: number("x") * zoom, y: number("y") * zoom, width: number("width") * zoom, height: number("height") * zoom)
                if let s = (clip["scale"] as? NSNumber)?.doubleValue, s > 0 { scale *= s }
            }
            let jpeg = ["jpeg", "webp"].contains(params["format"] as? String ?? "png")
            let quality = (params["quality"] as? NSNumber)?.doubleValue ?? 80
            webView.takeSnapshot(with: configuration) { image, error in
                guard let image, let data = ExtensionPageCapture.encode(image, scale: scale, jpeg: jpeg, quality: quality) else {
                    return fail(error ?? Failure.server("Unable to capture screenshot"))
                }
                finish(["data": data.base64EncodedString()])
            }
        }
    }

    private func layoutMetrics(_ webView: WKWebView, finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) {
        let script = """
        const v = window.visualViewport, d = document.documentElement;
        const layout = { pageX: scrollX, pageY: scrollY, clientWidth: d.clientWidth, clientHeight: d.clientHeight };
        const visual = { offsetX: v ? v.offsetLeft : 0, offsetY: v ? v.offsetTop : 0, pageX: v ? v.pageLeft : scrollX, pageY: v ? v.pageTop : scrollY,
          clientWidth: v ? v.width : innerWidth, clientHeight: v ? v.height : innerHeight, scale: v ? v.scale : 1, zoom: 1 };
        const content = { x: 0, y: 0, width: d.scrollWidth, height: d.scrollHeight };
        return { layoutViewport: layout, visualViewport: visual, contentSize: content,
          cssLayoutViewport: layout, cssVisualViewport: visual, cssContentSize: content };
        """
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { result in
            switch result {
            case .success(let value): finish(value)
            case .failure(let error): fail(error)
            }
        }
    }

    /// The page committed a new document (`Page.frameNavigated`).
    func pageCommitted(_ tab: Tab) {
        guard !sessions.isEmpty, let url = tab.webView?.url else { return }
        for session in sessions where session.tab === tab && session.pageEvents {
            send(session, "Page.frameNavigated", [
                "frame": [
                    "id": Self.mainFrameID, "loaderId": "", "url": url.absoluteString, "domainAndRegistry": "",
                    "securityOrigin": Self.origin(url), "mimeType": "text/html",
                ],
                "type": "Navigation",
            ])
        }
    }

    /// The page finished loading (`Page.loadEventFired`).
    func pageLoaded(_ tab: Tab) {
        guard !sessions.isEmpty else { return }
        for session in sessions where session.tab === tab && session.pageEvents {
            send(session, "Page.loadEventFired", ["timestamp": ProcessInfo.processInfo.systemUptime])
        }
    }

    private static func origin(_ url: URL) -> String {
        guard let scheme = url.scheme, let host = url.host else { return "null" }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    /// The page opened alert() / confirm() / prompt() or asks before it's left. With the Page
    /// domain on, the extension hears of it and may answer it (`Page.handleJavaScriptDialog`);
    /// the card is shown all the same, and whichever answers first wins.
    @MainActor
    func pageDialog(
        in tab: Tab, type: String, message: String, defaultPrompt: String = "", url: URL?, prompt: Prompt,
        show: @escaping @MainActor () async -> PromptResult?
    ) async -> PromptResult? {
        guard let session = sessions.first(where: { $0.tab === tab && $0.pageEvents }) else { return await show() }
        send(session, "Page.javascriptDialogOpening", [
            "url": url?.absoluteString ?? "", "frameId": Self.mainFrameID, "message": message, "type": type,
            "hasBrowserHandler": true, "defaultPrompt": defaultPrompt,
        ])
        let result: PromptResult? = await withCheckedContinuation { continuation in
            var answered = false
            let respond = { (result: PromptResult?) in
                guard !answered else { return }
                answered = true
                continuation.resume(returning: result)
            }
            let showing = Task { @MainActor in await show() }
            session.answerDialog = { accept, text in
                showing.cancel()
                PromptPresenter.withdraw(prompt.id)
                respond(PromptResult(confirmed: accept, fields: [text ?? defaultPrompt], checked: false))
            }
            Task { @MainActor in respond(await showing.value) }
        }
        session.answerDialog = nil
        if sessions.contains(where: { $0 === session }) {
            send(session, "Page.javascriptDialogClosed", ["result": result?.confirmed ?? false, "userInput": result?.fields.first ?? ""])
        }
        return result
    }

    // MARK: WebKit's private calls

    /// Runs `done` once the page has handled what was sent to it before: the page takes its
    /// messages in order, so a script's answer comes after them.
    static func settled(_ webView: WKWebView, _ done: @escaping () -> Void) {
        webView.evaluateJavaScript("0", in: nil, in: .defaultClient) { _ in done() }
    }

    /// Runs `done` once WebKit has handed every queued key or mouse event to the page.
    private static func afterEvents(_ webView: WKWebView, keys: Bool, _ done: @escaping () -> Void) {
        let selector = NSSelectorFromString(keys ? "_doAfterProcessingAllPendingKeyEvents:" : "_doAfterProcessingAllPendingMouseEvents:")
        guard webView.responds(to: selector) else { return DispatchQueue.main.async(execute: done) }
        typealias After = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
        let after = unsafeBitCast(webView.method(for: selector), to: After.self)
        after(webView, selector, { DispatchQueue.main.async(execute: done) })
    }

    /// One of WebCore's editing commands ("InsertText", "SelectAll", "Paste"…), as the page's
    /// own menu items and key bindings run them.
    static func editCommand(_ webView: WKWebView, _ command: String, _ argument: String? = nil, _ done: @escaping () -> Void) {
        let selector = NSSelectorFromString("_executeEditCommand:argument:completion:")
        guard webView.responds(to: selector) else { return done() }
        typealias Execute = @convention(c) (AnyObject, Selector, NSString, NSString?, @escaping @convention(block) (Bool) -> Void) -> Void
        let execute = unsafeBitCast(webView.method(for: selector), to: Execute.self)
        execute(webView, selector, command as NSString, argument as NSString?, { _ in DispatchQueue.main.async(execute: done) })
    }

    private static func editCommands(_ webView: WKWebView, _ commands: [String], _ done: @escaping () -> Void) {
        guard let first = commands.first else { return done() }
        editCommand(webView, first) { editCommands(webView, Array(commands.dropFirst()), done) }
    }

    private static func setResourceLoadDelegate(_ delegate: NSObject?, on webView: WKWebView) {
        let selector = NSSelectorFromString("_setResourceLoadDelegate:")
        guard webView.responds(to: selector) else { return }
        webView.perform(selector, with: delegate)
    }

    /// Defers WebKit's in-window activity-state transition while reparenting `webView` between the
    /// browser window and its off-screen backing window, so the page never sees a transient hidden
    /// state.
    private static func deferWindowChange(_ webView: WKWebView, _ body: () -> Void) {
        let begin = NSSelectorFromString("_beginDeferringViewInWindowChanges")
        let endSync = NSSelectorFromString("_endDeferringViewInWindowChangesSync")
        let end = NSSelectorFromString("_endDeferringViewInWindowChanges")
        let endSelector = webView.responds(to: endSync) ? endSync : end
        let canDefer = webView.responds(to: begin) && webView.responds(to: endSelector)
        if canDefer { webView.perform(begin) }
        body()
        if canDefer { webView.perform(endSelector) }
    }

    private static func setWindowOcclusionDetectionEnabled(_ enabled: Bool, on webView: WKWebView) {
        guard webView.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) else { return }
        webView.setValue(enabled, forKey: "windowOcclusionDetectionEnabled")
    }

    /// Runs `done` once WebKit has sent any pending activity-state update (focus, key window,
    /// visibility) to the web content process.
    private static func afterActivityStateUpdate(_ webView: WKWebView, _ done: @escaping () -> Void) {
        let selector = NSSelectorFromString("_doAfterActivityStateUpdate:")
        guard webView.responds(to: selector) else { return settled(webView, done) }
        typealias After = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
        let after = unsafeBitCast(webView.method(for: selector), to: After.self)
        after(webView, selector, { DispatchQueue.main.async(execute: done) })
    }

    /// Delivers a synthetic `mouseMoved` event into WebKit (`WKWebView` does not override
    /// `NSResponder.mouseMoved(with:)`, receiving real moves via its tracking area instead).
    private static func simulateMouseMove(_ event: NSEvent, in webView: WKWebView) {
        let selector = NSSelectorFromString("_simulateMouseMove:")
        if webView.responds(to: selector) {
            webView.perform(selector, with: event)
        } else {
            webView.mouseMoved(with: event)
        }
    }
}

/// Off-screen, non-activating window that hosts a debugger-attached background tab's `WKWebView`.
/// Because `canBecomeKey` and `canBecomeMain` are false, macOS never steals focus from the user's
/// active browser window or tab; overriding `isKeyWindow` lets WebKit treat the hosted page as an
/// active window so trusted `NSEvent`s (including `mouseMoved`) work and `makeFirstResponder`
/// toggles `document.hasFocus()` cleanly.
final class DebuggerBackingWindow: NSWindow {
    var pretendKey = false
    /// Set after attaching or toggling key state so the first mouse move / snapshot waits for
    /// WebKit's activity state update to reach the web content process.
    var needsActivitySync = false

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var isKeyWindow: Bool { pretendKey ? true : super.isKeyWindow }

    init(size: NSSize) {
        let clamped = NSSize(width: max(1, size.width), height: max(1, size.height))
        super.init(
            contentRect: NSRect(origin: Self.offscreenOrigin(for: clamped), size: clamped),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        ignoresMouseEvents = true
        isExcludedFromWindowsMenu = true
        acceptsMouseMovedEvents = true
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.ignoresCycle, .stationary, .transient]
        alphaValue = 0
        orderBack(nil)
    }

    func resize(to size: NSSize) {
        let clamped = NSSize(width: max(1, size.width), height: max(1, size.height))
        guard frame.size != clamped else { return }
        setFrame(NSRect(origin: Self.offscreenOrigin(for: clamped), size: clamped), display: false)
    }

    func tearDown(detaching webView: WKWebView?) {
        pretendKey = false
        needsActivitySync = false
        makeFirstResponder(nil)
        if let webView, webView.superview === contentView {
            webView.removeFromSuperview()
        }
        orderOut(nil)
        close()
    }

    private static func offscreenOrigin(for size: NSSize) -> NSPoint {
        let minX = NSScreen.screens.map(\.frame.minX).min() ?? 0
        let minY = NSScreen.screens.map(\.frame.minY).min() ?? 0
        return NSPoint(x: minX - size.width - 10_000, y: minY - size.height - 10_000)
    }
}

private extension NSEvent.EventType {
    var isDrag: Bool { self == .leftMouseDragged || self == .rightMouseDragged || self == .otherMouseDragged }
}

// MARK: - Network

/// WebKit's resource-load delegate (`_WKResourceLoadDelegate`) as CDP `Network` events.
final class NetworkObserver: NSObject {
    private let send: (String, [String: Any]) -> Void

    init(send: @escaping (String, [String: Any]) -> Void) {
        self.send = send
    }

    /// `_WKResourceLoadInfoResourceType`, in its order.
    private static let types = [
        "Manifest", "Ping", "CSPViolationReport", "Document", "Image", "Fetch", "Font", "Media", "Other",
        "Ping", "Script", "Stylesheet", "XHR", "Other",
    ]

    private static func describe(_ load: NSObject) -> (id: String, type: String, frameID: String) {
        let id = (load.value(forKey: "resourceLoadID") as? NSNumber)?.stringValue ?? "0"
        let raw = (load.value(forKey: "resourceType") as? NSNumber)?.intValue ?? -1
        let type = types.indices.contains(raw) ? types[raw] : "Other"
        let frame = load.value(forKey: "frame") as? NSObject
        let isMain = frame.flatMap { $0.responds(to: NSSelectorFromString("isMainFrame")) ? $0.value(forKey: "isMainFrame") as? Bool : nil } ?? true
        return (id, type, isMain ? ExtensionDebugger.mainFrameID : "frame")
    }

    private static func headers(_ fields: [AnyHashable: Any]?) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in fields ?? [:] { result["\(key)"] = "\(value)" }
        return result
    }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    @objc(webView:resourceLoad:didSendRequest:)
    func webView(_ webView: WKWebView, resourceLoad: NSObject, didSendRequest request: NSURLRequest) {
        let load = Self.describe(resourceLoad)
        send("Network.requestWillBeSent", [
            "requestId": load.id, "loaderId": "", "documentURL": webView.url?.absoluteString ?? "",
            "request": [
                "url": request.url?.absoluteString ?? "", "method": request.httpMethod ?? "GET",
                "headers": Self.headers(request.allHTTPHeaderFields), "initialPriority": "Medium", "referrerPolicy": "",
            ],
            "timestamp": Self.now, "wallTime": Date().timeIntervalSince1970, "initiator": ["type": "other"],
            "type": load.type, "frameId": load.frameID, "redirectHasExtraInfo": false,
        ])
    }

    @objc(webView:resourceLoad:didReceiveResponse:)
    func webView(_ webView: WKWebView, resourceLoad: NSObject, didReceiveResponse response: URLResponse) {
        let load = Self.describe(resourceLoad)
        let http = response as? HTTPURLResponse
        send("Network.responseReceived", [
            "requestId": load.id, "loaderId": "", "timestamp": Self.now, "type": load.type, "frameId": load.frameID,
            "response": [
                "url": response.url?.absoluteString ?? "", "status": http?.statusCode ?? 200,
                "statusText": http.map { HTTPURLResponse.localizedString(forStatusCode: $0.statusCode) } ?? "",
                "headers": Self.headers(http?.allHeaderFields), "mimeType": response.mimeType ?? "",
                "connectionReused": false, "connectionId": 0, "encodedDataLength": 0, "securityState": "unknown",
            ],
            "hasExtraInfo": false,
        ])
    }

    @objc(webView:resourceLoad:didCompleteWithError:response:)
    func webView(_ webView: WKWebView, resourceLoad: NSObject, didCompleteWithError error: NSError?, response: URLResponse?) {
        let load = Self.describe(resourceLoad)
        if let error {
            send("Network.loadingFailed", [
                "requestId": load.id, "timestamp": Self.now, "type": load.type, "errorText": error.localizedDescription,
                "canceled": error.code == NSURLErrorCancelled,
            ])
        } else {
            send("Network.loadingFinished", ["requestId": load.id, "timestamp": Self.now, "encodedDataLength": response?.expectedContentLength ?? 0])
        }
    }
}

// MARK: - Keys

/// What CDP's key events name (DOM `key` / `code`, its modifier bits) as AppKit has it.
enum CDPKeys {
    /// CDP modifier bits: Alt 1, Ctrl 2, Meta / Command 4, Shift 8.
    static func modifierFlags(_ value: Any?) -> NSEvent.ModifierFlags {
        let bits = value as? Int ?? 0
        var flags: NSEvent.ModifierFlags = []
        if bits & 1 != 0 { flags.insert(.option) }
        if bits & 2 != 0 { flags.insert(.control) }
        if bits & 4 != 0 { flags.insert(.command) }
        if bits & 8 != 0 { flags.insert(.shift) }
        return flags
    }

    static let modifierKeys: [String: NSEvent.ModifierFlags] = [
        "Shift": .shift, "Control": .control, "Alt": .option, "Meta": .command, "CapsLock": .capsLock,
    ]

    /// DOM `code` -> macOS virtual key code (Carbon's kVK_…).
    static let macKeyCodes: [String: UInt16] = [
        "KeyA": 0x00, "KeyS": 0x01, "KeyD": 0x02, "KeyF": 0x03, "KeyH": 0x04, "KeyG": 0x05, "KeyZ": 0x06, "KeyX": 0x07,
        "KeyC": 0x08, "KeyV": 0x09, "KeyB": 0x0B, "KeyQ": 0x0C, "KeyW": 0x0D, "KeyE": 0x0E, "KeyR": 0x0F, "KeyY": 0x10,
        "KeyT": 0x11, "Digit1": 0x12, "Digit2": 0x13, "Digit3": 0x14, "Digit4": 0x15, "Digit6": 0x16, "Digit5": 0x17,
        "Equal": 0x18, "Digit9": 0x19, "Digit7": 0x1A, "Minus": 0x1B, "Digit8": 0x1C, "Digit0": 0x1D, "BracketRight": 0x1E,
        "KeyO": 0x1F, "KeyU": 0x20, "BracketLeft": 0x21, "KeyI": 0x22, "KeyP": 0x23, "Enter": 0x24, "KeyL": 0x25,
        "KeyJ": 0x26, "Quote": 0x27, "KeyK": 0x28, "Semicolon": 0x29, "Backslash": 0x2A, "Comma": 0x2B, "Slash": 0x2C,
        "KeyN": 0x2D, "KeyM": 0x2E, "Period": 0x2F, "Tab": 0x30, "Space": 0x31, "Backquote": 0x32, "Backspace": 0x33,
        "Escape": 0x35, "MetaRight": 0x36, "MetaLeft": 0x37, "ShiftLeft": 0x38, "CapsLock": 0x39, "AltLeft": 0x3A,
        "ControlLeft": 0x3B, "ShiftRight": 0x3C, "AltRight": 0x3D, "ControlRight": 0x3E, "NumpadEnter": 0x4C,
        "F5": 0x60, "F6": 0x61, "F7": 0x62, "F3": 0x63, "F8": 0x64, "F9": 0x65, "F11": 0x67, "F10": 0x6D, "F12": 0x6F,
        "Home": 0x73, "PageUp": 0x74, "Delete": 0x75, "F4": 0x76, "End": 0x77, "F2": 0x78, "PageDown": 0x79, "F1": 0x7A,
        "ArrowLeft": 0x7B, "ArrowRight": 0x7C, "ArrowDown": 0x7D, "ArrowUp": 0x7E,
    ]

    private static let punctuation: [Character: String] = [
        ",": "Comma", ".": "Period", "/": "Slash", ";": "Semicolon", "'": "Quote", "[": "BracketLeft", "]": "BracketRight",
        "\\": "Backslash", "-": "Minus", "=": "Equal", "`": "Backquote", " ": "Space",
        "<": "Comma", ">": "Period", "?": "Slash", ":": "Semicolon", "\"": "Quote", "{": "BracketLeft", "}": "BracketRight",
        "|": "Backslash", "_": "Minus", "+": "Equal", "~": "Backquote",
        "!": "Digit1", "@": "Digit2", "#": "Digit3", "$": "Digit4", "%": "Digit5", "^": "Digit6", "&": "Digit7", "*": "Digit8",
        "(": "Digit9", ")": "Digit0",
    ]

    /// The `code` for a `key` when the caller gave none (a US layout).
    static func code(forKey key: String) -> String {
        if key.count == 1, let character = key.first {
            if character.isASCII, character.isLetter { return "Key" + character.uppercased() }
            if character.isASCII, character.isNumber { return "Digit\(character)" }
            if let name = punctuation[character] { return name }
        }
        if let modifier = ["Shift": "ShiftLeft", "Control": "ControlLeft", "Alt": "AltLeft", "Meta": "MetaLeft"][key] { return modifier }
        return key
    }

    /// The characters AppKit puts in a key event for `key` (function keys use its private-use
    /// characters, as a real keyboard's do).
    static func characters(forKey key: String) -> String {
        if key.count == 1 { return key }
        let function = { (code: Int) in UnicodeScalar(code).map { String(Character($0)) } ?? "" }
        switch key {
        case "Enter": return "\r"
        case "Tab": return "\t"
        case "Backspace": return "\u{7F}"
        case "Escape": return "\u{1B}"
        case "Delete": return function(NSDeleteFunctionKey)
        case "ArrowUp": return function(NSUpArrowFunctionKey)
        case "ArrowDown": return function(NSDownArrowFunctionKey)
        case "ArrowLeft": return function(NSLeftArrowFunctionKey)
        case "ArrowRight": return function(NSRightArrowFunctionKey)
        case "Home": return function(NSHomeFunctionKey)
        case "End": return function(NSEndFunctionKey)
        case "PageUp": return function(NSPageUpFunctionKey)
        case "PageDown": return function(NSPageDownFunctionKey)
        default:
            if key.hasPrefix("F"), let number = Int(key.dropFirst()), (1...12).contains(number) { return function(NSF1FunctionKey + number - 1) }
            return ""
        }
    }
}
