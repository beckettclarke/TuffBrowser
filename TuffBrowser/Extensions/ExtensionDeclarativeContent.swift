import Foundation

/// `chrome.declarativeContent`: rules that turn an extension's action on for the pages they match
/// (the Manifest V3 way of doing a page action: `action.disable()` everywhere, then a rule to show
/// it on some sites). Chrome keeps the rules across restarts, and extensions usually add them only
/// once, in `runtime.onInstalled`, so they are saved here.
///
/// Tuff knows each tab's address, so it checks the rules whenever a tab's page changes and tells the
/// extension (through the event relay) to enable or disable its action for that tab; the shim makes
/// the `action.enable` / `disable` call, since only the extension itself can. Supported: the
/// `pageUrl` and `isBookmarked` conditions of `PageStateMatcher`, and `ShowAction` /
/// `ShowPageAction`. `css` conditions can't be checked from outside the page and count as met;
/// `SetIcon` and `RequestContentScript` are accepted but do nothing.
final class ExtensionDeclarativeContent {
    static let shared = ExtensionDeclarativeContent()

    static let applyEvent = "declarativeContent.__apply"

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// extension id -> its rules, as the extension gave them (plus ids and priorities).
    private var rules: [String: [[String: Any]]] = [:]
    /// extension id -> the tabs its action was turned on for by a rule.
    private var shown: [String: Set<ObjectIdentifier>] = [:]
    private var nextID = 1
    private let file = Paths.appSupport.appendingPathComponent("extension-declarative-content.json")

    private init() {
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]] {
            rules = saved
        }
    }

    // MARK: onPageChanged.addRules / removeRules / getRules

    func addRules(_ added: [[String: Any]], extensionID: String) throws -> [[String: Any]] {
        var list = rules[extensionID] ?? []
        var result: [[String: Any]] = []
        for var rule in added {
            guard rule["conditions"] is [Any], rule["actions"] is [Any] else { throw Failure("A rule needs conditions and actions.") }
            if rule["id"] == nil {
                rule["id"] = "_\(nextID)_"
                nextID += 1
            }
            if rule["priority"] == nil { rule["priority"] = 100 }
            let id = rule["id"] as? String
            guard !list.contains(where: { $0["id"] as? String == id }) else { throw Failure("Duplicate rule ID: \(id ?? "")") }
            list.append(rule)
            result.append(rule)
        }
        rules[extensionID] = list
        save()
        BrowserState.shared.allTabs.forEach(evaluate)
        return result
    }

    func removeRules(_ ids: [String]?, extensionID: String) {
        if let ids {
            rules[extensionID]?.removeAll { ($0["id"] as? String).map(ids.contains) ?? false }
        } else {
            rules[extensionID] = nil
        }
        save()
        BrowserState.shared.allTabs.forEach(evaluate)
    }

    func getRules(_ ids: [String]?, extensionID: String) -> [[String: Any]] {
        let list = rules[extensionID] ?? []
        guard let ids else { return list }
        return list.filter { ($0["id"] as? String).map(ids.contains) ?? false }
    }

    func extensionUninstalled(_ id: String) {
        guard rules.removeValue(forKey: id) != nil else { return }
        shown[id] = nil
        save()
    }

    /// WebKit forgets the action's per-tab state with the extension; so does this.
    func extensionUnloaded(_ id: String) {
        shown[id] = nil
    }

    private func save() {
        let snapshot = rules.filter { !$0.value.isEmpty }
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot) else { return }
        try? data.write(to: file, options: .atomic)
    }

    // MARK: Checking pages

    /// Re-checks a tab after its page changed. Cheap when no extension has rules.
    func evaluate(_ tab: Tab) {
        guard !rules.isEmpty, tab.browser === BrowserState.shared else { return }
        for id in rules.keys { evaluate(tab, for: id) }
    }

    /// An extension started listening (its worker has just started): bring every tab up to date.
    func listenerAdded(extensionID: String) {
        guard rules[extensionID]?.isEmpty == false else { return }
        for tab in BrowserState.shared.allTabs { evaluate(tab, for: extensionID) }
    }

    private func evaluate(_ tab: Tab, for id: String) {
        let key = ObjectIdentifier(tab)
        let show = tab.url.map { url in (rules[id] ?? []).contains { matches($0, url: url) } } ?? false
        let wasShown = shown[id]?.contains(key) ?? false
        // Only undo what a rule did: the action's own state stays the extension's business.
        guard show != wasShown,
              ExtensionEventPush.shared.emit(Self.applyEvent, details: ["show": show], tab: tab, to: id) else { return }
        if show { shown[id, default: []].insert(key) } else { shown[id]?.remove(key) }
    }

    private func matches(_ rule: [String: Any], url: URL) -> Bool {
        let actions = rule["actions"] as? [[String: Any]] ?? []
        guard actions.contains(where: { ["declarativeContent.ShowAction", "declarativeContent.ShowPageAction"].contains($0["instanceType"] as? String ?? "") }) else {
            return false
        }
        // Any one condition is enough; within a condition, everything given must hold.
        return (rule["conditions"] as? [[String: Any]] ?? []).contains { condition in
            if let filter = condition["pageUrl"] as? [String: Any], !Self.urlMatches(url, filter) { return false }
            if let bookmarked = condition["isBookmarked"] as? Bool {
                let isBookmarked = BrowserState.shared.bookmarksProfileID.flatMap { BookmarkStore.shared.bookmark(for: url, profile: $0) } != nil
                if bookmarked != isBookmarked { return false }
            }
            return true
        }
    }

    /// Chrome's `events.UrlFilter` (the same rules as the shim's copy for event filters).
    static func urlMatches(_ url: URL, _ filter: [String: Any]) -> Bool {
        let host = url.host ?? "", path = url.path.isEmpty ? "/" : url.path, query = url.query ?? ""
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        let plain = parts?.string ?? url.absoluteString
        let scheme = url.scheme?.lowercased() ?? ""
        let origin = scheme + "://" + host + (url.port.map { ":\($0)" } ?? "")
        let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : 0)
        func regex(_ pattern: String, _ text: String) -> Bool {
            (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        let checks: [String: (Any) -> Bool] = [
            "hostContains": { ("." + host).contains($0 as? String ?? "") }, "hostEquals": { host == $0 as? String },
            "hostPrefix": { host.hasPrefix($0 as? String ?? "") }, "hostSuffix": { host.hasSuffix($0 as? String ?? "") },
            "pathContains": { path.contains($0 as? String ?? "") }, "pathEquals": { path == $0 as? String },
            "pathPrefix": { path.hasPrefix($0 as? String ?? "") }, "pathSuffix": { path.hasSuffix($0 as? String ?? "") },
            "queryContains": { query.contains($0 as? String ?? "") }, "queryEquals": { query == $0 as? String },
            "queryPrefix": { query.hasPrefix($0 as? String ?? "") }, "querySuffix": { query.hasSuffix($0 as? String ?? "") },
            "urlContains": { plain.contains($0 as? String ?? "") }, "urlEquals": { plain == $0 as? String },
            "urlPrefix": { plain.hasPrefix($0 as? String ?? "") }, "urlSuffix": { plain.hasSuffix($0 as? String ?? "") },
            "urlMatches": { regex($0 as? String ?? "", plain) },
            "originAndPathMatches": { regex($0 as? String ?? "", origin + path) },
            "schemes": { ($0 as? [String])?.contains(scheme) ?? false },
            "ports": { value in
                (value as? [Any])?.contains { entry in
                    if let range = entry as? [Int], range.count == 2 { return (range[0]...max(range[0], range[1])).contains(port) }
                    return entry as? Int == port
                } ?? false
            },
        ]
        return filter.allSatisfy { key, value in checks[key]?(value) ?? true }
    }
}
