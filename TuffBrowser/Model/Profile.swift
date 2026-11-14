import AppKit
import Observation
import WebKit

/// A set of spaces that belong together, such as "Home" or "School". Spaces on the same
/// profile share the favourites grid at the top of the sidebar, and extensions can be limited
/// to the spaces of particular profiles.
@Observable
final class Profile: Identifiable {
    let id: UUID
    var name: String
    /// SF Symbol name.
    var icon: String
    /// The tile grid at the top of the sidebar, shown in every space on this profile.
    var favorites: [Tab] = []
    /// Uses the browser's original website data (the profile that existed before profiles
    /// had their own cookies). Every other profile has a store of its own.
    let usesSharedStore: Bool
    /// An Incognito profile's in-memory store, dropped with the window.
    private let privateStore: WKWebsiteDataStore?

    init(id: UUID = UUID(), name: String, icon: String, usesSharedStore: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.usesSharedStore = usesSharedStore
        self.privateStore = nil
    }

    /// An Incognito profile: nothing it stores reaches the disk.
    init(name: String, icon: String, privateStore: WKWebsiteDataStore) {
        self.id = UUID()
        self.name = name
        self.icon = icon
        self.usesSharedStore = false
        self.privateStore = privateStore
    }

    var isPrivate: Bool { privateStore != nil }

    /// Where this profile's cookies, logins and site storage live.
    var dataStore: WKWebsiteDataStore {
        if let privateStore { return privateStore }
        return usesSharedStore ? DataStores.website : DataStores.store(forProfile: id)
    }

    static let icons: [String] = [
        "person.fill", "house.fill", "graduationcap.fill", "briefcase.fill", "book.fill", "gamecontroller.fill",
        "star.fill", "heart.fill", "flask.fill", "paintbrush.fill", "music.note", "leaf.fill",
    ]
}
