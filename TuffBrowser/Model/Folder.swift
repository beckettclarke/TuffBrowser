import Foundation
import Observation

/// A named group of pinned tabs in a space's sidebar, like Arc's folders. Its tabs behave like
/// any other pinned tab (they keep a home page and are unloaded rather than closed); the folder
/// only groups them and can be collapsed.
@Observable
final class Folder: Identifiable {
    let id: UUID
    var name: String
    var isOpen: Bool
    var tabs: [Tab] = []

    init(id: UUID = UUID(), name: String, isOpen: Bool = true) {
        self.id = id
        self.name = name
        self.isOpen = isOpen
    }
}
