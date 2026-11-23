import Foundation

/// `chrome.readingList`: a per-profile list of saved pages with read status and timestamps,
/// persisted in `reading-list.json`. Matches Chrome's MV3 `readingList` API: unique by URL,
/// `addEntry` / `removeEntry` / `updateEntry` / `query`, and `onEntryAdded` / `onEntryRemoved` /
/// `onEntryUpdated` events via `ExtensionEventPush`.
final class ExtensionReadingList {
    static let shared = ExtensionReadingList()

    struct Entry: Codable, Equatable {
        var url: String
        var title: String
        var hasBeenRead: Bool
        var creationTime: Double
        var lastUpdateTime: Double

        var dictionary: [String: Any] {
            [
                "url": url,
                "title": title,
                "hasBeenRead": hasBeenRead,
                "creationTime": creationTime,
                "lastUpdateTime": lastUpdateTime,
            ]
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private var entriesByProfile: [String: [Entry]] = [:]
    private let file: URL
    private let profileProvider: () -> String
    private let emitEvents: Bool

    init(
        file: URL = Paths.appSupport.appendingPathComponent("reading-list.json"),
        profileProvider: @escaping () -> String = { BrowserState.shared.bookmarksProfileID?.uuidString ?? "default" },
        emitEvents: Bool = true
    ) {
        self.file = file
        self.profileProvider = profileProvider
        self.emitEvents = emitEvents
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: [Entry]].self, from: data) {
            entriesByProfile = saved
        }
    }

    private func profileKey() -> String { profileProvider() }

    private static func validateURL(_ value: Any?) throws -> String {
        guard let raw = value as? String, !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else {
            throw Failure("URL is not supported.")
        }
        return url.absoluteString
    }

    private static func nowMilliseconds() -> Double {
        (Date().timeIntervalSince1970 * 1000).rounded()
    }

    private func save() {
        let nonEmpty = entriesByProfile.filter { !$0.value.isEmpty }
        guard let data = try? JSONEncoder().encode(nonEmpty) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private func emit(_ event: String, entry: Entry) {
        guard emitEvents else { return }
        ExtensionEventPush.shared.emit(event, args: [entry.dictionary])
    }

    // MARK: API

    func addEntry(_ details: [String: Any]) throws {
        let url = try Self.validateURL(details["url"])
        guard let title = details["title"] as? String else { throw Failure("title is required.") }
        guard let hasBeenRead = details["hasBeenRead"] as? Bool else { throw Failure("hasBeenRead is required.") }
        let key = profileKey()
        var list = entriesByProfile[key] ?? []
        guard !list.contains(where: { $0.url == url }) else { throw Failure("Duplicate URL.") }
        let now = Self.nowMilliseconds()
        let entry = Entry(url: url, title: title, hasBeenRead: hasBeenRead, creationTime: now, lastUpdateTime: now)
        list.append(entry)
        entriesByProfile[key] = list
        save()
        emit("readingList.onEntryAdded", entry: entry)
    }

    func removeEntry(_ details: [String: Any]) throws {
        let url = try Self.validateURL(details["url"])
        let key = profileKey()
        var list = entriesByProfile[key] ?? []
        guard let index = list.firstIndex(where: { $0.url == url }) else { throw Failure("URL not found.") }
        let removed = list.remove(at: index)
        entriesByProfile[key] = list
        save()
        emit("readingList.onEntryRemoved", entry: removed)
    }

    func updateEntry(_ details: [String: Any]) throws {
        let url = try Self.validateURL(details["url"])
        let newTitle = details["title"] as? String
        let newRead = details["hasBeenRead"] as? Bool
        guard newTitle != nil || newRead != nil else {
            throw Failure("At least one of `title` or `hasBeenRead` must be provided.")
        }
        let key = profileKey()
        var list = entriesByProfile[key] ?? []
        guard let index = list.firstIndex(where: { $0.url == url }) else { throw Failure("URL not found.") }
        if let newTitle { list[index].title = newTitle }
        if let newRead { list[index].hasBeenRead = newRead }
        list[index].lastUpdateTime = Self.nowMilliseconds()
        let updated = list[index]
        entriesByProfile[key] = list
        save()
        emit("readingList.onEntryUpdated", entry: updated)
    }

    func query(_ details: [String: Any]) throws -> [[String: Any]] {
        let urlFilter: String?
        if let raw = details["url"] {
            urlFilter = try Self.validateURL(raw)
        } else {
            urlFilter = nil
        }
        let titleFilter = details["title"] as? String
        let readFilter = details["hasBeenRead"] as? Bool
        let list = entriesByProfile[profileKey()] ?? []
        return list.filter { entry in
            if let urlFilter, entry.url != urlFilter { return false }
            if let titleFilter, entry.title != titleFilter { return false }
            if let readFilter, entry.hasBeenRead != readFilter { return false }
            return true
        }.map(\.dictionary)
    }
}
