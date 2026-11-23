import CryptoKit
import Foundation

/// Tuff's sidebar as sidebar sync sees it: spaces with their pinned tabs, folders and open
/// tabs, and each profile's favourites. Pinned tabs and favourites carry the page they were
/// pinned on as `url`.
struct SidebarSnapshot: Equatable {
    struct Tab: Equatable {
        var id: UUID
        var url: String
        var title: String
        var customTitle: String?
    }

    struct Folder: Equatable {
        var id: UUID
        var name: String
        var tabs: [Tab]
    }

    enum Item: Equatable {
        case tab(Tab)
        case folder(Folder)
    }

    struct Space: Equatable {
        var id: UUID
        var name: String
        var icon: String
        var colorHex: String
        var profile: UUID
        var pinned: [Item]
        var tabs: [Tab]
    }

    struct Profile: Equatable {
        var id: UUID
        var name: String
        var icon: String
        var favorites: [Tab]
    }

    var profiles: [Profile] = []
    var spaces: [Space] = []
}

/// Zen's sidebar sync (the "spaces" collection, Zen's `ZenSpacesSync`): one record per space,
/// folder, pinned tab, Essential and container, and a "layout" record with the order of the
/// spaces and of each container's Essentials. A tab record says where the tab lives
/// (`workspaceUuid`, `folderId`, `pinned`, `essential`); spaces and folders list `children` only
/// for their order.
///
/// Zen workspaces are Tuff's spaces, its Essentials are favourites, and its containers are
/// profiles (matched by name; the synced profile is the one without a container). Zen's nested
/// folders show as folders of their own after their parent. Split views, live folders and
/// anything newer are kept on the server as they are.
///
/// Like Zen, a change that arrives from the server wins over one made here; a change made
/// here is noticed by comparing Tuff's records with what they were at the last sync, so details
/// Tuff can't show (a gradient, a per-tab container) don't count as changes.
enum SidebarSync {
    typealias Record = [String: Any]

    static let collection = "spaces"
    static let layoutID = "layout"

    struct Options {
        /// The profile whose spaces have no container in Zen.
        var syncProfile: UUID
        /// Open tabs too, not only pinned tabs and favourites (Zen's "Include unpinned tabs").
        var includeTabs: Bool
    }

    /// What the engine keeps between syncs.
    struct Memory: Codable {
        /// Tuff's IDs (spaces, folders, tabs, profiles) → record IDs.
        var ids: [UUID: String] = [:]
        /// The server's records as last seen: ID → cleartext JSON.
        var mirror: [String: String] = [:]
        /// Digests of Tuff's own records at the end of the last sync.
        var local: [String: String] = [:]
        /// A space's icon and colour at the last sync ("<id>.icon", "<id>.color"), so the
        /// server's version (a Zen icon or gradient Tuff can only approximate) is only replaced
        /// when they change here.
        var appearance: [String: String] = [:]
    }

    // MARK: Records

    static func data(_ record: Record?) -> [String: Any]? { record?["data"] as? [String: Any] }
    static func kind(_ record: Record?) -> String? { record?["kind"] as? String }

    private static func string(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A record's content, independent of key order.
    static func digest(_ record: Record?) -> String? {
        guard let record, let json = try? JSONSerialization.data(withJSONObject: record, options: .sortedKeys) else { return nil }
        return Data(SHA256.hash(data: json)).base64URL
    }

    /// Records Tuff shows. Everything else (splits, unpinned tabs while those are off, kinds it
    /// doesn't know) is only passed along.
    static func isManaged(_ record: Record?, includeTabs: Bool) -> Bool {
        switch kind(record) {
        case "space", "folder": true
        case "tab": includeTabs || data(record)?["pinned"] as? Bool != false
        default: false
        }
    }

    private static func samePage(_ a: String, _ b: String) -> Bool {
        guard let x = URL(string: a), let y = URL(string: b) else { return a == b }
        return Tab.samePage(x, y)
    }

    // MARK: Tuff → records

    /// Tuff's sidebar as records, built on the server's (`remote`) so fields Tuff doesn't know
    /// are kept. `memory.ids` gains IDs for new items.
    static func project(
        _ sidebar: SidebarSnapshot, remote: [String: Record], memory: inout Memory, options: Options,
        icon: (UUID) -> String? = { _ in nil }, now: Date = Date()
    ) -> [String: Record] {
        let stamp = Int64(now.timeIntervalSince1970 * 1000)
        var out: [String: Record] = [:]
        func id(_ uuid: UUID, _ make: () -> String) -> String {
            if let id = memory.ids[uuid] { return id }
            let new = make()
            memory.ids[uuid] = new
            return new
        }
        func template(_ id: String) -> [String: Any]? { data(remote[id]) }
        func put(_ id: String, _ kind: String, _ data: [String: Any]) { out[id] = ["id": id, "kind": kind, "data": data] }

        // Containers: every profile but the synced one.
        var containerOf: [UUID: String] = [:]
        for profile in sidebar.profiles where profile.id != options.syncProfile {
            let guid = id(profile.id) { UUID().uuidString.lowercased() }
            containerOf[profile.id] = guid
            var d = template(guid) ?? [:]
            d["guid"] = guid
            d["name"] = profile.name
            d["icon"] = ZenIcons.container[profile.icon] ?? string(d["icon"]) ?? "fingerprint"
            d["color"] = string(d["color"]) ?? ZenIcons.containerColors[profile.name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % ZenIcons.containerColors.count]
            put(guid, "container", d)
        }
        var profileOfContainer: [String: UUID] = [:]
        for (uuid, rid) in memory.ids where sidebar.profiles.contains(where: { $0.id == uuid }) { profileOfContainer[rid] = uuid }
        func profile(ofContainer guid: Any?) -> UUID? {
            guard let guid = string(guid) else { return options.syncProfile }
            return profileOfContainer[guid]
        }
        func container(_ profile: UUID) -> Any { containerOf[profile] ?? NSNull() }

        func tab(_ tab: SidebarSnapshot.Tab, profile owner: UUID, space: String?, folder: String?, essential: Bool, pinned: Bool) -> String {
            let rid = id(tab.id) { "\(stamp)-\(UUID().uuidString.lowercased())" }
            let old = template(rid)
            var d = old ?? [:]
            let oldURL = string(old?["url"])
            let samePage = oldURL.map { Self.samePage($0, tab.url) } ?? false
            d["tabId"] = rid
            d["url"] = samePage ? oldURL! : tab.url
            d["title"] = samePage ? (old?["title"] ?? tab.title) : tab.title
            d["icon"] = samePage ? (old?["icon"] ?? "") : (icon(tab.id) ?? "")
            // A tab that stayed where it was keeps its own container (Zen has them per tab).
            let stayed = old != nil && (old?["essential"] as? Bool ?? false) == essential
                && (essential ? profile(ofContainer: old?["containerGuid"]) == owner : string(old?["workspaceUuid"]) == space)
            if !stayed { d["containerGuid"] = container(owner) }
            d["essential"] = essential
            d["pinned"] = pinned
            d["workspaceUuid"] = essential ? NSNull() : space.map { $0 as Any } ?? NSNull()
            d["folderId"] = folder.map { $0 as Any } ?? NSNull()
            d["staticLabel"] = tab.customTitle.map { $0 as Any } ?? NSNull()
            if d["hasStaticIcon"] == nil { d["hasStaticIcon"] = false }
            if d["defaultContainer"] == nil { d["defaultContainer"] = true }
            put(rid, "tab", d)
            return rid
        }

        // Folders first, so nesting (which only Zen can change) is known.
        var folderIDs = Set<String>()
        for space in sidebar.spaces {
            for case .folder(let folder) in space.pinned {
                folderIDs.insert(id(folder.id) { "\(stamp)-\(UUID().uuidString.prefix(8).lowercased())" })
            }
        }

        var children: [String: [String]] = [:]
        var spaceOrder: [String] = []
        for space in sidebar.spaces {
            let sid = id(space.id) { "{\(UUID().uuidString.lowercased())}" }
            spaceOrder.append(sid)
            var kids: [String] = []
            for item in space.pinned {
                switch item {
                case .tab(let t):
                    kids.append(tab(t, profile: space.profile, space: sid, folder: nil, essential: false, pinned: true))
                case .folder(let folder):
                    let fid = memory.ids[folder.id]!
                    let old = template(fid)
                    let parent = string(old?["parentFolderId"]).flatMap { folderIDs.contains($0) ? $0 : nil }
                    if parent == nil { kids.append(fid) }
                    children[fid] = folder.tabs.map { tab($0, profile: space.profile, space: sid, folder: fid, essential: false, pinned: true) }
                    var d = old ?? [:]
                    d["folderId"] = fid
                    d["name"] = folder.name
                    if d["icon"] == nil { d["icon"] = NSNull() }
                    d["workspaceUuid"] = sid
                    d["parentFolderId"] = parent.map { $0 as Any } ?? NSNull()
                    if d["live"] == nil { d["live"] = NSNull() }
                    put(fid, "folder", d)
                }
            }
            if options.includeTabs {
                kids += space.tabs.map { tab($0, profile: space.profile, space: sid, folder: nil, essential: false, pinned: false) }
            }
            children[sid] = kids

            let old = template(sid)
            var d = old ?? [:]
            d["uuid"] = sid
            d["name"] = space.name
            if old == nil || memory.appearance["\(sid).icon"] != space.icon, let zen = ZenIcons.zen(forSymbol: space.icon) {
                d["icon"] = zen
            }
            if d["icon"] == nil { d["icon"] = NSNull() }
            if old == nil || memory.appearance["\(sid).color"]?.lowercased() != space.colorHex.lowercased(), let theme = ZenTheme.theme(hex: space.colorHex) {
                d["theme"] = theme
            }
            if d["theme"] == nil { d["theme"] = NSNull() }
            if old == nil || profile(ofContainer: old?["containerGuid"]) != space.profile { d["containerGuid"] = container(space.profile) }
            put(sid, "space", d)
        }

        // Children lists: Tuff's order, with what only the server has (splits, nested folders,
        // tabs Tuff doesn't show) kept after the item it followed.
        let listed = Set(children.values.joined())
        for (owner, kids) in children {
            let old = (template(owner)?["children"] as? [String]) ?? []
            let mine = Set(kids)
            let carried = old.filter { child in
                if mine.contains(child) { return true }
                guard !listed.contains(child), let record = remote[child] else { return false }
                if !isManaged(record, includeTabs: options.includeTabs) { return true }
                return kind(record) == "folder" && string(data(record)?["parentFolderId"]) == owner && out[child] != nil
            }
            var d = data(out[owner]) ?? [:]
            d["children"] = BookmarkMerge.interleave(kids, carried)
            out[owner]?["data"] = d
        }

        // Layout: the spaces' order and each container's Essentials.
        if !sidebar.spaces.isEmpty {
            var essentials: [String: [String]] = [:]
            for profile in sidebar.profiles {
                for favorite in profile.favorites {
                    let rid = tab(favorite, profile: profile.id, space: nil, folder: nil, essential: true, pinned: true)
                    let key = string(data(out[rid])?["containerGuid"]) ?? "default"
                    essentials[key, default: []].append(rid)
                }
            }
            let old = template(layoutID)
            let oldSpaces = (old?["spaces"] as? [String] ?? []).filter { kind(remote[$0]) == "space" && !spaceOrder.contains($0) }
            var d = old ?? [:]
            d["spaces"] = BookmarkMerge.interleave(spaceOrder, oldSpaces)
            d["essentials"] = essentials
            put(layoutID, "layout", d)
        }
        return out
    }

    /// Notes each space's icon and colour as synced (see `Memory.appearance`).
    static func remember(_ sidebar: SidebarSnapshot, in memory: inout Memory) {
        var appearance: [String: String] = [:]
        for space in sidebar.spaces {
            guard let sid = memory.ids[space.id] else { continue }
            appearance["\(sid).icon"] = space.icon
            appearance["\(sid).color"] = space.colorHex
        }
        memory.appearance = appearance
    }

    // MARK: First sync

    /// Pairs Tuff's items with the server's on a first sync (spaces and folders by name, tabs
    /// by page), so a sidebar imported from Zen earlier isn't doubled.
    static func match(_ sidebar: SidebarSnapshot, remote: [String: Record], memory: inout Memory, options: Options) {
        var taken = Set(memory.ids.values)
        func claim(_ uuid: UUID, _ candidates: [String]) -> String? {
            guard memory.ids[uuid] == nil, let rid = candidates.sorted().first(where: { !taken.contains($0) }) else { return memory.ids[uuid] }
            memory.ids[uuid] = rid
            taken.insert(rid)
            return rid
        }
        func records(_ kind: String) -> [(String, [String: Any])] {
            remote.compactMap { id, record in Self.kind(record) == kind ? data(record).map { (id, $0) } : nil }
        }
        func sameName(_ a: Any?, _ b: String) -> Bool {
            (a as? String)?.trimmed.lowercased() == b.trimmed.lowercased()
        }
        let containers = records("container"), spaces = records("space"), folders = records("folder"), tabs = records("tab")

        for profile in sidebar.profiles {
            _ = claim(profile.id, containers.filter { sameName($0.1["name"], profile.name) }.map(\.0))
        }
        var profileOfContainer: [String: UUID] = [:]
        for (uuid, rid) in memory.ids where sidebar.profiles.contains(where: { $0.id == uuid }) { profileOfContainer[rid] = uuid }
        func profile(ofContainer guid: Any?) -> UUID? {
            guard let guid = string(guid) else { return options.syncProfile }
            return profileOfContainer[guid]
        }

        func matchTabs(_ list: [SidebarSnapshot.Tab], _ candidates: [(String, [String: Any])]) {
            for tab in list {
                _ = claim(tab.id, candidates.filter { string($0.1["url"]).map { samePage($0, tab.url) } == true }.map(\.0))
            }
        }
        for space in sidebar.spaces {
            guard let sid = claim(space.id, spaces.filter { sameName($0.1["name"], space.name) && profile(ofContainer: $0.1["containerGuid"]) == space.profile }.map(\.0)) else { continue }
            let pinned = tabs.filter { string($0.1["workspaceUuid"]) == sid && $0.1["essential"] as? Bool != true && $0.1["pinned"] as? Bool != false }
            for item in space.pinned {
                switch item {
                case .tab(let t): matchTabs([t], pinned)
                case .folder(let folder):
                    _ = claim(folder.id, folders.filter { string($0.1["workspaceUuid"]) == sid && sameName($0.1["name"], folder.name) }.map(\.0))
                    matchTabs(folder.tabs, pinned)
                }
            }
            if options.includeTabs {
                matchTabs(space.tabs, tabs.filter { string($0.1["workspaceUuid"]) == sid && $0.1["pinned"] as? Bool == false })
            }
        }
        for profile in sidebar.profiles {
            matchTabs(profile.favorites, tabs.filter { $0.1["essential"] as? Bool == true && Self.profile(of: $0.1, profileOfContainer, options) == profile.id })
        }
    }

    private static func profile(of tab: [String: Any], _ profileOfContainer: [String: UUID], _ options: Options) -> UUID? {
        guard let guid = string(tab["containerGuid"]) else { return options.syncProfile }
        return profileOfContainer[guid]
    }

    // MARK: Merging

    struct Merge {
        var merged: [String: Record]
        /// What arrived from the server and differs from what it had before.
        var remoteChanged: Set<String>
        /// Records to send: a record, or nil to delete it.
        var uploads: [String: Record?]
    }

    /// `base` is the server as last seen and `incoming` what changed there since (nil: deleted);
    /// `local` is Tuff's sidebar now and `memory.local` what it was at the last sync.
    static func merge(base: [String: Record], incoming: [String: Record?], local: [String: Record], lastLocal: [String: String], includeTabs: Bool) -> Merge {
        var remote = base
        var remoteChanged = Set<String>()
        for (id, record) in incoming {
            if digest(record) != digest(base[id]) { remoteChanged.insert(id) }
            remote[id] = record
        }
        var merged = remote
        for (id, record) in local where !remoteChanged.contains(id) && digest(record) != lastLocal[id] {
            merged[id] = record
        }
        // Gone here since the last sync (and not something Tuff only passes along).
        for id in lastLocal.keys where local[id] == nil && !remoteChanged.contains(id) && isManaged(remote[id], includeTabs: includeTabs) {
            merged[id] = nil
        }
        var uploads: [String: Record?] = [:]
        for id in Set(merged.keys).union(remote.keys) where digest(merged[id]) != digest(remote[id]) {
            uploads[id] = .some(merged[id])
        }
        return Merge(merged: merged, remoteChanged: remoteChanged, uploads: uploads)
    }

    // MARK: Records → Tuff

    /// The sidebar Tuff should show for `merged`. Items that didn't change on the server keep
    /// what Tuff has for them (names, icons, colours, pages); where things are and their order
    /// always follow the records. Nil when there would be no spaces left.
    static func plan(_ merged: [String: Record], current: SidebarSnapshot, memory: inout Memory, changed: Set<String>, options: Options) -> SidebarSnapshot? {
        var reverse: [String: UUID] = [:]
        for (uuid, rid) in memory.ids { reverse[rid] = uuid }
        func uuid(_ rid: String) -> UUID {
            if let known = reverse[rid] { return known }
            let new = UUID()
            reverse[rid] = new
            memory.ids[new] = rid
            return new
        }
        func d(_ rid: String) -> [String: Any] { data(merged[rid]) ?? [:] }
        func ids(_ kind: String) -> [String] { merged.keys.filter { Self.kind(merged[$0]) == kind }.sorted() }

        var currentTabs: [UUID: SidebarSnapshot.Tab] = [:]
        var currentSpaces: [UUID: SidebarSnapshot.Space] = [:]
        var currentFolders: [UUID: SidebarSnapshot.Folder] = [:]
        var position: [UUID: Int] = [:]
        func note(_ tab: SidebarSnapshot.Tab) {
            currentTabs[tab.id] = tab
            position[tab.id] = position.count
        }
        for profile in current.profiles { profile.favorites.forEach(note) }
        for space in current.spaces {
            currentSpaces[space.id] = space
            position[space.id] = position.count
            for item in space.pinned {
                switch item {
                case .tab(let t): note(t)
                case .folder(let f):
                    currentFolders[f.id] = f
                    position[f.id] = position.count
                    f.tabs.forEach(note)
                }
            }
            space.tabs.forEach(note)
        }
        /// Items the records don't order: as Tuff had them, new ones last.
        func ordered(_ list: [String]) -> [String] {
            list.sorted { a, b in
                let pa = reverse[a].flatMap { position[$0] } ?? Int.max, pb = reverse[b].flatMap { position[$0] } ?? Int.max
                return pa == pb ? a < b : pa < pb
            }
        }

        // Profiles: the synced one has no container; others by mapping, then name, else new.
        var profiles = current.profiles
        func profile(ofContainer value: Any?) -> UUID {
            guard let guid = string(value) else { return options.syncProfile }
            let record = data(merged[guid])
            let name = string(record?["name"]) ?? ZenIcons.builtinContainers[guid] ?? "Zen"
            if let known = reverse[guid], let index = profiles.firstIndex(where: { $0.id == known }) {
                if changed.contains(guid), known != options.syncProfile, profiles[index].name != name { profiles[index].name = name }
                return known
            }
            let taken = Set(memory.ids.keys)
            if let match = profiles.first(where: { !taken.contains($0.id) && $0.name.trimmed.lowercased() == name.trimmed.lowercased() }) {
                memory.ids[match.id] = guid
                reverse[guid] = match.id
                return match.id
            }
            let new = SidebarSnapshot.Profile(id: UUID(), name: name, icon: ZenIcons.symbol(forContainer: string(record?["icon"])) ?? "person.fill", favorites: [])
            profiles.append(new)
            memory.ids[new.id] = guid
            reverse[guid] = new.id
            return new.id
        }

        func tab(_ rid: String) -> SidebarSnapshot.Tab {
            let r = d(rid), id = uuid(rid)
            if let mine = currentTabs[id], !changed.contains(rid) { return mine }
            let mine = currentTabs[id]
            let label = string(r["staticLabel"])
            return SidebarSnapshot.Tab(id: id, url: string(r["url"]) ?? mine?.url ?? "", title: string(r["title"]) ?? mine?.title ?? "", customTitle: label)
        }

        // Spaces, in the layout's order.
        let spaceIDs = ids("space")
        guard !spaceIDs.isEmpty else { return nil }
        let layout = d(layoutID)
        let listedOrder = (layout["spaces"] as? [String] ?? []).filter { spaceIDs.contains($0) }
        var spaceOrder: [String] = []
        for rid in listedOrder + ordered(spaceIDs) where !spaceOrder.contains(rid) { spaceOrder.append(rid) }
        let fallbackSpace = spaceOrder.first { profile(ofContainer: d($0)["containerGuid"]) == options.syncProfile } ?? spaceOrder[0]

        // Where each folder and tab goes.
        let folderIDs = Set(ids("folder"))
        func spaceOf(_ r: [String: Any]) -> String {
            string(r["workspaceUuid"]).flatMap { spaceIDs.contains($0) ? $0 : nil } ?? fallbackSpace
        }
        var foldersIn: [String: [String]] = [:]
        var subfolders: [String: [String]] = [:]
        var folderSpace: [String: String] = [:]
        for fid in folderIDs.sorted() {
            let r = d(fid)
            if let parent = string(r["parentFolderId"]), folderIDs.contains(parent), parent != fid {
                subfolders[parent, default: []].append(fid)
            } else {
                let space = spaceOf(r)
                folderSpace[fid] = space
                foldersIn[space, default: []].append(fid)
            }
        }
        var looseIn: [String: [String]] = [:]
        var openIn: [String: [String]] = [:]
        var tabsIn: [String: [String]] = [:]
        var favoritesOf: [UUID: [String]] = [:]
        for rid in ids("tab") {
            let r = d(rid)
            guard string(r["url"]) != nil else { continue }
            if r["essential"] as? Bool == true {
                favoritesOf[profile(ofContainer: r["containerGuid"]), default: []].append(rid)
            } else if r["pinned"] as? Bool == false {
                if options.includeTabs { openIn[spaceOf(r), default: []].append(rid) }
            } else if let folder = string(r["folderId"]), folderIDs.contains(folder) {
                tabsIn[folder, default: []].append(rid)
            } else {
                looseIn[spaceOf(r), default: []].append(rid)
            }
        }
        /// `members` in the order `children` gives, the rest after.
        func arrange(_ members: [String], by children: Any?) -> [String] {
            let set = Set(members)
            var seen = Set<String>()
            var result = ((children as? [String]) ?? []).filter { set.contains($0) && seen.insert($0).inserted }
            for id in ordered(members) where seen.insert(id).inserted { result.append(id) }
            return result
        }

        func folder(_ fid: String, into items: inout [SidebarSnapshot.Item], depth: Int = 0) {
            let r = d(fid), id = uuid(fid)
            let mine = currentFolders[id]
            let name = mine != nil && !changed.contains(fid) ? mine!.name : string(r["name"]) ?? mine?.name ?? "Folder"
            let tabs = arrange(tabsIn[fid] ?? [], by: r["children"]).map(tab)
            items.append(.folder(SidebarSnapshot.Folder(id: id, name: name, tabs: tabs)))
            guard depth < 8 else { return }
            for sub in arrange(subfolders[fid] ?? [], by: r["children"]) { folder(sub, into: &items, depth: depth + 1) }
        }

        var spaces: [SidebarSnapshot.Space] = []
        var usedColors = Set(current.spaces.map { $0.colorHex.lowercased() })
        for sid in spaceOrder {
            let r = d(sid), id = uuid(sid)
            let mine = currentSpaces[id]
            let fresh = mine == nil || changed.contains(sid)
            let name = fresh ? string(r["name"]) ?? mine?.name ?? "Space" : mine!.name
            let icon = fresh ? ZenIcons.symbol(forZen: string(r["icon"])) ?? mine?.icon ?? "sparkles" : mine!.icon
            var color = fresh ? ZenTheme.hex(r["theme"]) ?? mine?.colorHex : mine!.colorHex
            if color == nil {
                color = Space.palette.first { !usedColors.contains($0.lowercased()) } ?? Space.palette[spaces.count % Space.palette.count]
                usedColors.insert(color!.lowercased())
            }
            var items: [SidebarSnapshot.Item] = []
            let loose = Set(looseIn[sid] ?? []), folders = Set(foldersIn[sid] ?? [])
            for child in arrange(Array(loose.union(folders)), by: r["children"]) {
                if loose.contains(child) { items.append(.tab(tab(child))) } else { folder(child, into: &items) }
            }
            let open = options.includeTabs ? arrange(openIn[sid] ?? [], by: r["children"]).map(tab) : mine?.tabs ?? []
            spaces.append(SidebarSnapshot.Space(
                id: id, name: name, icon: icon, colorHex: color!, profile: profile(ofContainer: r["containerGuid"]),
                pinned: items, tabs: open
            ))
        }

        // Favourites: each container's Essentials in the layout's order.
        let essentials = layout["essentials"] as? [String: Any] ?? [:]
        for index in profiles.indices {
            let id = profiles[index].id
            let keys = essentials.keys.filter { key in (key == "default" ? options.syncProfile : reverse[key]) == id }.sorted()
            let order = keys.flatMap { essentials[$0] as? [String] ?? [] }
            profiles[index].favorites = arrange(favoritesOf[id] ?? [], by: order).map(tab)
        }
        return SidebarSnapshot(profiles: profiles, spaces: spaces)
    }
}

// MARK: - Zen's icons and themes

enum ZenIcons {
    private static let selectable = "chrome://browser/skin/zen-icons/selectable/"

    /// Tuff's space symbols and Zen's icons that mean the same.
    private static let pairs: [(symbol: String, zen: String)] = [
        ("bookmark.fill", "bookmark"), ("flask.fill", "flask"), ("book.fill", "book"), ("briefcase.fill", "briefcase"),
        ("gamecontroller.fill", "game-controller"), ("music.note", "music"), ("star.fill", "star"), ("heart.fill", "heart"),
        ("graduationcap.fill", "school"), ("cart.fill", "basket"), ("paintbrush.fill", "brush"), ("hammer.fill", "build"),
        ("globe", "globe"), ("leaf.fill", "leaf"), ("moon.fill", "moon"), ("bolt.fill", "lightning"), ("film.fill", "video"),
        ("terminal.fill", "terminal"), ("airplane", "airplane"), ("camera.fill", "image"), ("cup.and.saucer.fill", "cafe"),
        ("dumbbell.fill", "weight"), ("sparkles", "tada"),
    ]

    /// Zen icons with a close symbol but none of Tuff's own.
    private static let extra: [String: String] = [
        "bed": "bed.double.fill", "bell": "bell.fill", "bug": "ladybug.fill", "call": "phone.fill", "card": "creditcard.fill",
        "chat": "bubble.left.fill", "checkbox": "checkmark.square.fill", "circle": "circle.fill", "cloud": "cloud.fill",
        "code": "chevron.left.forwardslash.chevron.right", "coins": "dollarsign.circle.fill", "construct": "wrench.and.screwdriver.fill",
        "cutlery": "fork.knife", "eye": "eye.fill", "fish": "fish.fill", "flag": "flag.fill", "flame": "flame.fill",
        "folder": "folder.fill", "globe-1": "globe", "grid-2x2": "square.grid.2x2.fill", "grid-3x3": "square.grid.3x3.fill",
        "inbox": "tray.fill", "key": "key.fill", "location": "location.fill", "lock-closed": "lock.fill",
        "logo-github": "chevron.left.forwardslash.chevron.right", "logo-usd": "dollarsign.circle.fill", "mail": "envelope.fill",
        "map": "map.fill", "megaphone": "megaphone.fill", "navigate": "location.north.fill", "page": "doc.fill",
        "palette": "paintpalette.fill", "paw": "pawprint.fill", "people": "person.2.fill", "pizza": "fork.knife",
        "fast-food": "fork.knife", "planet": "globe.americas.fill", "present": "gift.fill", "shirt": "tshirt.fill",
        "square": "square.fill", "squares": "square.on.square.fill", "star-1": "star.fill", "stats-chart": "chart.bar.fill",
        "sun": "sun.max.fill", "ticket": "ticket.fill", "time": "clock.fill", "trash": "trash.fill", "triangle": "triangle.fill",
        "volume-high": "speaker.wave.2.fill", "wallet": "wallet.pass.fill", "warning": "exclamationmark.triangle.fill",
        "water": "drop.fill", "american-football": "football.fill", "baseball": "baseball.fill",
        "extension-puzzle": "puzzlepiece.extension.fill", "layers": "square.3.layers.3d", "nuclear": "atom",
        "logo-rss": "dot.radiowaves.up.forward",
    ]

    /// A Zen space icon (`chrome://…/selectable/flask.svg`, or an emoji) as a symbol, if there is one.
    static func symbol(forZen icon: String?) -> String? {
        guard let icon, icon.hasPrefix(selectable) else { return nil }
        let name = String(icon.dropFirst(selectable.count)).replacingOccurrences(of: ".svg", with: "")
        return pairs.first { $0.zen == name }?.symbol ?? extra[name]
    }

    static func zen(forSymbol symbol: String) -> String? {
        pairs.first { $0.symbol == symbol }.map { selectable + $0.zen + ".svg" }
    }

    /// Tuff's profile symbols → Firefox container icons.
    static let container: [String: String] = [
        "person.fill": "fingerprint", "briefcase.fill": "briefcase", "cart.fill": "cart", "gift.fill": "gift",
        "airplane": "vacation", "fork.knife": "food", "pawprint.fill": "pet", "tree.fill": "tree", "leaf.fill": "tree",
        "dollarsign.circle.fill": "dollar", "circle.fill": "circle",
    ]

    static func symbol(forContainer icon: String?) -> String? {
        switch icon {
        case "fingerprint": "person.fill"
        case "briefcase": "briefcase.fill"
        case "dollar": "dollarsign.circle.fill"
        case "cart": "cart.fill"
        case "vacation": "airplane"
        case "gift": "gift.fill"
        case "food", "fruit": "fork.knife"
        case "pet": "pawprint.fill"
        case "tree": "leaf.fill"
        case "chill": "cup.and.saucer.fill"
        case "fence": "square.grid.3x3.fill"
        default: nil
        }
    }

    static let containerColors = ["blue", "turquoise", "green", "yellow", "orange", "red", "pink", "purple"]

    /// Firefox's default containers, which Zen syncs without a record of their own.
    static let builtinContainers = ["builtin-1": "Personal", "builtin-2": "Work", "builtin-3": "Banking", "builtin-4": "Shopping"]
}

/// Zen's space themes: a gradient of colour dots. Tuff keeps one colour per space, the primary dot.
enum ZenTheme {
    static func hex(_ theme: Any?) -> String? {
        guard let theme = theme as? [String: Any], let dots = theme["gradientColors"] as? [[String: Any]] else { return nil }
        let dot = dots.first { $0["isPrimary"] as? Bool == true } ?? dots.first
        let rgb = (dot?["c"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
        guard rgb.count >= 3 else { return nil }
        return String(format: "#%02X%02X%02X", Int(rgb[0].rounded()), Int(rgb[1].rounded()), Int(rgb[2].rounded()))
    }

    static func theme(hex: String) -> [String: Any]? {
        var value: UInt64 = 0
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, Scanner(string: digits).scanHexInt64(&value) else { return nil }
        let r = Int(value >> 16 & 0xFF), g = Int(value >> 8 & 0xFF), b = Int(value & 0xFF)
        let lightness = Int(((Double(max(r, g, b)) + Double(min(r, g, b))) / 2 / 255 * 100).rounded())
        return [
            "type": "gradient",
            "gradientColors": [[
                "c": [r, g, b], "isCustom": false, "algorithm": "floating", "isPrimary": true,
                "lightness": lightness, "position": ["x": 160, "y": 160], "type": "undefined",
            ] as [String: Any]],
            "opacity": 0.5,
            "texture": 0,
        ]
    }
}
