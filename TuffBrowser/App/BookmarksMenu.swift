import AppKit

/// Fills the Bookmarks menu each time it opens with the profile's bookmarks, folders as
/// submenus. Choosing a page opens it in the tab you're on; ⌘-choosing opens it in a new tab.
/// This is where bookmarks live in the vertical layout, which has no bookmarks bar.
final class BookmarksMenuFiller: NSObject, NSMenuDelegate {
    static let shared = BookmarksMenuFiller()

    /// Items this delegate added, so they can be replaced next time.
    private static let marker = 0x626B_6D6B  // "bkmk"

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.tag == Self.marker { menu.removeItem(item) }
        guard let state = AppDelegate.shared?.state, let profile = state.bookmarksProfileID else { return }
        let bookmarks = BookmarkStore.shared.items(for: profile)

        let separator = NSMenuItem.separator()
        separator.tag = Self.marker
        menu.addItem(separator)
        if bookmarks.isEmpty {
            let none = NSMenuItem(title: "No Bookmarks", action: nil, keyEquivalent: "")
            none.isEnabled = false
            none.tag = Self.marker
            menu.addItem(none)
        }
        for bookmark in bookmarks {
            let item = makeItem(bookmark)
            item.tag = Self.marker
            menu.addItem(item)
        }
    }

    private func makeItem(_ bookmark: Bookmark) -> NSMenuItem {
        guard bookmark.isFolder else {
            let item = NSMenuItem(title: Self.title(bookmark.displayTitle), action: #selector(openPage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = bookmark.url
            item.image = bookmark.url.flatMap(Self.icon(for:))
            item.toolTip = bookmark.url?.absoluteString
            return item
        }
        let submenu = NSMenu(title: bookmark.displayTitle)
        if bookmark.children.isEmpty {
            let none = NSMenuItem(title: "Empty Folder", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        } else {
            bookmark.children.map(makeItem).forEach(submenu.addItem)
            if bookmark.pages.count > 1 {
                submenu.addItem(.separator())
                let all = NSMenuItem(title: "Open All in New Tabs", action: #selector(openAll(_:)), keyEquivalent: "")
                all.target = self
                all.representedObject = bookmark.id
                submenu.addItem(all)
            }
        }
        let holder = NSMenuItem(title: Self.title(bookmark.displayTitle), action: nil, keyEquivalent: "")
        holder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        holder.submenu = submenu
        return holder
    }

    @objc private func openPage(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let app = AppDelegate.shared else { return }
        app.ensureBrowserWindow()
        let newTab = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        app.state.open(Bookmark(title: sender.title, url: url), inNewTab: newTab)
    }

    @objc private func openAll(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let app = AppDelegate.shared else { return }
        app.ensureBrowserWindow()
        let state = app.state
        guard let profile = state.bookmarksProfileID,
              let folder = BookmarkStore.shared.bookmark(withID: id, profile: profile) else { return }
        state.openAll(in: folder)
    }

    private static func title(_ text: String) -> String {
        text.count > 60 ? String(text.prefix(57)) + "…" : text
    }

    private static func icon(for url: URL) -> NSImage? {
        guard let image = FaviconStore.shared.cachedIcon(for: url)?.copy() as? NSImage else {
            return NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        }
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

extension AppDelegate {
    /// ⇧⌘D: bookmarks the page on screen, or edits its bookmark.
    @objc func bookmarkPage(_ sender: Any?) {
        ensureBrowserWindow()
        state.bookmarkCurrentPage()
    }

    /// ⇧⌘B: shows or hides the bookmarks bar (horizontal layout).
    @objc func toggleBookmarksBar(_ sender: Any?) {
        state.toggleBookmarksBar()
    }

    @objc func newBookmarkFolder(_ sender: Any?) {
        ensureBrowserWindow()
        let state = self.state
        Task { @MainActor in await state.addBookmarkFolder() }
    }

    /// The Bookmarks menu's commands, for `validateMenuItem`.
    func validateBookmarkMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(bookmarkPage(_:)):
            menuItem.title = state.currentBookmark == nil ? "Bookmark This Page" : "Edit Bookmark…"
            return state.canBookmarkCurrentPage
        case #selector(toggleBookmarksBar(_:)):
            menuItem.title = state.bookmarksBarShowing ? "Hide Bookmarks Bar" : "Show Bookmarks Bar"
            return state.tabLayout == .horizontal
        case #selector(newBookmarkFolder(_:)):
            return state.bookmarksProfileID != nil
        default:
            return true
        }
    }
}
