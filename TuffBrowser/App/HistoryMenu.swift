import AppKit

/// Fills the History menu each time it opens: a Recently Closed submenu, and the pages
/// visited most recently (as in Safari and Chrome). Choosing a page opens it in the tab you're
/// on; ⌘-choosing opens it in a new tab.
final class HistoryMenuFiller: NSObject, NSMenuDelegate {
    static let shared = HistoryMenuFiller()

    /// How many recent pages and closed tabs are listed.
    static let recentLimit = 15
    static let closedLimit = 15

    /// Items this delegate added, so they can be replaced next time.
    private static let marker = 0x7475_6666  // "tuff"

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.tag == Self.marker { menu.removeItem(item) }
        guard let app = AppDelegate.shared else { return }
        let state = app.state

        var added: [NSMenuItem] = []
        func mark(_ item: NSMenuItem) -> NSMenuItem { item.tag = Self.marker; return item }

        // Recently Closed.
        let closed = state.recentlyClosedForMenu(limit: Self.closedLimit)
        let closedMenu = NSMenu(title: "Recently Closed")
        if closed.isEmpty {
            let none = NSMenuItem(title: "No Recently Closed Tabs", action: nil, keyEquivalent: "")
            none.isEnabled = false
            closedMenu.addItem(none)
        } else {
            for entry in closed {
                let item = NSMenuItem(title: Self.title(entry.title, entry.url), action: #selector(reopen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.id
                item.image = Self.icon(for: entry.url)
                item.toolTip = entry.url.absoluteString
                closedMenu.addItem(item)
            }
        }
        let closedHolder = NSMenuItem(title: "Recently Closed", action: nil, keyEquivalent: "")
        closedHolder.submenu = closedMenu
        added.append(mark(closedHolder))

        // Recent pages (not shown in Incognito, which keeps no History).
        if !state.isPrivate {
            let recent = HistoryStore.shared.browse(HistoryStore.Filter(), offset: 0, limit: Self.recentLimit, profileID: state.currentProfile.id).items
            if !recent.isEmpty {
                added.append(mark(NSMenuItem.separator()))
                let heading = NSMenuItem(title: "Recently Visited", action: nil, keyEquivalent: "")
                heading.isEnabled = false
                added.append(mark(heading))
                for entry in recent {
                    let item = NSMenuItem(title: Self.title(entry.title, entry.url), action: #selector(openPage(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = entry.url
                    item.image = Self.icon(for: entry.url)
                    item.toolTip = entry.url.absoluteString
                    added.append(mark(item))
                }
            }
        }

        // After "Forward" and its separator: Back, Forward, separator, then these.
        var index = min(3, menu.items.count)
        for item in added {
            menu.insertItem(item, at: index)
            index += 1
        }
        menu.insertItem(mark(NSMenuItem.separator()), at: index)
    }

    @objc private func reopen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let state = AppDelegate.shared?.state else { return }
        _ = state.restoreSession(id: id)
    }

    @objc private func openPage(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let app = AppDelegate.shared else { return }
        app.ensureBrowserWindow()
        let state = app.state
        let newTab = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        if !newTab, let tab = state.selectedTab, !tab.isExtensionPage {
            tab.load(url)
        } else {
            state.newTab(url: url)
        }
    }

    private static func title(_ title: String, _ url: URL) -> String {
        let text = title.trimmed.isEmpty ? url.displayHost : title.trimmed
        return text.count > 60 ? String(text.prefix(57)) + "…" : text
    }

    private static func icon(for url: URL) -> NSImage? {
        guard let image = FaviconStore.shared.cachedIcon(for: url)?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
