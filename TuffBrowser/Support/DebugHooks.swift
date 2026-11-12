#if DEBUG
import AppKit
import SwiftUI
import WebKit

/// Debug-build-only automation used to test the app without a human at the keyboard.
///
///     TUFF_DATA_DIR=/tmp/tuff-test \
///     TUFF_DEBUG_SCRIPT="wait 1; open https://example.com; wait 3; snap /tmp/a.png; quit" \
///     Tuff.app/Contents/MacOS/Tuff
///
/// Commands are separated by ";". Nothing here is compiled into release builds.
enum DebugHooks {
    private static var logURL: URL? {
        ProcessInfo.processInfo.environment["TUFF_DEBUG_LOG"].map { URL(fileURLWithPath: $0) }
    }

    /// TEMP(bench): TUFF_BENCH=flag,flag switches pieces off to find what costs benchmark score.
    static let benchFlags: Set<String> = Set((ProcessInfo.processInfo.environment["TUFF_BENCH"] ?? "").split(separator: ",").map(String.init))
    static func bench(_ flag: String) -> Bool { benchFlags.contains(flag) }

    static func runIfRequested() {
        guard let script = ProcessInfo.processInfo.environment["TUFF_DEBUG_SCRIPT"] else { return }
        // One command per line when the script has several lines (lets commands contain ";").
        let separator: Character = script.contains("\n") ? "\n" : ";"
        let commands = script.split(separator: separator).map { String($0).trimmed }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        ExtensionManager.shared.tracer = { log("trace " + $0) }
        run(commands[...])
    }

    private static func log(_ line: String) {
        NSLog("TuffDebug: %@", line)
        guard let logURL else { return }
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    private static func run(_ commands: ArraySlice<String>) {
        guard let command = commands.first else { return }
        let rest = commands.dropFirst()
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let name = parts[0]
        let argument = parts.count > 1 ? parts[1] : ""
        let state = BrowserState.shared
        var delay = 0.05

        switch name {
        case "wait":
            delay = Double(argument) ?? 1
        case "open":
            if let url = URL(string: argument) { state.newTab(url: url) }
        case "load":
            if let url = URL(string: argument) { state.selectedTab?.load(url) }
        case "snap":
            snapshot(window: state.window, to: argument)
        case "snapall":
            for (i, window) in NSApp.windows.enumerated() where window.isVisible {
                snapshot(window: window, to: "\(argument)-\(i).png")
            }
        case "cmdbar":
            state.openCommandBar(argument == "edit" ? .editCurrent : .newTab)
        case "type":
            if let editor = (NSApp.keyWindow ?? state.window)?.firstResponder as? NSTextView {
                editor.insertText(argument, replacementRange: editor.selectedRange())
            } else {
                log("type: no text editor focused (\(String(describing: (NSApp.keyWindow ?? state.window)?.firstResponder)))")
            }
        case "key":
            let selectors: [String: Selector] = [
                "enter": #selector(NSResponder.insertNewline(_:)), "esc": #selector(NSResponder.cancelOperation(_:)),
                "down": #selector(NSResponder.moveDown(_:)), "up": #selector(NSResponder.moveUp(_:)),
                "tab": #selector(NSResponder.insertTab(_:)),
            ]
            if let selector = selectors[argument], let editor = (NSApp.keyWindow ?? state.window)?.firstResponder as? NSTextView {
                editor.doCommand(by: selector)
            }
        case "sidebar":
            state.toggleSidebar()
        case "peek":
            state.setPeeking(argument != "off")
        case "space":
            state.switchSpace(to: Int(argument) ?? 0)
        case "newspace":
            state.addSpace()
        case "editspace":
            state.editingSpaceID = argument == "off" ? nil : state.currentSpace.id
        case "spacecolor":
            state.currentSpace.colorHex = argument
        case "swipe":
            state.updateSwipe(deltaX: CGFloat(Double(argument) ?? 0), width: CGFloat(AppSettings.shared.general.sidebarWidth))
        case "swipeend":
            state.endSwipe(velocityX: CGFloat(Double(argument) ?? 0))
        case "select":
            let list = state.orderedTabs(in: state.currentSpace)
            if let i = Int(argument), list.indices.contains(i) { state.select(list[i]) }
        case "pin":
            if let tab = state.selectedTab { state.move(tab, to: .pinned) }
        case "fav":
            if let tab = state.selectedTab { state.move(tab, to: .favorites) }
        case "close":
            state.closeSelectedTab()
        case "back":
            state.selectedTab?.goBack()
        case "reopen":
            state.reopenClosedTab()
        case "history":
            let tab = state.selectedTab
            let list = tab?.webView?.backForwardList
            log("history url=\(tab?.url?.absoluteString ?? "-") back=\(list?.backList.map(\.url.absoluteString) ?? []) forward=\(list?.forwardList.map(\.url.absoluteString) ?? []) index=\(state.currentSpace.tabs.firstIndex { $0 === tab } ?? -1) notSecure=\(tab?.isNotSecure ?? false)")
        case "sleep":
            state.allTabs.filter { $0 !== state.selectedTab }.forEach { $0.sleep() }
        case "find":
            state.findVisible = true
        case "settings":
            AppDelegate.shared?.showSettings(tab: SettingsTab(rawValue: argument) ?? .general)
        case "permreq":
            // permreq host — shows the camera / microphone card on the selected tab.
            if let tab = state.selectedTab {
                withAnimation(Motion.snappy) {
                    tab.permissionRequest = PermissionRequest(host: argument, kind: .cameraAndMicrophone) { granted, remember in
                        log("permreq answered granted=\(String(describing: granted)) remember=\(remember)")
                        if let granted {
                            SitePermissions.shared.record(host: argument, kind: .cameraAndMicrophone, granted: granted, remember: remember)
                        }
                    }
                }
            }
        case "preset":
            if let preset = ThemePreset.all.first(where: { $0.id == argument }) { preset.apply(&AppSettings.shared.theme) }
        case "theme":
            // theme key=value, e.g. "theme grain=0.8"
            let pair = argument.split(separator: "=").map(String.init)
            if pair.count == 2, let value = Double(pair[1]) {
                switch pair[0] {
                case "grain": AppSettings.shared.theme.grain = value
                case "blur": AppSettings.shared.theme.blurRadius = value
                case "opacity": AppSettings.shared.theme.tintOpacity = value
                case "radius": AppSettings.shared.theme.cardRadius = value
                case "inset": AppSettings.shared.theme.cardInset = value
                default: break
                }
            }
        case "install":
            if let source = ExtensionManager.source(from: argument) { ExtensionManager.shared.install(source, confirm: false) }
        case "installask":
            // Like "install", but with the confirmation card.
            if let source = ExtensionManager.source(from: argument) { ExtensionManager.shared.install(source) }
        case "prompt":
            // prompt yes|no — answers the extension card on screen.
            log("prompt \(state.prompt?.title ?? "-") items=\(state.prompt?.items.map(\.text) ?? []) note=\(state.prompt?.note != nil)")
            MainActor.assumeIsolated { PromptPresenter.resolve(argument != "no") }
        case "snapview":
            // snapview <path> [settings] — draws the window's views without screen capture (works
            // without Screen Recording permission; blur and web content come out blank).
            let words = argument.split(separator: " ").map(String.init)
            let window = words.contains("settings") ? AppDelegate.shared?.visibleSettingsWindow : state.window
            if let path = words.first, let view = window?.contentView?.superview ?? window?.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                log("snapview \(path)")
            }
        case "askquit":
            // Quit as ⌘Q would, with the confirmation card (answer with "prompt yes|no").
            AppDelegate.confirmQuitInTests = true
            AppSettings.shared.behavior.confirmQuit = true
            NSApp.terminate(nil)
        case "alert", "confirm", "jsprompt":
            // Runs a page dialog in the selected tab and logs what the page got back.
            let call = name == "alert" ? "alert" : name == "confirm" ? "confirm" : "prompt"
            let js = "String(\(call)(\(String(reflecting: argument)), 'default text'))"
            state.selectedTab?.webView?.evaluateJavaScript(js) { value, error in
                log("\(name) -> \(value.map { "\($0)" } ?? "error \(error?.localizedDescription ?? "")")")
            }
        case "spaces":
            log("spaces " + state.spaces.map(\.name).joined(separator: ","))
        case "deletespace":
            // deletespace <index> [settings] — asks to delete a space (answer with "prompt yes|no").
            let words = argument.split(separator: " ")
            if let index = words.first.flatMap({ Int($0) }), state.spaces.indices.contains(index) {
                state.confirmDelete(state.spaces[index], from: words.contains("settings") ? .settings : .browser)
            }
        case "installfile":
            ExtensionManager.shared.install(.archive(URL(fileURLWithPath: argument)), confirm: false)
        case "installdir":
            ExtensionManager.shared.install(.folder(URL(fileURLWithPath: argument, isDirectory: true)), confirm: false)
        case "extaction":
            let actions = ExtensionManager.shared.actions(for: state.selectedTab)
            log("actions: \(actions.map { "\($0.name) badge=\($0.badge) icon=\($0.icon != nil)" })")
            if let i = Int(argument), actions.indices.contains(i) { ExtensionManager.shared.performAction(id: actions[i].id) }
        case "panel":
            // panel <action index> | close | last — opens / closes an extension side panel.
            let panels = SidePanelManager.shared
            if argument == "close" { panels.close() } else if argument == "last" { panels.toggleLast() } else {
                let actions = ExtensionManager.shared.actions(for: state.selectedTab)
                if let i = Int(argument), actions.indices.contains(i) { panels.toggle(actions[i].id) }
            }
        case "panelinfo":
            let panels = SidePanelManager.shared
            log("panel open=\(panels.openID ?? "-") showing=\(panels.isShowing) url=\(panels.host?.webView.url?.absoluteString ?? "-") available=\(panels.panelExtensionIDs) width=\(AppSettings.shared.general.sidePanelWidth)")
            for action in ExtensionManager.shared.actions(for: state.selectedTab) {
                log("panel action \(action.name) hasPanel=\(action.hasPanel) open=\(action.panelOpen)")
            }
        case "paneljs":
            // paneljs <async function body> — runs in the open side panel's page.
            let rest2 = rest
            guard let webView = SidePanelManager.shared.host?.webView else { log("paneljs: no panel"); break }
            webView.callAsyncJavaScript(argument, arguments: [:], in: nil, in: .page) { result in
                log("paneljs => \(result)")
                run(rest2)
            }
            return
        case "extensions":
            for record in ExtensionManager.shared.records {
                let context = ExtensionManager.shared.contexts[record.id]
                log("ext \(record.id) \(record.name) v\(record.version) enabled=\(record.enabled) loaded=\(context != nil) links=\(ExtensionManager.shared.linkSummary(record) ?? "all") error=\(record.lastError ?? "-") base=\(context?.baseURL.absoluteString ?? "-") errors=\(context?.errors.map(\.localizedDescription) ?? [])")
            }
        case "js":
            let rest2 = rest
            state.selectedTab?.webView?.evaluateJavaScript(argument) { result, error in
                log("js \(argument.prefix(60)) => \(result.map { "\($0)" } ?? "nil") \(error.map { "ERR \($0.localizedDescription)" } ?? "")")
                run(rest2)
            }
            return
        case "hitch":
            // hitch start | hitch stop <label> — main-thread frame timing (see PerfProbe).
            let words = argument.split(separator: " ", maxSplits: 1).map(String.init)
            if words.first == "start" {
                PerfProbe.startHitchMeter(in: state.window)
            } else {
                log("hitch \(words.count > 1 ? words[1] : "-"): " + PerfProbe.stopHitchMeter())
            }
        case "layers":
            // layers <path> — writes the browser window's layer tree.
            let tree = PerfProbe.layerTree(of: state.window)
            try? tree.write(toFile: argument, atomically: true, encoding: .utf8)
            log("layers \(tree.split(separator: "\n").first ?? "")")
        case "swipeanim":
            // swipeanim <pages> <seconds> — a scripted two-finger swipe across the sidebar.
            let v = argument.split(separator: " ").compactMap { Double($0) }
            guard v.count == 2 else { log("swipeanim: bad arguments"); break }
            let rest2 = rest
            PerfProbe.animateSwipe(pages: v[0], seconds: v[1], in: state.window) { run(rest2) }
            return
        case "faketabs":
            // faketabs <count> — fills the current space with unloaded tabs (sidebar stress test).
            let space = state.currentSpace
            for i in 0..<(Int(argument) ?? 20) {
                let hosts = ["example.com", "apple.com", "wikipedia.org", "github.com", "news.ycombinator.com"]
                let tab = Tab(url: URL(string: "https://\(hosts[i % hosts.count])/page/\(i)"), title: "Sample tab \(i) with a title long enough to fade out")
                tab.browser = state
                space.tabs.append(tab)
            }
        case "resize":
            // resize <width> <height> — animated window resize.
            let v = argument.split(separator: " ").compactMap { Double($0) }
            if v.count == 2, let window = state.window {
                var frame = window.frame
                frame.origin.y += frame.height - v[1]
                frame.size = NSSize(width: v[0], height: v[1])
                window.setFrame(frame, display: true, animate: true)
            }
        case "waitjs":
            // waitjs <timeout seconds> <expression> — polls the selected page until the
            // expression is truthy (benchmarks: wait for the score), then logs it.
            let words = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard words.count == 2, let timeout = Double(words[0]) else { log("waitjs: bad arguments"); break }
            let rest2 = rest
            let deadline = Date().addingTimeInterval(timeout)
            func poll() {
                guard let webView = state.selectedTab?.webView else { log("waitjs: no page"); run(rest2); return }
                webView.evaluateJavaScript(words[1]) { result, _ in
                    let text = result.map { "\($0)" } ?? ""
                    if !text.isEmpty, text != "0", text != "false", text != "<null>" {
                        log("waitjs => \(text)")
                        run(rest2)
                    } else if Date() > deadline {
                        log("waitjs timed out")
                        run(rest2)
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { poll() }
                    }
                }
            }
            poll()
            return
        case "asyncjs":
            let rest2 = rest
            state.selectedTab?.webView?.callAsyncJavaScript(argument, arguments: [:], in: nil, in: .page) { result in
                log("asyncjs => \(result)")
                run(rest2)
            }
            return
        case "pip":
            state.togglePictureInPicture()
        case "pipinfo":
            for tab in state.allTabs where tab.isAwake {
                log("pip \(tab.displayTitle.prefix(30)) selected=\(tab === state.selectedTab) pip=\(tab.isInPictureInPicture) auto=\(tab.enteredPictureInPictureAutomatically) audio=\(tab.isPlayingAudio)")
            }
        case "newprofile":
            state.addProfile(name: argument.isEmpty ? "New Profile" : argument)
        case "setprofile":
            // setprofile <profile index> — moves the current space to that profile.
            if let i = Int(argument), state.profiles.indices.contains(i) { state.setProfile(state.profiles[i], for: state.currentSpace) }
        case "link":
            // link <extension index> <profile index | s<space index> | all>
            let words = argument.split(separator: " ").map(String.init)
            let records = ExtensionManager.shared.records
            guard words.count == 2, let e = Int(words[0]), records.indices.contains(e) else { break }
            let id = records[e].id
            if words[1] == "all" {
                ExtensionManager.shared.setLinks(nil, id: id)
            } else if words[1].hasPrefix("s"), let i = Int(words[1].dropFirst()), state.spaces.indices.contains(i) {
                ExtensionManager.shared.toggleLink(state.spaces[i].id, id: id)
            } else if let i = Int(words[1]), state.profiles.indices.contains(i) {
                ExtensionManager.shared.toggleLink(state.profiles[i].id, id: id)
            }
        case "delprofile":
            // delprofile <profile index> — deletes it without asking.
            if let i = Int(argument), state.profiles.indices.contains(i) {
                let profile = state.profiles[i]
                log("delprofile \(profile.name) store=\(profile.dataStore.identifier?.uuidString ?? "shared")")
                state.delete(profile)
            }
        case "profiles":
            for profile in state.profiles {
                log("profile \(profile.name) spaces=\(state.spaces(in: profile).map(\.name)) favs=\(profile.favorites.map { $0.url?.host() ?? "-" }) store=\(profile.dataStore.identifier?.uuidString ?? "shared")")
            }
        case "info":
            let tab = state.selectedTab
            log("info space=\(state.currentSpaceIndex)/\(state.spaces.count) profile=\(state.currentProfile.name) tabs=\(state.currentSpace.tabs.count) pinned=\(state.currentSpace.pinned.count) favs=\(state.favorites.count) selected=\(tab?.displayTitle ?? "-") url=\(tab?.url?.absoluteString ?? "-") awake=\(state.allTabs.filter(\.isAwake).count) favicon=\(tab?.favicon != nil) loading=\(tab?.isLoading ?? false)")
            if let window = state.window {
                let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
                log("window frame=\(window.frame) lights=\(buttons.map { $0.convert($0.bounds, to: nil) }) firstResponder=\(type(of: window.firstResponder as Any))")
            }
        case "click":
            // click x y — a real mouse click delivered through the window's event path.
            let xy = argument.split(separator: " ").compactMap { Double($0) }
            if xy.count == 2, let window = state.window {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(
                        with: type, location: NSPoint(x: xy[0], y: xy[1]), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                    ) {
                        window.sendEvent(event)
                    }
                }
            }
        case "scroll":
            // scroll x y dy — a pixel-precise wheel event at a window point.
            let v = argument.split(separator: " ").compactMap { Double($0) }
            if v.count == 3, let window = state.window,
               let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(v[2]), wheel2: 0, wheel3: 0) {
                let screenPoint = window.convertPoint(toScreen: NSPoint(x: v[0], y: v[1]))
                let height = NSScreen.screens.first?.frame.height ?? 0
                cg.location = CGPoint(x: screenPoint.x, y: height - screenPoint.y)
                if let event = NSEvent(cgEvent: cg) {
                    let target = window.contentView?.hitTest(NSPoint(x: v[0], y: v[1]))
                    log("scroll target=\(target.map { String(describing: type(of: $0)) } ?? "nil")")
                    target?.scrollWheel(with: event)
                }
            }
        case "hittest":
            // hittest x y — which view would receive a mouse event at this window point (origin bottom-left)?
            let xy = argument.split(separator: " ").compactMap { Double($0) }
            if xy.count == 2, let content = state.window?.contentView {
                let point = NSPoint(x: xy[0], y: xy[1])
                let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
                var chain: [String] = []
                var view = hit
                while let v = view, chain.count < 6 {
                    chain.append(String(describing: type(of: v)))
                    view = v.superview
                }
                log("hittest \(argument) => \(chain.joined(separator: " < "))")
            }
        case "quit":
            NSApp.terminate(nil)
            return
        default:
            log("unknown command: \(command)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { run(rest) }
    }

    /// Captures one of our own windows via the window server (works without Screen Recording
    /// permission because the window belongs to this process).
    private static func snapshot(window: NSWindow?, to path: String) {
        guard let window, window.windowNumber > 0 else { log("snap: no window"); return }
        typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { log("snap: no capture API"); return }
        let capture = unsafeBitCast(symbol, to: CaptureFn.self)
        // .null rect, kCGWindowListOptionIncludingWindow (1 << 3), bounds-ignore-framing | nominal resolution.
        guard let image = capture(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 4))?.takeRetainedValue() else {
            log("snap: capture failed")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        log("snap \(path) \(image.width)x\(image.height)")
    }
}
// MARK: - Page tracing (TUFF_EXT_DEBUG)

extension DebugHooks {
    /// Logs how the 1Password website and the extension's content script talk to each other:
    /// the B5… DOM events each side fires and listens for, with the *names* of their fields
    /// only (the sign-in event carries the account password), plus the page's own errors.
    static func installPageTracer(into controller: WKUserContentController) {
        guard ProcessInfo.processInfo.environment["TUFF_EXT_DEBUG"] != nil else { return }
        controller.addUserScript(WKUserScript(source: pageTracer, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(PageTraceHandler.shared, name: "tuffPageTrace")
    }

    private static let pageTracer = #"""
    (function () {
      if (!/(^|\.)1password\.(com|ca|eu)$/.test(location.hostname)) return;
      var post = function (t) { try { window.webkit.messageHandlers.tuffPageTrace.postMessage(location.host + location.pathname + ' ' + String(t).slice(0, 500)); } catch (e) {} };
      var shape = function (d) {
        if (d === null || d === undefined) return String(d);
        if (typeof d !== 'object') return typeof d;
        try { return '{' + Object.keys(d).join(',') + '}'; } catch (e) { return 'object'; }
      };
      var interesting = /^(B5|b5|share-save|test-managed|open-extension|Check)/;
      var dispatch = EventTarget.prototype.dispatchEvent;
      EventTarget.prototype.dispatchEvent = function (event) {
        if (event && interesting.test(event.type)) post('page fires ' + event.type + ' detail=' + shape(event.detail));
        return dispatch.call(this, event);
      };
      var listen = EventTarget.prototype.addEventListener;
      var seen = {};
      EventTarget.prototype.addEventListener = function (type, fn, options) {
        if (interesting.test(type) && !seen[type]) { seen[type] = 1; post('page listens ' + type); }
        return listen.call(this, type, fn, options);
      };
      // Events the extension fires at the page (dispatched from its own world, so the hook
      // above can't see them).
      ['B5OPXReady', 'B5InitializeDevice', 'B5InitializeSession', 'B5RequestDelegatedSession', 'B5ExtensionPinStatusResponse',
       'B5TrustedDeviceUpgradeRequest', 'B5ForwardIAPReceiptToB5', 'B5ExtensionCanEnrollDesktopAppResponse', 'B5xCredentialHydrationResponse']
        .forEach(function (type) {
          listen.call(document, type, function (e) { post('extension fires ' + type + ' detail=' + shape(e.detail)); }, true);
        });
      ['error', 'warn'].forEach(function (level) {
        var original = console[level];
        console[level] = function () {
          try { post('console.' + level + ' ' + Array.prototype.map.call(arguments, function (a) { return a instanceof Error ? a.name + ': ' + a.message : (typeof a === 'string' ? a : shape(a)); }).join(' ')); } catch (e) {}
          return original.apply(this, arguments);
        };
      });
      window.addEventListener('error', function (e) { post('uncaught ' + e.message + ' @ ' + e.filename + ':' + e.lineno); });
      document.addEventListener('DOMContentLoaded', function () {
        setTimeout(function () { post('marker b5xBuildNumber=' + (document.body && document.body.dataset.b5xBuildNumber)); }, 3000);
      });
      post('tracer on');
    })();
    """#
}

private final class PageTraceHandler: NSObject, WKScriptMessageHandler {
    static let shared = PageTraceHandler()
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        ExtensionManager.shared.trace("page " + String(describing: message.body))
    }
}
#endif
