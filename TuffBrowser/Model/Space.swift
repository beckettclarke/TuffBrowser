import AppKit
import Observation

/// One entry in a space's pinned section.
enum PinnedItem: Identifiable {
    case tab(Tab)
    case folder(Folder)

    var id: UUID {
        switch self {
        case .tab(let tab): tab.id
        case .folder(let folder): folder.id
        }
    }

    var tab: Tab? { if case .tab(let tab) = self { tab } else { nil } }
    var folder: Folder? { if case .folder(let folder) = self { folder } else { nil } }
}

@Observable
final class Space: Identifiable {
    let id: UUID
    var name: String
    /// SF Symbol name.
    var icon: String
    /// Window tint used while this space is showing.
    var colorHex: String
    /// The profile this space belongs to (see `Profile`).
    var profileID: UUID
    /// The pinned section in sidebar order: pinned tabs and folders of pinned tabs, mixed.
    var pinnedItems: [PinnedItem] = []
    var tabs: [Tab] = []
    var selectedTabID: UUID?

    init(id: UUID = UUID(), name: String, icon: String, colorHex: String, profileID: UUID) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.profileID = profileID
    }

    var color: NSColor { NSColor(hex: colorHex) }

    /// Pinned tabs that are not in a folder.
    var pinned: [Tab] { pinnedItems.compactMap(\.tab) }

    var folders: [Folder] { pinnedItems.compactMap(\.folder) }

    /// Every pinned tab, in folders or not, in sidebar order.
    var allPinned: [Tab] {
        pinnedItems.flatMap { item -> [Tab] in
            switch item {
            case .tab(let tab): [tab]
            case .folder(let folder): folder.tabs
            }
        }
    }

    /// The folder holding a tab, if it is in one.
    func folder(containing tab: Tab) -> Folder? {
        folders.first { $0.tabs.contains { $0 === tab } }
    }

    /// Where a loose pinned tab or a folder sits in `pinnedItems`.
    func pinnedIndex(of id: UUID) -> Int? {
        pinnedItems.firstIndex { $0.id == id }
    }

    /// Takes a tab out of the pinned section, wherever it is in it.
    func removePinned(_ tab: Tab) {
        pinnedItems.removeAll { $0.tab === tab }
        for folder in folders { folder.tabs.removeAll { $0 === tab } }
    }

    static let icons: [String] = [
        "bookmark.fill", "flask.fill", "book.fill", "house.fill", "briefcase.fill", "gamecontroller.fill",
        "music.note", "star.fill", "heart.fill", "graduationcap.fill", "cart.fill", "paintbrush.fill",
        "hammer.fill", "globe", "leaf.fill", "moon.fill", "bolt.fill", "film.fill",
        "terminal.fill", "airplane", "camera.fill", "cup.and.saucer.fill", "dumbbell.fill", "sparkles",
    ]

    /// Curated tints in pages of six: moody darks, deeper colours, muted mid-tones, then lights.
    static let presetPages: [[String]] = [
        ["#0E1A1C", "#111827", "#1C1329", "#26140F", "#0F2417", "#1A1A1D"],
        ["#2A1020", "#0B2233", "#1F2A44", "#2D2416", "#163028", "#2E1A3A"],
        ["#3E5266", "#4E6151", "#6B4E71", "#8A5A44", "#3F6663", "#76705F"],
        ["#E9E1D2", "#D3E4F0", "#F1D9DC", "#DDEBD8", "#E6DDF3", "#F3E7C9"],
    ]

    /// Every preset, darks first (new spaces take the first one not already in use).
    static let palette: [String] = presetPages.flatMap { $0 }
}
