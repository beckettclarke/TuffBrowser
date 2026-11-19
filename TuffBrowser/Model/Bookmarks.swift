import AppKit
import Observation

/// A saved page, or a folder of them (`url == nil`).
struct Bookmark: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Empty for a page shown as just its icon on the bookmarks bar.
    var title: String
    var url: URL?
    var children: [Bookmark] = []

    var isFolder: Bool { url == nil }

    /// The title, or the site's name when there is none.
    var displayTitle: String {
        let text = title.trimmed
        if !text.isEmpty { return text }
        return url?.displayHost ?? "Untitled Folder"
    }

    /// Every page in this folder and the folders inside it.
    var pages: [Bookmark] { children.flatMap { $0.isFolder ? $0.pages : [$0] } }

    /// Pages that can be saved: not blank tabs or extensions' own pages.
    static func canSave(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        return !ExtensionManager.isExtensionPage(url) && scheme != "about"
    }

    /// The same page with or without a trailing slash counts as already bookmarked.
    static func matchKey(_ url: URL) -> String {
        var text = url.absoluteString
        if text.hasSuffix("/") { text.removeLast() }
        return text.lowercased()
    }
}

/// Each profile's bookmarks, in the order of the bookmarks bar, persisted as JSON. Incognito
/// windows use the main window's (as in Chrome).
@Observable
final class BookmarkStore {
    static let shared = BookmarkStore()

    /// The bookmarks bar of each profile, by profile ID.
    private(set) var lists: [UUID: [Bookmark]] = [:]
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let saver = Debouncer(delay: 1)
    @ObservationIgnored private let writer = HistoryWriter(label: "tuff.bookmarks-save")
    @ObservationIgnored private var unsaved = false

    init(file: URL = Paths.appSupport.appendingPathComponent("bookmarks.json")) {
        self.file = file
        // A small file, read when first needed (the bookmarks bar, the menu or the command bar).
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([String: [Bookmark]].self, from: data) else { return }
        for (key, list) in saved {
            if let id = UUID(uuidString: key) { lists[id] = list }
        }
    }

    deinit {
        saver.cancel()
    }

    func items(for profile: UUID) -> [Bookmark] { lists[profile] ?? [] }

    /// The bookmark for this page, wherever it is.
    func bookmark(for url: URL, profile: UUID) -> Bookmark? {
        let key = Bookmark.matchKey(url)
        return Self.first(in: items(for: profile)) { $0.url.map(Bookmark.matchKey) == key }
    }

    func bookmark(withID id: UUID, profile: UUID) -> Bookmark? {
        Self.first(in: items(for: profile)) { $0.id == id }
    }

    /// Pages whose title or address has every word typed, best first (title matches, then
    /// shorter addresses).
    func search(_ query: String, limit: Int, profile: UUID) -> [Bookmark] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let pages = items(for: profile).flatMap { $0.isFolder ? $0.pages : [$0] }
        let hits = pages.filter { page in
            let haystack = page.title.lowercased() + " " + (page.url?.absoluteString.lowercased() ?? "")
            return words.allSatisfy(haystack.contains)
        }
        return Array(hits.sorted { a, b in
            let aTitle = a.title.lowercased().contains(words[0]), bTitle = b.title.lowercased().contains(words[0])
            if aTitle != bTitle { return aTitle }
            return (a.url?.absoluteString.count ?? 0) < (b.url?.absoluteString.count ?? 0)
        }.prefix(limit))
    }

    // MARK: Changes

    /// Adds a page at the end of the bar (or of `folder`), or at `index` there.
    @discardableResult
    func add(url: URL, title: String, profile: UUID, into folder: UUID? = nil, at index: Int? = nil) -> Bookmark {
        let bookmark = Bookmark(title: title.trimmed, url: url)
        insert(bookmark, into: folder, at: index, profile: profile)
        return bookmark
    }

    @discardableResult
    func addFolder(named name: String, profile: UUID, at index: Int? = nil) -> Bookmark {
        let folder = Bookmark(title: name.trimmed, url: nil)
        insert(folder, into: nil, at: index, profile: profile)
        return folder
    }

    func update(_ id: UUID, title: String, url: URL?, profile: UUID) {
        change(profile) { list in
            _ = Self.modify(id, in: &list) { bookmark in
                bookmark.title = title.trimmed
                // A folder stays a folder, a page stays a page.
                if !bookmark.isFolder, let url { bookmark.url = url }
            }
        }
    }

    func remove(_ id: UUID, profile: UUID) {
        change(profile) { list in _ = Self.take(id, from: &list) }
    }

    /// Moves a bookmark to `index` in the bar (or in `folder`), counted with it already taken
    /// out; nil puts it at the end. A folder can't go inside itself.
    func move(_ id: UUID, into folder: UUID?, at index: Int?, profile: UUID) {
        let list = items(for: profile)
        guard let moving = Self.first(in: list, where: { $0.id == id }) else { return }
        if let folder {
            guard folder != id, Self.first(in: moving.children, where: { $0.id == folder }) == nil,
                  Self.first(in: list, where: { $0.id == folder })?.isFolder == true else { return }
        }
        change(profile) { list in
            guard let taken = Self.take(id, from: &list) else { return }
            if !Self.insert(taken, into: folder, at: index, list: &list) { list.append(taken) }
        }
    }

    /// A deleted profile's bookmarks join the end of the profile its spaces went to.
    func moveAll(from old: UUID, to new: UUID) {
        guard let moving = lists[old], !moving.isEmpty else {
            lists[old] = nil
            return
        }
        lists[new, default: []].append(contentsOf: moving)
        lists[old] = nil
        scheduleSave()
    }

    private func insert(_ bookmark: Bookmark, into folder: UUID?, at index: Int?, profile: UUID) {
        change(profile) { list in
            if !Self.insert(bookmark, into: folder, at: index, list: &list) { list.append(bookmark) }
        }
    }

    private func change(_ profile: UUID, _ body: (inout [Bookmark]) -> Void) {
        var list = items(for: profile)
        body(&list)
        guard list != items(for: profile) else { return }
        lists[profile] = list
        scheduleSave()
    }

    // MARK: Tree helpers

    private static func first(in list: [Bookmark], where match: (Bookmark) -> Bool) -> Bookmark? {
        for item in list {
            if match(item) { return item }
            if item.isFolder, let found = first(in: item.children, where: match) { return found }
        }
        return nil
    }

    /// Removes the bookmark with `id` from wherever it is in `list`, and returns it.
    private static func take(_ id: UUID, from list: inout [Bookmark]) -> Bookmark? {
        if let index = list.firstIndex(where: { $0.id == id }) { return list.remove(at: index) }
        for index in list.indices where list[index].isFolder {
            if let found = take(id, from: &list[index].children) { return found }
        }
        return nil
    }

    private static func modify(_ id: UUID, in list: inout [Bookmark], _ body: (inout Bookmark) -> Void) -> Bool {
        for index in list.indices {
            if list[index].id == id {
                body(&list[index])
                return true
            }
            if list[index].isFolder, modify(id, in: &list[index].children, body) { return true }
        }
        return false
    }

    /// False when `folder` isn't in the list.
    private static func insert(_ bookmark: Bookmark, into folder: UUID?, at index: Int?, list: inout [Bookmark]) -> Bool {
        guard let folder else {
            list.insert(bookmark, at: min(max(0, index ?? list.count), list.count))
            return true
        }
        return modify(folder, in: &list) { target in
            target.children.insert(bookmark, at: min(max(0, index ?? target.children.count), target.children.count))
        }
    }

    // MARK: Saving

    private func scheduleSave() {
        unsaved = true
        saver.schedule { [weak self] in self?.saveNow() }
    }

    func saveNow(synchronously: Bool = false) {
        saver.cancel()
        guard unsaved else { return }
        unsaved = false
        let snapshot = Dictionary(uniqueKeysWithValues: lists.map { ($0.key.uuidString, $0.value) })
        let file = self.file
        writer.write(synchronously: synchronously) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }
}

// MARK: - Window actions

extension BrowserState {
    /// Whose bookmarks this window shows: its profile's, or for an Incognito window the main
    /// window's. Nil before the session is restored.
    var bookmarksProfileID: UUID? {
        let owner = isPrivate ? BrowserState.shared : self
        return owner.profiles.isEmpty ? nil : owner.currentProfile.id
    }

    /// The bar only exists in the horizontal layout; vertical tabs keep bookmarks out of sight
    /// (the Bookmarks menu and the command bar still find them).
    var bookmarksBarShowing: Bool { tabLayout == .horizontal && AppSettings.shared.tabs.showBookmarksBar }

    /// The bookmark for the page on screen, if it has one.
    var currentBookmark: Bookmark? {
        guard let url = selectedTab?.url, let profile = bookmarksProfileID else { return nil }
        return BookmarkStore.shared.bookmark(for: url, profile: profile)
    }

    var canBookmarkCurrentPage: Bool { Bookmark.canSave(selectedTab?.url) && bookmarksProfileID != nil }

    /// ⇧⌘D and the star in the address bar: bookmarks the page, or edits its bookmark.
    func bookmarkCurrentPage() {
        guard let tab = selectedTab, let url = tab.url, Bookmark.canSave(url), let profile = bookmarksProfileID else { return }
        if let existing = BookmarkStore.shared.bookmark(for: url, profile: profile) {
            Task { @MainActor in await self.edit(existing) }
            return
        }
        BookmarkStore.shared.add(url: url, title: tab.displayTitle, profile: profile)
        let hint = tabLayout == .horizontal && !bookmarksBarShowing ? " · ⇧⌘B shows the bar" : ""
        show(Toast(symbol: "star.fill", text: "Bookmarked" + hint))
    }

    func bookmark(_ tab: Tab, into folder: UUID? = nil, at index: Int? = nil) {
        guard let url = tab.url, Bookmark.canSave(url), let profile = bookmarksProfileID else { return }
        BookmarkStore.shared.add(url: url, title: tab.displayTitle, profile: profile, into: folder, at: index)
    }

    func toggleBookmarksBar() {
        AppSettings.shared.tabs.showBookmarksBar.toggle()
    }

    /// Opens a bookmarked page in the tab on screen, or in a new tab.
    func open(_ bookmark: Bookmark, inNewTab: Bool = false, select: Bool = true) {
        guard let url = bookmark.url else { return }
        if !inNewTab, let tab = selectedTab, !tab.isExtensionPage {
            tab.load(url)
            focusWebView()
        } else {
            newTab(url: url, select: select)
        }
    }

    /// The folder's pages in new tabs, showing the first.
    func openAll(in folder: Bookmark) {
        for (index, page) in folder.pages.enumerated() {
            open(page, inNewTab: true, select: index == 0)
        }
    }

    /// Edits a bookmark's name and address (a folder's name) on a card, which can also remove it.
    @MainActor
    func edit(_ bookmark: Bookmark) async {
        guard let profile = bookmarksProfileID else { return }
        var prompt = Prompt(
            symbol: bookmark.isFolder ? "folder.fill" : "star.fill",
            title: bookmark.isFolder ? "Rename Folder" : "Edit Bookmark",
            confirmTitle: "Save"
        )
        prompt.browser = self
        if bookmark.isFolder {
            prompt.fields = [Prompt.Field(placeholder: "Folder name", text: bookmark.title)]
        } else {
            prompt.icon = bookmark.url.flatMap { FaviconStore.shared.cachedIcon(for: $0) }
            prompt.symbolColor = .systemYellow
            prompt.message = "Leave the name empty to show just the site’s icon on the bookmarks bar."
            prompt.fields = [
                Prompt.Field(placeholder: "Name", text: bookmark.title),
                Prompt.Field(placeholder: "Address", text: bookmark.url?.absoluteString ?? ""),
            ]
            prompt.alternateTitle = "Remove"
        }
        let result = await PromptPresenter.ask(prompt)
        if result.alternate {
            BookmarkStore.shared.remove(bookmark.id, profile: profile)
            show(Toast(symbol: "star.slash", text: "Bookmark removed"))
            return
        }
        guard result.confirmed else { return }
        let title = result.fields.first ?? bookmark.title
        let address = result.fields.count > 1 ? result.fields[1].trimmed : ""
        let url = address.isEmpty ? bookmark.url : Self.resolve(address, engine: AppSettings.shared.general.searchEngine)
        BookmarkStore.shared.update(bookmark.id, title: title, url: url, profile: profile)
    }

    /// Asks for a name, then adds an empty folder at the end of the bar (or at `index`).
    @MainActor
    func addBookmarkFolder(at index: Int? = nil) async {
        guard let profile = bookmarksProfileID else { return }
        var prompt = Prompt(
            symbol: "folder.badge.plus", title: "New Bookmark Folder", confirmTitle: "Add Folder",
            fields: [Prompt.Field(placeholder: "Folder name", text: "New Folder")]
        )
        prompt.browser = self
        let result = await PromptPresenter.ask(prompt)
        guard result.confirmed else { return }
        let name = result.fields.first?.trimmed ?? ""
        BookmarkStore.shared.addFolder(named: name.isEmpty ? "New Folder" : name, profile: profile, at: index)
    }

    /// Removes a bookmark; a folder with pages in it asks first.
    @MainActor
    func delete(_ bookmark: Bookmark) async {
        guard let profile = bookmarksProfileID else { return }
        if bookmark.isFolder, !bookmark.children.isEmpty {
            let count = bookmark.pages.count
            var prompt = Prompt(
                symbol: "folder.fill",
                title: "Delete “\(bookmark.displayTitle)”?",
                message: "The folder and the \(count == 1 ? "bookmark" : "\(count) bookmarks") in it will be deleted. This can’t be undone.",
                confirmTitle: "Delete Folder",
                destructive: true
            )
            prompt.browser = self
            guard await PromptPresenter.present(prompt) else { return }
        }
        BookmarkStore.shared.remove(bookmark.id, profile: profile)
    }
}
