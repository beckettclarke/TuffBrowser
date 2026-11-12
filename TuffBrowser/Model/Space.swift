import AppKit
import Observation

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
    var pinned: [Tab] = []
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
