import AppKit
import Sparkle
import SwiftUI
import WebKit

final class AppDelegate: NSObject {
    private(set) static weak var shared: AppDelegate?

    let state = BrowserState.shared
    private var windowController: BrowserWindowController?
    private var settingsWindow: SettingsWindowController?
    private let updater = UpdateController()
    /// The quit card on screen, if any.
    private var quitPromptID: UUID?
    /// Set once the user has said yes, so the follow-up `terminate` goes straight through.
    private var quitConfirmed = false
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
            windowController = BrowserWindowController(state: state)
        }
        windowController?.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The Settings window, if it is on screen (prompts raised from Settings are drawn in it).
    var visibleSettingsWindow: NSWindow? {
        settingsWindow.map(\.window).flatMap { $0.isVisible ? $0 : nil }
    }

    func showSettings(tab: SettingsTab) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(state: state) }
        settingsWindow?.show(tab)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Menu actions

    @objc func showAbout(_ sender: Any?) { showSettings(tab: .about) }
    @objc func showSettingsWindow(_ sender: Any?) { showSettings(tab: .general) }
    @objc func showExtensions(_ sender: Any?) { showSettings(tab: .extensions) }
    @objc func checkForUpdates(_ sender: Any?) { updater.checkForUpdates() }
    @objc func showBrowserWindow(_ sender: Any?) { showMainWindow() }

    @objc func newTab(_ sender: Any?) {
        showMainWindow()
        state.openCommandBar(.newTab)
    }

    @objc func openLocation(_ sender: Any?) {
        showMainWindow()
        state.openCommandBar(.editCurrent)
    }

    @objc func newSpace(_ sender: Any?) {
        showMainWindow()
        state.addSpace()
    }

    @objc func closeTab(_ sender: Any?) {
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
    @objc func reload(_ sender: Any?) { state.selectedTab?.reload() }
    @objc func reloadFromOrigin(_ sender: Any?) { state.selectedTab?.reload(fromOrigin: true) }
    @objc func stopLoading(_ sender: Any?) { state.selectedTab?.stop() }
    @objc func goBack(_ sender: Any?) { state.selectedTab?.goBack() }
    @objc func goForward(_ sender: Any?) { state.selectedTab?.goForward() }
    @objc func copyLink(_ sender: Any?) { state.copyCurrentURL() }
    @objc func nextTab(_ sender: Any?) { state.selectAdjacentTab(offset: 1) }
    @objc func previousTab(_ sender: Any?) { state.selectAdjacentTab(offset: -1) }
    @objc func nextSpace(_ sender: Any?) { state.switchSpace(by: 1) }
    @objc func previousSpace(_ sender: Any?) { state.switchSpace(by: -1) }
    @objc func showInspector(_ sender: Any?) { state.selectedTab?.showInspector() }

    @objc func findInPage(_ sender: Any?) {
        guard state.selectedTab != nil else { return }
        if state.findVisible {
            // Toggle off and on so the field takes focus again.
            state.findVisible = false
            DispatchQueue.main.async { self.state.findVisible = true }
        } else {
            state.findVisible = true
        }
    }

    @objc func zoomIn(_ sender: Any?) {
        guard let tab = state.selectedTab else { return }
        tab.setZoom(tab.pageZoom * 1.1)
    }

    @objc func zoomOut(_ sender: Any?) {
        guard let tab = state.selectedTab else { return }
        tab.setZoom(tab.pageZoom / 1.1)
    }

    @objc func zoomReset(_ sender: Any?) { state.selectedTab?.setZoom(CGFloat(AppSettings.shared.advanced.defaultZoom)) }

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
        guard let webView = state.selectedTab?.webView, let window = state.window else { return }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
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
        state.restore()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if runningCopy != nil {
            // Quit without saving anything: this copy never loaded the profile.
            exit(0)
        }
        showMainWindow()
        updater.start()
        #if DEBUG
        DebugHooks.runIfRequested()
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let other = runningCopy {
            // Hand links to the copy that is already running, then leave.
            guard let app = other.bundleURL else { exit(0) }
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in exit(0) }
            return
        }
        for url in urls { state.newTab(url: url) }
        if windowController != nil { showMainWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitConfirmed { return .terminateNow }
        let testing = Paths.testDataDirectory != nil && !Self.confirmQuitInTests
        guard runningCopy == nil, !testing, AppSettings.shared.behavior.confirmQuit, !Self.isSystemQuit else { return .terminateNow }

        // ⌘Q again while the card is up confirms it.
        if let id = quitPromptID {
            if PromptPresenter.currentID == id { PromptPresenter.resolve(true) }
            return .terminateCancel
        }

        let tabCount = state.allTabs.filter { $0.url != nil }.count
        let prompt = Prompt(
            icon: NSApp.applicationIconImage,
            title: "Quit Tuff?",
            subtitle: tabCount == 1 ? "1 tab open" : "\(tabCount) tabs open",
            message: AppSettings.shared.general.restoreSession
                ? "Your tabs will be back next time you open Tuff."
                : "Your tabs won’t be restored next time.",
            confirmTitle: "Quit",
            checkbox: "Don’t ask again",
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

    /// Logout, restart and shutdown carry a quit reason; those shouldn't stop to ask.
    private static var isSystemQuit: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication else { return false }
        return event.attributeDescriptor(forKeyword: kAEQuitReason) != nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.saveNow()
        if AppSettings.shared.privacy.clearHistoryOnQuit {
            HistoryStore.shared.clear(synchronously: true)
        } else {
            HistoryStore.shared.saveNow(synchronously: true)
        }
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

/// Sparkle wrapper. The updater only starts once a feed URL and signing key are configured,
/// so development builds don't nag about a missing appcast.
final class UpdateController {
    private var controller: SPUStandardUpdaterController?

    var isConfigured: Bool {
        let info = Bundle.main.infoDictionary
        let feed = info?["SUFeedURL"] as? String ?? ""
        let key = info?["SUPublicEDKey"] as? String ?? ""
        return feed.hasPrefix("https://") && !key.isEmpty
    }

    func start() {
        guard isConfigured, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        if let controller {
            controller.checkForUpdates(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Updates aren’t set up for this build"
        alert.informativeText = "Set TUFF_APPCAST_URL and TUFF_SPARKLE_PUBLIC_KEY in project.yml (see the README), then rebuild. Sparkle will handle the rest."
        alert.runModal()
    }
}
