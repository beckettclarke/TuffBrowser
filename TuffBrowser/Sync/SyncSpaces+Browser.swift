import AppKit

/// Sidebar sync on the live window: reading its spaces, tabs and favourites, and making them
/// match what the server has (`SidebarSync.plan`).
extension BrowserState {
    /// Only web pages sync; Tuff's own pages and blank tabs stay where they are.
    private static func syncable(_ url: URL?) -> URL? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    private func syncTab(_ tab: Tab, pinned: Bool) -> SidebarSnapshot.Tab? {
        guard let url = Self.syncable(pinned ? tab.homeURL ?? tab.url : tab.url) else { return nil }
        return SidebarSnapshot.Tab(id: tab.id, url: url.absoluteString, title: tab.title, customTitle: tab.customTitle)
    }

    func sidebarSnapshot() -> SidebarSnapshot {
        SidebarSnapshot(
            profiles: profiles.filter { !$0.isPrivate }.map { profile in
                SidebarSnapshot.Profile(id: profile.id, name: profile.name, icon: profile.icon, favorites: profile.favorites.compactMap { syncTab($0, pinned: true) })
            },
            spaces: spaces.map { space in
                SidebarSnapshot.Space(
                    id: space.id, name: space.name, icon: space.icon, colorHex: space.colorHex, profile: space.profileID,
                    pinned: space.pinnedItems.compactMap { item in
                        switch item {
                        case .tab(let tab): syncTab(tab, pinned: true).map(SidebarSnapshot.Item.tab)
                        case .folder(let folder):
                            .folder(SidebarSnapshot.Folder(id: folder.id, name: folder.name, tabs: folder.tabs.compactMap { syncTab($0, pinned: true) }))
                        }
                    },
                    tabs: space.tabs.compactMap { syncTab($0, pinned: false) }
                )
            }
        )
    }

    /// A tab's icon for another device: a small PNG as a data: URL.
    func syncIcon(for id: UUID) -> String? {
        guard let image = allTabs.first(where: { $0.id == id })?.favicon else { return nil }
        let size = NSSize(width: 32, height: 32)
        let small = NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
        guard let tiff = small.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    /// Makes the sidebar `plan`. Tabs that stay keep their pages and web views; tabs that sync
    /// can't carry (Tuff's own pages, blank tabs) stay where they were. `icons` are data: URLs
    /// for new tabs' icons.
    func applySidebar(_ plan: SidebarSnapshot, includeTabs: Bool, icons: [UUID: String]) {
        guard !plan.spaces.isEmpty else { return }
        let previous = selectedTab
        let shownSpace = currentSpace.id
        let before = allTabs
        var pool: [UUID: Tab] = [:]
        for tab in before { pool[tab.id] = tab }
        var kept = Set<UUID>()
        var created: [Tab] = []

        func make(_ s: SidebarSnapshot.Tab, pinned: Bool) -> Tab {
            kept.insert(s.id)
            let url = URL(string: s.url)
            if let tab = pool[s.id] {
                if pinned {
                    if let url, tab.homeURL.map({ !Tab.samePage($0, url) }) ?? true {
                        tab.homeURL = url
                        if !tab.isAwake {
                            tab.url = url
                            tab.title = s.title
                        }
                    }
                } else {
                    tab.homeURL = nil
                    if let url, !tab.isAwake, tab.url.map({ !Tab.samePage($0, url) }) ?? true {
                        tab.url = url
                        tab.title = s.title
                    }
                }
                tab.customTitle = s.customTitle
                return tab
            }
            let tab = Tab(id: s.id, url: url, title: s.title, homeURL: pinned ? url : nil)
            tab.customTitle = s.customTitle
            if tab.favicon == nil, let icon = icons[s.id], let image = Self.image(fromDataURL: icon) { tab.favicon = image }
            pool[s.id] = tab
            created.append(tab)
            return tab
        }
        /// `new`, with the tabs sync doesn't carry put back where they were in `old`.
        func keeping(_ new: [Tab], from old: [Tab], pinned: Bool) -> [Tab] {
            var result = new
            for (index, tab) in old.enumerated() where syncTab(tab, pinned: pinned) == nil {
                kept.insert(tab.id)
                result.insert(tab, at: min(index, result.count))
            }
            return result
        }

        // Profiles: new ones for containers Tuff had no profile for; renamed ones.
        var profileByID: [UUID: Profile] = [:]
        for profile in profiles { profileByID[profile.id] = profile }
        for p in plan.profiles {
            if let profile = profileByID[p.id] {
                if profile.name != p.name {
                    profile.name = p.name
                    profileDidChange(profile)
                }
            } else {
                let profile = Profile(id: p.id, name: p.name, icon: p.icon)
                profileByID[p.id] = profile
                profiles.append(profile)
                ExtensionContainers.shared.profileCreated(profile)
            }
            let profile = profileByID[p.id]!
            profile.favorites = keeping(p.favorites.map { make($0, pinned: true) }, from: profile.favorites, pinned: true)
        }

        var folderByID: [UUID: Folder] = [:]
        for space in spaces { for folder in space.folders { folderByID[folder.id] = folder } }
        var spaceByID: [UUID: Space] = [:]
        for space in spaces { spaceByID[space.id] = space }
        var next: [Space] = []
        for s in plan.spaces {
            let space = spaceByID[s.id] ?? Space(id: s.id, name: s.name, icon: s.icon, colorHex: s.colorHex, profileID: s.profile)
            space.name = s.name
            space.icon = s.icon
            space.colorHex = s.colorHex
            let movedProfile = space.profileID != s.profile
            space.profileID = s.profile

            var items: [PinnedItem] = s.pinned.map { item in
                switch item {
                case .tab(let t):
                    return .tab(make(t, pinned: true))
                case .folder(let f):
                    let folder = folderByID[f.id] ?? Folder(id: f.id, name: f.name, isOpen: false)
                    folder.name = f.name
                    folder.tabs = keeping(f.tabs.map { make($0, pinned: true) }, from: folder.tabs, pinned: true)
                    return .folder(folder)
                }
            }
            for (index, item) in space.pinnedItems.enumerated() {
                guard let tab = item.tab, syncTab(tab, pinned: true) == nil else { continue }
                kept.insert(tab.id)
                items.insert(item, at: min(index, items.count))
            }
            space.pinnedItems = items
            if includeTabs {
                space.tabs = keeping(s.tabs.map { make($0, pinned: false) }, from: space.tabs, pinned: false)
            } else {
                kept.formUnion(space.tabs.map(\.id))
            }
            if movedProfile, let profile = profileByID[s.profile] {
                for tab in space.allPinned + space.tabs { tab.moveToDataStore(profile.dataStore) }
            }
            next.append(space)
        }

        // Whatever is gone from the server is gone here.
        for tab in before where !kept.contains(tab.id) {
            ext?.didClose(tab)
            tab.tearDown()
        }
        for space in next {
            if let id = space.selectedTabID, tab(withID: id, in: space) == nil {
                space.selectedTabID = (space.tabs.first ?? space.allPinned.first)?.id
            }
        }
        spaces = next
        pruneSplits()
        currentSpaceIndex = spaces.firstIndex { $0.id == shownSpace } ?? min(currentSpaceIndex, spaces.count - 1)
        pagerPosition = Double(currentSpaceIndex)
        if !created.isEmpty { adopt(created) }
        if selectedTab !== previous {
            spaceDidChange(previous: previous)
        } else {
            scheduleSave()
        }
    }

    private static func image(fromDataURL string: String) -> NSImage? {
        guard string.hasPrefix("data:"), let comma = string.firstIndex(of: ",") else { return nil }
        let header = string[..<comma]
        let body = String(string[string.index(after: comma)...])
        let data = header.hasSuffix(";base64") ? Data(base64Encoded: body) : body.removingPercentEncoding.map { Data($0.utf8) }
        return data.flatMap(NSImage.init(data:))
    }
}
