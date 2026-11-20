import Foundation

/// One item of a bookmark tree in Sync's terms, keyed by its GUID in `SyncBookmarkTree`.
struct SyncBookmarkNode: Equatable {
    enum Kind: String {
        case bookmark, folder
        /// Separators, queries, livemarks and bookmarks Tuff can't open: kept where they are on
        /// the server, never shown.
        case other
    }

    var kind: Kind
    var title: String
    var url: String?
    var parent: String
    var children: [String] = []

    func sameValue(_ other: SyncBookmarkNode) -> Bool {
        kind == other.kind && title == other.title && url == other.url
    }
}

typealias SyncBookmarkTree = [String: SyncBookmarkNode]

/// Merging bookmarks: Tuff's, the server's, and the tree both agreed on after the last sync
/// (the base). Each side's changes since the base are kept; where both changed the same thing,
/// the server's wins. On a first sync (no base), items with the same name and address in the
/// same folder are taken to be the same bookmark rather than doubled.
enum BookmarkMerge {
    /// Firefox's top-level folders, under the "places" root that is never synced.
    static let roots = ["menu", "toolbar", "unfiled", "mobile"]
    static let places = "places"
    /// Where an item goes when the folder it was in is gone.
    static let fallbackParent = "unfiled"

    // MARK: Records

    /// The node a (decrypted) bookmark record describes; nil for a deletion or the places root.
    static func node(from record: [String: Any]) -> SyncBookmarkNode? {
        guard record["deleted"] as? Bool != true, let id = record["id"] as? String, id != places else { return nil }
        let type = record["type"] as? String ?? ""
        let title = record["title"] as? String ?? ""
        let parent = record["parentid"] as? String ?? fallbackParent
        switch type {
        case "folder":
            return SyncBookmarkNode(kind: .folder, title: title, parent: parent, children: record["children"] as? [String] ?? [])
        case "bookmark":
            let address = record["bmkUri"] as? String
            let usable = address.flatMap(URL.init(string:))?.scheme != nil
            return SyncBookmarkNode(kind: usable ? .bookmark : .other, title: title, url: address, parent: parent)
        default:
            return SyncBookmarkNode(kind: .other, title: title, url: record["bmkUri"] as? String, parent: parent)
        }
    }

    static func tree(from records: [String: [String: Any]]) -> SyncBookmarkTree {
        var tree = SyncBookmarkTree()
        for (id, record) in records { if let node = node(from: record) { tree[id] = node } }
        return tree
    }

    /// The record to upload for a merged node, keeping whatever else the server's record had
    /// (tags, keywords, dates…).
    static func record(_ id: String, _ node: SyncBookmarkNode, in tree: SyncBookmarkTree, existing: [String: Any]?, now: Date = Date()) -> [String: Any] {
        var record = existing ?? [:]
        record["id"] = id
        record.removeValue(forKey: "deleted")
        switch node.kind {
        case .bookmark:
            record["type"] = "bookmark"
            record["title"] = node.title
            record["bmkUri"] = node.url ?? ""
        case .folder:
            record["type"] = "folder"
            record["title"] = node.title
            record["children"] = node.children
        case .other:
            break
        }
        record["parentid"] = node.parent
        record["parentName"] = tree[node.parent]?.title ?? ""
        if record["dateAdded"] == nil { record["dateAdded"] = Int(now.timeIntervalSince1970 * 1000) }
        return record
    }

    // MARK: First sync

    /// Pairs items Tuff has that the base doesn't with server items the base doesn't have
    /// either, when they match (same kind, name and address) in folders already paired.
    /// Returns local GUID → server GUID.
    static func duplicates(base: SyncBookmarkTree, local: SyncBookmarkTree, remote: SyncBookmarkTree) -> [String: String] {
        var renames: [String: String] = [:]
        var taken = Set<String>()
        var pending = roots.map { ($0, $0) }
        var visited = Set<String>()
        while let (localFolder, remoteFolder) = pending.popLast() {
            guard visited.insert(localFolder).inserted, let lf = local[localFolder], let rf = remote[remoteFolder] else { continue }
            for child in lf.children {
                guard let node = local[child] else { continue }
                if base[child] == nil, remote[child] == nil {
                    let match = rf.children.first { candidate in
                        guard base[candidate] == nil, local[candidate] == nil, !taken.contains(candidate),
                              let other = remote[candidate], node.kind != .other else { return false }
                        return other.sameValue(node)
                    }
                    if let match {
                        renames[child] = match
                        taken.insert(match)
                        if node.kind == .folder { pending.append((child, match)) }
                    }
                } else if node.kind == .folder, remote[child]?.kind == .folder {
                    pending.append((child, child))
                }
            }
        }
        return renames
    }

    static func renamed(_ tree: SyncBookmarkTree, _ renames: [String: String]) -> SyncBookmarkTree {
        guard !renames.isEmpty else { return tree }
        func id(_ old: String) -> String { renames[old] ?? old }
        var result = SyncBookmarkTree()
        for (key, var node) in tree {
            node.parent = id(node.parent)
            node.children = node.children.map(id)
            result[id(key)] = node
        }
        return result
    }

    // MARK: Merge

    static func merge(base: SyncBookmarkTree, local: SyncBookmarkTree, remote: SyncBookmarkTree) -> SyncBookmarkTree {
        // Which items survive, with which name and address, under which folder.
        var kept = SyncBookmarkTree()
        for id in Set(local.keys).union(remote.keys) where !roots.contains(id) {
            let b = base[id], l = local[id], r = remote[id]
            switch (l, r) {
            case let (l?, r?):
                var node = b.map { r.sameValue($0) } == true ? l : r
                node.parent = (b != nil && r.parent == b!.parent) ? l.parent : r.parent
                kept[id] = node
            case let (l?, nil):
                // New here, or changed here after the server deleted it.
                if let b, l.sameValue(b), l.parent == b.parent { continue }
                kept[id] = l
            case let (nil, r?):
                if let b, r.sameValue(b), r.parent == b.parent { continue }
                kept[id] = r
            case (nil, nil):
                continue
            }
        }
        for id in roots {
            var node = remote[id] ?? local[id] ?? base[id] ?? SyncBookmarkNode(kind: .folder, title: id, parent: places)
            node.kind = .folder
            node.parent = places
            kept[id] = node
        }

        // An item whose folder is gone moves up to the nearest folder that's left.
        for id in Array(kept.keys) where !roots.contains(id) {
            var parent = kept[id]!.parent
            var steps = 0
            while kept[parent]?.kind != .folder, steps < 64 {
                parent = (local[parent] ?? remote[parent] ?? base[parent])?.parent ?? fallbackParent
                steps += 1
            }
            if kept[parent]?.kind != .folder || parent == places { parent = fallbackParent }
            kept[id]!.parent = parent
        }
        // Two devices moving folders into each other makes a loop; break it.
        for id in Array(kept.keys) where !roots.contains(id) {
            var seen: Set<String> = [id]
            var parent = kept[id]!.parent
            while !roots.contains(parent), let next = kept[parent] {
                if !seen.insert(parent).inserted {
                    kept[id]!.parent = fallbackParent
                    break
                }
                parent = next.parent
            }
        }

        // Each folder's order: whichever side rearranged it, with the other side's additions
        // put in after the item they followed.
        var byParent: [String: [String]] = [:]
        for (id, node) in kept where !roots.contains(id) { byParent[node.parent, default: []].append(id) }
        for id in Array(kept.keys) where kept[id]!.kind == .folder {
            let lc = local[id]?.children, rc = remote[id]?.children, bc = base[id]?.children
            var order: [String]
            switch (lc, rc) {
            case let (lc?, rc?):
                if let bc, lc == bc { order = rc } else if let bc, rc == bc { order = lc } else { order = interleave(rc, lc) }
            case let (lc?, nil): order = lc
            case let (nil, rc?): order = rc
            case (nil, nil): order = []
            }
            let members = Set(byParent[id] ?? [])
            var seen = Set<String>()
            var children = order.filter { members.contains($0) && seen.insert($0).inserted }
            let rest = members.subtracting(seen).sorted { a, b in
                let ia = lc?.firstIndex(of: a) ?? rc?.firstIndex(of: a) ?? Int.max
                let ib = lc?.firstIndex(of: b) ?? rc?.firstIndex(of: b) ?? Int.max
                return ia == ib ? a < b : ia < ib
            }
            children += rest
            kept[id]!.children = children
        }
        for (id, node) in kept where node.kind != .folder { kept[id]!.children = [] }
        return kept
    }

    /// `primary`, with the items only `secondary` has placed after the one they follow there.
    static func interleave(_ primary: [String], _ secondary: [String]) -> [String] {
        var result = primary
        var present = Set(primary)
        for (index, id) in secondary.enumerated() where !present.contains(id) {
            let before = secondary[..<index].last { present.contains($0) }
            let at = before.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            result.insert(id, at: at)
            present.insert(id)
        }
        return result
    }

    // MARK: Tuff's bookmarks

    /// The names Tuff gives Firefox's other top-level folders, which sit at the end of its
    /// bookmarks bar (as an import from Firefox puts them).
    static let rootNames = ["menu": "Bookmarks Menu", "unfiled": "Other Bookmarks", "mobile": "Mobile Bookmarks"]

    /// Tuff's bookmarks as a tree. `ids` maps Tuff's bookmark IDs to GUIDs and gains one for
    /// each new bookmark. Items of kinds Tuff can't show are carried over from `base` into the
    /// folders they were in, so they don't look deleted.
    static func localTree(_ list: [Bookmark], base: SyncBookmarkTree, ids: inout [UUID: String]) -> SyncBookmarkTree {
        var tree = SyncBookmarkTree()
        var rootFolders: [String: Bookmark] = [:]
        for item in list where item.isFolder {
            if let guid = ids[item.id], rootNames[guid] != nil { rootFolders[guid] = item }
        }
        // Folders an import from Firefox made stand for its top-level folders, the first time.
        for (root, name) in rootNames where rootFolders[root] == nil {
            if let folder = list.first(where: { $0.isFolder && ids[$0.id] == nil && $0.title == name }) {
                ids[folder.id] = root
                rootFolders[root] = folder
            }
        }

        func add(_ item: Bookmark, parent: String) -> String {
            // A top-level folder's GUID on a folder moved into another one: it isn't that any more.
            var guid = ids[item.id] ?? SyncGUID.make()
            if roots.contains(guid) { guid = SyncGUID.make() }
            ids[item.id] = guid
            if item.isFolder {
                let children = item.children.map { add($0, parent: guid) }
                tree[guid] = SyncBookmarkNode(kind: .folder, title: item.title, parent: parent, children: children)
            } else {
                tree[guid] = SyncBookmarkNode(kind: .bookmark, title: item.title, url: item.url?.absoluteString, parent: parent)
            }
            return guid
        }

        let rootIDs = Set(rootFolders.values.map(\.id))
        let bar = list.filter { !rootIDs.contains($0.id) }.map { add($0, parent: "toolbar") }
        for root in roots {
            let children = root == "toolbar" ? bar : (rootFolders[root]?.children.map { add($0, parent: root) } ?? [])
            tree[root] = SyncBookmarkNode(kind: .folder, title: base[root]?.title ?? root, parent: places, children: children)
        }

        // Separators and the like, back where they were.
        for (folderID, folder) in base where folder.kind == .folder {
            guard tree[folderID]?.kind == .folder else { continue }
            for (index, child) in folder.children.enumerated() {
                guard let node = base[child], node.kind == .other, tree[child] == nil else { continue }
                var placed = node
                placed.parent = folderID
                tree[child] = placed
                let siblings = tree[folderID]!.children
                let before = folder.children[..<index].last { siblings.contains($0) }
                let at = before.flatMap { siblings.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
                tree[folderID]!.children.insert(child, at: at)
            }
        }
        return tree
    }

    /// The merged tree as Tuff's bookmarks bar: the toolbar's items, then a folder for each
    /// other top-level folder that has anything in it, where that folder was before.
    static func tuffList(_ tree: SyncBookmarkTree, previous: [Bookmark], ids: inout [UUID: String]) -> [Bookmark] {
        var uuids: [String: UUID] = [:]
        for (uuid, guid) in ids { uuids[guid] = uuid }
        var used: [UUID: String] = [:]

        func uuid(for guid: String) -> UUID {
            let id = uuids[guid] ?? UUID()
            used[id] = guid
            return id
        }
        func build(_ guid: String, depth: Int = 0) -> Bookmark? {
            guard let node = tree[guid], depth < 100 else { return nil }
            switch node.kind {
            case .bookmark:
                guard let url = node.url.flatMap(URL.init(string:)) else { return nil }
                return Bookmark(id: uuid(for: guid), title: node.title, url: url)
            case .folder:
                return Bookmark(id: uuid(for: guid), title: node.title, url: nil, children: node.children.compactMap { build($0, depth: depth + 1) })
            case .other:
                return nil
            }
        }

        var list = tree["toolbar"]?.children.compactMap { build($0) } ?? []
        var placed: [(index: Int, folder: Bookmark)] = []
        for root in roots where root != "toolbar" {
            let children = tree[root]?.children.compactMap { build($0) } ?? []
            guard !children.isEmpty else { continue }
            let id = uuid(for: root)
            let index = previous.firstIndex { $0.id == id } ?? Int.max
            let title = previous.first { $0.id == id }?.title ?? rootNames[root] ?? root
            placed.append((index, Bookmark(id: id, title: title, url: nil, children: children)))
        }
        for (index, folder) in placed.sorted(by: { $0.index < $1.index }) {
            list.insert(folder, at: min(index, list.count))
        }
        ids = used
        return list
    }
}
