import AppKit
import Flint
import SwiftUI
import WebKit

extension Updater {
    /// Tuff's updater: it installs releases of this repo, stable or nightly
    /// (tagged like `v0.2.0-nightly.20261118`).
    static let app = Updater(source: GitHubSource("beckettclarke/TuffBrowser", assetPattern: "Tuff-*.zip"), channels: [.nightly])
}

final class AppDelegate: NSObject {
    private(set) static weak var shared: AppDelegate?

    /// The main window's state: the session that is saved and restored.
    let mainState = BrowserState.shared
    /// The state menu commands act on: the browser window in front, Incognito or not.
    var state: BrowserState { BrowserState.active }
    private var windowController: BrowserWindowController?
    /// Open Incognito windows. Each has its own state, dropped when it closes.
    private var incognitoControllers: [BrowserWindowController] = []
    private var settingsWindow: SettingsWindowController?
    /// The quit card on screen, if any.
    private var quitPromptID: UUID?
    /// Set once the user has said yes, so the follow-up `terminate` goes straight through.
    private var quitConfirmed = false
    /// Running downloads have been stopped for quitting (`pauseDownloadsThenQuit`).
    private var downloadsPausedForQuit = false
    /// Debug scripts run with a test profile, which normally skips the quit card.
    static var confirmQuitInTests = false
    /// Set when another copy was already running; this one hands over and quits.
    private var runningCopy: NSRunningApplication?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    // MARK: Windows

    func showMainWindow() {
        if windowController == nil {
            windowController = BrowserWindowController(state: mainState)
        }
        windowController?.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens a new Incognito window, with the command bar up to type where to go.
    @discardableResult
    func openIncognitoWindow(url: URL? = nil) -> BrowserState {
        let incognito = BrowserState.makeIncognito()
        let controller = BrowserWindowController(state: incognito)
        controller.onClose = { [weak self, weak controller] in
            incognito.tearDownAll()
            self?.incognitoControllers.removeAll { $0 === controller }
            // Site permissions answered in Incognito last only while some Incognito window is open.
            if self?.incognitoControllers.isEmpty ?? true {
                SitePermissions.shared.forgetIncognito()
                SiteSettings.shared.forgetIncognito()
                ExternalAppLinks.forgetIncognito()
                HTTPSUpgrade.forgetIncognito()
                // Incognito downloads leave the list with the last Incognito window.
                DownloadManager.shared.forgetPrivateItems()
            }
        }
        incognitoControllers.append(controller)
        controller.show()
        NSApp.activate(ignoringOtherApps: true)
        if let url {
            incognito.newTab(url: url)
        } else {
            incognito.openNewTab()
        }
        return incognito
    }

    /// Brings a browser window forward if none is: the main one.
    func ensureBrowserWindow() {
        if BrowserState.active === mainState { showMainWindow() }
    }

    /// The Settings window, if it is on screen (prompts raised from Settings are drawn in it).
    var visibleSettingsWindow: NSWindow? {
        settingsWindow.map(\.window).flatMap { $0.isVisible ? $0 : nil }
    }

    /// Opens Settings at `tab`, or with nil, at the page you last had open. `site` opens
    /// Websites on one site's settings.
    func showSettings(tab: SettingsTab? = nil, site: String? = nil) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(state: mainState) }
        settingsWindow?.show(tab, site: site)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Menu actions

    @objc func showAbout(_ sender: Any?) { showSettings(tab: .about) }
    @objc func showSettingsWindow(_ sender: Any?) { showSettings() }
    @objc func showExtensions(_ sender: Any?) { showSettings(tab: .extensions) }
    @objc func showBrowserWindow(_ sender: Any?) { showMainWindow() }

    @objc func showWelcome(_ sender: Any?) {
        showMainWindow()
        Onboarding.shared.show()
    }

    @objc func newTab(_ sender: Any?) {
        ensureBrowserWindow()
        state.openNewTab()
    }

    @objc func newIncognitoWindow(_ sender: Any?) { openIncognitoWindow() }

    @objc func openLocation(_ sender: Any?) {
        ensureBrowserWindow()
        state.openCommandBar(.editCurrent)
    }

    @objc func newSpace(_ sender: Any?) {
        ensureBrowserWindow()
        state.addSpace()
    }

    @objc func newFolder(_ sender: Any?) {
        ensureBrowserWindow()
        state.addFolder()
    }

    @objc func closeTab(_ sender: Any?) {
        let state = self.state
        // ⌘W closes whichever auxiliary window is in front (Settings, inspector), else the tab.
        if let key = NSApp.keyWindow, key !== state.window {
            key.performClose(sender)
        } else if state.commandBar != nil {
            state.closeCommandBar()
        } else {
            state.closeSelectedTab()
        }
    }

    @objc func reopenClosedTab(_ sender: Any?) { state.reopenClosedTab() }
    @objc func toggleSidebar(_ sender: Any?) { state.toggleSidebar() }
    @objc func toggleSidePanel(_ sender: Any?) { SidePanelManager.shared.toggleLast() }

    // MARK: Split view

    /// ⌘\: opens a page beside this one, or goes back to one page.
    @objc func toggleSplit(_ sender: Any?) { state.toggleSplit() }
    /// ⌥⌘\: gives the keyboard to the other side.
    @objc func focusOtherSplitSide(_ sender: Any?) { state.focusOtherSplitSide() }
    @objc func swapSplitSides(_ sender: Any?) { state.swapSplitSides() }
    @objc func reload(_ sender: Any?) { state.selectedTab?.reload() }
    @objc func reloadFromOrigin(_ sender: Any?) { state.selectedTab?.reload(fromOrigin: true) }
    @objc func stopLoading(_ sender: Any?) { state.selectedTab?.stop() }
    @objc func goBack(_ sender: Any?) { state.selectedTab?.goBack() }
    @objc func goForward(_ sender: Any?) { state.selectedTab?.goForward() }

    @objc func showHistory(_ sender: Any?) {
        ensureBrowserWindow()
        state.showHistory()
    }

    @objc func showImport(_ sender: Any?) { showSettings(tab: .importData) }
    @objc func copyLink(_ sender: Any?) { state.copyCurrentURL() }
    @objc func toggleReader(_ sender: Any?) { state.selectedTab?.toggleReader() }
    @objc func toggleTranslation(_ sender: Any?) { state.selectedTab?.toggleTranslation() }
    @objc func nextTab(_ sender: Any?) { state.selectAdjacentTab(offset: 1) }
    @objc func previousTab(_ sender: Any?) { state.selectAdjacentTab(offset: -1) }
    @objc func nextSpace(_ sender: Any?) { state.switchSpace(by: 1) }
    @objc func previousSpace(_ sender: Any?) { state.switchSpace(by: -1) }
    @objc func showInspector(_ sender: Any?) { state.selectedTab?.showInspector() }

    @objc func findInPage(_ sender: Any?) {
        guard state.selectedTab != nil else { return }
        if state.findVisible {
            // Already open: back into the field, with what was typed selected. (Hiding and
            // re-showing the bar to rebuild the field didn't always work: SwiftUI could merge
            // the two changes, leaving nothing rebuilt and the keyboard in the page.)
            state.focusFindField()
        } else {
            state.findVisible = true
        }
    }

    @objc func zoomIn(_ sender: Any?) {
        guard let tab = state.selectedTab else { return }
        if tab.reader != nil { ReaderSettings.shared.grow(); return }
        if let pdf = tab.pdf, pdf.isReady { pdf.zoomIn(); return }
        tab.setZoom(Tab.zoomStep(from: tab.pageZoom, up: true))
    }

    @objc func zoomOut(_ sender: Any?) {
        guard let tab = state.selectedTab else { return }
        if tab.reader != nil { ReaderSettings.shared.shrink(); return }
        if let pdf = tab.pdf, pdf.isReady { pdf.zoomOut(); return }
        tab.setZoom(Tab.zoomStep(from: tab.pageZoom, up: false))
    }

    @objc func zoomReset(_ sender: Any?) {
        if state.selectedTab?.reader != nil { ReaderSettings.shared.resetSize(); return }
        if let pdf = state.selectedTab?.pdf, pdf.isReady { pdf.setZoom(.auto); return }
        state.selectedTab?.setZoom(CGFloat(AppSettings.shared.advanced.defaultZoom))
    }

    @objc func togglePin(_ sender: Any?) {
        guard let tab = state.selectedTab, let section = state.section(of: tab) else { return }
        state.move(tab, to: section == .tabs ? .pinned : .tabs, in: state.currentSpace)
    }

    @objc func duplicateTab(_ sender: Any?) {
        if let tab = state.selectedTab { state.duplicate(tab) }
    }

    @objc func toggleMute(_ sender: Any?) {
        if let tab = state.selectedTab { tab.setMuted(!tab.isMuted) }
    }

    @objc func togglePictureInPicture(_ sender: Any?) { state.togglePictureInPicture() }

    @objc func selectTabByNumber(_ sender: NSMenuItem) { state.selectTab(atOrdinal: sender.tag) }
    @objc func selectSpaceByNumber(_ sender: NSMenuItem) { state.switchSpace(to: sender.tag - 1) }

    @objc func printPage(_ sender: Any?) {
        if let pdf = state.selectedTab?.pdf, pdf.isReady { pdf.print(); return }
        // In reader mode, the article prints rather than the page.
        guard let webView = state.selectedTab?.reader?.view ?? state.selectedTab?.webView, let window = state.window else { return }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
}

// MARK: - Menu validation

extension AppDelegate: NSMenuItemValidation {
    /// Greys out commands that would do nothing right now (Back with no history, Print with no
    /// page…), and names the toggles for what they will do. A disabled item's shortcut also goes
    /// on to the page instead of being swallowed.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let state = self.state
        let tab = state.selectedTab
        let pdfReady = tab?.pdf?.isReady ?? false
        switch menuItem.action {
        case #selector(goBack(_:)):
            return tab.map { $0.canGoBack || $0.pdfAwaitingCommit } ?? false
        case #selector(goForward(_:)):
            return tab?.canGoForward ?? false
        case #selector(reload(_:)), #selector(reloadFromOrigin(_:)):
            return tab?.url != nil
        case #selector(stopLoading(_:)):
            return tab.map { $0.isLoading || $0.pdf?.phase == .downloading } ?? false
        case #selector(printPage(_:)):
            return pdfReady || tab?.webView != nil
        case #selector(findInPage(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(zoomReset(_:)):
            return tab != nil
        case #selector(copyLink(_:)), #selector(duplicateTab(_:)):
            return tab?.url != nil
        case #selector(toggleReader(_:)):
            menuItem.title = tab?.reader != nil ? "Exit Reader Mode" : "Enter Reader Mode"
            return tab?.reader != nil || tab?.canUseReader == true
        case #selector(toggleTranslation(_:)):
            menuItem.title = tab?.translation != nil
                ? "Show Original"
                : "Translate to \(PageTranslation.name(of: PageTranslation.preferredTarget))"
            return tab?.translation != nil || (tab?.isAwake == true && tab?.pdf == nil && tab?.url != nil)
        case #selector(reopenClosedTab(_:)):
            return state.hasClosedTabs
        case #selector(togglePin(_:)):
            guard let tab, let section = state.section(of: tab) else {
                menuItem.title = "Pin Tab"
                return false
            }
            menuItem.title = switch section {
            case .tabs: "Pin Tab"
            case .pinned: "Unpin Tab"
            case .favorites: "Remove from Favourites"
            }
            return true
        case #selector(toggleSplit(_:)):
            let showing = state.visibleSplit != nil
            menuItem.title = showing ? "Close Split View" : "New Split View…"
            return showing || tab != nil
        case #selector(focusOtherSplitSide(_:)), #selector(swapSplitSides(_:)):
            return state.visibleSplit != nil
        case #selector(toggleMute(_:)):
            menuItem.title = tab?.isMuted == true ? "Unmute Tab" : "Mute Tab"
            return tab != nil
        case #selector(showInspector(_:)):
            return tab?.webView != nil && AppSettings.shared.advanced.webInspector
        case #selector(togglePictureInPicture(_:)):
            return tab?.isAwake == true || state.allTabs.contains { $0.isInPictureInPicture }
        case #selector(toggleSidebar(_:)):
            return state.tabLayout == .vertical
        case #selector(nextTab(_:)), #selector(previousTab(_:)):
            return state.orderedTabs(in: state.currentSpace).count > 1
        case #selector(selectTabByNumber(_:)):
            let count = state.orderedTabs(in: state.currentSpace).count
            return menuItem.tag >= 9 ? count > 0 : count >= menuItem.tag
        case #selector(nextSpace(_:)):
            return state.currentSpaceIndex + 1 < state.spaces.count
        case #selector(previousSpace(_:)):
            return state.currentSpaceIndex > 0
        case #selector(selectSpaceByNumber(_:)):
            return state.spaces.count >= menuItem.tag
        default:
            return validateMoreMenuItems(menuItem)
        }
    }
}

extension AppDelegate: NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if let other = Self.otherRunningCopy() {
            // Two copies on one profile run two sets of extensions over the same storage, and
            // they overwrite each other's state (1Password goes unresponsive after signing in).
            runningCopy = other
            other.activate()
            return
        }
        NSApp.mainMenu = MainMenu.build(target: self)
        ExtensionManager.shared.start()
        mainState.restore()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if runningCopy != nil {
            // Quit without saving anything: this copy never loaded the profile.
            exit(0)
        }
        // Starts reading history from disk in the background, before the first page wants it.
        _ = HistoryStore.shared
        // Puts the compiled ad-blocking lists on (or builds them) before the first page loads.
        ContentBlocker.shared.start()
        // Puts back saved torrents; the client stays off the network if there are none.
        TorrentBridge.setUp()
        showMainWindow()
        Onboarding.shared.showIfNeeded()
        #if DEBUG
        DebugHooks.runIfRequested()
        #else
        // Checks shortly after launch, then daily. Debug builds have their own bundle ID, which a
        // release would never match.
        Updater.app.start()
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let other = runningCopy {
            // Hand links to the copy that is already running, then leave.
            guard let app = other.bundleURL else { exit(0) }
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in exit(0) }
            return
        }
        // Magnet links and .torrent files go to the torrent client's add sheet.
        for url in urls where !TorrentBridge.open(url) { mainState.newTab(url: url) }
        if windowController != nil { showMainWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitConfirmed { return pauseDownloadsThenQuit() }
        let testing = Paths.testDataDirectory != nil && !Self.confirmQuitInTests
        let downloading = runningCopy == nil ? DownloadManager.shared.activeCount : 0
        // Downloads in progress are worth a card even with "confirm before quitting" off.
        guard runningCopy == nil, !testing, AppSettings.shared.behavior.confirmQuit || downloading > 0, !Self.isSystemQuit,
              !Self.updateInstalled
        else { return pauseDownloadsThenQuit() }

        // ⌘Q again while the card is up confirms it.
        if let id = quitPromptID {
            if PromptPresenter.currentID == id { PromptPresenter.resolve(true) }
            return .terminateCancel
        }

        let tabCount = BrowserState.all.flatMap(\.allTabs).filter { $0.url != nil }.count
        let tabsMessage = AppSettings.shared.general.restoreSession
            ? "Your tabs will be back next time you open Tuff."
            : "Your open tabs won’t be restored next time. Spaces, pinned tabs and favourites stay."
        let prompt = Prompt(
            icon: NSApp.applicationIconImage,
            title: "Quit Tuff?",
            subtitle: downloading > 0
                ? (downloading == 1 ? "1 download in progress" : "\(downloading) downloads in progress")
                : (tabCount == 1 ? "1 tab open" : "\(tabCount) tabs open"),
            message: downloading > 0
                ? "Downloads stop when Tuff quits. Next time, Resume in the downloads list carries on where each left off, if the site allows it."
                : tabsMessage,
            confirmTitle: "Quit",
            // "Don't ask again" is about the everyday quit card; downloads always ask.
            checkbox: downloading > 0 ? nil : "Don’t ask again",
            confirmKey: (KeyboardShortcut("q", modifiers: .command), "⌘Q")
        )
        quitPromptID = prompt.id
        Task { @MainActor in
            let result = await PromptPresenter.ask(prompt)
            quitPromptID = nil
            if result.checked { AppSettings.shared.behavior.confirmQuit = false }
            guard result.confirmed else { return }
            quitConfirmed = true
            NSApp.terminate(nil)
        }
        // The card answers later; quitting again goes through `quitConfirmed`.
        return .terminateCancel
    }

    /// Quits now, or once running downloads have stopped and handed back what they need to
    /// carry on later (`pauseAllForQuit`): this quit is called off, and a new one made then.
    /// (`.terminateLater` can't be used: when the quit comes from a block on the main queue,
    /// as the quit card's does, the stop callbacks queue up behind it and the app hangs.)
    /// Logout and shutdown aren't held up; their downloads just stop.
    private func pauseDownloadsThenQuit() -> NSApplication.TerminateReply {
        guard runningCopy == nil, !downloadsPausedForQuit, !Self.isSystemQuit,
              DownloadManager.shared.activeCount > 0 else { return .terminateNow }
        DownloadManager.shared.pauseAllForQuit { [weak self] in
            self?.downloadsPausedForQuit = true
            self?.quitConfirmed = true
            NSApp.terminate(nil)
        }
        return .terminateCancel
    }

    /// Logout, restart and shutdown carry a quit reason; those shouldn't stop to ask.
    private static var isSystemQuit: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication else { return false }
        return event.attributeDescriptor(forKeyword: kAEQuitReason) != nil
    }

    /// An update has replaced the app on disk (Flint's Restart Now), so this quit reopens Tuff:
    /// no card, which would leave the restart waiting on it.
    private static var updateInstalled: Bool {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        let onDisk = NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String
        return onDisk != nil && onDisk != Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainState.saveNow(synchronously: true)
        AppSettings.shared.saveNow()
        if AppSettings.shared.privacy.clearHistoryOnQuit {
            HistoryStore.shared.clear(synchronously: true)
        } else {
            HistoryStore.shared.saveNow(synchronously: true)
        }
        BookmarkStore.shared.saveNow(synchronously: true)
        DownloadManager.shared.saveNow(quitting: true)
        TorrentSession.shared.shutdown()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Another Tuff with this bundle ID (so the same profile) that is already running, e.g. the
    /// copy in /Applications while one from the build folder is open.
    private static func otherRunningCopy() -> NSRunningApplication? {
        if Paths.testDataDirectory != nil { return nil }  // test runs have a profile of their own
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first { $0.processIdentifier != me && !$0.isTerminated }
    }
}
