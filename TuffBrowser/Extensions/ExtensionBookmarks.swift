import Foundation

/// `chrome.bookmarks` / Firefox `browser.bookmarks`, on Tuff's own bookmarks (`BookmarkStore`) of
/// the profile the main window shows. Tuff keeps one tree per profile whose top level is the
/// bookmarks bar, so extensions see Chrome's shape: a root ("0") holding the bar ("1"), which holds
/// everything else. Bookmark ids are Tuff's UUIDs.
///
/// Events come from comparing the tree before and after every change (`BookmarkStore.didChange`),
/// so changes made in Tuff, by sync or by another extension all reach listeners. Tuff keeps no
/// dates, so nodes have no `dateAdded`, and `getRecent` goes by position (newest are added last).
final class ExtensionBookmarks {
    static let shared = ExtensionBookmarks()

    static let rootID = "0"
    static let barID = "1"
    private static let events: Set<String> = [
        "bookmarks.onCreated", "bookmarks.onRemoved", "bookmarks.onChanged", "bookmarks.onMoved",
    ]

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private var store: BookmarkStore { .shared }
    /// The last tree seen of each profile, to work out what a change did.
    private var snapshots: [UUID: [Bookmark]]
    private var observer: NSObjectProtocol?

    private init() {
        snapshots = BookmarkStore.shared.lists
        observer = NotificationCenter.default.addObserver(forName: BookmarkStore.didChange, object: nil, queue: nil) { [weak self] _ in
            self?.storeChanged()
        }
    }

    private func profile() throws -> UUID {
        guard let id = BrowserState.shared.bookmarksProfileID else { throw Failure("Bookmarks aren’t available yet.") }
        return id
    }

    // MARK: Reading

    func get(_ ids: [String]) throws -> [[String: Any]] {
        let list = store.items(for: try profile())
        return try ids.map { id in
            if id == Self.rootID { return rootNode(list, deep: false) }
            if id == Self.barID { return barNode(list, deep: false) }
            guard let found = Self.locate(id, in: list) else { throw Failure("Can’t find bookmark for id.") }
            return node(found.bookmark, parent: found.parent, index: found.index, deep: false)
        }
    }

    func getChildren(_ id: String) throws -> [[String: Any]] {
        let list = store.items(for: try profile())
        if id == Self.rootID { return [barNode(list, deep: false)] }
        if id == Self.barID { return nodes(list, parent: Self.barID, deep: false) }
        guard let found = Self.locate(id, in: list) else { throw Failure("Can’t find parent bookmark for id.") }
        return nodes(found.bookmark.children, parent: id, deep: false)
    }

    func getTree() throws -> [[String: Any]] {
        [rootNode(store.items(for: try profile()), deep: true)]
    }

    func getSubTree(_ id: String) throws -> [[String: Any]] {
        let list = store.items(for: try profile())
        if id == Self.rootID { return [rootNode(list, deep: true)] }
        if id == Self.barID { return [barNode(list, deep: true)] }
        guard let found = Self.locate(id, in: list) else { throw Failure("Can’t find parent bookmark for id.") }
        return [node(found.bookmark, parent: found.parent, index: found.index, deep: true)]
    }

    func getRecent(_ count: Int) throws -> [[String: Any]] {
        guard count >= 1 else { throw Failure("numberOfItems cannot be less than 1.") }
        let tree = Self.flatten(store.items(for: try profile()))
        let pages = tree.order.reversed().compactMap { tree.entries[$0] }.filter { !$0.bookmark.isFolder }
        return pages.prefix(count).map { node($0.bookmark, parent: $0.parent, index: $0.index, deep: false) }
    }

    /// A string matches pages and folders with every word in their title or address; an object
    /// can also ask for an exact `url` and / or `title`.
    func search(_ query: Any?) throws -> [[String: Any]] {
        var words: [String] = [], url: String?, title: String?
        if let text = query as? String {
            words = text.lowercased().split(separator: " ").map(String.init)
        } else if let object = query as? [String: Any] {
            words = (object["query"] as? String)?.lowercased().split(separator: " ").map(String.init) ?? []
            url = object["url"] as? String
            title = object["title"] as? String
            if let url, URL(string: url)?.scheme == nil { throw Failure("Invalid URL.") }
        } else {
            throw Failure("A search query is required.")
        }
        let list = store.items(for: try profile())
        var results: [[String: Any]] = []
        func visit(_ items: [Bookmark], parent: String) {
            for (index, item) in items.enumerated() {
                let haystack = item.title.lowercased() + " " + (item.url?.absoluteString.lowercased() ?? "")
                let matches = words.allSatisfy(haystack.contains)
                    && (url == nil || item.url?.absoluteString == url)
                    && (title == nil || item.title == title)
                if matches, !(words.isEmpty && url == nil && title == nil) {
                    results.append(node(item, parent: parent, index: index, deep: false))
                }
                if item.isFolder { visit(item.children, parent: item.id.uuidString) }
            }
        }
        visit(list, parent: Self.barID)
        return results
    }

    // MARK: Changes

    func create(_ details: [String: Any]) throws -> [String: Any] {
        let profile = try profile()
        if (details["type"] as? String) == "separator" { throw Failure("Tuff’s bookmarks have no separators.") }
        let parent = try folder(details["parentId"] as? String ?? Self.barID, profile: profile)
        let index = details["index"] as? Int
        let title = details["title"] as? String ?? ""
        let created: Bookmark
        if let address = details["url"] as? String {
            guard let url = URL(string: address), url.scheme != nil else { throw Failure("Invalid URL.") }
            created = store.add(url: url, title: title, profile: profile, into: parent, at: index)
        } else {
            created = store.addFolder(named: title, profile: profile, into: parent, at: index)
        }
        return try located(created.id.uuidString, profile: profile)
    }

    func update(_ id: String, changes: [String: Any]) throws -> [String: Any] {
        let profile = try profile()
        guard let found = Self.locate(id, in: store.items(for: profile)) else { throw Failure("Can’t find bookmark for id.") }
        var url: URL?
        if let address = changes["url"] as? String {
            guard !found.bookmark.isFolder else { throw Failure("Can’t set URL of a bookmark folder.") }
            guard let parsed = URL(string: address), parsed.scheme != nil else { throw Failure("Invalid URL.") }
            url = parsed
        }
        store.update(found.bookmark.id, title: changes["title"] as? String ?? found.bookmark.title, url: url, profile: profile)
        return try located(id, profile: profile)
    }

    func move(_ id: String, destination: [String: Any]) throws -> [String: Any] {
        let profile = try profile()
        let list = store.items(for: profile)
        guard let found = Self.locate(id, in: list) else { throw Failure("Can’t find bookmark for id.") }
        let parentID = destination["parentId"] as? String ?? found.parent
        let parent = try folder(parentID, profile: profile)
        if let parent, parent == found.bookmark.id || Self.locate(parent.uuidString, in: found.bookmark.children) != nil {
            throw Failure("Can’t move a folder into itself or one of its folders.")
        }
        // Chrome counts the index with the bookmark still in place; Tuff with it taken out.
        var index = destination["index"] as? Int
        if let target = index, parentID == found.parent, target > found.index { index = target - 1 }
        store.move(found.bookmark.id, into: parent, at: index, profile: profile)
        return try located(id, profile: profile)
    }

    func remove(_ id: String, recursive: Bool) throws {
        let profile = try profile()
        if id == Self.rootID || id == Self.barID { throw Failure("Can’t modify the root bookmark folders.") }
        guard let found = Self.locate(id, in: store.items(for: profile)) else { throw Failure("Can’t find bookmark for id.") }
        if !recursive, !found.bookmark.children.isEmpty { throw Failure("Can’t remove non-empty folder (use recursive to force).") }
        store.remove(found.bookmark.id, profile: profile)
    }

    /// The folder `id` names: nil for the bar (Tuff's top level).
    private func folder(_ id: String, profile: UUID) throws -> UUID? {
        if id == Self.barID { return nil }
        if id == Self.rootID { throw Failure("Can’t modify the root bookmark folders.") }
        guard let found = Self.locate(id, in: store.items(for: profile)) else { throw Failure("Can’t find parent bookmark for id.") }
        guard found.bookmark.isFolder else { throw Failure("Parameter 'parentId' does not specify a folder.") }
        return found.bookmark.id
    }

    private func located(_ id: String, profile: UUID) throws -> [String: Any] {
        guard let found = Self.locate(id, in: store.items(for: profile)) else { throw Failure("Can’t find bookmark for id.") }
        return node(found.bookmark, parent: found.parent, index: found.index, deep: false)
    }

    // MARK: Nodes

    private func node(_ bookmark: Bookmark, parent: String, index: Int, deep: Bool) -> [String: Any] {
        var node: [String: Any] = [
            "id": bookmark.id.uuidString, "parentId": parent, "index": index, "title": bookmark.title,
            "type": bookmark.isFolder ? "folder" : "bookmark", "syncing": false,
        ]
        if let url = bookmark.url {
            node["url"] = url.absoluteString
        } else if deep {
            node["children"] = nodes(bookmark.children, parent: bookmark.id.uuidString, deep: true)
        }
        return node
    }

    private func nodes(_ list: [Bookmark], parent: String, deep: Bool) -> [[String: Any]] {
        list.enumerated().map { node($1, parent: parent, index: $0, deep: deep) }
    }

    private func barNode(_ list: [Bookmark], deep: Bool) -> [String: Any] {
        var node: [String: Any] = [
            "id": Self.barID, "parentId": Self.rootID, "index": 0, "title": "Bookmarks bar",
            "type": "folder", "folderType": "bookmarks-bar", "syncing": false,
        ]
        if deep { node["children"] = nodes(list, parent: Self.barID, deep: true) }
        return node
    }

    private func rootNode(_ list: [Bookmark], deep: Bool) -> [String: Any] {
        var node: [String: Any] = ["id": Self.rootID, "title": "", "type": "folder", "syncing": false]
        if deep { node["children"] = [barNode(list, deep: true)] }
        return node
    }

    private static func locate(_ id: String, in list: [Bookmark], parent: String = barID) -> (bookmark: Bookmark, parent: String, index: Int)? {
        for (index, item) in list.enumerated() {
            if item.id.uuidString == id { return (item, parent, index) }
            if item.isFolder, let found = locate(id, in: item.children, parent: item.id.uuidString) { return found }
        }
        return nil
    }

    // MARK: Events

    private struct Entry {
        let bookmark: Bookmark
        let parent: String
        let index: Int
    }

    /// Every bookmark by id, and the ids in tree order (folders before what they hold).
    private static func flatten(_ list: [Bookmark]) -> (entries: [String: Entry], order: [String]) {
        var entries: [String: Entry] = [:], order: [String] = []
        func visit(_ items: [Bookmark], parent: String) {
            for (index, item) in items.enumerated() {
                let id = item.id.uuidString
                entries[id] = Entry(bookmark: item, parent: parent, index: index)
                order.append(id)
                if item.isFolder { visit(item.children, parent: id) }
            }
        }
        visit(list, parent: barID)
        return (entries, order)
    }

    private func storeChanged() {
        let lists = store.lists
        defer { snapshots = lists }
        guard let profile = BrowserState.shared.bookmarksProfileID, ExtensionEventPush.shared.isListening(to: Self.events) else { return }
        let old = Self.flatten(snapshots[profile] ?? []), new = Self.flatten(lists[profile] ?? [])
        let push = ExtensionEventPush.shared

        // Removed: only the outermost of what went (a folder's contents go with it).
        for id in old.order where new.entries[id] == nil {
            guard let entry = old.entries[id], entry.parent == Self.barID || new.entries[entry.parent] != nil else { continue }
            push.emit("bookmarks.onRemoved", args: [id, [
                "parentId": entry.parent, "index": entry.index,
                "node": node(entry.bookmark, parent: entry.parent, index: entry.index, deep: true),
            ]])
        }
        for id in new.order where old.entries[id] == nil {
            guard let entry = new.entries[id] else { continue }
            push.emit("bookmarks.onCreated", args: [id, node(entry.bookmark, parent: entry.parent, index: entry.index, deep: false)])
        }
        for id in new.order {
            guard let before = old.entries[id]?.bookmark, let after = new.entries[id]?.bookmark,
                  before.title != after.title || before.url != after.url else { continue }
            var info: [String: Any] = ["title": after.title]
            if let url = after.url { info["url"] = url.absoluteString }
            push.emit("bookmarks.onChanged", args: [id, info])
        }
        for id in movedIDs(old: old, new: new) {
            guard let before = old.entries[id], let after = new.entries[id] else { continue }
            push.emit("bookmarks.onMoved", args: [id, [
                "parentId": after.parent, "index": after.index, "oldParentId": before.parent, "oldIndex": before.index,
            ]])
        }
    }

    /// Bookmarks that changed folder, or were reordered within one. Within a folder, the ones
    /// that kept their order relative to each other (the longest such run) stayed put; the rest
    /// moved. That way one bookmark dragged along isn't reported with everything it passed.
    private func movedIDs(old: (entries: [String: Entry], order: [String]), new: (entries: [String: Entry], order: [String])) -> [String] {
        var moved = Set<String>()
        var stayed: [String: [String]] = [:]  // parent -> kept ids, in the new order
        for id in new.order {
            guard let before = old.entries[id], let after = new.entries[id] else { continue }
            if before.parent != after.parent { moved.insert(id) } else { stayed[after.parent, default: []].append(id) }
        }
        for ids in stayed.values {
            let oldIndexes = ids.map { old.entries[$0]!.index }
            let kept = Self.longestIncreasingRun(oldIndexes)
            for (position, id) in ids.enumerated() where !kept.contains(position) { moved.insert(id) }
        }
        return new.order.filter(moved.contains)
    }

    /// Positions of one longest strictly increasing subsequence of `values`.
    private static func longestIncreasingRun(_ values: [Int]) -> Set<Int> {
        var tails: [Int] = []          // position of the smallest tail of each run length
        var previous = [Int](repeating: -1, count: values.count)
        for (position, value) in values.enumerated() {
            var low = 0, high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if values[tails[mid]] < value { low = mid + 1 } else { high = mid }
            }
            if low > 0 { previous[position] = tails[low - 1] }
            if low == tails.count { tails.append(position) } else { tails[low] = position }
        }
        var run = Set<Int>()
        var position = tails.last ?? -1
        while position >= 0 {
            run.insert(position)
            position = previous[position]
        }
        return run
    }
}
