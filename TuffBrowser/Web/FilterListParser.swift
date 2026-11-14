import Foundation

/// Turns Adblock Plus–style filter lists (EasyList, EasyPrivacy, the uBlock filter lists, …)
/// into WebKit content rule lists — WebKit's only way to block a request before it is sent.
///
/// What carries over: network filters (`||host^`, paths, wildcards, `$third-party`, resource
/// types, `domain=`, `match-case`, `important`, `@@` exceptions, `$document` exceptions) and
/// element hiding (`##selector`, `#@#` exceptions, `$generichide`). What doesn't, because content
/// rule lists can't express it: anything that rewrites (`redirect=`, `removeparam`, `csp=`, header
/// and HTML filtering), procedural cosmetic filters (`:has-text`, `:upward`, …) and scriptlets
/// (`##+js(…)`). Those filters are skipped whole rather than applied approximately.
struct FilterListParser {
    /// Bump when the output changes, so cached compiled lists are rebuilt.
    static let version = 3

    struct Result {
        /// Content rule lists as JSON, each under WebKit's 150,000-rule limit.
        var lists: [String]
        var networkFilters = 0
        var cosmeticFilters = 0
        var skipped = 0
        var webkitRules = 0
    }

    typealias Rule = [String: Any]

    private var blocks: [Rule] = []
    private var exceptions: [Rule] = []
    private var important: [Rule] = []
    /// `@@…$document`: pages where nothing is blocked.
    private var pageExceptions: [Rule] = []
    /// Hosts excluded from generic element hiding (`@@||host^$generichide` / `$elemhide`).
    private var genericHideOff = Set<String>()
    private var genericSelectors: [String] = []
    private var genericSelectorExceptions: [String: Set<String>] = [:]
    /// Domain set (joined) → selectors.
    private var specificSelectors: [String: (domains: [String], selectors: [String])] = [:]
    private var specificExceptions = Set<String>()
    private var badFilters = Set<String>()
    private var stats = Result(lists: [])

    // MARK: Entry point

    /// `validSelectors` filters the element-hiding selectors (WebKit drops a whole batch of
    /// selectors when one of them is invalid CSS); it gets them all at once.
    static func parse(_ texts: [String], validSelectors: ([String]) -> Set<String>) -> Result {
        var parser = FilterListParser()
        var lines: [Substring] = []
        for text in texts { lines += preprocess(text) }
        // $badfilter cancels another filter; collect them first.
        for line in lines where line.contains("badfilter") {
            if let normalized = normalizedBadFilter(line) { parser.badFilters.insert(normalized) }
        }
        for line in lines { parser.add(line) }
        return parser.finish(validSelectors: validSelectors)
    }

    // MARK: Preprocessing (`!#if` blocks)

    /// Lines of a list with comments dropped and `!#if … !#endif` blocks resolved the way uBO
    /// does for a browser that is neither Chromium nor Firefox.
    private static func preprocess(_ text: String) -> [Substring] {
        var out: [Substring] = []
        var stack: [Bool] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)[...]
            if line.hasPrefix("!#if ") {
                stack.append(condition(line.dropFirst(5)))
                continue
            }
            if line.hasPrefix("!#else") { if let last = stack.popLast() { stack.append(!last) }; continue }
            if line.hasPrefix("!#endif") { _ = stack.popLast(); continue }
            if stack.contains(false) { continue }
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }
            out.append(line)
        }
        return out
    }

    private static let trueTokens: Set<String> = ["env_safari", "cap_html_filtering_false", "false_never"]

    private static func condition(_ expression: Substring) -> Bool {
        // `a || b && !c` without parentheses is all these lists use.
        let text = expression.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        return text.components(separatedBy: "||").contains { clause in
            clause.components(separatedBy: "&&").allSatisfy { token in
                var t = token.trimmingCharacters(in: .whitespaces)
                var negate = false
                while t.hasPrefix("!") { negate.toggle(); t.removeFirst() }
                return trueTokens.contains(t) != negate
            }
        }
    }

    // MARK: Lines

    private mutating func add(_ line: Substring) {
        if let marker = Self.cosmeticMarker(in: line) {
            addCosmetic(line, marker: marker)
        } else {
            addNetwork(line)
        }
    }

    /// `##`, `#@#` and the extended markers (`#?#`, `#$#`, `#%#`, `#@?#`, …), and uBO's HTML `##^`.
    private static func cosmeticMarker(in line: Substring) -> Range<Substring.Index>? {
        guard let hash = line.firstIndex(of: "#") else { return nil }
        let rest = line[hash...]
        for marker in ["##", "#@#", "#?#", "#@?#", "#$#", "#@$#", "#%#", "#@%#", "#$?#", "#@$?#"] where rest.hasPrefix(marker) {
            return hash..<line.index(hash, offsetBy: marker.count)
        }
        // A `#` further on (in a URL fragment, say): look again after it.
        if let next = line[line.index(after: hash)...].firstIndex(of: "#"), next > hash {
            return cosmeticMarker(in: line[line.index(after: hash)...])
        }
        return nil
    }

    // MARK: Element hiding

    private static let proceduralMarkers = [
        ":has-text(", ":-abp-", ":contains(", ":upward(", ":xpath(", ":matches-css", ":min-text-length(",
        ":watch-attr(", ":remove(", ":style(", ":others(", ":matches-path(", ":matches-attr(", ":matches-media(",
        ":matches-prop(", ":if(", ":if-not(", ":nth-ancestor(", ":-ext-", ":spath(", ":remove-attr(",
        ":remove-class(", ":shadow(", ":matches-property(",
    ]

    private mutating func addCosmetic(_ line: Substring, marker: Range<Substring.Index>) {
        let kind = line[marker]
        let selector = String(line[marker.upperBound...])
        guard kind == "##" || kind == "#@#", !selector.isEmpty, !selector.hasPrefix("+js("), !selector.hasPrefix("^"),
              !Self.proceduralMarkers.contains(where: selector.contains), Self.isASCII(selector) else {
            stats.skipped += 1
            return
        }
        let (included, excluded) = Self.domains(line[..<marker.lowerBound], separator: ",")
        if line[..<marker.lowerBound].split(separator: ",").contains(where: { $0.hasSuffix(".*") }), included.isEmpty {
            stats.skipped += 1   // only entity domains (`google.*`), which WebKit can't match
            return
        }
        stats.cosmeticFilters += 1
        if kind == "#@#" {
            if included.isEmpty {
                genericSelectorExceptions[selector, default: []].formUnion(["*"])
            } else {
                for domain in included {
                    genericSelectorExceptions[selector, default: []].insert(domain)
                    specificExceptions.insert(domain + "##" + selector)
                }
            }
            return
        }
        if included.isEmpty {
            if excluded.isEmpty {
                genericSelectors.append(selector)
            } else {
                genericSelectorExceptions[selector, default: []].formUnion(excluded)
                genericSelectors.append(selector)
            }
        } else {
            let key = included.sorted().joined(separator: ",")
            specificSelectors[key, default: (included.sorted(), [])].selectors.append(selector)
        }
    }

    // MARK: Network filters

    private static let typeOptions: [String: [String]] = [
        "script": ["script"], "image": ["image"], "stylesheet": ["style-sheet"], "css": ["style-sheet"],
        "object": ["other"], "xmlhttprequest": ["fetch"], "xhr": ["fetch"], "ping": ["ping"], "beacon": ["ping"],
        "media": ["media"], "font": ["font"], "websocket": ["websocket"], "other": ["other"],
        "subdocument": ["subdocument"], "frame": ["subdocument"], "popup": ["popup"],
        "document": ["document"], "doc": ["document"],
    ]
    private static let defaultTypes = ["script", "image", "style-sheet", "font", "media", "ping", "fetch", "websocket", "other", "subdocument"]
    private static let ignoredOptions: Set<String> = ["_", "stealth", "~stealth"]

    private mutating func addNetwork(_ line: Substring) {
        var text = line
        var isException = false
        if text.hasPrefix("@@") { isException = true; text = text.dropFirst(2) }
        if badFilters.contains(String(line)) { stats.skipped += 1; return }

        // Options follow the last `$` — except inside a /regex/.
        var pattern = text
        var options: [Substring] = []
        if text.hasPrefix("/"), let close = text.range(of: "/$", options: .backwards), close.lowerBound > text.startIndex {
            pattern = text[..<text.index(after: close.lowerBound)]
            options = text[close.upperBound...].split(separator: ",")
        } else if !text.hasPrefix("/") || !text.hasSuffix("/"), let dollar = text.lastIndex(of: "$") {
            pattern = text[..<dollar]
            options = text[text.index(after: dollar)...].split(separator: ",")
        }

        var types: Set<String> = []
        var negatedTypes: Set<String> = []
        var party: String?
        var caseSensitive = false
        var isImportant = false
        var included: [String] = []
        var excluded: [String] = []
        var hidingException = false
        for raw in options {
            let option = raw.lowercased()
            if Self.ignoredOptions.contains(option) { continue }
            if let mapped = Self.typeOptions[option] { types.formUnion(mapped); continue }
            if option.hasPrefix("~"), let mapped = Self.typeOptions[String(option.dropFirst())] { negatedTypes.formUnion(mapped); continue }
            switch option {
            case "all": types.formUnion(Self.defaultTypes + ["document", "popup"])
            case "third-party", "3p", "~first-party", "~1p": party = "third-party"
            case "~third-party", "first-party", "1p", "~3p": party = "first-party"
            case "match-case": caseSensitive = true
            case "important": isImportant = true
            case "generichide", "ghide", "elemhide", "ehide":
                guard isException else { stats.skipped += 1; return }
                hidingException = true
            default:
                if option.hasPrefix("domain=") || option.hasPrefix("from=") {
                    let value = option[option.index(after: option.firstIndex(of: "=")!)...]
                    (included, excluded) = Self.domains(value, separator: "|")
                    if included.isEmpty && excluded.isEmpty { stats.skipped += 1; return }
                } else {
                    // redirect=, removeparam, csp=, header=, denyallow=, to=, method=, …
                    stats.skipped += 1
                    return
                }
            }
        }

        // Exceptions that switch element hiding off for a site.
        if hidingException {
            if let host = Self.plainHost(pattern) { genericHideOff.insert(host) }
            if types.isEmpty { return }
        }

        guard let regexes = Self.urlRegexes(pattern) else { stats.skipped += 1; return }

        // `@@…$document`: nothing is blocked on matching pages.
        if isException, types.contains("document") {
            for regex in regexes {
                pageExceptions.append(["trigger": ["url-filter": ".*", "if-top-url": [regex]], "action": ["type": "ignore-previous-rules"]])
            }
            types.remove("document")
            if types.isEmpty { stats.networkFilters += 1; return }
        }

        var resolved = types.isEmpty ? Set(Self.defaultTypes) : types
        resolved.subtract(negatedTypes)
        if types.isEmpty, !negatedTypes.isEmpty { resolved = Set(Self.defaultTypes).subtracting(negatedTypes) }
        guard !resolved.isEmpty else { stats.skipped += 1; return }

        var base: [String: Any] = [:]
        if caseSensitive { base["url-filter-is-case-sensitive"] = true }
        if let party { base["load-type"] = [party] }
        if !included.isEmpty { base["if-domain"] = included.map { "*" + $0 } }
        else if !excluded.isEmpty { base["unless-domain"] = excluded.map { "*" + $0 } }

        var groups: [[String: Any]] = []
        let plain = resolved.subtracting(["document", "subdocument"]).sorted()
        if !plain.isEmpty { groups.append(["resource-type": plain]) }
        let top = resolved.contains("document")
        let child = resolved.contains("subdocument")
        if top && child { groups.append(["resource-type": ["document"]]) }
        else if top { groups.append(["resource-type": ["document"], "load-context": ["top-frame"]]) }
        else if child { groups.append(["resource-type": ["document"], "load-context": ["child-frame"]]) }

        let action = ["type": isException ? "ignore-previous-rules" : "block"]
        stats.networkFilters += 1
        for regex in regexes {
            for group in groups {
                var trigger = base.merging(group) { _, new in new }
                trigger["url-filter"] = regex
                let rule: Rule = ["trigger": trigger, "action": action]
                if isException { exceptions.append(rule) }
                else if isImportant { important.append(rule) }
                else { blocks.append(rule) }
            }
        }
    }

    // MARK: Patterns

    private static let separator = "[^-a-zA-Z0-9_.%]"
    private static let hostStart = "^[^:]+:(//)?([^/?#]*\\.)?"

    /// ABP pattern → WebKit url-filter regexes (nil when WebKit's regex subset can't say it).
    static func urlRegexes(_ pattern: Substring) -> [String]? {
        guard isASCII(pattern) else { return nil }
        if pattern.count > 1, pattern.hasPrefix("/"), pattern.hasSuffix("/") {
            let body = String(pattern.dropFirst().dropLast())
            guard isSupportedRegex(body) else { return nil }
            return [body.replacingOccurrences(of: "\\/", with: "/")]
        }
        var body = pattern
        var start = ""
        if body.hasPrefix("||") { start = hostStart; body = body.dropFirst(2) }
        else if body.hasPrefix("|") { start = "^"; body = body.dropFirst() }
        var end = ""
        var trailingSeparator = false
        if body.hasSuffix("|") { end = "$"; body = body.dropLast() }
        else if body.hasSuffix("^") { trailingSeparator = true; body = body.dropLast() }
        var out = ""
        for ch in body {
            switch ch {
            case "*": out += ".*"
            case "^": out += separator
            case ".", "+", "?", "(", ")", "{", "}", "[", "]", "\\", "$", "|": out += "\\" + String(ch)
            default: out.append(ch)
            }
        }
        let regex = start + out
        if trailingSeparator {
            // After a bare host the URL always goes on (`/`, `:`, `?`), so one pattern does.
            if start == hostStart, !body.contains("/"), !body.contains("*") { return [regex + separator] }
            return [regex + separator, regex + "$"]
        }
        let full = regex + end
        return [full.isEmpty || full == "^" ? ".*" : full]
    }

    /// WebKit content rule lists understand `.`, `*`, `+`, `?`, character classes, groups and
    /// `^` / `$` — no alternation, counted repeats, shorthand classes or lookarounds.
    static func isSupportedRegex(_ regex: String) -> Bool {
        guard isASCII(regex) else { return false }
        if regex.contains("|") || regex.contains("{") || regex.contains("(?") { return false }
        if regex.range(of: #"\\[dDwWsSbB0-9]"#, options: .regularExpression) != nil { return false }
        if regex.range(of: #"[*+?]\?"#, options: .regularExpression) != nil { return false }
        // Anchors only at the ends: `^` first (or opening a negated class), `$` last.
        let chars = Array(regex)
        for (i, ch) in chars.enumerated() {
            let escaped = i > 0 && chars[i - 1] == "\\"
            if ch == "$", i != chars.count - 1, !escaped { return false }
            if ch == "^", i != 0, !escaped, chars[i - 1] != "[" { return false }
        }
        return true
    }

    /// `||host^` → host (for `$generichide`-style exceptions).
    private static func plainHost(_ pattern: Substring) -> String? {
        guard pattern.hasPrefix("||") else { return nil }
        var host = pattern.dropFirst(2)
        if host.hasSuffix("^") { host = host.dropLast() }
        guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return host.lowercased()
    }

    /// `a.com,~b.com` / `a.com|~b.com` → included and excluded hosts (entity `google.*` entries dropped).
    private static func domains(_ text: Substring, separator: Character) -> (included: [String], excluded: [String]) {
        var included: [String] = []
        var excluded: [String] = []
        for part in text.split(separator: separator) {
            var domain = part.trimmingCharacters(in: .whitespaces).lowercased()
            let negated = domain.hasPrefix("~")
            if negated { domain.removeFirst() }
            guard !domain.isEmpty, !domain.hasSuffix(".*"), !domain.contains("/"), isASCII(domain[...]) else { continue }
            if negated { excluded.append(domain) } else { included.append(domain) }
        }
        return (included, excluded)
    }

    private static func normalizedBadFilter(_ line: Substring) -> String? {
        guard let dollar = line.lastIndex(of: "$") else { return nil }
        let options = line[line.index(after: dollar)...].split(separator: ",").filter { $0 != "badfilter" }
        guard options.count < line[line.index(after: dollar)...].split(separator: ",").count else { return nil }
        return options.isEmpty ? String(line[..<dollar]) : String(line[..<dollar]) + "$" + options.joined(separator: ",")
    }

    private static func isASCII<S: StringProtocol>(_ text: S) -> Bool {
        text.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7f }
    }

    // MARK: Output

    private static let rulesPerList = 80_000
    private static let selectorsPerRule = 100

    private mutating func finish(validSelectors: ([String]) -> Set<String>) -> Result {
        // Element hiding, first in each list so later exceptions can't cancel it for subresources.
        var allSelectors = Set(genericSelectors)
        for entry in specificSelectors.values { allSelectors.formUnion(entry.selectors) }
        let valid = validSelectors(Array(allSelectors))
        var cosmetic: [Rule] = []
        let hideOff = genericHideOff.sorted().map { "*" + $0 }
        var plainGeneric: [String] = []
        var seen = Set<String>()
        for selector in genericSelectors where valid.contains(selector) && seen.insert(selector).inserted {
            if let off = genericSelectorExceptions[selector] {
                if off.contains("*") { continue }
                var unless = Set(off.map { "*" + $0 })
                unless.formUnion(hideOff)
                cosmetic.append(["trigger": ["url-filter": ".*", "unless-domain": unless.sorted()],
                                 "action": ["type": "css-display-none", "selector": selector]])
            } else {
                plainGeneric.append(selector)
            }
        }
        for batch in stride(from: 0, to: plainGeneric.count, by: Self.selectorsPerRule) {
            let selectors = plainGeneric[batch..<min(batch + Self.selectorsPerRule, plainGeneric.count)]
            var trigger: [String: Any] = ["url-filter": ".*"]
            if !hideOff.isEmpty { trigger["unless-domain"] = hideOff }
            cosmetic.append(["trigger": trigger, "action": ["type": "css-display-none", "selector": selectors.joined(separator: ", ")]])
        }
        for (_, entry) in specificSelectors.sorted(by: { $0.key < $1.key }) {
            let selectors = Array(Set(entry.selectors.filter { selector in
                valid.contains(selector) && !entry.domains.contains { specificExceptions.contains($0 + "##" + selector) }
            })).sorted()
            for batch in stride(from: 0, to: selectors.count, by: Self.selectorsPerRule) {
                let chunk = selectors[batch..<min(batch + Self.selectorsPerRule, selectors.count)]
                cosmetic.append(["trigger": ["url-filter": ".*", "if-domain": entry.domains.map { "*" + $0 }],
                                 "action": ["type": "css-display-none", "selector": chunk.joined(separator: ", ")]])
            }
        }

        // Every list carries all exceptions (they only cancel rules in their own list); blocks and
        // element hiding are shared out. Order: hiding, blocks, exceptions, important, page exceptions.
        let tail = exceptions.count + important.count + pageExceptions.count
        let room = max(10_000, Self.rulesPerList - tail)
        let shared = cosmetic + blocks
        var lists: [String] = []
        var total = 0
        var start = 0
        repeat {
            let chunk = shared[start..<min(start + room, shared.count)]
            let list = Array(chunk) + exceptions + important + pageExceptions
            if let data = try? JSONSerialization.data(withJSONObject: list), let json = String(data: data, encoding: .utf8) {
                lists.append(json)
                total += list.count
            }
            start += room
        } while start < shared.count
        stats.lists = lists
        stats.webkitRules = total
        return stats
    }
}
