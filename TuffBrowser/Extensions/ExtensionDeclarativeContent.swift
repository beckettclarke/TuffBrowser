import Foundation
import WebKit

/// `chrome.declarativeContent`: rules that turn an extension's action on for the pages they match
/// (the Manifest V3 way of doing a page action: `action.disable()` everywhere, then a rule to show
/// it on some sites). Chrome keeps the rules across restarts, and extensions usually add them only
/// once, in `runtime.onInstalled`, so they are saved here.
///
/// Tuff knows each tab's address, so it checks the rules whenever a tab's page changes and tells the
/// extension (through the event relay) what to do for that tab; the shim makes the `action.enable` /
/// `disable` / `setIcon` and `scripting` calls, since only the extension itself can. Supported: the
/// `pageUrl` and `isBookmarked` conditions of `PageStateMatcher`, and all four actions: `ShowAction`
/// / `ShowPageAction`, `SetIcon` (the icon arrives as plain pixels, see the shim) and
/// `RequestContentScript` (run once per page, when it has loaded). `css` conditions can't be
/// checked from outside the page and count as met.
final class ExtensionDeclarativeContent {
    static let shared = ExtensionDeclarativeContent()

    static let applyEvent = "declarativeContent.__apply"

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// extension id -> its rules, as the extension gave them (plus ids and priorities).
    private var rules: [String: [[String: Any]]] = [:]
    /// What the rules did to one tab's action, so it can be undone when they stop matching.
    private struct Applied: Equatable {
        var show = false
        /// The SetIcon pixels as JSON, to notice a change.
        var icon: String?
    }

    /// extension id -> tab -> what its rules did there.
    private var applied: [String: [ObjectIdentifier: Applied]] = [:]
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
        applied[id] = nil
        save()
    }

    /// WebKit forgets the action's per-tab state with the extension; so does this.
    func extensionUnloaded(_ id: String) {
        applied[id] = nil
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
        guard let url = tab.url else {
            applyActions([], to: tab, for: id)
            return
        }
        let extRules = rules[id] ?? []
        let selectors = Self.cssSelectors(in: extRules)
        if selectors.isEmpty {
            applyActions(matchingActions(extRules, url: url, matchedCSS: []), to: tab, for: id)
            return
        }
        guard let webView = tab.webView else {
            applyActions(matchingActions(extRules, url: url, matchedCSS: []), to: tab, for: id)
            return
        }
        Self.checkCSS(selectors, in: webView) { [weak self, weak tab] matched in
            guard let self, let tab, tab.url == url else { return }
            let currentRules = self.rules[id] ?? []
            self.applyActions(self.matchingActions(currentRules, url: url, matchedCSS: matched), to: tab, for: id)
        }
    }

    private func applyActions(_ actions: [[String: Any]], to tab: Tab, for id: String) {
        let key = ObjectIdentifier(tab)
        let icon = actions.first { Self.type($0) == "declarativeContent.SetIcon" }?["imageData"]
        let now = Applied(
            show: actions.contains { Self.showTypes.contains(Self.type($0)) },
            icon: icon.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .sortedKeys) }.map { String(decoding: $0, as: UTF8.self) }
        )
        let before = applied[id]?[key] ?? Applied()
        // Only undo what a rule did: the action's own state stays the extension's business.
        guard now != before else { return }
        var details: [String: Any] = [:]
        if now.show != before.show { details["show"] = now.show }
        if now.icon != before.icon { details["icon"] = now.icon == nil ? NSNull() : icon }
        guard ExtensionEventPush.shared.emit(Self.applyEvent, details: details, tab: tab, to: id) else { return }
        applied[id, default: [:]][key] = now == Applied() ? nil : now
    }

    /// A page finished loading: runs the content scripts that matching rules ask for, and
    /// re-evaluates rules with CSS conditions now that the DOM is built.
    func pageLoaded(_ tab: Tab) {
        guard !rules.isEmpty, tab.browser === BrowserState.shared, let url = tab.url else { return }
        for id in rules.keys {
            let extRules = rules[id] ?? []
            let selectors = Self.cssSelectors(in: extRules)
            let deliver: (Set<String>) -> Void = { [weak self, weak tab] matched in
                guard let self, let tab, tab.url == url else { return }
                let actions = self.matchingActions(self.rules[id] ?? [], url: url, matchedCSS: matched)
                if !selectors.isEmpty { self.applyActions(actions, to: tab, for: id) }
                let scripts = actions
                    .filter { Self.type($0) == "declarativeContent.RequestContentScript" }
                    .map { action in
                        [
                            "js": action["js"] as? [String] ?? [], "css": action["css"] as? [String] ?? [],
                            "allFrames": action["allFrames"] as? Bool ?? false,
                            "matchAboutBlank": action["matchAboutBlank"] as? Bool ?? false,
                        ] as [String: Any]
                    }
                guard !scripts.isEmpty, let context = ExtensionManager.shared.contexts[id], context.hasAccess(to: url, in: tab) else { return }
                ExtensionEventPush.shared.emit(Self.applyEvent, details: ["scripts": scripts], tab: tab, to: id)
            }
            if selectors.isEmpty {
                deliver([])
            } else if let webView = tab.webView {
                Self.checkCSS(selectors, in: webView, completion: deliver)
            } else {
                deliver([])
            }
        }
    }

    private static let showTypes: Set<String> = ["declarativeContent.ShowAction", "declarativeContent.ShowPageAction"]

    private static func type(_ action: [String: Any]) -> String { action["instanceType"] as? String ?? "" }

    private static func cssSelectors(in rules: [[String: Any]]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rule in rules {
            for condition in rule["conditions"] as? [[String: Any]] ?? [] {
                for selector in condition["css"] as? [String] ?? [] where seen.insert(selector).inserted {
                    result.append(selector)
                }
            }
        }
        return result
    }

    private static let cssCheckScript = """
    const matched = [];
    for (const sel of selectors) {
      try {
        const nodes = document.querySelectorAll(sel);
        for (const el of nodes) {
          if (el.getClientRects && el.getClientRects().length > 0) { matched.push(sel); break; }
          const style = getComputedStyle(el);
          if (style && style.display !== 'none') { matched.push(sel); break; }
        }
      } catch (e) {}
    }
    return matched;
    """

    static func checkCSS(_ selectors: [String], in webView: WKWebView, completion: @escaping (Set<String>) -> Void) {
        webView.callAsyncJavaScript(cssCheckScript, arguments: ["selectors": selectors], in: nil, in: WebEngine.scriptWorld) { result in
            let list = (try? result.get()) as? [String] ?? []
            completion(Set(list))
        }
    }

    /// The actions of the extension's rules whose conditions the tab's page meets, highest priority first.
    private func matchingActions(_ extRules: [[String: Any]], url: URL, matchedCSS: Set<String>) -> [[String: Any]] {
        extRules
            .filter { Self.matches($0, url: url, matchedCSS: matchedCSS) }
            .sorted { ($0["priority"] as? Int ?? 100) > ($1["priority"] as? Int ?? 100) }
            .flatMap { $0["actions"] as? [[String: Any]] ?? [] }
    }

    static func matches(_ rule: [String: Any], url: URL, matchedCSS: Set<String> = []) -> Bool {
        // Any one condition is enough; within a condition, everything given must hold.
        (rule["conditions"] as? [[String: Any]] ?? []).contains { condition in
            if let filter = condition["pageUrl"] as? [String: Any], !Self.urlMatches(url, filter) { return false }
            if let bookmarked = condition["isBookmarked"] as? Bool {
                let isBookmarked = BrowserState.shared.bookmarksProfileID.flatMap { BookmarkStore.shared.bookmark(for: url, profile: $0) } != nil
                if bookmarked != isBookmarked { return false }
            }
            if let css = condition["css"] as? [String], !css.isEmpty {
                if !css.allSatisfy(matchedCSS.contains) { return false }
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
