import AppKit
import Observation
import SwiftUI
import WebKit

enum TabSection: Equatable { case favorites, pinned, tabs }

enum CommandBarMode: Equatable {
    /// ⌘T — the result opens in a new tab.
    case newTab
    /// ⌘L — the result replaces the current tab.
    case editCurrent
}

/// A regular tab that was closed, kept so ⇧⌘T can bring it back where it was, history and all.
/// Saved with the session, so the list outlives a relaunch.
struct ClosedTab: Codable {
    var url: URL
    var title: String
    var spaceID: UUID
    /// Where it sat in its space's tab list.
    var index: Int?
    /// Back / forward history (`Tab.sessionState`).
    var sessionState: Data?
    /// Stable identifier for `chrome.sessions`; optional so older sessions still decode.
    var id: UUID?
    /// When the tab was closed, for `chrome.sessions` `lastModified`.
    var closedAt: Date?
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var symbol: String
    var text: String
}

/// The single source of truth for the browser window: spaces, tabs, selection and chrome state.
@Observable
final class BrowserState {
    static let shared = BrowserState()

    var spaces: [Space] = []
    /// Every space belongs to one profile; spaces on the same profile share its favourites.
    var profiles: [Profile] = []
    var currentSpaceIndex = 0
    /// Position of the sidebar pager in pages. Fractional while a swipe is in flight.
    var pagerPosition: Double = 0

    var sidebarVisible = true
    /// The sidebar is collapsed but temporarily floating over the page (mouse at the window edge).
    var sidebarPeeking = false
    var isFullscreen = false
    var commandBar: CommandBarMode?
    var findVisible = false
    var toast: Toast?
    /// The dialog card covering a window, if one is up (see `PromptPresenter`).
    var prompt: Prompt?
    var draggingTab: Tab?
    /// A folder being dragged within its space's pinned section.
    var draggingFolder: Folder?
    var editingSpaceID: UUID?
    /// The folder whose name is being edited in the sidebar.
    var renamingFolderID: UUID?
    /// The tab whose name is being edited in the sidebar.
    var renamingTabID: UUID?
    var downloadsVisible = false

    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var closedTabs: [ClosedTab] = []
    private static let closedTabLimit = 30
    @ObservationIgnored private let saver = Debouncer(delay: 1)
    @ObservationIgnored private var sleepTimer: Timer?
    /// The tab that was on screen before a selection change still being handed over (see
    /// `selectionDidChange(from:)`); `pipHandoffPending` says whether one is.
    @ObservationIgnored private weak var pipHandoffFrom: Tab?
    @ObservationIgnored private var pipHandoffPending = false
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var pendingURLs: [URL] = []

    private let sessionFile = Paths.appSupport.appendingPathComponent("session.json")
    private var settings: AppSettings { .shared }

    private init() {}

    // MARK: Lookups

    var currentSpace: Space {
        spaces[max(0, min(currentSpaceIndex, spaces.count - 1))]
    }

    /// The profile a space belongs to (the first one if its profile has gone missing).
    func profile(for space: Space) -> Profile {
        profiles.first { $0.id == space.profileID } ?? profiles[0]
    }

    var currentProfile: Profile { profile(for: currentSpace) }

    /// The favourites grid showing now: the current space's profile's.
    var favorites: [Tab] { spaces.isEmpty || profiles.isEmpty ? [] : currentProfile.favorites }

    func favorites(in space: Space) -> [Tab] { profile(for: space).favorites }

    func spaces(in profile: Profile) -> [Space] { spaces.filter { $0.profileID == profile.id } }

    /// The profile a tab belongs to: the one whose favourites hold it, or its space's.
    func profile(containing tab: Tab) -> Profile? {
        if let profile = profiles.first(where: { $0.favorites.contains { $0 === tab } }) { return profile }
        return space(containing: tab).map { profile(for: $0) }
    }

    /// Cookies and site data for a tab's web pages: its profile's.
    func dataStore(for tab: Tab) -> WKWebsiteDataStore {
        (profile(containing: tab) ?? (spaces.isEmpty || profiles.isEmpty ? nil : currentProfile))?.dataStore ?? DataStores.website
    }

    var selectedTab: Tab? {
        guard !spaces.isEmpty, let id = currentSpace.selectedTabID else { return nil }
        return tab(withID: id, in: currentSpace)
    }

    func tab(withID id: UUID, in space: Space) -> Tab? {
        favorites(in: space).first { $0.id == id } ?? space.allPinned.first { $0.id == id } ?? space.tabs.first { $0.id == id }
    }

    /// Favourites, then the space's pinned tabs, then its regular tabs — the order shown in the sidebar.
    /// Tabs in collapsed folders are left out, apart from the one showing.
    func orderedTabs(in space: Space) -> [Tab] {
        let pinned = space.pinnedItems.flatMap { item -> [Tab] in
            switch item {
            case .tab(let tab): [tab]
            case .folder(let folder): folder.isOpen ? folder.tabs : folder.tabs.filter { $0.id == space.selectedTabID }
            }
        }
        return favorites(in: space) + pinned + space.tabs
    }

    var allTabs: [Tab] { profiles.flatMap(\.favorites) + spaces.flatMap { $0.allPinned + $0.tabs } }

    func space(containing tab: Tab) -> Space? {
        spaces.first { $0.allPinned.contains { $0 === tab } || $0.tabs.contains { $0 === tab } }
    }

    func folder(containing tab: Tab) -> Folder? {
        for space in spaces { if let folder = space.folder(containing: tab) { return folder } }
        return nil
    }

    func section(of tab: Tab) -> TabSection? {
        if profiles.contains(where: { $0.favorites.contains { $0 === tab } }) { return .favorites }
        guard let space = space(containing: tab) else { return nil }
        return space.allPinned.contains { $0 === tab } ? .pinned : .tabs
    }

    /// The tint currently showing, blended between neighbours while swiping spaces.
    var currentTint: NSColor {
        guard settings.theme.useSpaceColors, !spaces.isEmpty else { return NSColor(hex: settings.theme.tintHex) }
        let p = max(0, min(Double(spaces.count - 1), pagerPosition))
        let lower = Int(p.rounded(.down))
        let upper = min(spaces.count - 1, lower + 1)
        return spaces[lower].color.mixed(with: spaces[upper].color, fraction: CGFloat(p - Double(lower)))
    }

    private func animate(_ animation: Animation = Motion.snappy, _ body: () -> Void) {
        if settings.animationsEnabled {
            withAnimation(animation, body)
        } else {
            body()
        }
    }

    // MARK: Tabs

    @discardableResult
    func newTab(
        url: URL?, select: Bool = true, in targetSpace: Space? = nil,
        configuration: WKWebViewConfiguration? = nil, after opener: Tab? = nil
    ) -> Tab {
        guard restored else {
            if let url { pendingURLs.append(url) }
            return Tab(url: url)
        }
        let space = targetSpace ?? opener.flatMap { self.space(containing: $0) } ?? currentSpace
        let tab = Tab(url: url)
        tab.browser = self
        tab.openerTab = opener
        var index = settings.tabs.newTabPosition == .top ? 0 : space.tabs.count
        if let opener, let i = space.tabs.firstIndex(where: { $0 === opener }) { index = i + 1 }
        animate { space.tabs.insert(tab, at: index) }
        if configuration != nil || url != nil { tab.wake(configuration: configuration, opener: opener) }
        ExtensionManager.shared.didOpen(tab)
        if select { self.select(tab) }
        scheduleSave()
        return tab
    }

    func select(_ tab: Tab) {
        let previous = selectedTab
        if let owner = space(containing: tab), owner !== currentSpace, let index = spaces.firstIndex(where: { $0 === owner }) {
            switchSpace(to: index)
        }
        let space = currentSpace
        previous?.lastActive = Date()
        tab.lastActive = Date()
        tab.wake()
        if space.selectedTabID != tab.id {
            animate(Motion.quick) { space.selectedTabID = tab.id }
        }
        findVisible = false
        if previous !== tab { ExtensionManager.shared.didActivate(tab, previous: previous) }
        selectionDidChange(from: previous)
        updateWindowTitle()
        focusWebView()
        scheduleSave()
    }

    func close(_ tab: Tab) {
        guard let section = section(of: tab) else { return }
        let wasSelected = selectedTab === tab

        // Pick what each affected space should show next, before the lists change.
        for space in spaces where space.selectedTabID == tab.id {
            space.selectedTabID = neighbour(of: tab, in: space)?.id
        }

        switch section {
        case .favorites, .pinned:
            // Pinned tabs never go away; closing one unloads it and sends it home.
            tab.sleep(resetToHome: true)
        case .tabs:
            if let url = tab.url, let space = space(containing: tab) {
                closedTabs.append(ClosedTab(
                    url: url, title: tab.title, spaceID: space.id,
                    index: space.tabs.firstIndex { $0 === tab }, sessionState: tab.sessionState,
                    id: UUID(), closedAt: Date()
                ))
                if closedTabs.count > Self.closedTabLimit { closedTabs.removeFirst(closedTabs.count - Self.closedTabLimit) }
                ExtensionEventPush.shared.emit("sessions.onChanged", args: [])
            }
            ExtensionManager.shared.didClose(tab)
            animate { spaces.forEach { $0.tabs.removeAll { $0 === tab } } }
            tab.tearDown()
        }

        if wasSelected {
            if let next = selectedTab {
                next.wake()
                next.lastActive = Date()
                ExtensionManager.shared.didActivate(next, previous: nil)
            }
            findVisible = false
            updateWindowTitle()
            focusWebView()
        }
        scheduleSave()
    }

    private func neighbour(of tab: Tab, in space: Space) -> Tab? {
        if settings.tabs.afterClose == .recent {
            return (space.tabs + space.allPinned + favorites(in: space))
                .filter { $0 !== tab }
                .max { $0.lastActive < $1.lastActive }
        }
        if let i = space.tabs.firstIndex(where: { $0 === tab }) {
            let below = i + 1 < space.tabs.count ? space.tabs[i + 1] : nil
            let above = i > 0 ? space.tabs[i - 1] : nil
            return settings.tabs.afterClose == .above ? (above ?? below) : (below ?? above)
        }
        // A pinned / favourite tab was closed: fall back to the most recently used awake tab.
        return (space.tabs + space.allPinned + favorites(in: space))
            .filter { $0 !== tab && $0.isAwake }
            .max { $0.lastActive < $1.lastActive }
    }

    func closeSelectedTab() {
        if let tab = selectedTab {
            close(tab)
        } else {
            window?.performClose(nil)
        }
    }

    /// Brings back the last closed tab in its old space and place, with its back / forward history.
    func reopenClosedTab() {
        guard restored, let last = closedTabs.popLast() else { return }
        ExtensionEventPush.shared.emit("sessions.onChanged", args: [])
        let space = spaces.first { $0.id == last.spaceID } ?? currentSpace
        if space !== currentSpace, let index = spaces.firstIndex(where: { $0 === space }) { switchSpace(to: index) }
        let tab = Tab(url: last.url, title: last.title, sessionState: last.sessionState)
        tab.browser = self
        let index = min(last.index ?? (settings.tabs.newTabPosition == .top ? 0 : space.tabs.count), space.tabs.count)
        animate { space.tabs.insert(tab, at: index) }
        tab.wake()
        ExtensionManager.shared.didOpen(tab)
        select(tab)
        scheduleSave()
    }

    /// Forgets recently closed tabs (with their history), e.g. when history is cleared.
    func forgetClosedTabs() {
        closedTabs.removeAll()
        scheduleSave()
    }

    // MARK: WebExtension sessions API (chrome.sessions)

    /// Gives legacy closed tabs (saved before these fields existed) an id and close time.
    private func ensureClosedTabIDs() {
        var changed = false
        for i in closedTabs.indices {
            if closedTabs[i].id == nil { closedTabs[i].id = UUID(); changed = true }
            if closedTabs[i].closedAt == nil { closedTabs[i].closedAt = Date(); changed = true }
        }
        if changed { scheduleSave() }
    }

    /// Recently closed tabs, newest first, in the shape `chrome.sessions.getRecentlyClosed` expects.
    func recentlyClosedSessions(maxResults: Int) -> [[String: Any]] {
        ensureClosedTabIDs()
        return closedTabs.reversed().prefix(max(0, maxResults)).compactMap { closed in
            guard let id = closed.id else { return nil }
            return [
                "lastModified": (closed.closedAt ?? Date()).timeIntervalSince1970 * 1000,
                "tab": [
                    "sessionId": id.uuidString,
                    "url": closed.url.absoluteString,
                    "title": closed.title,
                    "windowId": "1",
                    "index": closed.index ?? 0,
                ],
            ]
        }
    }

    /// Reopens a closed tab by its session id (nil = the most recent), with its history. Returns the
    /// restored session in Chrome's shape, or nil if there is nothing to restore.
    func restoreSession(id: String?) -> [String: Any]? {
        ensureClosedTabIDs()
        let index: Int? = id.flatMap { id in closedTabs.firstIndex { $0.id?.uuidString == id } } ?? closedTabs.indices.last
        guard let index else { return nil }
        let closed = closedTabs.remove(at: index)
        ExtensionEventPush.shared.emit("sessions.onChanged", args: [])
        let space = spaces.first { $0.id == closed.spaceID } ?? currentSpace
        if space !== currentSpace, let i = spaces.firstIndex(where: { $0 === space }) { switchSpace(to: i) }
        let tab = Tab(url: closed.url, title: closed.title, sessionState: closed.sessionState)
        tab.browser = self
        let atIndex = min(closed.index ?? (settings.tabs.newTabPosition == .top ? 0 : space.tabs.count), space.tabs.count)
        animate { space.tabs.insert(tab, at: atIndex) }
        tab.wake()
        ExtensionManager.shared.didOpen(tab)
        select(tab)
        scheduleSave()
        return [
            "tab": [
                "sessionId": closed.id?.uuidString ?? "",
                "url": closed.url.absoluteString,
                "title": closed.title,
                "windowId": "1",
            ],
        ]
    }

    /// Gives a tab its own name in the sidebar. An empty name, or the page's own title, goes
    /// back to showing the page's title.
    func rename(_ tab: Tab, to name: String) {
        let trimmed = name.trimmed
        tab.customTitle = trimmed.isEmpty || trimmed == tab.pageTitle ? nil : trimmed
        if renamingTabID == tab.id { renamingTabID = nil }
        if tab === selectedTab { updateWindowTitle() }
        scheduleSave()
    }

    /// Shows a pinned tab and takes it back to the page it was pinned on.
    func returnHome(_ tab: Tab) {
        if selectedTab !== tab { select(tab) }
        tab.returnHome()
        focusWebView()
    }

    func duplicate(_ tab: Tab) {
        guard let url = tab.url else { return }
        newTab(url: url, after: tab)
    }

    func selectAdjacentTab(offset: Int) {
        let list = orderedTabs(in: currentSpace)
        guard !list.isEmpty else { return }
        let current = selectedTab.flatMap { t in list.firstIndex { $0 === t } } ?? (offset > 0 ? -1 : 0)
        let next = (current + offset + list.count) % list.count
        select(list[next])
    }

    func selectTab(atOrdinal ordinal: Int) {
        let list = orderedTabs(in: currentSpace)
        guard !list.isEmpty else { return }
        select(ordinal >= 9 ? list[list.count - 1] : list[min(ordinal - 1, list.count - 1)])
    }

    /// Moves a tab between favourites / pinned / regular, or reorders within a section.
    /// For `.pinned`, `index` is a place in the space's `pinnedItems` (among folders and pinned
    /// tabs), or with `folder`, a place in that folder.
    func move(_ tab: Tab, to section: TabSection, in space: Space? = nil, folder: Folder? = nil, at index: Int? = nil) {
        let destination = space ?? self.space(containing: tab) ?? currentSpace
        let origin = self.space(containing: tab)
        let wasSelectedInOrigin = origin?.selectedTabID == tab.id

        animate {
            profiles.forEach { $0.favorites.removeAll { $0 === tab } }
            spaces.forEach { s in
                s.removePinned(tab)
                s.tabs.removeAll { $0 === tab }
            }
            switch section {
            case .favorites:
                let profile = profile(for: destination)
                profile.favorites.insert(tab, at: min(index ?? profile.favorites.count, profile.favorites.count))
            case .pinned where folder != nil && destination.folders.contains(where: { $0 === folder }):
                let folder = folder!
                folder.tabs.insert(tab, at: min(index ?? folder.tabs.count, folder.tabs.count))
            case .pinned:
                let count = destination.pinnedItems.count
                destination.pinnedItems.insert(.tab(tab), at: min(index ?? count, count))
            case .tabs:
                destination.tabs.insert(tab, at: min(index ?? 0, destination.tabs.count))
            }
        }

        if section == .tabs {
            tab.homeURL = nil
        } else if tab.homeURL == nil {
            tab.homeURL = tab.url
        }
        // Moved to a profile with other cookies.
        tab.moveToDataStore(dataStore(for: tab))

        if let origin, origin !== destination, section != .favorites, wasSelectedInOrigin {
            origin.selectedTabID = origin.tabs.first?.id
            if origin === currentSpace {
                selectedTab?.wake()
                updateWindowTitle()
            }
        }
        scheduleSave()
    }

    // MARK: Navigation

    func openCommandBar(_ mode: CommandBarMode) {
        let resolved: CommandBarMode = (mode == .editCurrent && selectedTab == nil) ? .newTab : mode
        let wasOpen = commandBar != nil
        animate(Motion.snappy) { commandBar = resolved }
        // Take the keyboard from the page right away, so nothing typed before the bar's field
        // is on screen lands in a text field on the page. The field takes it next.
        if !wasOpen, let window, window.firstResponder is WKWebView {
            window.makeFirstResponder(nil)
        }
    }

    func closeCommandBar() {
        guard commandBar != nil else { return }
        animate(Motion.quick) { commandBar = nil }
        focusWebView()
    }

    func open(input: String, mode: CommandBarMode) {
        let text = input.trimmed
        guard !text.isEmpty else { return }
        open(url: Self.resolve(text, engine: settings.general.searchEngine), mode: mode)
    }

    func open(url: URL, mode: CommandBarMode) {
        if mode == .editCurrent, let tab = selectedTab {
            tab.load(url)
            focusWebView()
        } else {
            newTab(url: url)
        }
    }

    /// Turns whatever was typed into a URL: a real URL, a bare domain, or a search.
    static func resolve(_ input: String, engine: SearchEngine) -> URL {
        let text = input.trimmed
        let lower = text.lowercased()
        if !text.contains(" ") {
            if lower.contains("://") || lower.hasPrefix("about:") || lower.hasPrefix("data:") || lower.hasPrefix("file:"),
               let url = URL(string: text), url.scheme != nil {
                return url
            }
            let hostPart = lower.split(separator: "/").first.map(String.init) ?? lower
            let bareHost = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
            let isLocal = bareHost == "localhost" || bareHost.hasSuffix(".local") || bareHost.hasSuffix(".localhost")
            let isIP = bareHost.split(separator: ".").count == 4 && bareHost.split(separator: ".").allSatisfy { Int($0) != nil }
            let hasPort = hostPart.contains(":") && Int(hostPart.split(separator: ":").last ?? "") != nil
            let looksLikeDomain = bareHost.contains(".") && !bareHost.hasSuffix(".") && !bareHost.hasPrefix(".")
                && (bareHost.split(separator: ".").last?.count ?? 0) >= 2
                && bareHost.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
            if isLocal || isIP || (hasPort && !bareHost.isEmpty && bareHost.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) {
                if let url = URL(string: "http://" + text) { return url }
            } else if looksLikeDomain, let url = URL(string: "https://" + text) {
                return url
            }
        }
        return engine.searchURL(for: text)
    }

    func copyCurrentURL() {
        guard let url = selectedTab?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        show(Toast(symbol: "link", text: "Copied link"))
    }

    func show(_ toast: Toast) {
        animate(Motion.snappy) { self.toast = toast }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, self.toast?.id == toast.id else { return }
            self.animate(Motion.smooth) { self.toast = nil }
        }
    }

    // MARK: Spaces

    func switchSpace(to index: Int) {
        guard spaces.indices.contains(index) else { return }
        let previous = selectedTab
        previous?.lastActive = Date()
        animate(Motion.smooth) {
            currentSpaceIndex = index
            pagerPosition = Double(index)
        }
        spaceDidChange(previous: previous)
    }

    private func spaceDidChange(previous: Tab?) {
        ExtensionManager.shared.spaceDidChange()
        if let tab = selectedTab {
            tab.wake()
            tab.lastActive = Date()
            if previous !== tab { ExtensionManager.shared.didActivate(tab, previous: previous) }
        }
        selectionDidChange(from: previous)
        findVisible = false
        updateWindowTitle()
        if commandBar == nil { focusWebView() }
        scheduleSave()
    }

    func switchSpace(by offset: Int) {
        let next = currentSpaceIndex + offset
        guard spaces.indices.contains(next) else { return }
        switchSpace(to: next)
    }

    @discardableResult
    func addSpace(select: Bool = true) -> Space {
        let used = Set(spaces.map(\.colorHex))
        let color = Space.palette.first { !used.contains($0) } ?? Space.palette[spaces.count % Space.palette.count]
        let usedIcons = Set(spaces.map(\.icon))
        let icon = Space.icons.first { !usedIcons.contains($0) } ?? "sparkles"
        let profileID = spaces.isEmpty ? profiles[0].id : currentSpace.profileID
        let space = Space(name: "New Space", icon: icon, colorHex: color, profileID: profileID)
        animate { spaces.append(space) }
        if select {
            switchSpace(to: spaces.count - 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.editingSpaceID = space.id }
        } else {
            scheduleSave()
        }
        return space
    }

    /// Reorders spaces, keeping the one on screen selected.
    func moveSpace(from source: Int, to destination: Int) {
        guard spaces.indices.contains(source), spaces.indices.contains(destination), source != destination else { return }
        let current = currentSpace
        animate {
            let space = spaces.remove(at: source)
            spaces.insert(space, at: destination)
            currentSpaceIndex = spaces.firstIndex { $0 === current } ?? 0
            pagerPosition = Double(currentSpaceIndex)
        }
        scheduleSave()
    }

    /// Asks before deleting a space, since its tabs go with it. Every "Delete Space" control goes
    /// through here.
    func confirmDelete(_ space: Space, from host: Prompt.Host = .browser) {
        guard spaces.count > 1 else { return }
        let tabCount = space.allPinned.count + space.tabs.count
        let prompt = Prompt(
            host: host,
            symbol: space.icon,
            symbolColor: space.color,
            title: "Delete “\(space.name)”?",
            subtitle: tabCount == 0 ? "No tabs" : tabCount == 1 ? "1 tab" : "\(tabCount) tabs",
            message: tabCount == 0 ? nil : "Its tabs will be closed too. This can’t be undone.",
            confirmTitle: "Delete Space",
            destructive: true
        )
        Task { @MainActor in
            guard await PromptPresenter.present(prompt), spaces.contains(where: { $0 === space }) else { return }
            delete(space)
        }
    }

    func delete(_ space: Space) {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0 === space }) else { return }
        let previous = selectedTab
        for tab in space.allPinned + space.tabs {
            ExtensionManager.shared.didClose(tab)
            tab.tearDown()
        }
        let newIndex = currentSpaceIndex > index || currentSpaceIndex == spaces.count - 1
            ? max(0, currentSpaceIndex - 1) : currentSpaceIndex
        animate(Motion.smooth) {
            spaces.remove(at: index)
            currentSpaceIndex = min(newIndex, spaces.count - 1)
            pagerPosition = Double(currentSpaceIndex)
        }
        ExtensionManager.shared.forgetLinks(to: space.id)
        spaceDidChange(previous: previous)
    }

    // MARK: Folders

    /// Adds a folder to a space's pinned section, optionally moving a tab into it, and starts
    /// editing its name.
    @discardableResult
    func addFolder(in space: Space? = nil, with tab: Tab? = nil) -> Folder {
        let space = space ?? currentSpace
        let taken = Set(space.folders.map(\.name))
        var name = "New Folder"
        var n = 2
        while taken.contains(name) { name = "New Folder \(n)"; n += 1 }
        let folder = Folder(name: name)
        // A folder made from a pinned tab takes that tab's place; otherwise it goes at the end.
        let index = tab.flatMap { space.pinnedIndex(of: $0.id) }
            ?? tab.flatMap { t in space.folder(containing: t).flatMap { space.pinnedIndex(of: $0.id) }.map { $0 + 1 } }
            ?? space.pinnedItems.count
        animate { space.pinnedItems.insert(.folder(folder), at: index) }
        if let tab { move(tab, to: .pinned, in: space, folder: folder) }
        if space !== currentSpace, let index = spaces.firstIndex(where: { $0 === space }) { switchSpace(to: index) }
        if !sidebarVisible { toggleSidebar() }
        renamingFolderID = folder.id
        scheduleSave()
        return folder
    }

    func toggle(_ folder: Folder) {
        animate { folder.isOpen.toggle() }
        scheduleSave()
    }

    func rename(_ folder: Folder, to name: String) {
        let trimmed = name.trimmed
        if !trimmed.isEmpty { folder.name = trimmed }
        if renamingFolderID == folder.id { renamingFolderID = nil }
        scheduleSave()
    }

    func space(containing folder: Folder) -> Space? {
        spaces.first { $0.folders.contains { $0 === folder } }
    }

    /// Removes a folder. Its tabs stay pinned where the folder was, so nothing is lost.
    func delete(_ folder: Folder) {
        guard let space = space(containing: folder), let index = space.pinnedIndex(of: folder.id) else { return }
        animate {
            space.pinnedItems.remove(at: index)
            space.pinnedItems.insert(contentsOf: folder.tabs.map(PinnedItem.tab), at: index)
        }
        if renamingFolderID == folder.id { renamingFolderID = nil }
        scheduleSave()
    }

    /// Moves a folder up or down one place among its space's pinned tabs and folders.
    func move(_ folder: Folder, by offset: Int) {
        guard let space = space(containing: folder), let index = space.pinnedIndex(of: folder.id),
              space.pinnedItems.indices.contains(index + offset) else { return }
        animate { space.pinnedItems.swapAt(index, index + offset) }
        scheduleSave()
    }

    /// Puts a folder at a place in its space's `pinnedItems`: the place of the item it was
    /// dragged onto (which moves aside), or the end.
    func move(_ folder: Folder, to index: Int) {
        guard let space = space(containing: folder), let from = space.pinnedIndex(of: folder.id) else { return }
        let target = min(max(0, index), space.pinnedItems.count - 1)
        guard target != from else { return }
        animate {
            let item = space.pinnedItems.remove(at: from)
            space.pinnedItems.insert(item, at: target)
        }
        scheduleSave()
    }

    // MARK: Profiles

    @discardableResult
    func addProfile(name: String = "New Profile") -> Profile {
        let used = Set(profiles.map(\.icon))
        let icon = Profile.icons.first { !used.contains($0) } ?? "person.fill"
        let profile = Profile(name: name, icon: icon)
        animate { profiles.append(profile) }
        scheduleSave()
        return profile
    }

    /// Moves a space to another profile. Its favourites change with it; if the tab it was
    /// showing was one of the old profile's favourites, it shows its first tab instead.
    func setProfile(_ profile: Profile, for space: Space) {
        guard space.profileID != profile.id else { return }
        let wasCurrent = space === currentSpace
        let previous = wasCurrent ? selectedTab : nil
        animate { space.profileID = profile.id }
        if let id = space.selectedTabID, tab(withID: id, in: space) == nil {
            space.selectedTabID = (space.tabs.first ?? space.allPinned.first)?.id
        }
        // The space's open pages now use the new profile's cookies.
        for tab in space.allPinned + space.tabs { tab.moveToDataStore(profile.dataStore) }
        if wasCurrent {
            spaceDidChange(previous: previous)
        } else {
            scheduleSave()
        }
    }

    /// Deletes a profile: its spaces move to another profile and its favourites are closed.
    func delete(_ profile: Profile) {
        guard profiles.count > 1, let fallback = profiles.first(where: { $0 !== profile }) else { return }
        let previous = selectedTab
        for space in spaces(in: profile) { space.profileID = fallback.id }
        for tab in profile.favorites {
            for space in spaces where space.selectedTabID == tab.id { space.selectedTabID = space.tabs.first?.id }
            ExtensionManager.shared.didClose(tab)
            tab.tearDown()
        }
        // Its spaces' open pages move to the other profile's cookies.
        for space in spaces where space.profileID == fallback.id {
            for tab in space.allPinned + space.tabs { tab.moveToDataStore(fallback.dataStore) }
        }
        animate { profiles.removeAll { $0 === profile } }
        if !profile.usesSharedStore { DataStores.removeStore(forProfile: profile.id) }
        ExtensionManager.shared.profileDeleted(profile.id)
        spaceDidChange(previous: previous)
    }

    // Interactive two-finger swipe across the sidebar.

    func updateSwipe(deltaX: CGFloat, width: CGFloat) {
        guard width > 0, spaces.count > 0 else { return }
        var delta = -Double(deltaX / width)
        let proposed = pagerPosition + delta
        let maxPosition = Double(spaces.count - 1)
        // Rubber-band past the first / last space.
        if proposed < 0 || proposed > maxPosition { delta *= 0.28 }
        let base = Double(currentSpaceIndex)
        pagerPosition = max(base - 1, min(base + 1, max(-0.35, min(maxPosition + 0.35, pagerPosition + delta))))
    }

    func endSwipe(velocityX: CGFloat) {
        let base = Double(currentSpaceIndex)
        let travelled = pagerPosition - base
        var target = currentSpaceIndex
        let flick = abs(velocityX) > 6
        if travelled > 0.33 || (flick && velocityX < 0 && travelled > 0.04) { target += 1 }
        if travelled < -0.33 || (flick && velocityX > 0 && travelled < -0.04) { target -= 1 }
        target = max(0, min(spaces.count - 1, target))

        let previous = selectedTab
        let changed = target != currentSpaceIndex
        animate(Animation.spring(response: 0.36, dampingFraction: 0.86)) {
            currentSpaceIndex = target
            pagerPosition = Double(target)
        }
        if changed {
            previous?.lastActive = Date()
            spaceDidChange(previous: previous)
        }
    }

    // MARK: Chrome

    func toggleSidebar() {
        animate(Motion.sidebar) {
            sidebarVisible.toggle()
            sidebarPeeking = false
        }
    }

    func setPeeking(_ peeking: Bool) {
        guard sidebarPeeking != peeking, !sidebarVisible || !peeking else { return }
        animate(Motion.snappy) { sidebarPeeking = peeking }
    }

    static let findFieldIdentifier = "find-field"

    /// Puts the keyboard in the open find bar's field and selects what it holds.
    func focusFindField() {
        func field(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.identifier?.rawValue == Self.findFieldIdentifier { return field }
            for sub in view.subviews { if let hit = field(in: sub) { return hit } }
            return nil
        }
        guard let window, let root = window.contentView?.superview ?? window.contentView,
              let field = field(in: root), window.makeFirstResponder(field) else { return }
        field.currentEditor()?.selectAll(nil)
    }

    /// Gives the keyboard to the page, unless something of Tuff's has it on purpose: the command
    /// bar, a card in this window (its Return / Esc must not reach the page), or the find bar
    /// while it is being typed in. This runs whenever the page on show changes (a tab waking,
    /// a tab moving to a new web view), which used to pull focus out of those.
    func focusWebView() {
        guard commandBar == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.commandBar == nil, let window = self.window else { return }
            if let prompt = self.prompt, prompt.host == .browser { return }
            if self.findVisible, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
               (editor.delegate as? NSTextField)?.identifier?.rawValue == Self.findFieldIdentifier { return }
            if let view = self.selectedTab?.webView, view.window === window {
                window.makeFirstResponder(view)
            }
        }
    }

    func updateWindowTitle() {
        window?.title = selectedTab?.displayTitle ?? "Tuff"
    }

    func tabDidChange(_ tab: Tab, properties: WKWebExtension.TabChangedProperties) {
        ExtensionManager.shared.didChange(tab, properties: properties)
        if tab === selectedTab, properties.contains(.title) { updateWindowTitle() }
        if properties.contains(.title) || properties.contains(.URL) { scheduleSave() }
    }

    func tabDidNavigate(_ tab: Tab) {
        if tab === selectedTab { findVisible = false }
    }

    // MARK: Picture in picture

    /// Puts the current tab's video into picture in picture, or takes it out. With no video on
    /// the page, sends another tab's PiP video back to its page and shows that tab.
    func togglePictureInPicture() {
        guard let tab = selectedTab, tab.isAwake else { exitOtherPictureInPicture(); return }
        tab.togglePictureInPicture { [weak self] outcome in
            guard let self, outcome == .none || outcome == .failed else { return }
            if self.exitOtherPictureInPicture() { return }
            self.show(Toast(symbol: "pip", text: outcome == .failed ? "This video can’t play in Picture in Picture" : "No video to play in Picture in Picture"))
        }
    }

    @discardableResult
    private func exitOtherPictureInPicture() -> Bool {
        guard let other = allTabs.first(where: { $0.isInPictureInPicture && $0 !== selectedTab }) else { return false }
        other.togglePictureInPicture()
        return true
    }

    /// Hands video over when the tab on screen changes: the tab left behind pops a playing video
    /// into PiP, and the tab now showing takes back one that went there that way. Waits a turn
    /// of the run loop, since switching space and then tab passes through a tab in between.
    private func selectionDidChange(from previous: Tab?) {
        if !pipHandoffPending {
            pipHandoffPending = true
            pipHandoffFrom = previous
            DispatchQueue.main.async { [weak self] in self?.finishPictureInPictureHandoff() }
        }
    }

    private func finishPictureInPictureHandoff() {
        let from = pipHandoffFrom
        pipHandoffPending = false
        pipHandoffFrom = nil
        let to = selectedTab
        guard from !== to else { return }
        to?.leaveAutomaticPictureInPicture()
        guard settings.tabs.autoPictureInPicture, let from else { return }
        enterPictureInPictureWhenHidden(from, attempts: 12)
    }

    /// Waits for the page fade (`WebStackView`) to take the tab's web view out of the window:
    /// starting PiP in a web view that is still fading out stalls the fade and leaves the new
    /// page see-through.
    private func enterPictureInPictureWhenHidden(_ tab: Tab, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak tab] in
            guard let self, let tab, tab !== self.selectedTab, let view = tab.webView,
                  self.allTabs.contains(where: { $0 === tab }) else { return }
            if view.window == nil {
                tab.enterPictureInPictureAutomatically()
            } else if attempts > 1 {
                self.enterPictureInPictureWhenHidden(tab, attempts: attempts - 1)
            } else {
                ExtensionManager.shared.trace("pip auto skipped: web view still on screen")
            }
        }
    }

    // MARK: Tab sleeping

    private func startSleepTimer() {
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.sleepIdleTabs()
        }
    }

    /// Unloads web views that have been in the background for a while, keeping their state,
    /// and closes regular tabs nobody has looked at in a long time (if that's turned on).
    func sleepIdleTabs() {
        closeIdleTabs()
        let minutes = settings.general.sleepAfterMinutes
        guard minutes > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        let visible = selectedTab
        for tab in allTabs where tab.isAwake && tab !== visible {
            if tab.isPlayingAudio || tab.isLoading || tab.isInPictureInPicture { continue }
            if spaces.contains(where: { $0.selectedTabID == tab.id }) && tab.lastActive > cutoff { continue }
            if tab.lastActive < cutoff { tab.sleep() }
        }
    }

    private func closeIdleTabs() {
        let hours = settings.tabs.closeIdleAfterHours
        guard hours > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        let visible = selectedTab
        let stale = spaces.flatMap(\.tabs).filter { tab in
            tab !== visible && tab.lastActive < cutoff && !tab.isPlayingAudio && !tab.isInPictureInPicture
                && !tab.isLoading && tab.permissionRequest == nil
        }
        stale.forEach { close($0) }
    }

    // MARK: Persistence

    private struct TabSnapshot: Codable {
        var id: UUID
        var url: URL?
        var title: String
        var homeURL: URL?
        var lastActive: Date?
        /// Back / forward history; missing in older sessions.
        var history: Data?
        /// The user's name for the tab, if they gave it one.
        var customTitle: String?
        /// Where the pinned page redirected to (`Tab.homeLandingURL`).
        var homeLanding: URL?
    }

    private struct FolderSnapshot: Codable {
        var id: UUID
        var name: String
        var open: Bool
        var tabs: [TabSnapshot]
    }

    /// One entry of a space's pinned section: a tab or a folder.
    private struct PinnedItemSnapshot: Codable {
        var tab: TabSnapshot?
        var folder: FolderSnapshot?
    }

    private struct SpaceSnapshot: Codable {
        var id: UUID
        var name: String
        var icon: String
        var colorHex: String
        var profile: UUID?
        /// Every pinned tab, flat. Read only when `pinnedItems` is missing (older sessions);
        /// still written so an older build keeps the tabs that are in folders.
        var pinned: [TabSnapshot]
        /// The pinned section with its folders, in order.
        var pinnedItems: [PinnedItemSnapshot]?
        var tabs: [TabSnapshot]
        var selected: UUID?
    }

    private struct ProfileSnapshot: Codable {
        var id: UUID
        var name: String
        var icon: String
        var favorites: [TabSnapshot]
        /// Missing in sessions from before profiles had their own cookies.
        var sharedStore: Bool?
    }

    private struct SessionSnapshot: Codable {
        var spaces: [SpaceSnapshot]
        var profiles: [ProfileSnapshot]?
        /// Favourites from before profiles existed; read once, then carried by a profile.
        var favorites: [TabSnapshot]?
        var currentSpace: Int
        var sidebarVisible: Bool
        /// Recently closed tabs, oldest first; missing in older sessions.
        var closedTabs: [ClosedTab]?
    }

    func scheduleSave() {
        guard restored else { return }
        saver.schedule { [weak self] in self?.saveNow() }
    }

    func saveNow() {
        guard restored else { return }
        // With "Clear history when Tuff quits" on, tabs' history and closed tabs stay off disk.
        let keepHistory = !settings.privacy.clearHistoryOnQuit
        func snap(_ t: Tab) -> TabSnapshot {
            TabSnapshot(
                id: t.id, url: t.url, title: t.title, homeURL: t.homeURL, lastActive: t.lastActive,
                history: keepHistory ? t.sessionState : nil, customTitle: t.customTitle,
                homeLanding: t.homeLandingURL
            )
        }
        let snapshot = SessionSnapshot(
            spaces: spaces.map { s in
                SpaceSnapshot(
                    id: s.id, name: s.name, icon: s.icon, colorHex: s.colorHex, profile: s.profileID,
                    pinned: s.allPinned.map(snap),
                    pinnedItems: s.pinnedItems.map { item in
                        switch item {
                        case .tab(let tab): PinnedItemSnapshot(tab: snap(tab))
                        case .folder(let f): PinnedItemSnapshot(folder: FolderSnapshot(id: f.id, name: f.name, open: f.isOpen, tabs: f.tabs.map(snap)))
                        }
                    },
                    tabs: s.tabs.filter { $0.url != nil }.map(snap), selected: s.selectedTabID
                )
            },
            profiles: profiles.map {
                ProfileSnapshot(id: $0.id, name: $0.name, icon: $0.icon, favorites: $0.favorites.map(snap), sharedStore: $0.usesSharedStore)
            },
            favorites: nil,
            currentSpace: currentSpaceIndex,
            sidebarVisible: sidebarVisible,
            closedTabs: keepHistory ? closedTabs : nil
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: sessionFile, options: .atomic)
    }

    func restore() {
        guard !restored else { return }
        func make(_ s: TabSnapshot) -> Tab {
            let tab = Tab(id: s.id, url: s.url, title: s.title, homeURL: s.homeURL, sessionState: s.history)
            if let date = s.lastActive { tab.lastActive = date }
            tab.customTitle = s.customTitle
            tab.homeLandingURL = s.homeLanding
            tab.browser = self
            return tab
        }

        let saved = (try? Data(contentsOf: sessionFile)).flatMap { try? JSONDecoder().decode(SessionSnapshot.self, from: $0) }
        // Closed tabs come back even when the session doesn't, so ⇧⌘T can reopen last time's tabs.
        if !settings.privacy.clearHistoryOnQuit {
            closedTabs = Array((saved?.closedTabs ?? []).suffix(Self.closedTabLimit))
        }

        if settings.general.restoreSession, let snapshot = saved, !snapshot.spaces.isEmpty {
            if let saved = snapshot.profiles, !saved.isEmpty {
                // Before profiles had their own cookies they all used the shared store; the first
                // keeps it (so you stay signed in), the rest start fresh.
                profiles = saved.enumerated().map { index, p in
                    let profile = Profile(id: p.id, name: p.name, icon: p.icon, usesSharedStore: p.sharedStore ?? (index == 0))
                    profile.favorites = p.favorites.map(make)
                    return profile
                }
            } else {
                // A session from before profiles: everything goes on one profile.
                let profile = Profile(name: "Personal", icon: "person.fill", usesSharedStore: true)
                profile.favorites = (snapshot.favorites ?? []).map(make)
                profiles = [profile]
            }
            let known = Set(profiles.map(\.id))
            spaces = snapshot.spaces.map { s in
                let profileID = s.profile.flatMap { known.contains($0) ? $0 : nil } ?? profiles[0].id
                let space = Space(id: s.id, name: s.name, icon: s.icon, colorHex: s.colorHex, profileID: profileID)
                if let items = s.pinnedItems {
                    space.pinnedItems = items.compactMap { item in
                        if let t = item.tab { return .tab(make(t)) }
                        guard let f = item.folder else { return nil }
                        let folder = Folder(id: f.id, name: f.name, isOpen: f.open)
                        folder.tabs = f.tabs.map(make)
                        return .folder(folder)
                    }
                } else {
                    space.pinnedItems = s.pinned.map { .tab(make($0)) }
                }
                space.tabs = s.tabs.map(make)
                space.selectedTabID = s.selected
                if let id = s.selected, tab(withID: id, in: space) == nil { space.selectedTabID = nil }
                return space
            }
            currentSpaceIndex = max(0, min(snapshot.currentSpace, spaces.count - 1))
            sidebarVisible = snapshot.sidebarVisible
        } else {
            let profile = Profile(name: "Personal", icon: "person.fill", usesSharedStore: true)
            profiles = [profile]
            spaces = [
                Space(name: "Home", icon: "bookmark.fill", colorHex: Space.palette[0], profileID: profile.id),
                Space(name: "Lab", icon: "flask.fill", colorHex: Space.palette[2], profileID: profile.id),
                Space(name: "Reading", icon: "book.fill", colorHex: Space.palette[1], profileID: profile.id),
            ]
            currentSpaceIndex = 0
        }
        pagerPosition = Double(currentSpaceIndex)
        restored = true

        allTabs.forEach { ExtensionManager.shared.didOpen($0) }
        selectedTab?.lastActive = Date()
        selectedTab?.wake()
        pendingURLs.forEach { newTab(url: $0) }
        pendingURLs.removeAll()
        startSleepTimer()
        ExtensionManager.shared.applyLinks()
    }
}
