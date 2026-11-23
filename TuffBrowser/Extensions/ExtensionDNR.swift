import Foundation

/// Native helpers for `chrome.declarativeNetRequest` methods WebKit omits:
/// `getAvailableStaticRuleCount`, `testMatchOutcome`, `updateStaticRules`, and `getDisabledRuleIds`.
final class ExtensionDNR {
    static let shared = ExtensionDNR()

    static let guaranteedMinimumStaticRules = 30_000
    static let maxDisabledStaticRules = 5_000

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// extensionID -> (rulesetID -> sorted disabled static rule IDs).
    private var disabled: [String: [String: [Int]]] = [:]
    private let file: URL

    init(file: URL = Paths.appSupport.appendingPathComponent("extension-dnr-disabled.json")) {
        self.file = file
        if let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode([String: [String: [Int]]].self, from: data) {
            disabled = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(disabled) else { return }
        try? data.write(to: file, options: .atomic)
    }

    func extensionUninstalled(_ extensionID: String) {
        guard disabled.removeValue(forKey: extensionID) != nil else { return }
        save()
    }

    // MARK: updateStaticRules / getDisabledRuleIds

    func disabledRuleIDs(rulesetID: String, extensionID: String, manifest: [String: Any]) throws -> [Int] {
        guard Self.rulesetEntry(id: rulesetID, in: manifest) != nil else {
            throw Failure("Invalid ruleset id '\(rulesetID)'.")
        }
        return disabled[extensionID]?[rulesetID] ?? []
    }

    func updateStaticRules(
        rulesetID: String,
        disableRuleIDs: [Int],
        enableRuleIDs: [Int],
        extensionID: String,
        manifest: [String: Any],
        resources: URL?
    ) throws {
        guard let entry = Self.rulesetEntry(id: rulesetID, in: manifest) else {
            throw Failure("Invalid ruleset id '\(rulesetID)'.")
        }
        var current = Set(disabled[extensionID]?[rulesetID] ?? [])
        for id in enableRuleIDs { current.remove(id) }
        for id in disableRuleIDs { current.insert(id) }

        // Enforce Chrome's global per-extension disabled static rule limit across all rulesets.
        var otherCount = 0
        for (otherRuleset, ids) in disabled[extensionID] ?? [:] where otherRuleset != rulesetID {
            otherCount += ids.count
        }
        guard otherCount + current.count <= Self.maxDisabledStaticRules else {
            throw Failure("The number of disabled static rules exceeds the limit of \(Self.maxDisabledStaticRules).")
        }

        if current.isEmpty {
            disabled[extensionID]?.removeValue(forKey: rulesetID)
            if disabled[extensionID]?.isEmpty == true { disabled[extensionID] = nil }
        } else {
            disabled[extensionID, default: [:]][rulesetID] = current.sorted()
        }
        save()

        // Keep the staged/packaged ruleset JSON in sync so WebKit compiles without disabled rules.
        if let resources, let path = entry["path"] as? String {
            Self.syncRulesetFile(path: path, in: resources, disabledIDs: current)
        }
    }

    /// Re-applies persisted disabled static rules to a freshly staged extension copy (before WebKit loads it).
    func applyDisabledRules(extensionID: String, manifest: [String: Any], resources: URL) {
        guard let map = disabled[extensionID], !map.isEmpty else { return }
        for (rulesetID, ids) in map where !ids.isEmpty {
            guard let entry = Self.rulesetEntry(id: rulesetID, in: manifest),
                  let path = entry["path"] as? String else { continue }
            Self.syncRulesetFile(path: path, in: resources, disabledIDs: Set(ids))
        }
    }

    private static func rulesetEntry(id: String, in manifest: [String: Any]) -> [String: Any]? {
        guard let dnr = manifest["declarative_net_request"] as? [String: Any],
              let list = dnr["rule_resources"] as? [[String: Any]] else { return nil }
        return list.first { ($0["id"] as? String) == id }
    }

    private static func syncRulesetFile(path: String, in resources: URL, disabledIDs: Set<Int>) {
        let base = resources.standardizedFileURL.path
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let file = resources.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(base + "/") else { return }
        let backup = file.deletingLastPathComponent().appendingPathComponent(".__tuff_orig_" + file.lastPathComponent)
        let fm = FileManager.default
        if !fm.fileExists(atPath: backup.path) {
            try? fm.copyItem(at: file, to: backup)
        }
        let source = fm.fileExists(atPath: backup.path) ? backup : file
        guard let data = try? Data(contentsOf: source),
              let rules = (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) as? [[String: Any]] else {
            return
        }
        let filtered = disabledIDs.isEmpty ? rules : rules.filter { rule in
            guard let id = rule["id"] as? Int else { return true }
            return !disabledIDs.contains(id)
        }
        if let out = try? JSONSerialization.data(withJSONObject: filtered) {
            try? out.write(to: file, options: .atomic)
        }
    }

    // MARK: getAvailableStaticRuleCount & testMatchOutcome

    /// Reads an extension's enabled static rulesets from disk and reports how many static rules
    /// remain below Chrome's `GUARANTEED_MINIMUM_STATIC_RULES` budget.
    static func availableStaticRuleCount(
        manifest: [String: Any], resources: URL?, enabledRulesetIDs: [String]?,
        disabledByRuleset: [String: Set<Int>] = [:]
    ) -> Int {
        let rulesets = loadStaticRulesets(
            manifest: manifest, resources: resources,
            enabledRulesetIDs: enabledRulesetIDs, disabledByRuleset: disabledByRuleset
        )
        let used = rulesets.reduce(0) { $0 + $1.rules.count }
        return max(0, guaranteedMinimumStaticRules - used)
    }

    func disabledMap(for extensionID: String) -> [String: Set<Int>] {
        (disabled[extensionID] ?? [:]).mapValues(Set.init)
    }

    /// Evaluates a request against the extension's enabled static rulesets, dynamic rules, and
    /// session rules, returning `{ matchedRules: [{ ruleId, rulesetId }] }`.
    static func testMatchOutcome(
        request: [String: Any], manifest: [String: Any], resources: URL?,
        enabledRulesetIDs: [String]?, dynamicRules: [[String: Any]], sessionRules: [[String: Any]],
        disabledByRuleset: [String: Set<Int>] = [:]
    ) throws -> [String: Any] {
        guard let urlString = request["url"] as? String, let url = URL(string: urlString), url.scheme != nil else {
            throw Failure("request.url must be a valid URL.")
        }
        let resourceType = (request["type"] as? String)?.lowercased() ?? "other"
        let method = (request["method"] as? String)?.lowercased() ?? "get"
        let initiatorURL = (request["initiator"] as? String).flatMap(URL.init(string:))
        let tabID = request["tabId"] as? Int ?? -1

        var candidates: [(rule: [String: Any], rulesetID: String)] = []
        for ruleset in loadStaticRulesets(
            manifest: manifest, resources: resources,
            enabledRulesetIDs: enabledRulesetIDs, disabledByRuleset: disabledByRuleset
        ) {
            for rule in ruleset.rules { candidates.append((rule, ruleset.id)) }
        }
        for rule in dynamicRules { candidates.append((rule, "_dynamic")) }
        for rule in sessionRules { candidates.append((rule, "_session")) }

        struct Match {
            let ruleID: Int
            let rulesetID: String
            let actionType: String
            let priority: Int
        }

        var matches: [Match] = []
        for entry in candidates {
            guard let id = entry.rule["id"] as? Int,
                  let action = entry.rule["action"] as? [String: Any],
                  let actionType = action["type"] as? String else { continue }
            let condition = entry.rule["condition"] as? [String: Any] ?? [:]
            guard matchesCondition(
                condition, url: url, urlString: urlString, initiator: initiatorURL,
                resourceType: resourceType, method: method, tabID: tabID
            ) else { continue }
            let priority = entry.rule["priority"] as? Int ?? 1
            matches.append(Match(ruleID: id, rulesetID: entry.rulesetID, actionType: actionType, priority: priority))
        }

        guard !matches.isEmpty else { return ["matchedRules": [[String: Any]]()] }

        // Chrome DNR precedence: higher priority wins; on tie: allow > allowAllRequests > block > upgradeScheme > redirect > modifyHeaders.
        func rank(_ type: String) -> Int {
            switch type {
            case "allow": return 6
            case "allowAllRequests": return 5
            case "block": return 4
            case "upgradeScheme": return 3
            case "redirect": return 2
            case "modifyHeaders": return 1
            default: return 0
            }
        }

        let sorted = matches.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            if rank(a.actionType) != rank(b.actionType) { return rank(a.actionType) > rank(b.actionType) }
            return a.ruleID < b.ruleID
        }

        let top = sorted[0]
        let selected: [Match]
        if top.actionType == "modifyHeaders" {
            // Multiple modifyHeaders rules can match together (until a lower-priority blocking/allow rule doesn't suppress them).
            let allowCut = sorted.first(where: { $0.actionType == "allow" || $0.actionType == "allowAllRequests" })?.priority ?? Int.min
            selected = sorted.filter { $0.actionType == "modifyHeaders" && $0.priority >= allowCut }
        } else {
            selected = [top]
        }

        return [
            "matchedRules": selected.map { ["ruleId": $0.ruleID, "rulesetId": $0.rulesetID] as [String: Any] },
        ]
    }

    // MARK: Static ruleset loading

    private static func loadStaticRulesets(
        manifest: [String: Any], resources: URL?, enabledRulesetIDs: [String]?,
        disabledByRuleset: [String: Set<Int>]
    ) -> [(id: String, rules: [[String: Any]])] {
        guard let resources,
              let dnr = manifest["declarative_net_request"] as? [String: Any],
              let list = dnr["rule_resources"] as? [[String: Any]] else { return [] }
        let enabledSet = enabledRulesetIDs.map(Set.init)
        let base = resources.standardizedFileURL.path
        var loaded: [(String, [[String: Any]])] = []
        for entry in list {
            guard let id = entry["id"] as? String, let path = entry["path"] as? String else { continue }
            let enabled = enabledSet.map { $0.contains(id) } ?? (entry["enabled"] as? Bool ?? false)
            guard enabled else { continue }
            let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
            let file = resources.appendingPathComponent(relative).standardizedFileURL
            guard file.path.hasPrefix(base + "/") else { continue }
            let backup = file.deletingLastPathComponent().appendingPathComponent(".__tuff_orig_" + file.lastPathComponent)
            let source = FileManager.default.fileExists(atPath: backup.path) ? backup : file
            guard let data = try? Data(contentsOf: source),
                  let rules = (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) as? [[String: Any]] else { continue }
            let disabledIDs = disabledByRuleset[id] ?? []
            let active = disabledIDs.isEmpty ? rules : rules.filter { rule in
                guard let ruleID = rule["id"] as? Int else { return true }
                return !disabledIDs.contains(ruleID)
            }
            loaded.append((id, active))
        }
        return loaded
    }

    // MARK: Condition evaluation

    private static func matchesCondition(
        _ condition: [String: Any], url: URL, urlString: String, initiator: URL?,
        resourceType: String, method: String, tabID: Int
    ) -> Bool {
        if let types = condition["resourceTypes"] as? [String],
           !types.contains(where: { $0.lowercased() == resourceType }) { return false }
        if let excluded = condition["excludedResourceTypes"] as? [String],
           excluded.contains(where: { $0.lowercased() == resourceType }) { return false }

        if let methods = condition["requestMethods"] as? [String],
           !methods.contains(where: { $0.lowercased() == method }) { return false }
        if let excluded = condition["excludedRequestMethods"] as? [String],
           excluded.contains(where: { $0.lowercased() == method }) { return false }

        if let tabIDs = condition["tabIds"] as? [Int], !tabIDs.contains(tabID) { return false }
        if let excluded = condition["excludedTabIds"] as? [Int], excluded.contains(tabID) { return false }

        let requestHost = url.host?.lowercased() ?? ""
        let initiatorHost = initiator?.host?.lowercased()

        if let domains = condition["requestDomains"] as? [String],
           !matchesAnyDomain(requestHost, domains: domains) { return false }
        if let excluded = condition["excludedRequestDomains"] as? [String],
           matchesAnyDomain(requestHost, domains: excluded) { return false }

        let initDomains = (condition["initiatorDomains"] as? [String]) ?? (condition["domains"] as? [String])
        if let initDomains {
            guard let initiatorHost, matchesAnyDomain(initiatorHost, domains: initDomains) else { return false }
        }
        let excludedInitDomains = (condition["excludedInitiatorDomains"] as? [String]) ?? (condition["excludedDomains"] as? [String])
        if let excludedInitDomains, let initiatorHost, matchesAnyDomain(initiatorHost, domains: excludedInitDomains) {
            return false
        }

        if let domainType = condition["domainType"] as? String {
            let firstParty: Bool
            if let initiatorHost, !initiatorHost.isEmpty, !requestHost.isEmpty {
                firstParty = ExtensionCookies.registrableDomain(of: requestHost) == ExtensionCookies.registrableDomain(of: initiatorHost)
            } else {
                firstParty = true
            }
            if domainType == "firstParty" && !firstParty { return false }
            if domainType == "thirdParty" && firstParty { return false }
        }

        let caseSensitive = condition["isUrlFilterCaseSensitive"] as? Bool ?? false
        if let urlFilter = condition["urlFilter"] as? String, !urlFilter.isEmpty {
            guard matchesURLFilter(urlFilter, urlString: urlString, caseSensitive: caseSensitive) else { return false }
        }
        if let regexFilter = condition["regexFilter"] as? String, !regexFilter.isEmpty {
            let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(pattern: regexFilter, options: options),
                  regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)) != nil else { return false }
        }
        return true
    }

    private static func matchesAnyDomain(_ host: String, domains: [String]) -> Bool {
        guard !host.isEmpty else { return false }
        return domains.contains { raw in
            let d = raw.lowercased()
            return host == d || host.hasSuffix("." + d)
        }
    }

    /// Evaluates Chrome's DNR `urlFilter` syntax (`||`, leading/trailing `|`, `*`, `^`).
    static func matchesURLFilter(_ filter: String, urlString: String, caseSensitive: Bool) -> Bool {
        if filter == "*" { return true }
        var pattern = ""
        var body = filter
        var domainAnchored = false
        var startAnchored = false
        var endAnchored = false

        if body.hasPrefix("||") {
            domainAnchored = true
            body.removeFirst(2)
        } else if body.hasPrefix("|") {
            startAnchored = true
            body.removeFirst(1)
        }
        if body.hasSuffix("|") {
            endAnchored = true
            body.removeLast(1)
        }

        if domainAnchored {
            pattern += #"^[a-zA-Z][a-zA-Z0-9+.-]*://(?:[^/?#]*\.)?"#
        } else if startAnchored {
            pattern += "^"
        }

        for char in body {
            switch char {
            case "*": pattern += ".*"
            case "^": pattern += #"(?:[^a-zA-Z0-9_.%-]|$)"#
            default: pattern += NSRegularExpression.escapedPattern(for: String(char))
            }
        }
        if endAnchored { pattern += "$" }

        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
        return regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)) != nil
    }
}
