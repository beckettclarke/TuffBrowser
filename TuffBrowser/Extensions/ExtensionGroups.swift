import AppKit
import WebKit

/// `chrome.tabGroups` and `tabs.group` / `tabs.ungroup`, on Tuff's folders. A folder is a named
/// group of pinned tabs in a space's sidebar, so grouping a tab pins it into the folder and
/// ungrouping puts it back with the space's regular tabs.
///
/// Chrome's group ids are integers that last for the browser session; folders get one the first
/// time an extension sees them. Folders have no colour, so a colour an extension sets is kept
/// for the session only (and reads back), and folders it never set one for read as grey.
///
/// Tabs travel by their index in the window (`BrowserState.allTabs`, the order WebKit reports):
/// the shim turns tab ids into indexes and back, since Tuff can't know WebKit's tab ids.
final class ExtensionTabGroups {
    static let shared = ExtensionTabGroups()

    static let colors = ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]

    private var browser: BrowserState { .shared }
    private var ids: [UUID: Int] = [:]
    private var nextID = 1
    private var colorsByFolder: [UUID: String] = [:]
    /// Folders an extension made with `tabs.group`; like Chrome's groups they go away when their
    /// last tab is ungrouped. The user's own folders are never removed that way.
    private var madeByExtension: Set<UUID> = []

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    func id(for folder: Folder) -> Int {
        if let id = ids[folder.id] { return id }
        let id = nextID
        nextID += 1
        ids[folder.id] = id
        return id
    }

    private func folder(withID id: Int) -> Folder? {
        guard let uuid = ids.first(where: { $0.value == id })?.key else { return nil }
        return browser.spaces.lazy.flatMap(\.folders).first { $0.id == uuid }
    }

    private func requireFolder(_ value: Any?) throws -> Folder {
        guard let id = value as? Int, let folder = folder(withID: id) else {
            throw Failure("No group with id: \(value ?? "?").")
        }
        return folder
    }

    /// The group as Chrome describes it. `windowId` is filled in by the shim.
    func info(_ folder: Folder) -> [String: Any] {
        [
            "id": id(for: folder),
            "title": folder.name,
            "collapsed": !folder.isOpen,
            "color": colorsByFolder[folder.id] ?? "grey",
            "windowId": -1,
        ]
    }

    private var allFolders: [Folder] { browser.spaces.flatMap(\.folders) }

    func get(_ args: [String: Any]) throws -> [String: Any] {
        info(try requireFolder(args["groupId"]))
    }

    func query(_ args: [String: Any]) -> [[String: Any]] {
        allFolders.filter { folder in
            if let collapsed = args["collapsed"] as? Bool, collapsed == folder.isOpen { return false }
            if let title = args["title"] as? String, !Self.titleMatches(folder.name, pattern: title) { return false }
            if let color = args["color"] as? String, color != (colorsByFolder[folder.id] ?? "grey") { return false }
            return true
        }.map(info)
    }

    /// Chrome matches `title` as a pattern where `*` stands for any run of characters.
    static func titleMatches(_ title: String, pattern: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*")
        return title.range(of: "^" + escaped + "$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    func update(_ args: [String: Any]) throws -> [String: Any] {
        let folder = try requireFolder(args["groupId"])
        let properties = args["updateProperties"] as? [String: Any] ?? [:]
        var colorChanged = false
        if let color = properties["color"] as? String {
            guard Self.colors.contains(color) else { throw Failure("Invalid color: \(color).") }
            colorChanged = colorsByFolder[folder.id] != color
            colorsByFolder[folder.id] = color
        }
        // Renaming and collapsing report onUpdated themselves (BrowserState tells this class).
        let title = (properties["title"] as? String).flatMap { $0 == folder.name ? nil : $0 }
        let collapse = (properties["collapsed"] as? Bool).flatMap { $0 == folder.isOpen ? $0 : nil }
        if let title { browser.rename(folder, to: title) }
        if collapse != nil { browser.toggle(folder) }
        if colorChanged, title == nil, collapse == nil { emit("tabGroups.onUpdated", folder) }
        return info(folder)
    }

    /// `tabGroups.move`: `index` is a tab index in the window; the folder goes to the place among
    /// its space's pinned tabs and folders nearest to it (-1: the end).
    func move(_ args: [String: Any]) throws -> [String: Any] {
        let folder = try requireFolder(args["groupId"])
        guard let space = browser.space(containing: folder) else { throw Failure("No group with id: \(args["groupId"] ?? "?").") }
        let properties = args["moveProperties"] as? [String: Any] ?? [:]
        guard let index = properties["index"] as? Int else { throw Failure("index is required.") }
        let all = browser.allTabs
        var target = space.pinnedItems.count - 1
        if index >= 0, index < all.count {
            let tab = all[index]
            if let place = space.pinnedIndex(of: tab.id) {
                target = place
            } else if let inFolder = space.folder(containing: tab), let place = space.pinnedIndex(of: inFolder.id) {
                target = place
            } else if browser.section(of: tab) == .favorites {
                target = 0
            }
        }
        browser.move(folder, to: target)
        return info(folder)
    }

    /// `tabs.group`: puts tabs into a group, a new one unless `groupId` names one. Returns its id.
    func group(_ args: [String: Any]) throws -> Int {
        let tabs = try Self.tabs(args["tabs"])
        guard !tabs.isEmpty else { throw Failure("No tabs to group.") }
        if tabs.contains(where: { browser.section(of: $0) == .favorites }) {
            throw Failure("Tabs in Favorites can’t be grouped.")
        }
        let folder: Folder
        if let id = args["groupId"] {
            folder = try requireFolder(id)
        } else {
            guard let space = browser.space(containing: tabs[0]) else { throw Failure("No tab to group.") }
            folder = browser.addFolder(in: space, interactive: false)
            madeByExtension.insert(folder.id)
        }
        guard let space = browser.space(containing: folder) else { throw Failure("No group to add to.") }
        for tab in tabs where browser.folder(containing: tab) !== folder {
            browser.move(tab, to: .pinned, in: space, folder: folder)
        }
        return id(for: folder)
    }

    /// `tabs.ungroup`: takes tabs out of their folders, back to their space's regular tabs.
    func ungroup(_ args: [String: Any]) throws {
        let tabs = try Self.tabs(args["tabs"])
        var emptied: [Folder] = []
        for tab in tabs {
            guard let folder = browser.folder(containing: tab), let space = browser.space(containing: folder) else { continue }
            browser.move(tab, to: .tabs, in: space)
            if folder.tabs.isEmpty, madeByExtension.contains(folder.id), !emptied.contains(where: { $0 === folder }) {
                emptied.append(folder)
            }
        }
        // Reports onRemoved through folderRemoved.
        for folder in emptied { browser.delete(folder) }
    }

    /// For the shim to decorate `tabs.query` / `tabs.get` results: each tab's group id
    /// (-1: none), by index in the window.
    func groupIDs() -> [Int] {
        browser.allTabs.map { tab in browser.folder(containing: tab).map(id(for:)) ?? -1 }
    }

    private static func tabs(_ value: Any?) throws -> [Tab] {
        let all = BrowserState.shared.allTabs
        let indexes = (value as? [Int]) ?? (value as? Int).map { [$0] } ?? []
        return try indexes.map { index in
            guard all.indices.contains(index) else { throw Failure("No tab with that id.") }
            return all[index]
        }
    }

    // MARK: Events

    func emit(_ event: String, _ folder: Folder) {
        ExtensionEventPush.shared.emit(event, args: [info(folder)], extra: ["groupWindow": true])
    }

    /// Called by `BrowserState` when the user changes folders.
    func folderCreated(_ folder: Folder) { emit("tabGroups.onCreated", folder) }
    func folderChanged(_ folder: Folder) { emit("tabGroups.onUpdated", folder) }
    func folderMoved(_ folder: Folder) { emit("tabGroups.onMoved", folder) }
    func folderRemoved(_ folder: Folder) {
        let gone = info(folder)
        ids.removeValue(forKey: folder.id)
        colorsByFolder.removeValue(forKey: folder.id)
        madeByExtension.remove(folder.id)
        ExtensionEventPush.shared.emit("tabGroups.onRemoved", args: [gone], extra: ["groupWindow": true])
    }
}

/// Firefox's `browser.contextualIdentities` (containers), on Tuff's profiles: each profile has
/// its own cookies and site data, which is what a container is. `cookieStoreId` is
/// `firefox-container-<profile id>`.
final class ExtensionContainers {
    static let shared = ExtensionContainers()

    static let prefix = "firefox-container-"
    static let colorCodes: [String: String] = [
        "blue": "#37adff", "turquoise": "#00c79a", "green": "#51cd00", "yellow": "#ffcb00", "orange": "#ff9f00",
        "red": "#ff613d", "pink": "#ff4bda", "purple": "#af51f5", "toolbar": "#7c7c7d",
    ]
    /// Firefox's container icons and the SF Symbols Tuff uses for them.
    static let icons: [(firefox: String, symbol: String)] = [
        ("fingerprint", "person.fill"), ("briefcase", "briefcase.fill"), ("dollar", "dollarsign.circle.fill"),
        ("cart", "cart.fill"), ("circle", "circle.fill"), ("gift", "gift.fill"), ("vacation", "airplane"),
        ("food", "fork.knife"), ("fruit", "carrot.fill"), ("pet", "pawprint.fill"), ("tree", "leaf.fill"),
        ("chill", "cup.and.saucer.fill"), ("fence", "house.fill"),
    ]
    /// Tuff's own profile icons that have no Firefox twin above.
    private static let extraIcons: [String: String] = [
        "graduationcap.fill": "circle", "book.fill": "circle", "gamecontroller.fill": "chill", "star.fill": "gift",
        "heart.fill": "pet", "flask.fill": "circle", "paintbrush.fill": "circle", "music.note": "chill",
    ]

    private var browser: BrowserState { .shared }
    /// A colour an extension set, for the session (Tuff colours spaces, not profiles).
    private var colors: [UUID: String] = [:]

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    func cookieStoreID(_ profile: Profile) -> String { Self.prefix + profile.id.uuidString.lowercased() }

    func profile(for cookieStoreID: Any?) -> Profile? {
        guard let id = cookieStoreID as? String, id.hasPrefix(Self.prefix),
              let uuid = UUID(uuidString: String(id.dropFirst(Self.prefix.count))) else { return nil }
        return browser.profiles.first { $0.id == uuid }
    }

    private func require(_ value: Any?) throws -> Profile {
        guard let profile = profile(for: value) else { throw Failure("Invalid contextual identity: \(value ?? "?")") }
        return profile
    }

    func info(_ profile: Profile) -> [String: Any] {
        let icon = Self.icons.first { $0.symbol == profile.icon }?.firefox ?? Self.extraIcons[profile.icon] ?? "circle"
        let color = colors[profile.id] ?? Self.colorName(for: browser.spaces(in: profile).first?.color)
        return [
            "name": profile.name,
            "icon": icon,
            "iconUrl": "resource://usercontext-content/\(icon).svg",
            "color": color,
            "colorCode": Self.colorCodes[color] ?? "#7c7c7d",
            "cookieStoreId": cookieStoreID(profile),
        ]
    }

    /// The Firefox container colour nearest a space's colour.
    static func colorName(for color: NSColor?) -> String {
        guard let rgb = color?.usingColorSpace(.sRGB), rgb.saturationComponent >= 0.15, rgb.brightnessComponent >= 0.12 else {
            return "toolbar"
        }
        let hue = rgb.hueComponent * 360
        switch hue {
        case ..<15: return "red"
        case ..<40: return "orange"
        case ..<65: return "yellow"
        case ..<150: return "green"
        case ..<195: return "turquoise"
        case ..<255: return "blue"
        case ..<290: return "purple"
        case ..<340: return "pink"
        default: return "red"
        }
    }

    func query(_ args: [String: Any]) -> [[String: Any]] {
        browser.profiles.filter { profile in
            if let name = args["name"] as? String, name != profile.name { return false }
            if let id = args["cookieStoreId"] as? String, id != cookieStoreID(profile) { return false }
            return true
        }.map(info)
    }

    func get(_ args: [String: Any]) throws -> [String: Any] { info(try require(args["cookieStoreId"])) }

    func create(_ args: [String: Any]) throws -> [String: Any] {
        guard let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            throw Failure("name is required.")
        }
        let symbol = (args["icon"] as? String).flatMap { icon in Self.icons.first { $0.firefox == icon }?.symbol }
        // Reports onCreated itself.
        let profile = browser.addProfile(name: name, icon: symbol)
        apply(args, to: profile)
        return info(profile)
    }

    func update(_ args: [String: Any]) throws -> [String: Any] {
        let profile = try require(args["cookieStoreId"])
        let details = args["details"] as? [String: Any] ?? [:]
        if let name = (details["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty { profile.name = name }
        apply(details, to: profile)
        browser.scheduleSave()
        profileChanged(profile)
        return info(profile)
    }

    private func apply(_ details: [String: Any], to profile: Profile) {
        if let icon = details["icon"] as? String, let symbol = Self.icons.first(where: { $0.firefox == icon })?.symbol {
            profile.icon = symbol
        }
        if let color = details["color"] as? String, Self.colorCodes[color] != nil { colors[profile.id] = color }
    }

    /// Removing a container deletes a profile and its website data, so the user is asked first.
    func remove(_ args: [String: Any], extensionName: String, finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) {
        let profile: Profile
        do { profile = try require(args["cookieStoreId"]) } catch { return fail(error) }
        guard browser.profiles.count > 1 else { return fail(Failure("The last profile can’t be removed.")) }
        let info = info(profile)
        Task { @MainActor in
            let confirmed = await PromptPresenter.present(Prompt(
                symbol: "trash.fill", symbolColor: .systemRed,
                title: "Delete the profile “\(profile.name)”?",
                message: "“\(extensionName)” wants to remove it. Its favourites are closed and its cookies and site data are deleted; its spaces move to another profile.",
                confirmTitle: "Delete Profile", destructive: true
            ))
            guard confirmed, self.browser.profiles.contains(where: { $0 === profile }) else {
                return fail(Failure("The user declined to remove the profile."))
            }
            self.browser.delete(profile)
            finish(info)
        }
    }

    /// For the shim to decorate `tabs.query` / `tabs.get` results: each tab's `cookieStoreId`,
    /// by index in the window.
    func cookieStoreIDs() -> [String] {
        browser.allTabs.map { tab in
            if let profile = browser.profiles.first(where: { $0.favorites.contains { $0 === tab } }) { return cookieStoreID(profile) }
            guard let space = browser.space(containing: tab) else { return "firefox-default" }
            return cookieStoreID(browser.profile(for: space))
        }
    }

    /// `tabs.create({cookieStoreId})`: a tab in the first space on that profile (the current
    /// space if it is one). Returns its index in the window.
    func openTab(_ args: [String: Any]) throws -> Int {
        let profile = try require(args["cookieStoreId"])
        let spaces = browser.spaces(in: profile)
        guard let space = spaces.first(where: { $0 === browser.currentSpace }) ?? spaces.first else {
            throw Failure("The profile “\(profile.name)” has no space to open a tab in.")
        }
        let url = (args["url"] as? String).flatMap(URL.init(string:))
        let tab = browser.newTab(url: url, select: args["active"] as? Bool ?? true, in: space)
        guard let index = browser.allTabs.firstIndex(where: { $0 === tab }) else { throw Failure("The tab couldn’t be opened.") }
        return index
    }

    // MARK: Events

    func profileChanged(_ profile: Profile) {
        ExtensionEventPush.shared.emit("contextualIdentities.onUpdated", args: [["contextualIdentity": info(profile)]])
    }

    func profileCreated(_ profile: Profile) {
        ExtensionEventPush.shared.emit("contextualIdentities.onCreated", args: [["contextualIdentity": info(profile)]])
    }

    func profileRemoved(_ info: [String: Any]) {
        colors = colors.filter { key, _ in browser.profiles.contains { $0.id == key } }
        ExtensionEventPush.shared.emit("contextualIdentities.onRemoved", args: [["contextualIdentity": info]])
    }
}
