import Foundation

/// Firefox's `sessions.setTabValue` / `getTabValue` / `removeTabValue` and the window versions:
/// small values an extension pins to a tab (Tree Style Tab keeps each tab's place in its tree this
/// way). Firefox keeps them with the session, so they outlive a relaunch, and they follow a closed
/// tab when it's reopened; so do these, saved by tab id in a file of their own.
///
/// Tuff has the one browser window, so window values are kept under one key.
final class ExtensionSessionValues {
    static var shared: ExtensionSessionValues {
        if let instance { return instance }
        let made = ExtensionSessionValues()
        instance = made
        return made
    }
    /// Made when first needed, so quitting doesn't read the file just to have nothing to save.
    private static var instance: ExtensionSessionValues?

    private static let windowKey = "window"

    /// extension id -> tab id (or `windowKey`) -> key -> value.
    private var values: [String: [String: [String: Any]]] = [:]
    private let file = Paths.appSupport.appendingPathComponent("extension-session-values.json")
    private let saver = Debouncer(delay: 1)
    private var unsaved = false

    private init() {
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: [String: [String: Any]]] else { return }
        // Tabs that are gone (closed for good, or not brought back with the session) take theirs with them.
        let state = BrowserState.shared
        let known = Set(state.allTabs.map(\.id.uuidString) + state.closedTabIDs.map(\.uuidString) + [Self.windowKey])
        values = saved.mapValues { $0.filter { known.contains($0.key) } }.filter { !$0.value.isEmpty }
        let targets = { (all: [String: [String: [String: Any]]]) in all.values.reduce(0) { $0 + $1.count } }
        if targets(values) != targets(saved) { scheduleSave() }
    }

    // MARK: The API

    func get(_ key: String, tab: Tab?, extensionID: String) -> Any? {
        values[extensionID]?[Self.target(tab)]?[key]
    }

    func set(_ key: String, value: Any, tab: Tab?, extensionID: String) {
        values[extensionID, default: [:]][Self.target(tab), default: [:]][key] = value
        scheduleSave()
    }

    func remove(_ key: String, tab: Tab?, extensionID: String) {
        let target = Self.target(tab)
        guard values[extensionID]?[target]?.removeValue(forKey: key) != nil else { return }
        if values[extensionID]?[target]?.isEmpty == true { values[extensionID]?[target] = nil }
        if values[extensionID]?.isEmpty == true { values[extensionID] = nil }
        scheduleSave()
    }

    private static func target(_ tab: Tab?) -> String { tab?.id.uuidString ?? windowKey }

    // MARK: Following tabs

    /// A tab was closed and kept as `closedID` for reopening: its values wait there.
    func tabClosed(_ id: UUID, as closedID: UUID) {
        move(from: id.uuidString, to: closedID.uuidString)
    }

    /// A closed tab came back as a new tab.
    func tabReopened(_ closedID: UUID, as id: UUID) {
        move(from: closedID.uuidString, to: id.uuidString)
    }

    func extensionUninstalled(_ id: String) {
        guard values.removeValue(forKey: id) != nil else { return }
        scheduleSave()
    }

    private func move(from old: String, to new: String) {
        var changed = false
        for id in values.keys {
            guard let moving = values[id]?.removeValue(forKey: old) else { continue }
            values[id]?[new] = moving
            changed = true
        }
        if changed { scheduleSave() }
    }

    private func scheduleSave() {
        unsaved = true
        saver.schedule { [weak self] in self?.saveNow() }
    }

    private func saveNow() {
        guard unsaved, let data = try? JSONSerialization.data(withJSONObject: values) else { return }
        unsaved = false
        try? data.write(to: file, options: .atomic)
    }

    /// Writes what's waiting to be saved, when quitting.
    static func saveIfNeeded() {
        instance?.saver.cancel()
        instance?.saveNow()
    }
}
