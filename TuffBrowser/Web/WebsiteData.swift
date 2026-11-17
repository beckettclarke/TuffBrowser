import Foundation
import WebKit

/// Cookies and site storage across every profile's data store, by site: list what is stored,
/// remove one site's, or remove everything changed in a stretch of time.
enum WebsiteData {
    struct Site: Identifiable, Equatable {
        /// WebKit's name for the site (its registrable domain, e.g. "google.com").
        let name: String
        /// What kinds of data it keeps, across profiles ("Cookies", "Local storage"…).
        let kinds: [String]
        var id: String { name }
    }

    /// Time ranges for "Remove data from…", as Chrome and Safari offer them.
    enum Range: String, CaseIterable, Identifiable {
        case lastHour, today, lastWeek, lastMonth, allTime
        var id: String { rawValue }

        var label: String {
            switch self {
            case .lastHour: "The Last Hour"
            case .today: "Today"
            case .lastWeek: "The Last 7 Days"
            case .lastMonth: "The Last 4 Weeks"
            case .allTime: "All Time"
            }
        }

        var since: Date {
            let now = Date()
            switch self {
            case .lastHour: return now.addingTimeInterval(-3600)
            case .today: return Calendar.current.startOfDay(for: now)
            case .lastWeek: return now.addingTimeInterval(-7 * 86400)
            case .lastMonth: return now.addingTimeInterval(-28 * 86400)
            case .allTime: return .distantPast
            }
        }
    }

    private static let types = WKWebsiteDataStore.allWebsiteDataTypes()

    /// Every site with data in any profile, sorted by name.
    static func sites(completion: @escaping ([Site]) -> Void) {
        var kinds: [String: Set<String>] = [:]
        let group = DispatchGroup()
        for store in DataStores.all {
            group.enter()
            store.fetchDataRecords(ofTypes: types) { records in
                for record in records {
                    kinds[record.displayName, default: []].formUnion(record.dataTypes.map(label))
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion(kinds.map { Site(name: $0.key, kinds: $0.value.sorted()) }.sorted { $0.name < $1.name })
        }
    }

    /// Removes one site's cookies and storage from every profile.
    static func remove(site name: String, completion: @escaping () -> Void = {}) {
        let group = DispatchGroup()
        for store in DataStores.all {
            group.enter()
            store.fetchDataRecords(ofTypes: types) { records in
                let matching = records.filter { $0.displayName == name }
                guard !matching.isEmpty else { group.leave(); return }
                store.removeData(ofTypes: types, for: matching) { group.leave() }
            }
        }
        group.notify(queue: .main, execute: completion)
    }

    /// The site a page's data is filed under (WebKit names records by registrable domain).
    static func siteName(for url: URL?, completion: @escaping (String?) -> Void) {
        guard let host = url?.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { completion(nil); return }
        sites { list in
            // The longest record name the host ends with: "mail.google.com" → "google.com".
            let match = list.map(\.name).filter { host == $0 || host.hasSuffix("." + $0) }.max { $0.count < $1.count }
            completion(match)
        }
    }

    /// Removes everything stored or changed since the range began, in every profile.
    static func remove(_ range: Range, completion: @escaping () -> Void = {}) {
        let group = DispatchGroup()
        for store in DataStores.all {
            group.enter()
            store.removeData(ofTypes: types, modifiedSince: range.since) { group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }

    private static func label(_ type: String) -> String {
        switch type {
        case WKWebsiteDataTypeCookies: "Cookies"
        case WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage: "Site storage"
        case WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeWebSQLDatabases, WKWebsiteDataTypeFileSystem: "Databases"
        case WKWebsiteDataTypeServiceWorkerRegistrations: "Offline data"
        case WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache,
             WKWebsiteDataTypeOfflineWebApplicationCache: "Cache"
        default: "Other data"
        }
    }
}
