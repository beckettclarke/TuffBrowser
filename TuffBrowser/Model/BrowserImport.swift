import AppKit
import Compression
import SQLite3
import SwiftUI

// Brings history, bookmarks and spaces over from other browsers on this Mac.
//
// Everything is read from copies: a running browser holds its databases locked, and Tuff never
// writes to another browser's files. Reading happens off the main thread (`BrowserImporter.read`);
// what was read is then added to Tuff on the main thread (`BrowserImporter.apply`).

// MARK: - Sources

enum ImportKind: String, CaseIterable, Identifiable {
    case history, bookmarks, spaces
    var id: String { rawValue }
}

/// A browser Tuff knows how to read.
struct BrowserSource: Identifiable, Hashable {
    enum Engine { case chromium, firefox, safari }

    let id: String
    let name: String
    let engine: Engine
    /// Chromium's "User Data" folder, the folder holding Firefox's profiles.ini, or ~/Library/Safari.
    let root: URL
    let bundleIDs: [String]
    let kinds: [ImportKind]
    /// Opera keeps its one profile in `root` itself.
    var singleProfile = false

    var appURL: URL? {
        bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    var icon: NSImage {
        if let appURL { return NSWorkspace.shared.icon(forFile: appURL.path) }
        return NSImage(systemSymbolName: "globe", accessibilityDescription: name) ?? NSImage()
    }

    /// The name used for things made from the import ("Chrome Bookmarks").
    var shortName: String {
        switch id {
        case "chrome", "chrome-beta", "chrome-canary": "Chrome"
        case "edge": "Edge"
        default: name
        }
    }

    static func == (a: BrowserSource, b: BrowserSource) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// One of a browser's profiles (Chrome's "Default" / "Profile 1", a Firefox profile folder).
struct BrowserProfile: Identifiable, Hashable {
    var id: String { dir.path }
    let name: String
    let dir: URL
}

enum ImportProblem: Error {
    /// macOS kept Tuff out (Safari always needs Full Disk Access; other browsers' folders can
    /// need "access data from other apps").
    case noAccess
    case missing
    case unreadable(String)

    init(_ error: Error) {
        let ns = error as NSError
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        let posix = ns.domain == NSPOSIXErrorDomain ? ns.code : (underlying?.domain == NSPOSIXErrorDomain ? underlying!.code : 0)
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError || ns.code == NSFileWriteNoPermissionError {
            self = .noAccess
        } else if posix == Int(EPERM) || posix == Int(EACCES) {
            self = .noAccess
        } else if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError {
            self = .missing
        } else if posix == Int(ENOENT) {
            self = .missing
        } else if let problem = error as? ImportProblem {
            self = problem
        } else {
            self = .unreadable(error.localizedDescription)
        }
    }
}

// MARK: - What was read

struct ImportedTab {
    var title: String
    var url: URL
}

struct ImportedFolder {
    var name: String
    var tabs: [ImportedTab]
}

enum ImportedPinned {
    case tab(ImportedTab)
    case folder(ImportedFolder)
}

struct ImportedSpace {
    var name: String
    var colorHex: String?
    var pinned: [ImportedPinned]
}

/// A bookmark or a folder of them (`url == nil`).
struct ImportedBookmark {
    var title: String
    var url: URL?
    var children: [ImportedBookmark] = []

    var count: Int { url != nil ? 1 : children.reduce(0) { $0 + $1.count } }
}

struct ImportedBookmarks {
    /// The bookmarks bar / toolbar / Favourites bar.
    var bar: [ImportedBookmark] = []
    /// The other top-level collections ("Other Bookmarks", "Bookmarks Menu", "Reading List"…).
    var roots: [ImportedBookmark] = []

    var count: Int { bar.reduce(0) { $0 + $1.count } + roots.reduce(0) { $0 + $1.count } }
}

struct ImportedLayout {
    var spaces: [ImportedSpace] = []
    var favorites: [ImportedTab] = []
}

/// Everything read from one browser profile. A kind that couldn't be read is nil and has its
/// reason in `problems`.
struct ImportBundle {
    var history: [HistoryEntry]?
    var bookmarks: ImportedBookmarks?
    var layout: ImportedLayout?
    var problems: [ImportKind: ImportProblem] = [:]

    var needsAccess: Bool { problems.values.contains { if case .noAccess = $0 { true } else { false } } }
}

/// What an import added, for the summary in Settings.
struct ImportSummary {
    var pages = 0
    var bookmarks = 0
    var bookmarkSpace: String?
    var spaces = 0
    var pinnedTabs = 0
    var favorites = 0

    var isEmpty: Bool { pages == 0 && bookmarks == 0 && spaces == 0 && favorites == 0 }

    var text: String {
        func n(_ count: Int, _ one: String, _ many: String) -> String {
            "\(count.formatted()) \(count == 1 ? one : many)"
        }
        var parts: [String] = []
        if pages > 0 { parts.append(n(pages, "page of history", "pages of history")) }
        if bookmarks > 0 {
            var part = n(bookmarks, "bookmark", "bookmarks")
            if let bookmarkSpace { part += " (in the “\(bookmarkSpace)” space)" }
            parts.append(part)
        }
        if spaces > 0 { parts.append(n(spaces, "space", "spaces") + " with " + n(pinnedTabs, "pinned tab", "pinned tabs")) }
        if favorites > 0 { parts.append(n(favorites, "favorite", "favorites")) }
        guard !parts.isEmpty else { return "Nothing new to import." }
        if parts.count == 1 { return "Imported " + parts[0] + "." }
        return "Imported " + parts.dropLast().joined(separator: ", ") + " and " + parts.last! + "."
    }
}

// MARK: - Importer

enum BrowserImporter {
    /// How much history to bring over: the most recent pages, up to what `HistoryStore` keeps.
    static let historyLimit = 20000

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let support = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)

    static let known: [BrowserSource] = {
        func at(_ path: String) -> URL { support.appending(path: path, directoryHint: .isDirectory) }
        let both: [ImportKind] = [.history, .bookmarks]
        return [
            BrowserSource(id: "safari", name: "Safari", engine: .safari, root: home.appending(path: "Library/Safari", directoryHint: .isDirectory),
                          bundleIDs: ["com.apple.Safari"], kinds: both),
            BrowserSource(id: "chrome", name: "Google Chrome", engine: .chromium, root: at("Google/Chrome"), bundleIDs: ["com.google.Chrome"], kinds: both),
            BrowserSource(id: "arc", name: "Arc", engine: .chromium, root: at("Arc/User Data"),
                          bundleIDs: ["company.thebrowser.Browser"], kinds: [.history, .spaces]),
            BrowserSource(id: "zen", name: "Zen", engine: .firefox, root: at("zen"), bundleIDs: ["app.zen-browser.zen"], kinds: [.history, .bookmarks, .spaces]),
            BrowserSource(id: "firefox", name: "Firefox", engine: .firefox, root: at("Firefox"), bundleIDs: ["org.mozilla.firefox"], kinds: both),
            BrowserSource(id: "edge", name: "Microsoft Edge", engine: .chromium, root: at("Microsoft Edge"), bundleIDs: ["com.microsoft.edgemac"], kinds: both),
            BrowserSource(id: "brave", name: "Brave", engine: .chromium, root: at("BraveSoftware/Brave-Browser"), bundleIDs: ["com.brave.Browser"], kinds: both),
            BrowserSource(id: "dia", name: "Dia", engine: .chromium, root: at("Dia/User Data"), bundleIDs: ["company.thebrowser.dia"], kinds: both),
            BrowserSource(id: "vivaldi", name: "Vivaldi", engine: .chromium, root: at("Vivaldi"), bundleIDs: ["com.vivaldi.Vivaldi"], kinds: both),
            BrowserSource(id: "opera", name: "Opera", engine: .chromium, root: at("com.operasoftware.Opera"),
                          bundleIDs: ["com.operasoftware.Opera"], kinds: both, singleProfile: true),
            BrowserSource(id: "chromium", name: "Chromium", engine: .chromium, root: at("Chromium"), bundleIDs: ["org.chromium.Chromium"], kinds: both),
            BrowserSource(id: "chrome-beta", name: "Chrome Beta", engine: .chromium, root: at("Google/Chrome Beta"),
                          bundleIDs: ["com.google.Chrome.beta"], kinds: both),
            BrowserSource(id: "chrome-canary", name: "Chrome Canary", engine: .chromium, root: at("Google/Chrome Canary"),
                          bundleIDs: ["com.google.Chrome.canary"], kinds: both),
        ]
    }()

    /// Browsers that are installed or have left a profile on this Mac. (A folder alone isn't
    /// enough: password managers drop native-messaging files into browsers that aren't there.)
    static func detect() -> [BrowserSource] {
        let fm = FileManager.default
        return known.filter { source in
            if source.appURL != nil { return true }
            switch source.engine {
            case .safari: return false
            case .firefox: return fm.fileExists(atPath: source.root.appending(path: "profiles.ini").path)
            case .chromium:
                let marker = source.singleProfile ? "History" : "Local State"
                return fm.fileExists(atPath: source.root.appending(path: marker).path)
            }
        }
    }

    // MARK: Profiles

    static func profiles(for source: BrowserSource) -> [BrowserProfile] {
        switch source.engine {
        case .safari:
            return [BrowserProfile(name: "Safari", dir: source.root)]
        case .chromium:
            return chromiumProfiles(source)
        case .firefox:
            return firefoxProfiles(source)
        }
    }

    private static func chromiumProfiles(_ source: BrowserSource) -> [BrowserProfile] {
        if source.singleProfile { return [BrowserProfile(name: "Default", dir: source.root)] }
        let fm = FileManager.default
        var found: [BrowserProfile] = []
        // "Local State" names each profile folder.
        if let data = try? Data(contentsOf: source.root.appending(path: "Local State")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            for (folder, info) in cache {
                let dir = source.root.appending(path: folder, directoryHint: .isDirectory)
                guard fm.fileExists(atPath: dir.path) else { continue }
                let name = (info as? [String: Any])?["name"] as? String
                found.append(BrowserProfile(name: name?.isEmpty == false ? name! : folder, dir: dir))
            }
        }
        if found.isEmpty, let folders = try? fm.contentsOfDirectory(atPath: source.root.path) {
            for folder in folders where folder == "Default" || folder.hasPrefix("Profile ") {
                let dir = source.root.appending(path: folder, directoryHint: .isDirectory)
                if fm.fileExists(atPath: dir.appending(path: "History").path) || fm.fileExists(atPath: dir.appending(path: "Bookmarks").path) {
                    found.append(BrowserProfile(name: folder, dir: dir))
                }
            }
        }
        // Couldn't look inside (no access yet): offer the usual one, so trying it can ask.
        if found.isEmpty { found = [BrowserProfile(name: "Default", dir: source.root.appending(path: "Default", directoryHint: .isDirectory))] }
        return found.sorted { a, b in
            let aDefault = a.dir.lastPathComponent == "Default", bDefault = b.dir.lastPathComponent == "Default"
            if aDefault != bDefault { return aDefault }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private static func firefoxProfiles(_ source: BrowserSource) -> [BrowserProfile] {
        let fm = FileManager.default
        guard let text = try? String(contentsOf: source.root.appending(path: "profiles.ini"), encoding: .utf8) else { return [] }
        var sections: [[String: String]] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmed
            if line.hasPrefix("[") {
                sections.append(["#": line])
            } else if let eq = line.firstIndex(of: "="), !sections.isEmpty {
                sections[sections.count - 1][String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
        }
        func dir(_ path: String, relative: Bool) -> URL {
            relative ? source.root.appending(path: path, directoryHint: .isDirectory) : URL(fileURLWithPath: path, isDirectory: true)
        }
        // The profile the browser actually opens is named in its [Install…] section.
        let installed = sections.first { $0["#"]?.hasPrefix("[Install") == true }?["Default"]
        var profiles: [(BrowserProfile, isDefault: Bool)] = []
        for section in sections where section["#"]?.hasPrefix("[Profile") == true {
            guard let path = section["Path"] else { continue }
            let folder = dir(path, relative: section["IsRelative"] != "0")
            let name = section["Name"] ?? folder.lastPathComponent
            let isDefault = installed.map { $0 == path } ?? (section["Default"] == "1")
            profiles.append((BrowserProfile(name: name, dir: folder), isDefault))
        }
        let used = profiles.filter { fm.fileExists(atPath: $0.0.dir.appending(path: "places.sqlite").path) }
        return (used.isEmpty ? profiles : used).sorted { $0.isDefault && !$1.isDefault }.map(\.0)
    }

    // MARK: Reading

    /// Reads the chosen kinds from a profile. Slow (copies databases); call off the main thread.
    static func read(_ source: BrowserSource, profile: BrowserProfile, kinds: Set<ImportKind>) -> ImportBundle {
        var bundle = ImportBundle()
        func attempt<T>(_ kind: ImportKind, _ body: () throws -> T) -> T? {
            do { return try body() } catch {
                bundle.problems[kind] = ImportProblem(error)
                return nil
            }
        }
        if kinds.contains(.history) {
            bundle.history = attempt(.history) {
                switch source.engine {
                case .chromium: try chromiumHistory(profile.dir)
                case .firefox: try firefoxHistory(profile.dir)
                case .safari: try safariHistory(profile.dir)
                }
            }
        }
        if kinds.contains(.bookmarks), source.kinds.contains(.bookmarks) {
            bundle.bookmarks = attempt(.bookmarks) {
                switch source.engine {
                case .chromium: try chromiumBookmarks(profile.dir)
                case .firefox: try firefoxBookmarks(profile.dir)
                case .safari: try safariBookmarks(profile.dir)
                }
            }
        }
        if kinds.contains(.spaces), source.kinds.contains(.spaces) {
            bundle.layout = attempt(.spaces) {
                switch source.id {
                case "arc": try arcLayout(source, profile: profile)
                case "zen": try zenLayout(profile.dir)
                default: ImportedLayout()
                }
            }
        }
        return bundle
    }

    private static func isWeb(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func webURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), isWeb(url) else { return nil }
        return url
    }

    // MARK: History

    private static func chromiumHistory(_ profile: URL) throws -> [HistoryEntry] {
        let db = try SQLiteCopy(profile.appending(path: "History"))
        var list: [HistoryEntry] = []
        // Chromium counts microseconds from 1601.
        try db.query("""
            SELECT url, title, visit_count, last_visit_time FROM urls
            WHERE hidden = 0 AND last_visit_time > 0 ORDER BY last_visit_time DESC LIMIT \(historyLimit)
            """) { row in
            guard let url = webURL(row.text(0)) else { return }
            let date = Date(timeIntervalSince1970: Double(row.int(3)) / 1_000_000 - 11_644_473_600)
            list.append(HistoryEntry(url: url, title: row.text(1), lastVisit: date, visits: max(1, row.int(2))))
        }
        return list
    }

    private static func firefoxHistory(_ profile: URL) throws -> [HistoryEntry] {
        let db = try SQLiteCopy(profile.appending(path: "places.sqlite"))
        var list: [HistoryEntry] = []
        try db.query("""
            SELECT url, IFNULL(title, ''), visit_count, last_visit_date FROM moz_places
            WHERE hidden = 0 AND visit_count > 0 AND last_visit_date IS NOT NULL
            ORDER BY last_visit_date DESC LIMIT \(historyLimit)
            """) { row in
            guard let url = webURL(row.text(0)) else { return }
            let date = Date(timeIntervalSince1970: Double(row.int(3)) / 1_000_000)
            list.append(HistoryEntry(url: url, title: row.text(1), lastVisit: date, visits: max(1, row.int(2))))
        }
        return list
    }

    private static func safariHistory(_ root: URL) throws -> [HistoryEntry] {
        let db = try SQLiteCopy(root.appending(path: "History.db"))
        var list: [HistoryEntry] = []
        // The title is the one from the latest visit (SQLite takes the other columns from the
        // row MAX() picked). Visit times count seconds from 2001.
        try db.query("""
            SELECT i.url, IFNULL(v.title, ''), i.visit_count, MAX(v.visit_time) FROM history_items i
            JOIN history_visits v ON v.history_item = i.id GROUP BY i.id ORDER BY 4 DESC LIMIT \(historyLimit)
            """) { row in
            guard let url = webURL(row.text(0)) else { return }
            let date = Date(timeIntervalSinceReferenceDate: row.double(3))
            list.append(HistoryEntry(url: url, title: row.text(1), lastVisit: date, visits: max(1, row.int(2))))
        }
        return list
    }

    // MARK: Bookmarks

    private static func chromiumBookmarks(_ profile: URL) throws -> ImportedBookmarks {
        let data: Data
        do { data = try Data(contentsOf: profile.appending(path: "Bookmarks")) } catch {
            // A profile that never saved a bookmark has no file.
            if case .missing = ImportProblem(error) { return ImportedBookmarks() }
            throw error
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { throw ImportProblem.unreadable("Bookmarks isn’t in a format Tuff knows.") }
        func node(_ dict: [String: Any]) -> ImportedBookmark? {
            let name = dict["name"] as? String ?? ""
            if dict["type"] as? String == "url" {
                guard let url = webURL(dict["url"] as? String) else { return nil }
                return ImportedBookmark(title: name, url: url)
            }
            let children = (dict["children"] as? [[String: Any]] ?? []).compactMap(node)
            return ImportedBookmark(title: name, url: nil, children: children)
        }
        var result = ImportedBookmarks()
        if let bar = roots["bookmark_bar"] as? [String: Any] { result.bar = node(bar)?.children ?? [] }
        for (key, fallback) in [("other", "Other Bookmarks"), ("synced", "Mobile Bookmarks")] {
            guard let dict = roots[key] as? [String: Any], var root = node(dict), root.count > 0 else { continue }
            if root.title.isEmpty { root.title = fallback }
            result.roots.append(root)
        }
        return result
    }

    private static func firefoxBookmarks(_ profile: URL) throws -> ImportedBookmarks {
        let db = try SQLiteCopy(profile.appending(path: "places.sqlite"))
        struct Row { var id: Int; var parent: Int; var type: Int; var title: String; var url: String; var guid: String }
        var rows: [Row] = []
        try db.query("""
            SELECT b.id, b.parent, b.type, IFNULL(b.title, ''), IFNULL(p.url, ''), IFNULL(b.guid, '')
            FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk ORDER BY b.parent, b.position
            """) { row in
            rows.append(Row(id: row.int(0), parent: row.int(1), type: row.int(2), title: row.text(3), url: row.text(4), guid: row.text(5)))
        }
        let children = Dictionary(grouping: rows, by: \.parent)
        func node(_ row: Row) -> ImportedBookmark? {
            switch row.type {
            case 1:
                guard let url = webURL(row.url) else { return nil }
                return ImportedBookmark(title: row.title, url: url)
            case 2:
                return ImportedBookmark(title: row.title, url: nil, children: (children[row.id] ?? []).compactMap(node))
            default:
                return nil
            }
        }
        var result = ImportedBookmarks()
        for (guid, name) in [("menu________", "Bookmarks Menu"), ("unfiled_____", "Other Bookmarks"), ("mobile______", "Mobile Bookmarks")] {
            guard let row = rows.first(where: { $0.guid == guid }), var root = node(row), root.count > 0 else { continue }
            root.title = name
            result.roots.append(root)
        }
        if let toolbar = rows.first(where: { $0.guid == "toolbar_____" }) { result.bar = node(toolbar)?.children ?? [] }
        return result
    }

    private static func safariBookmarks(_ root: URL) throws -> ImportedBookmarks {
        let data = try Data(contentsOf: root.appending(path: "Bookmarks.plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ImportProblem.unreadable("Bookmarks.plist isn’t in a format Tuff knows.")
        }
        func node(_ dict: [String: Any]) -> ImportedBookmark? {
            switch dict["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                guard let url = webURL(dict["URLString"] as? String) else { return nil }
                let title = (dict["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
                return ImportedBookmark(title: title, url: url)
            case "WebBookmarkTypeList":
                let children = (dict["Children"] as? [[String: Any]] ?? []).compactMap(node)
                return ImportedBookmark(title: dict["Title"] as? String ?? "", url: nil, children: children)
            default:
                return nil
            }
        }
        var result = ImportedBookmarks()
        for child in plist["Children"] as? [[String: Any]] ?? [] {
            guard var list = node(child), list.url == nil else { continue }
            switch list.title {
            case "BookmarksBar": result.bar = list.children
            case "BookmarksMenu": list.title = "Bookmarks Menu"; if list.count > 0 { result.roots.append(list) }
            case "com.apple.ReadingList": list.title = "Reading List"; if list.count > 0 { result.roots.append(list) }
            default: if list.count > 0 { result.roots.append(list) }
            }
        }
        return result
    }

    // MARK: Arc

    /// Arc keeps its spaces, pinned tabs and favourites in StorableSidebar.json, beside "User Data".
    /// Ordered collections there are flat arrays that alternate keys and values, so lookups go by
    /// each object's own `id`.
    private static func arcLayout(_ source: BrowserSource, profile: BrowserProfile) throws -> ImportedLayout {
        let file = source.root.deletingLastPathComponent().appending(path: "StorableSidebar.json")
        let data = try Data(contentsOf: file)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let containers = (json["sidebar"] as? [String: Any])?["containers"] as? [Any],
              let main = dicts(containers).first(where: { $0["spaces"] != nil }) else {
            throw ImportProblem.unreadable("Arc’s sidebar file isn’t in a format Tuff knows.")
        }
        var items: [String: [String: Any]] = [:]
        for item in dicts(main["items"]) { if let id = item["id"] as? String { items[id] = item } }

        func children(_ item: [String: Any]) -> [[String: Any]] {
            strings(item["childrenIds"]).compactMap { items[$0] }
        }
        func tab(_ item: [String: Any]) -> ImportedTab? {
            guard let tab = (item["data"] as? [String: Any])?["tab"] as? [String: Any],
                  let url = webURL(tab["savedURL"] as? String) else { return nil }
            let custom = (item["title"] as? String)?.trimmed ?? ""
            return ImportedTab(title: custom.isEmpty ? (tab["savedTitle"] as? String ?? "") : custom, url: url)
        }
        func isFolder(_ item: [String: Any]) -> Bool { (item["data"] as? [String: Any])?["list"] != nil }
        func tabs(in item: [String: Any]) -> [ImportedTab] {
            if let t = tab(item) { return [t] }
            return children(item).flatMap(tabs(in:))
        }
        // Tuff folders are one level deep: a folder in a folder becomes "Outer › Inner".
        func folders(_ item: [String: Any], prefix: String?) -> [ImportedFolder] {
            let title = (item["title"] as? String)?.trimmed ?? ""
            let name = [prefix, title.isEmpty ? "Folder" : title].compactMap { $0 }.joined(separator: " › ")
            var own: [ImportedTab] = []
            var nested: [ImportedFolder] = []
            for child in children(item) {
                if isFolder(child) { nested += folders(child, prefix: name) } else { own += tabs(in: child) }
            }
            return (own.isEmpty ? [] : [ImportedFolder(name: name, tabs: own)]) + nested
        }

        // Spaces belong to Arc profiles; take the chosen profile's, or every space if none match.
        let chosen = profile.dir.lastPathComponent
        func profileFolder(_ value: Any?) -> String {
            if let dict = value as? [String: Any], dict["default"] != nil { return "Default" }
            return firstString(forKey: "directoryBasename", in: value) ?? "Default"
        }
        let allSpaces = dicts(main["spaces"])
        let mine = allSpaces.filter { profileFolder($0["profile"]) == chosen }
        var layout = ImportedLayout()
        for space in mine.isEmpty ? allSpaces : mine {
            let ids = strings(space["containerIDs"])
            var pinned: [ImportedPinned] = []
            if let i = ids.firstIndex(of: "pinned"), i + 1 < ids.count, let container = items[ids[i + 1]] {
                for child in children(container) {
                    if isFolder(child) {
                        pinned += folders(child, prefix: nil).map { .folder($0) }
                    } else {
                        pinned += tabs(in: child).map { .tab($0) }
                    }
                }
            }
            let name = (space["title"] as? String)?.trimmed ?? ""
            layout.spaces.append(ImportedSpace(name: name.isEmpty ? "Arc Space" : name, colorHex: rgbHex(in: space["customInfo"]), pinned: pinned))
        }

        // Favourites: the top-apps container of each profile, listed as [profile, id, …].
        let topApps = (main["topAppsContainerIDs"] as? [Any]) ?? []
        var favoriteContainers: [(profile: String, id: String)] = []
        var lastProfile = "Default"
        for value in topApps {
            if let id = value as? String { favoriteContainers.append((lastProfile, id)) } else { lastProfile = profileFolder(value) }
        }
        let ownFavorites = favoriteContainers.filter { $0.profile == chosen }
        for container in (ownFavorites.isEmpty ? favoriteContainers : ownFavorites) {
            if let item = items[container.id] { layout.favorites += children(item).flatMap(tabs(in:)) }
        }
        return layout
    }

    // MARK: Zen

    /// Zen keeps workspaces, pinned tabs, folders and Essentials in zen-sessions.jsonlz4 (older
    /// versions: in the session file, with workspaces in places.sqlite).
    private static func zenLayout(_ profile: URL) throws -> ImportedLayout {
        let fm = FileManager.default
        let sessions = profile.appending(path: "zen-sessions.jsonlz4")
        var tabs: [[String: Any]] = []
        var spaces: [[String: Any]] = []
        var folders: [[String: Any]] = []
        if fm.fileExists(atPath: sessions.path) {
            let json = try JSONSerialization.jsonObject(with: try mozLZ4(Data(contentsOf: sessions))) as? [String: Any] ?? [:]
            tabs = dicts(json["tabs"])
            spaces = dicts(json["spaces"])
            folders = dicts(json["folders"])
        } else {
            let file = profile.appending(path: "sessionstore.jsonlz4")
            let json = try JSONSerialization.jsonObject(with: try mozLZ4(Data(contentsOf: file))) as? [String: Any] ?? [:]
            for window in dicts(json["windows"]) {
                tabs += dicts(window["tabs"])
                if spaces.isEmpty { spaces = dicts(window["spaces"]) }
                folders += dicts(window["folders"])
            }
            if spaces.isEmpty, let db = try? SQLiteCopy(profile.appending(path: "places.sqlite")), db.hasTable("zen_workspaces") {
                try? db.query("SELECT uuid, name FROM zen_workspaces ORDER BY position") { row in
                    spaces.append(["uuid": row.text(0), "name": row.text(1)])
                }
            }
        }

        var folderNames: [String: String] = [:]
        var folderParents: [String: String] = [:]
        for folder in folders {
            guard let id = folder["id"] as? String else { continue }
            folderNames[id] = (folder["name"] as? String)?.trimmed
            if let parent = folder["parentId"] as? String { folderParents[id] = parent }
        }
        func folderName(_ id: String) -> String {
            var parts: [String] = []
            var current: String? = id
            while let c = current, parts.count < 6 {
                let name = folderNames[c] ?? ""
                parts.insert(name.isEmpty ? "Folder" : name, at: 0)
                current = folderParents[c]
            }
            return parts.joined(separator: " › ")
        }

        func pinnedTab(_ tab: [String: Any]) -> ImportedTab? {
            let entries = dicts(tab["entries"])
            let index = (tab["index"] as? NSNumber)?.intValue ?? entries.count
            let current = entries.indices.contains(index - 1) ? entries[index - 1] : entries.last
            // A pinned tab's home is the page it was pinned on.
            let initial = (tab["_zenPinnedInitialState"] as? [String: Any])?["entry"] as? [String: Any]
            guard let url = webURL(initial?["url"] as? String) ?? webURL(current?["url"] as? String) else { return nil }
            let label = (tab["zenStaticLabel"] as? String)?.trimmed ?? ""
            let title = label.isEmpty ? (initial?["title"] as? String ?? current?["title"] as? String ?? "") : label
            return ImportedTab(title: title, url: url)
        }

        var layout = ImportedLayout()
        var bySpace: [String: [ImportedPinned]] = [:]
        var folderSlots: [String: (space: String, index: Int)] = [:]
        for tab in tabs where (tab["pinned"] as? Bool) == true || (tab["zenEssential"] as? Bool) == true {
            guard let imported = pinnedTab(tab) else { continue }
            if (tab["zenEssential"] as? Bool) == true {
                layout.favorites.append(imported)
                continue
            }
            let space = tab["zenWorkspace"] as? String ?? ""
            if let group = tab["groupId"] as? String, folderNames[group] != nil {
                if let slot = folderSlots[group], case .folder(var folder) = bySpace[slot.space]![slot.index] {
                    folder.tabs.append(imported)
                    bySpace[slot.space]![slot.index] = .folder(folder)
                } else {
                    bySpace[space, default: []].append(.folder(ImportedFolder(name: folderName(group), tabs: [imported])))
                    folderSlots[group] = (space, bySpace[space]!.count - 1)
                }
            } else {
                bySpace[space, default: []].append(.tab(imported))
            }
        }

        var seen = Set<String>()
        for (n, space) in spaces.enumerated() {
            let id = space["uuid"] as? String ?? ""
            seen.insert(id)
            let name = (space["name"] as? String)?.trimmed ?? ""
            let color = ((space["theme"] as? [String: Any]).flatMap { dicts($0["gradientColors"]).first?["c"] as? [Any] })
                .flatMap { values -> String? in
                    let rgb = values.compactMap { ($0 as? NSNumber)?.doubleValue }
                    return rgb.count >= 3 ? hex(rgb[0] / 255, rgb[1] / 255, rgb[2] / 255) : nil
                }
            layout.spaces.append(ImportedSpace(name: name.isEmpty ? "Zen Space \(n + 1)" : name, colorHex: color, pinned: bySpace[id] ?? []))
        }
        // Pinned tabs whose workspace wasn't listed still come along.
        let orphans = bySpace.filter { !seen.contains($0.key) }.flatMap(\.value)
        if !orphans.isEmpty { layout.spaces.append(ImportedSpace(name: "Zen", colorHex: nil, pinned: orphans)) }
        return layout
    }

    /// Firefox's compressed JSON: "mozLz40\0", the decompressed size (little-endian UInt32), then
    /// one raw LZ4 block.
    static func mozLZ4(_ data: Data) throws -> Data {
        let magic = Data("mozLz40\0".utf8)
        guard data.count > 12, data.prefix(8) == magic else { throw ImportProblem.unreadable("Not a mozLz4 file.") }
        let bytes = [UInt8](data)
        let size = Int(bytes[8]) | Int(bytes[9]) << 8 | Int(bytes[10]) << 16 | Int(bytes[11]) << 24
        guard size > 0, size < 512 << 20 else { throw ImportProblem.unreadable("Unexpected mozLz4 size.") }
        var output = [UInt8](repeating: 0, count: size)
        let written = bytes.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, size, src.baseAddress! + 12, bytes.count - 12, nil, COMPRESSION_LZ4_RAW)
            }
        }
        guard written == size else { throw ImportProblem.unreadable("Couldn’t decompress a mozLz4 file.") }
        return Data(output)
    }

    // MARK: JSON helpers

    private static func dicts(_ value: Any?) -> [[String: Any]] {
        (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    private static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private static func firstString(forKey key: String, in value: Any?) -> String? {
        if let dict = value as? [String: Any] {
            if let s = dict[key] as? String { return s }
            for v in dict.values { if let s = firstString(forKey: key, in: v) { return s } }
        } else if let list = value as? [Any] {
            for v in list { if let s = firstString(forKey: key, in: v) { return s } }
        }
        return nil
    }

    /// The first colour (an object with red / green / blue) anywhere in `value`.
    private static func rgbHex(in value: Any?) -> String? {
        if let dict = value as? [String: Any] {
            if let r = (dict["red"] as? NSNumber)?.doubleValue, let g = (dict["green"] as? NSNumber)?.doubleValue,
               let b = (dict["blue"] as? NSNumber)?.doubleValue {
                let scale = max(r, g, b) > 1 ? 255.0 : 1.0
                return hex(r / scale, g / scale, b / scale)
            }
            for key in dict.keys.sorted() { if let found = rgbHex(in: dict[key]) { return found } }
        } else if let list = value as? [Any] {
            for v in list { if let found = rgbHex(in: v) { return found } }
        }
        return nil
    }

    private static func hex(_ r: Double, _ g: Double, _ b: Double) -> String {
        func c(_ v: Double) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }

    // MARK: Adding to Tuff

    /// Adds what was read to the browser: history to `HistoryStore`, bookmarks as a new space,
    /// spaces as spaces on the current profile, favourites to its favourites grid.
    @MainActor
    static func apply(_ bundle: ImportBundle, from source: BrowserSource, to state: BrowserState) -> ImportSummary {
        var summary = ImportSummary()
        if let history = bundle.history, !history.isEmpty {
            HistoryStore.shared.merge(history, profileID: state.currentProfile.id)
            summary.pages = history.count
        }

        let profile = state.currentProfile
        var newTabs: [Tab] = []
        var newSpaces: [Space] = []
        var usedColors = Set(state.spaces.map(\.colorHex))
        var usedIcons = Set(state.spaces.map(\.icon))

        func makeTab(_ t: ImportedTab) -> Tab {
            let tab = Tab(url: t.url, title: t.title, homeURL: t.url)
            newTabs.append(tab)
            return tab
        }
        func makeSpace(name: String, icon preferred: String?, color: String?) -> Space {
            let color = color ?? Space.palette.first { !usedColors.contains($0) } ?? Space.palette[(state.spaces.count + newSpaces.count) % Space.palette.count]
            usedColors.insert(color)
            let icon = preferred ?? Space.icons.first { !usedIcons.contains($0) } ?? "sparkles"
            usedIcons.insert(icon)
            let space = Space(name: name, icon: icon, colorHex: color, profileID: profile.id)
            newSpaces.append(space)
            return space
        }
        func uniqueName(_ name: String) -> String {
            let taken = Set(state.spaces.map(\.name) + newSpaces.map(\.name))
            guard taken.contains(name) else { return name }
            var n = 2
            while taken.contains("\(name) \(n)") { n += 1 }
            return "\(name) \(n)"
        }

        // Bookmarks: one space, the bar's bookmarks pinned loose, every folder a (closed) folder.
        if let bookmarks = bundle.bookmarks, bookmarks.count > 0 {
            func flatten(_ folder: ImportedBookmark, prefix: String?) -> [ImportedFolder] {
                let title = folder.title.trimmed
                let name = [prefix, title.isEmpty ? "Folder" : title].compactMap { $0 }.joined(separator: " › ")
                let own = folder.children.compactMap { b in b.url.map { ImportedTab(title: b.title, url: $0) } }
                let nested = folder.children.filter { $0.url == nil }.flatMap { flatten($0, prefix: name) }
                return (own.isEmpty ? [] : [ImportedFolder(name: name, tabs: own)]) + nested
            }
            var items: [PinnedItem] = []
            func add(_ folders: [ImportedFolder]) {
                for f in folders {
                    let folder = Folder(name: f.name, isOpen: false)
                    folder.tabs = f.tabs.map(makeTab)
                    items.append(.folder(folder))
                }
            }
            for b in bookmarks.bar {
                if let url = b.url {
                    items.append(.tab(makeTab(ImportedTab(title: b.title, url: url))))
                } else {
                    add(flatten(b, prefix: nil))
                }
            }
            for root in bookmarks.roots {
                // A collection's own bookmarks get a folder named after it; its folders keep their names.
                let loose = root.children.compactMap { b in b.url.map { ImportedTab(title: b.title, url: $0) } }
                if !loose.isEmpty { add([ImportedFolder(name: root.title, tabs: loose)]) }
                for sub in root.children where sub.url == nil { add(flatten(sub, prefix: nil)) }
            }
            let name = uniqueName("\(source.shortName) Bookmarks")
            let space = makeSpace(name: name, icon: usedIcons.contains("bookmark.fill") ? nil : "bookmark.fill", color: nil)
            space.pinnedItems = items
            summary.bookmarks = bookmarks.count
            summary.bookmarkSpace = name
        }

        if let layout = bundle.layout {
            for imported in layout.spaces {
                let space = makeSpace(name: uniqueName(imported.name), icon: nil, color: imported.colorHex)
                space.pinnedItems = imported.pinned.map { item in
                    switch item {
                    case .tab(let t):
                        return .tab(makeTab(t))
                    case .folder(let f):
                        let folder = Folder(name: f.name, isOpen: true)
                        folder.tabs = f.tabs.map(makeTab)
                        return .folder(folder)
                    }
                }
                summary.spaces += 1
                summary.pinnedTabs += space.allPinned.count
            }
            for fav in layout.favorites where !profile.favorites.contains(where: { $0.url.map { Tab.samePage($0, fav.url) } ?? false }) {
                profile.favorites.append(makeTab(fav))
                summary.favorites += 1
            }
        }

        if !newSpaces.isEmpty {
            withAnimation(Motion.smooth) { state.spaces.append(contentsOf: newSpaces) }
        }
        if !newTabs.isEmpty { state.adopt(newTabs) }
        return summary
    }
}

// MARK: - SQLite

/// A read-only look at another app's SQLite database, through a private copy (the app may have
/// it open and locked). The copy is deleted with this object.
final class SQLiteCopy {
    struct Row {
        fileprivate let statement: OpaquePointer
        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    }

    private var db: OpaquePointer?
    private let folder: URL

    init(_ file: URL) throws {
        let fm = FileManager.default
        folder = fm.temporaryDirectory.appending(path: "TuffImport-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: file.lastPathComponent)
        do {
            try fm.copyItem(at: file, to: copy)
        } catch {
            try? fm.removeItem(at: folder)
            throw ImportProblem(error)
        }
        // Recent changes may still be in the write-ahead log; SQLite folds it in on open.
        let wal = URL(fileURLWithPath: file.path + "-wal")
        if fm.fileExists(atPath: wal.path) { try? fm.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal")) }
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Couldn’t open \(file.lastPathComponent)."
            sqlite3_close(db)
            db = nil
            try? fm.removeItem(at: folder)
            throw ImportProblem.unreadable(message)
        }
    }

    deinit {
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: folder)
    }

    func query(_ sql: String, _ each: (Row) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ImportProblem.unreadable(db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error")
        }
        defer { sqlite3_finalize(statement) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW { each(Row(statement: statement)); continue }
            if step == SQLITE_DONE { break }
            throw ImportProblem.unreadable(db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error")
        }
    }

    func hasTable(_ name: String) -> Bool {
        var found = false
        try? query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(name.replacingOccurrences(of: "'", with: "''"))'") { _ in found = true }
        return found
    }
}
