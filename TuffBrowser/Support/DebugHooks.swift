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

    static func runIfRequested() {
        guard let script = ProcessInfo.processInfo.environment["TUFF_DEBUG_SCRIPT"] else { return }
        // One command per line when the script has several lines (lets commands contain ";").
        let separator: Character = script.contains("\n") ? "\n" : ";"
        let commands = script.split(separator: separator).map { String($0).trimmed }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        ExtensionManager.shared.tracer = { log("trace " + $0) }
        run(commands[...])
    }

    /// The context menu item `rightclick` picks when the menu opens (`pickFromContextMenu`).
    static var contextMenuPick: String?

    /// Called by the page's context menu as it opens: logs its items, and picks the one a
    /// `rightclick` command named.
    static func pickFromContextMenu(_ menu: NSMenu) {
        guard ProcessInfo.processInfo.environment["TUFF_DEBUG_SCRIPT"] != nil else { return }
        log("contextmenu \(menu.items.map(\.title).filter { !$0.isEmpty })")
        guard let title = contextMenuPick else { return }
        contextMenuPick = nil
        guard let index = menu.items.firstIndex(where: { $0.title == title }) else {
            log("contextmenu: no item \(title)")
            return
        }
        DispatchQueue.main.async {
            menu.performActionForItem(at: index)
            menu.cancelTracking()
        }
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

    /// The window later commands act on: an Incognito one after `incognito`, until `main`.
    private static var target: BrowserState?

    private static func run(_ commands: ArraySlice<String>) {
        guard let command = commands.first else { return }
        let rest = commands.dropFirst()
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let name = parts[0]
        let argument = parts.count > 1 ? parts[1] : ""
        let state = target ?? BrowserState.shared
        var delay = 0.05

        switch name {
        case "incognito":
            // incognito [url] — opens an Incognito window; later commands act on it.
            target = AppDelegate.shared?.openIncognitoWindow(url: URL(string: argument))
            if !argument.isEmpty { target?.closeCommandBar() }
        case "main":
            target = nil
        case "layout":
            // layout vertical|horizontal [incognito]
            let words = argument.split(separator: " ")
            let value = TabLayout(rawValue: words.first.map(String.init) ?? "") ?? .vertical
            if words.count > 1 { AppSettings.shared.tabs.incognitoLayout = value } else { AppSettings.shared.tabs.layout = value }
        case "style":
            // style glass|vibrancy|solid|seamless
            // style glass|vibrancy|solid|seamless, or style incognito-seamless on|off
            if let style = BackgroundStyle(rawValue: argument) { AppSettings.shared.theme.style = style }
            if argument.hasPrefix("incognito-seamless") { AppSettings.shared.theme.incognitoSeamless = argument.hasSuffix("on") }
        case "headercolor":
            log("headercolor \(state.selectedTab?.headerColor.map { "\($0)" } ?? "nil") tint=\(state.currentTint)")
        case "wait":
            delay = Double(argument) ?? 1
        case "open":
            if let url = URL(string: argument) { state.newTab(url: url) }
        case "history":
            state.showHistory()
        case "bookmark":
            // bookmark — bookmarks the page on screen; bookmark folder <name>; bookmark bar on|off;
            // bookmark list
            let words = argument.split(separator: " ", maxSplits: 1).map(String.init)
            let profile = state.bookmarksProfileID
            switch words.first {
            case "folder":
                if let profile { BookmarkStore.shared.addFolder(named: words.count > 1 ? words[1] : "Folder", profile: profile) }
            case "bar":
                AppSettings.shared.tabs.showBookmarksBar = words.count > 1 && words[1] == "on"
            case "list":
                let items = profile.map { BookmarkStore.shared.items(for: $0) } ?? []
                log("bookmarks \(items.map { $0.isFolder ? "[\($0.displayTitle): \($0.children.count)]" : $0.displayTitle })")
            default:
                state.bookmarkCurrentPage()
            }
        case "import":
            // import <browser id> [history,bookmarks,spaces] — e.g. "import zen spaces"
            let words = argument.split(separator: " ").map(String.init)
            if let source = BrowserImporter.known.first(where: { $0.id == words.first }),
               let profile = BrowserImporter.profiles(for: source).first {
                let kinds = words.count > 1
                    ? Set(words[1].split(separator: ",").compactMap { ImportKind(rawValue: String($0)) })
                    : Set(source.kinds)
                let started = Date()
                let bundle = BrowserImporter.read(source, profile: profile, kinds: kinds)
                let summary = MainActor.assumeIsolated { BrowserImporter.apply(bundle, from: source, to: state) }
                log("import \(source.id) profile=\(profile.name) took=\(String(format: "%.2f", Date().timeIntervalSince(started)))s "
                    + "problems=\(bundle.problems) — \(summary.text)")
            } else {
                log("import: unknown browser \(argument)")
            }
        case "zoom":
            // zoom [level|reload] — sets the selected tab's zoom (or reloads it), then logs it.
            if argument == "reload" { state.selectedTab?.webView?.reload() }
            else if let level = Double(argument) { state.selectedTab?.setZoom(CGFloat(level)) }
            let tab = state.selectedTab
            log("zoom \(tab?.url?.absoluteString ?? "-") tab=\(tab?.pageZoom ?? 0) view=\(tab?.webView?.pageZoom ?? 0)")
        case "load":
            if let url = URL(string: argument) { state.selectedTab?.load(url) }
        case "snap":
            snapshot(window: state.window, to: argument)
        case "favicon":
            // favicon <path> — writes the selected tab's icon as a PNG (and logs whether it has one).
            let icon = state.selectedTab?.favicon
            if let png = icon?.pngData { try? png.write(to: URL(fileURLWithPath: argument)) }
            log("favicon \(icon.map { "\($0.size)" } ?? "nil") -> \(argument)")
        case "pagesnap":
            // pagesnap <path> — the selected tab's page as WebKit draws it. Unlike `snap`, this
            // works while the screen is locked (window capture comes back white then).
            let rest2 = rest
            guard let view = state.selectedTab?.webView else {
                log("pagesnap: no web view")
                break
            }
            view.takeSnapshot(with: nil) { image, error in
                if let png = image?.pngData {
                    try? png.write(to: URL(fileURLWithPath: argument))
                    log("pagesnap \(argument) \(Int(image!.size.width))x\(Int(image!.size.height))")
                } else {
                    log("pagesnap failed: \(error?.localizedDescription ?? "no image")")
                }
                run(rest2)
            }
            return
        case "snapall":
            for (i, window) in NSApp.windows.enumerated() where window.isVisible {
                snapshot(window: window, to: "\(argument)-\(i).png")
            }
        case "cmdbar":
            // cmdbar [edit|close]
            if argument == "close" { state.closeCommandBar() } else { state.openCommandBar(argument == "edit" ? .editCurrent : .newTab) }
        case "type":
            if let editor = (NSApp.keyWindow ?? state.window)?.firstResponder as? NSTextView {
                // "␣" types a space (script lines are trimmed, so a trailing space would be lost).
                editor.insertText(argument.replacingOccurrences(of: "␣", with: " "), replacementRange: editor.selectedRange())
            } else {
                log("type: no text editor focused (\(String(describing: (NSApp.keyWindow ?? state.window)?.firstResponder)))")
            }
        case "key":
            let selectors: [String: Selector] = [
                "enter": #selector(NSResponder.insertNewline(_:)), "esc": #selector(NSResponder.cancelOperation(_:)),
                "down": #selector(NSResponder.moveDown(_:)), "up": #selector(NSResponder.moveUp(_:)),
                "tab": #selector(NSResponder.insertTab(_:)), "backspace": #selector(NSResponder.deleteBackward(_:)),
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
        case "cleartabs":
            // Clears the current space's tab list as the divider's Clear button does, and logs what's left.
            let space = state.currentSpace
            state.clearTabs(in: space)
            log("cleartabs left=\(space.tabs.map(\.displayTitle)) selected=\(state.selectedTab?.displayTitle ?? "nil")")
        case "select":
            let list = state.orderedTabs(in: state.currentSpace)
            if let i = Int(argument), list.indices.contains(i) { state.select(list[i]) }
        case "split":
            // split <url> — opens url beside the selected tab; split <n> — puts tab n (as `select`
            // counts) beside it; split off|toggle|swap|other|fraction <0–1>; split state — logs the split.
            let words = argument.split(separator: " ").map(String.init)
            switch words.first ?? "" {
            case "off": state.closeSplit()
            case "toggle": state.toggleSplit()
            case "pair":
                // split pair <dragged n> <target n> — as dropping one tab's row onto another's.
                let list = state.orderedTabs(in: state.currentSpace)
                let n = words.dropFirst().compactMap { Int($0) }
                if n.count == 2, list.indices.contains(n[0]), list.indices.contains(n[1]) { state.pair(list[n[0]], with: list[n[1]]) }
            case "leave":
                let list = state.orderedTabs(in: state.currentSpace)
                if words.count > 1, let n = Int(words[1]), list.indices.contains(n) { state.leaveSplit(list[n]) }
            case "swap": state.swapSplitSides()
            case "other": state.focusOtherSplitSide()
            case "responder":
                // Hands the keyboard to the other side's page directly, as a click into it would.
                if let view = state.splitPartner?.webView { state.window?.makeFirstResponder(view) }
            case "fraction": state.setSplitFraction(Double(words.count > 1 ? words[1] : "") ?? 0.5)
            case "state":
                let split = state.visibleSplit
                let name = { (id: UUID?) in id.flatMap { id in state.allTabs.first { $0.id == id }?.displayTitle } ?? "nil" }
                log("split key=\(state.window?.isKeyWindow ?? false) active=\(NSApp.isActive) stored=\(state.currentSpace.split.map { "\(name($0.leading))|\(name($0.trailing))" } ?? "nil") frame=\(state.window?.contentView?.frame.size ?? .zero) showing=\(split != nil) leading=\(name(split?.leading)) trailing=\(name(split?.trailing)) fraction=\(split?.fraction ?? 0) selected=\(state.selectedTab?.displayTitle ?? "nil") partner=\(state.splitPartner?.displayTitle ?? "nil") partnerAwake=\(state.splitPartner?.isAwake ?? false) firstResponder=\(state.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") selectedInWindow=\(state.selectedTab?.webView?.window != nil) partnerInWindow=\(state.splitPartner?.webView?.window != nil) webViewsInWindow=\(state.allTabs.filter { $0.webView?.window != nil }.map(\.displayTitle))")
            default:
                if let n = Int(argument) {
                    let list = state.orderedTabs(in: state.currentSpace)
                    if list.indices.contains(n) { state.split(with: list[n]) }
                } else if let url = URL(string: argument) {
                    state.open(url: url, mode: .splitTab)
                }
            }
        case "drag":
            // drag <n> — as if tab n (as `select` counts) were being dragged; drag off — the drag ended.
            if argument == "off" {
                endSidebarDrag(state)
            } else if let n = Int(argument) {
                let list = state.orderedTabs(in: state.currentSpace)
                if list.indices.contains(n) { state.draggingTab = list[n] }
            }
        case "viewsnap":
            // viewsnap <path> — draws the window's views into a picture in-process, which (unlike
            // `snap`) needs no screen capture. Web pages may come out blank.
            guard let view = state.window?.contentView?.superview ?? state.window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { log("viewsnap: no view"); break }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: argument))
            log("viewsnap \(argument) \(rep.pixelsWide)x\(rep.pixelsHigh)")
        case "pagedrop":
            // pagedrop x y [hover] — feeds the page's drop view (`PageDropView`) a dragged tab at a
            // point in its own coordinates (top-left origin), hovering only or dropping too.
            let words = argument.split(separator: " ").map(String.init)
            let xy = words.prefix(2).compactMap { Double($0) }
            func find(_ view: NSView) -> PageDropView? {
                if let view = view as? PageDropView { return view }
                for sub in view.subviews { if let hit = find(sub) { return hit } }
                return nil
            }
            guard xy.count == 2, let root = state.window?.contentView, let view = find(root) else {
                log("pagedrop: no drop view")
                break
            }
            let point = CGPoint(x: xy[0], y: xy[1])
            let accepted = view.update?(point) ?? false
            log("pagedrop size=\(view.bounds.size) accepted=\(accepted)")
            if words.count < 3 { _ = view.drop?(point) }
        case "pin":
            if let tab = state.selectedTab { state.move(tab, to: .pinned) }
        case "folder":
            // folder [name] — new folder holding the selected tab (if any), named at once.
            let folder = state.addFolder(with: state.selectedTab)
            if !argument.isEmpty { state.rename(folder, to: argument) }
        case "foldertoggle":
            // foldertoggle <index>
            let folders = state.currentSpace.folders
            if let i = Int(argument), folders.indices.contains(i) { state.toggle(folders[i]) }
        case "foldertospace":
            // foldertospace <folder> <space> — moves a folder of the current space to another space.
            let parts = argument.split(separator: " ").compactMap { Int($0) }
            let folders = state.currentSpace.folders
            if parts.count == 2, folders.indices.contains(parts[0]), state.spaces.indices.contains(parts[1]) {
                state.move(folders[parts[0]], toSpace: state.spaces[parts[1]])
            }
            log("folders " + state.spaces.map { "\($0.name)=\($0.folders.map { "\($0.name)(\($0.tabs.count))" })" }.joined(separator: " "))
        case "tofolder":
            // tofolder <index> — moves the selected tab into that folder of the current space.
            let folders = state.currentSpace.folders
            if let tab = state.selectedTab, let i = Int(argument), folders.indices.contains(i) {
                state.move(tab, to: .pinned, in: state.currentSpace, folder: folders[i])
            }
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
            state.allTabs.filter { !state.isOnScreen($0) }.forEach { $0.sleep() }
        case "find":
            // find [query|next|prev|off] — opens the find bar (searching for query), steps
            // through matches, or closes it.
            switch argument {
            case "off": state.closeFind()
            case "next": state.findAgain(forward: true)
            case "prev": state.findAgain(forward: false)
            default:
                state.findVisible = true
                if !argument.isEmpty { state.findQuery = argument }
            }
        case "findstatus":
            log("findstatus \(state.findStatus)")
        case "action":
            // action <selector> — runs a menu command, e.g. "action viewSource".
            let sent = NSApp.sendAction(Selector(argument + ":"), to: AppDelegate.shared, from: nil)
            log("action \(argument) sent=\(sent)")
        case "site":
            // site js|popups on|off|default — this tab's site settings.
            let words = argument.split(separator: " ").map(String.init)
            let value: Bool? = words.last == "default" ? nil : words.last == "on"
            SiteSettings.shared.update(state.selectedTab?.url, incognito: state.isPrivate) { entry in
                if words.first == "js" { entry.javaScript = value } else { entry.popups = value }
            }
        case "complete":
            log("complete \(argument) => \(HistoryStore.shared.hostCompletion(for: argument, profileID: BrowserState.shared.currentProfile.id) ?? "-")")
        case "forward":
            state.selectedTab?.goForward()
        case "reload":
            state.selectedTab?.reload()
        case "pdf":
            // pdf sidebar|more|zoommenu|close|rotate|log, pdf zoom <level|fit|width|auto>,
            // pdf find <text>, pdf page <n>, pdf scroll <page|vertical|horizontal>,
            // pdf spreads <none|odd|even>, pdf tool <hand|select>, pdf select <a-b>
            let words = argument.split(separator: " ", maxSplits: 1).map(String.init)
            let value = words.count > 1 ? words[1] : ""
            guard let pdf = state.selectedTab?.pdf else {
                let list = state.selectedTab?.webView?.backForwardList
                log("pdf: no PDF showing url=\(state.selectedTab?.url?.absoluteString ?? "-") web=\(state.selectedTab?.webView?.url?.absoluteString ?? "-") "
                    + "back=\(list?.backList.map(\.url.absoluteString) ?? []) forward=\(list?.forwardList.map(\.url.absoluteString) ?? [])")
                break
            }
            switch words.first ?? "" {
            case "sidebar": pdf.sidebarVisible = value != "off"
            case "more": pdf.dropdown = .more
            case "zoommenu": pdf.dropdown = .zoom
            case "close": pdf.dropdown = nil
            case "rotate": pdf.rotate(clockwise: true)
            case "props": pdf.showProperties()
            case "export": pdf.exportPages()
            case "present": pdf.startPresentation()
            case "contents": pdf.sidebarPane = .outline
            case "focus":
                state.focusWebView()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    log("pdf focus inWindow=\(pdf.view.window === state.window) superview=\(pdf.view.superview != nil) responder=\(String(describing: state.window?.firstResponder))")
                }
            case "page": pdf.go(to: (Int(value) ?? 1) - 1)
            case "scroll": pdf.setScrollMode(PDFViewer.ScrollMode(rawValue: value) ?? .vertical)
            case "spreads": pdf.setSpreads(PDFViewer.Spreads(rawValue: value) ?? .none)
            case "tool": pdf.setTool(value == "hand" ? .hand : .select)
            case "select": pdf.selectedPages = Set(PageRanges.parse(value, count: pdf.pageCount) ?? [])
            case "find":
                state.findVisible = true
                pdf.find(value)
            case "zoom":
                switch value {
                case "fit": pdf.setZoom(.pageFit)
                case "width": pdf.setZoom(.pageWidth)
                case "auto": pdf.setZoom(.auto)
                default: pdf.setZoom(.custom, scale: CGFloat(Double(value) ?? 1))
                }
            default:
                let tab = state.selectedTab
                let list = tab?.webView?.backForwardList
                log("pdf phase=\(pdf.phase) url=\(pdf.url.absoluteString) title=\(pdf.displayTitle) pages=\(pdf.pageCount) page=\(pdf.pageIndex + 1) "
                    + "zoom=\(pdf.zoomLabel) mode=\(pdf.zoomMode) matches=\(pdf.matchCount) file=\(pdf.fileURL?.path ?? "-") "
                    + "tabURL=\(tab?.url?.absoluteString ?? "-") webURL=\(tab?.webView?.url?.absoluteString ?? "-") "
                    + "back=\(list?.backList.map(\.url.absoluteString) ?? []) forward=\(list?.forwardList.map(\.url.absoluteString) ?? []) "
                    + "firstResponder=\(String(describing: state.window?.firstResponder.map { type(of: $0) }))")
            }
        case "settings":
            AppDelegate.shared?.showSettings(tab: SettingsTab(rawValue: argument) ?? .general)
        case "settingsquery", "settingsfind":
            // settingsquery <words> types into the Settings search field; settingsfind also
            // presses Return (opens the best result and scrolls to it).
            if SettingsWindowController.current == nil { AppDelegate.shared?.showSettings() }
            SettingsWindowController.current?.debugSearch(argument, open: name == "settingsfind")
        case "permreq":
            // permreq host — shows the camera / microphone card on the selected tab.
            if let tab = state.selectedTab {
                withAnimation(Motion.snappy) {
                    tab.permissionRequest = PermissionRequest(host: argument, kind: .cameraAndMicrophone) { granted, remember in
                        log("permreq answered granted=\(String(describing: granted)) remember=\(remember)")
                        if let granted {
                            SitePermissions.shared.record(origin: "https://" + argument, kind: .cameraAndMicrophone, granted: granted, remember: remember, incognito: state.isPrivate)
                        }
                    }
                }
            }
        case "permanswer":
            // permanswer yes|no|none — answers (and remembers) the permission card on the selected tab.
            let request = state.selectedTab?.permissionRequest
            log("permanswer \(request.map { "\($0.host) \($0.kind.rawValue)" } ?? "no request")")
            state.selectedTab?.resolvePermission(granted: argument == "none" ? nil : argument != "no", remember: true)
        case "preset":
            if let style = BackgroundStyle(rawValue: argument) { AppSettings.shared.theme.style = style }
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
        case "onboarding":
            // onboarding [next|back|done|<step>] — shows the welcome screen, or moves it on.
            let onboarding = Onboarding.shared
            switch argument {
            case "": onboarding.show()
            case "next": onboarding.next()
            case "back": onboarding.back()
            case "done": onboarding.finish()
            default:
                let step = Onboarding.Step.allCases.first { "\($0)".lowercased() == argument.lowercased() }
                if let step { onboarding.go(to: step) } else { log("onboarding: no step \(argument)") }
            }
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
        case "blocker":
            // blocker on|off|allow — switches the built-in blocker, or allows the selected site.
            var privacy = AppSettings.shared.privacy
            if argument == "on" || argument == "off" {
                privacy.blockAds = argument == "on"
                AppSettings.shared.privacy = privacy
            } else if argument == "allow", let host = state.selectedTab?.url?.host {
                ContentBlocker.shared.toggleAllowed(host: host, reloading: state.selectedTab)
            }
            log("blocker enabled=\(AppSettings.shared.privacy.blockAds) allowed=\(AppSettings.shared.privacy.adBlockAllowlist)")
        case "popups":
            // popups — what the pop-up blocker stopped on the selected tab.
            let tab = state.selectedTab
            log("popups blocked=\(tab?.blockedPopups.map(\.absoluteString) ?? []) allowed=\(tab?.popupsAllowed ?? false)")
        case "historymenu":
            // historymenu — fills the History menu as if it opened, and logs its items.
            if let menu = NSApp.mainMenu?.item(withTitle: "History")?.submenu {
                HistoryMenuFiller.shared.menuNeedsUpdate(menu)
                let closed = menu.item(withTitle: "Recently Closed")?.submenu?.items.map(\.title) ?? []
                log("historymenu items=\(menu.items.map { $0.isSeparatorItem ? "—" : $0.title }) closed=\(closed)")
            }
        case "pasteandgo":
            // pasteandgo <text> — puts text on the clipboard and runs Paste and Go.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(argument, forType: .string)
            state.pasteAndGo()
        case "fsbanner":
            log("fsbanner \(FullScreenBanner.shared.debugState)")
        case "inspect":
            // inspect — opens Web Inspector for the selected tab (private _WKInspector.show).
            if let inspector = state.selectedTab?.webView?.value(forKey: "_inspector") as? NSObject,
               inspector.responds(to: NSSelectorFromString("show")) {
                inspector.perform(NSSelectorFromString("show"))
                log("inspect: shown")
            } else {
                log("inspect: no inspector")
            }
        case "capture":
            // capture — the selected tab's camera / microphone / full-screen state.
            let tab = state.selectedTab
            log("capture camera=\(tab?.cameraInUse ?? false) mic=\(tab?.microphoneInUse ?? false) fullscreen=\(tab?.isFullScreen ?? false)")
        case "js":
            let rest2 = rest
            state.selectedTab?.webView?.evaluateJavaScript(argument) { result, error in
                log("js \(argument.prefix(60)) => \(result.map { "\($0)" } ?? "nil") \(error.map { "ERR \($0.localizedDescription)" } ?? "")")
                run(rest2)
            }
            return
        case "engine":
            // engine — what WebKit's process pool is doing for the selected tab.
            if let pool = state.selectedTab?.webView?.configuration.value(forKey: "processPool") as? NSObject {
                func read(_ key: String) -> String { pool.responds(to: NSSelectorFromString(key)) ? "\(pool.value(forKey: key) ?? "nil")" : "n/a" }
                log("engine custom=\(pool !== (WKWebViewConfiguration().value(forKey: "processPool") as? NSObject)) cacheCapacity=\(read("_processCacheCapacity")) cached=\(read("_processCacheSize")) prewarmed=\(read("_hasPrewarmedWebProcess")) processes=\(read("_webProcessCount"))")
            } else {
                log("engine: no web view")
            }
        case "timeopen":
            // timeopen <url> — how long the main thread spends opening and closing a tab.
            guard let url = URL(string: argument) else { break }
            func ms(_ body: () -> Void) -> String {
                let start = CACurrentMediaTime()
                body()
                return String(format: "%.1f", (CACurrentMediaTime() - start) * 1000)
            }
            var configuration: WKWebViewConfiguration!
            let config = ms { configuration = WebEngine.makeConfiguration() }
            var view: TuffWebView!
            let create = ms { view = WebEngine.makeWebView(configuration: configuration) }
            let load = ms { view.load(URLRequest(url: url)) }
            let drop = ms { view.stopLoading(); view = nil; configuration = nil }
            var tab: Tab!
            let open = ms { tab = state.newTab(url: url) }
            let close = ms { state.close(tab) }
            log("timeopen config=\(config) webview=\(create) load=\(load) drop=\(drop) | newTab=\(open) close=\(close) ms")
        case "timeload":
            // timeload <url> — opens a tab and logs how long until the page has finished loading.
            guard let url = URL(string: argument) else { break }
            let rest2 = rest
            let start = CACurrentMediaTime()
            let tab = state.newTab(url: url)
            var observation: NSKeyValueObservation?
            var began = false
            observation = tab.webView?.observe(\.isLoading, options: [.initial, .new]) { view, _ in
                if view.isLoading { began = true; return }
                guard began else { return }
                observation?.invalidate()
                observation = nil
                log(String(format: "timeload %.0f ms  %@", (CACurrentMediaTime() - start) * 1000, url.host ?? url.lastPathComponent))
                DispatchQueue.main.async { run(rest2) }
            }
            return
        case "pattern":
            // pattern — puts a high-contrast test pattern behind the window, to judge the glass.
            PerfProbe.showPattern(behind: state.window)
        case "snapscreen":
            // snapscreen <path> — the window as composited on screen, with whatever shows
            // through it (unlike `snap`, which captures the window alone).
            log("snapscreen \(argument) " + PerfProbe.captureScreen(under: state.window, to: argument))
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
        case "press":
            // press [cmd+][shift+][opt+]<letter> — a real key press through the event queue, so it
            // takes the same path as the keyboard (the focused web view sees it first).
            var flags: NSEvent.ModifierFlags = []
            let words = argument.lowercased().split(separator: "+").map(String.init)
            for word in words.dropLast() {
                switch word {
                case "cmd": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "opt", "alt": flags.insert(.option)
                case "ctrl": flags.insert(.control)
                default: break
                }
            }
            let letters = "asdfhgzxcv bqweryt123465=97-80]ou[ip lj'k;\\,/nm.\t"
            guard let key = words.last.map({ $0 == "tab" ? "\t" : $0 }), key.count == 1,
                  let index = letters.firstIndex(of: Character(key)),
                  let window = state.window else { log("press: bad key \(argument)"); break }
            let code = UInt16(letters.distance(from: letters.startIndex, to: index))
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                    isARepeat: false, keyCode: code
                ) { NSApp.postEvent(event, atStart: false) }
            }
        case "responder":
            let window = NSApp.keyWindow ?? state.window
            let editor = window?.firstResponder as? NSTextView
            let text = editor.map {
                let owner = ($0.delegate as? NSView)?.identifier?.rawValue ?? String(describing: $0.delegate.map { type(of: $0) })
                return " text=\"\($0.string)\" selected=\(NSStringFromRange($0.selectedRange())) field=\(owner)"
            } ?? ""
            log("responder tabs=\(state.allTabs.count) selected=\(state.selectedTab?.url?.absoluteString ?? "-") key=\(window?.isKeyWindow ?? false) active=\(NSApp.isActive) \(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")\(text)")        case "waitjs":
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
        case "pagemenu":
            // pagemenu [off|screenshot] — opens / closes the page menu off the address bar.
            if argument == "screenshot" { PageMenu.openOn = .screenshot }
            state.pageMenuVisible = argument != "off"
        case "readersnap":
            // readersnap <path> — reader mode's article as WebKit draws it (works with the screen locked).
            let rest2 = rest
            guard let view = state.selectedTab?.reader?.view else { log("readersnap: not in reader mode"); run(rest2); return }
            view.takeSnapshot(with: nil) { image, error in
                if let image, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: argument))
                    log("readersnap \(argument) \(Int(image.size.width))x\(Int(image.size.height))")
                } else {
                    log("readersnap failed \(error.map { "\($0)" } ?? "")")
                }
                run(rest2)
            }
            return
        case "readerjs":
            // readerjs <js> — evaluates in reader mode's own web view.
            let rest2 = rest
            if let view = state.selectedTab?.reader?.view {
                view.evaluateJavaScript(argument) { result, error in
                    log("readerjs \(argument.prefix(60)) => \(result.map { "\($0)" } ?? "nil") \(error.map { "ERR \($0)" } ?? "")")
                    run(rest2)
                }
            } else {
                log("readerjs: not in reader mode")
                run(rest2)
            }
            return
        case "readerprobe":
            // readerprobe — runs reader mode's article extraction and logs what came back (or the error).
            let rest2 = rest
            let started = Date()
            state.selectedTab?.webView?.callAsyncJavaScript(ReaderScript.extract, arguments: ["debug": true], in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let value):
                    let dict = value as? [String: Any]
                    log("readerprobe \(Int(Date().timeIntervalSince(started) * 1000))ms title=\(dict?["title"] ?? "-") html=\((dict?["html"] as? String)?.count ?? 0) failed=\(dict?["failed"] ?? "-") \(dict.map { d in d.filter { $0.key != "html" } }.map { "\($0)" } ?? "nil")")
                case .failure(let error):
                    log("readerprobe ERR \(error)")
                }
                run(rest2)
            }
            return
        case "reader":
            // reader [on|off|toggle|theme …|font …] — reader mode on the selected tab, then logs what it found.
            let tab = state.selectedTab
            switch argument {
            case "on": tab?.openReader()
            case "off": tab?.closeReader()
            case "toggle": tab?.toggleReader()
            default:
                // reader theme <auto|light|sepia|dark> / reader font <serif|sans>
                let words = argument.split(separator: " ").map(String.init)
                if words.count == 2, words[0] == "theme", let theme = ReaderTheme(rawValue: words[1]) { ReaderSettings.shared.prefs.theme = theme }
                if words.count == 2, words[0] == "font", let font = ReaderFont(rawValue: words[1]) { ReaderSettings.shared.prefs.font = font }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let a = tab?.reader?.article
                log("reader active=\(tab?.reader != nil) available=\(tab?.canUseReader ?? false) title=\(a?.title ?? "-") byline=\(a?.byline ?? "-") site=\(a?.siteName ?? "-") date=\(a?.published ?? "-") minutes=\(a?.minutes ?? 0) html=\(a?.html.count ?? 0)")
                run(rest)
            }
            return
        case "extpin":
            // extpin <action index> on|off — pins an extension to the sidebar or the page menu.
            let words = argument.split(separator: " ").map(String.init)
            let actions = ExtensionManager.shared.actions(for: state.selectedTab)
            if let i = words.first.flatMap({ Int($0) }), actions.indices.contains(i) {
                ExtensionManager.shared.setPinned(words.last != "off", id: actions[i].id)
            }
            log("extpin " + ExtensionManager.shared.actions(for: state.selectedTab).map { "\($0.name)=\($0.pinned)" }.joined(separator: ","))
        case "screenshot":
            // screenshot visible|full|select | area x y w h — captures into the editor.
            let words = argument.split(separator: " ").map(String.init)
            switch words.first {
            case "full": Screenshotter.start(.fullPage, in: state)
            case "select": Screenshotter.start(.area, in: state)
            case "area":
                let v = words.dropFirst().compactMap { Double($0) }
                if v.count == 4, let tab = state.selectedTab, let webView = tab.webView {
                    Screenshotter.snap(webView, rect: CGRect(x: v[0], y: v[1], width: v[2], height: v[3]), mode: .area, tab: tab, state: state)
                }
            default: Screenshotter.start(.visible, in: state)
            }
            delay = 1
        case "shot":
            // shot info | save <path> | markup | tool <name> | close
            let words = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard let session = state.screenshot else { log("shot: no screenshot"); break }
            switch words.first {
            case "save":
                if words.count > 1, let png = session.pngData { try? png.write(to: URL(fileURLWithPath: words[1])) }
                log("shot saved \(words.last ?? "")")
            case "markup":
                // A sample of every tool, to look at.
                let w = session.pointSize.width, h = min(session.pointSize.height, 700)
                let colors = ScreenshotSession.palette
                session.commit(Annotation(tool: .arrow, color: colors[0], width: 4.5, points: [CGPoint(x: w * 0.15, y: h * 0.2), CGPoint(x: w * 0.4, y: h * 0.45)]))
                session.commit(Annotation(tool: .box, color: colors[3], width: 4.5, points: [CGPoint(x: w * 0.5, y: h * 0.15), CGPoint(x: w * 0.85, y: h * 0.4)]))
                session.commit(Annotation(tool: .highlighter, color: colors[1], width: 4.5, points: stride(from: 0.1, through: 0.6, by: 0.05).map { CGPoint(x: w * $0, y: h * 0.62) }))
                session.commit(Annotation(tool: .pen, color: colors[2], width: 4.5, points: stride(from: 0.0, through: 6.3, by: 0.3).map { CGPoint(x: w * 0.7 + cos($0) * 40, y: h * 0.7 + sin($0) * 40) }))
                var text = Annotation(tool: .text, color: colors[5], width: 4.5, points: [CGPoint(x: w * 0.15, y: h * 0.8)])
                text.text = "Look here"
                session.commit(text)
            case "tool":
                session.tool = AnnotationTool(rawValue: words.last ?? "") ?? session.tool
            case "pick":
                // shot pick x y — what the Select tool would pick at an image point.
                let v = (words.count > 1 ? words[1] : "").split(separator: " ").compactMap { Double($0) }
                session.tool = .select
                if v.count == 2 { session.select(AnnotationGeometry.hit(session.annotations, at: CGPoint(x: v[0], y: v[1]), tolerance: 5)?.id) }
                log("shot picked \(session.selected.map { "\($0.tool.rawValue) frame=\(AnnotationGeometry.frame($0))" } ?? "nothing")")
            case "edit":
                // shot edit move dx dy | edit <handle> x y — drags the selection, as one undo step.
                let v = (words.count > 1 ? words[1] : "").split(separator: " ").map(String.init)
                if let a = session.selected, v.count == 3, let x = Double(v[1]), let y = Double(v[2]) {
                    let handles: [String: AnnotationHandle] = ["start": .start, "end": .end, "tl": .topLeading, "tr": .topTrailing, "bl": .bottomLeading, "br": .bottomTrailing]
                    session.update(a.id) { item in
                        if v[0] == "move" { item = AnnotationGeometry.moved(a, by: CGSize(width: x, height: y)) }
                        else if let h = handles[v[0]] { item = AnnotationGeometry.resized(a, handle: h, to: CGPoint(x: x, y: y)) }
                    }
                    log("shot edited \(session.selected.map { "\($0.points.prefix(2)) frame=\(AnnotationGeometry.frame($0))" } ?? "-")")
                }
            case "delete":
                if let id = session.selectedID { session.delete(id) }
            case "undo":
                session.undo()
            case "redo":
                session.redo()
            case "close":
                state.screenshot = nil
            default: break
            }
            log("shot \(session.mode.rawValue) \(session.image.width)x\(session.image.height) points=\(session.pointSize) annotations=\(session.annotations.count)")
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
                log("window frame=\(window.frame) visible=\(window.occlusionState.contains(.visible)) lights=\(buttons.map { $0.convert($0.bounds, to: nil) }) firstResponder=\(type(of: window.firstResponder as Any))")
            }
        case "rightclick":
            // rightclick x y [item title] — a real right-click at a window point; the page's
            // context menu opens, its items are logged, and the titled one (if any) is picked.
            let words = argument.split(separator: " ", maxSplits: 2).map(String.init)
            let xy = words.prefix(2).compactMap { Double($0) }
            contextMenuPick = words.count > 2 ? words[2] : nil
            if xy.count == 2, let window = state.window {
                for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                    if let event = NSEvent.mouseEvent(
                        with: type, location: NSPoint(x: xy[0], y: xy[1]), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                    ) {
                        window.sendEvent(event)
                    }
                }
            }
        case "resolve":
            // resolve <text> — what typing it in the command bar would open.
            log("resolve \(argument) => \(BrowserState.resolve(argument, engine: AppSettings.shared.general.searchEngine).absoluteString)")
        case "sheet":
            // sheet — logs the sheet on the browser window (a save panel, say) and cancels it.
            let sheet = state.window?.attachedSheet
            log("sheet \(sheet.map { "\(type(of: $0)) name=\(($0 as? NSSavePanel)?.nameFieldStringValue ?? "-")" } ?? "none")")
            if let panel = sheet as? NSSavePanel {
                panel.cancel(nil)
            } else if let sheet {
                state.window?.endSheet(sheet, returnCode: .cancel)
            }
        case "downloads":
            if argument == "retry", let item = DownloadManager.shared.items.first(where: { DownloadManager.shared.canRetry($0) }) {
                log("downloads retry \(item.filename) resume=\(item.resumeData != nil)")
                DownloadManager.shared.retry(item)
            }
            for item in DownloadManager.shared.items {
                log("download \(item.filename) state=\(item.state) dest=\(item.destination?.path ?? "-") bytes=\(item.bytesReceived)")
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
        case "move", "middleclick":
            // move x y — the pointer moves to a window point (origin bottom-left);
            // middleclick x y — a middle-button click there. Both go through the event queue,
            // so the app's event monitors see them (`onMiddleClick`).
            let xy = argument.split(separator: " ").compactMap { Double($0) }
            if xy.count == 2, let window = state.window {
                let types: [NSEvent.EventType] = name == "move" ? [.mouseMoved] : [.otherMouseDown, .otherMouseUp]
                for type in types {
                    guard let cg = CGEvent(
                        mouseEventSource: nil,
                        mouseType: type == .mouseMoved ? .mouseMoved : type == .otherMouseDown ? .otherMouseDown : .otherMouseUp,
                        mouseCursorPosition: .zero, mouseButton: .center
                    ) else { continue }
                    cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
                    cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                    let screen = window.convertPoint(toScreen: NSPoint(x: xy[0], y: xy[1]))
                    cg.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
                    if let event = NSEvent(cgEvent: cg) { NSApp.postEvent(event, atStart: false) }
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
