import Foundation

/// Turns Adblock Plus–style filter lists (EasyList, EasyPrivacy, the uBlock filter lists, …)
/// into WebKit content rule lists — WebKit's only way to block a request before it is sent.
///
/// What carries over: network filters (`||host^`, paths, wildcards, `$third-party`, resource
/// types, `domain=`, `match-case`, `important`, `@@` exceptions, `$document` exceptions) and
/// element hiding (`##selector`, `#@#` exceptions, `$generichide`). What doesn't, because content
/// rule lists can't express it: anything that rewrites (`redirect=`, `removeparam`, `csp=`, header
/// and HTML filtering) are skipped whole rather than applied approximately. Procedural cosmetic
/// filters and scriptlets are handled separately by `AdvancedContentBlocker`.
struct FilterListParser {
    /// Bump when the output changes, so cached compiled lists are rebuilt.
    static let version = 8

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
    private var genericExclusions: [String: Set<String>] = [:]
    private var genericSelectorExceptions: [String: [DomainException]] = [:]
    /// Domain set (joined) → selectors.
    private var specificSelectors: [String: (domains: [String], excluded: [String], selectors: [String])] = [:]
    private var specificExceptions: [String: [DomainException]] = [:]
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
        let parsedDomains = Self.domains(line[..<marker.lowerBound], separator: ",")
        let (included, excluded) = (parsedDomains.included, parsedDomains.excluded)
        if parsedDomains.unsupportedIncluded, included.isEmpty {
            stats.skipped += 1
            return
        }
        stats.cosmeticFilters += 1
        if kind == "#@#" {
            let exception = DomainException(included: included.isEmpty ? ["*"] : included, excluded: excluded)
            genericSelectorExceptions[selector, default: []].append(exception)
            if !included.isEmpty { specificExceptions[selector, default: []].append(exception) }
            return
        }
        if included.isEmpty {
            if !excluded.isEmpty { genericExclusions[selector, default: []].formUnion(excluded) }
            genericSelectors.append(selector)
        } else {
            let domains = included.sorted()
            let excluded = excluded.sorted()
            let key = (domains + excluded.map { "~" + $0 }).joined(separator: ",")
            specificSelectors[key, default: (domains, excluded, [])].selectors.append(selector)
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
                    let parsed = Self.domains(value, separator: "|")
                    (included, excluded) = (parsed.included, parsed.excluded)
                    if parsed.unsupportedIncluded && included.isEmpty || included.isEmpty && excluded.isEmpty {
                        stats.skipped += 1
                        return
                    }
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
                else {
                    blocks.append(rule)
                    // WebKit forbids if-domain and unless-domain together. A later exception
                    // keeps a normal block from reaching the excluded domains.
                    if !included.isEmpty {
                        for domain in excluded {
                            var exceptionTrigger = trigger
                            exceptionTrigger.removeValue(forKey: "unless-domain")
                            exceptionTrigger["if-domain"] = ["*" + domain]
                            exceptions.append(["trigger": exceptionTrigger, "action": ["type": "ignore-previous-rules"]])
                        }
                    }
                }
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

    /// `a.com,~b.com` / `a.com|~b.com` → included and excluded hosts. An unsupported positive
    /// entry is important: dropping `kat.*` while keeping `~other.example` would widen a rule to
    /// every site instead of merely losing the entity's coverage.
    private static func domains(
        _ text: Substring, separator: Character
    ) -> (included: [String], excluded: [String], unsupportedIncluded: Bool) {
        var included: [String] = []
        var excluded: [String] = []
        var unsupportedIncluded = false
        for part in text.split(separator: separator) {
            var domain = part.trimmingCharacters(in: .whitespaces).lowercased()
            let negated = domain.hasPrefix("~")
            if negated { domain.removeFirst() }
            guard !domain.isEmpty else { continue }
            if domain.hasSuffix(".*") || domain.contains("/") || !isASCII(domain[...]) {
                if !negated { unsupportedIncluded = true }
                continue
            }
            if negated { excluded.append(domain) } else { included.append(domain) }
        }
        return (included, excluded, unsupportedIncluded)
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

    // MARK: Cosmetic domains

    private struct DomainException {
        var included: [String]
        var excluded: [String]
    }

    private struct DomainVariant {
        var included: String
        var excluded: Set<String>
    }

    private static func domain(_ parent: String, contains child: String) -> Bool {
        parent == "*" || parent == child || child.hasSuffix("." + parent)
    }

    private static func intersection(_ a: String, _ b: String) -> String? {
        if domain(a, contains: b) { return b }
        if domain(b, contains: a) { return a }
        return nil
    }

    /// Subtracts each exception from a rule's domains. A variant whose exception has exclusions
    /// needs a second rule for those exclusions: `unless-domain` alone would wrongly keep the
    /// exception in force there too.
    private static func domainVariants(
        included: [String], excluded: Set<String>, exceptions: [DomainException]
    ) -> [DomainVariant] {
        var variants = included.map { DomainVariant(included: $0, excluded: excluded) }
        for exception in exceptions {
            var next: [DomainVariant] = []
            for variant in variants {
                let overlapping = exception.included.filter { intersection(variant.included, $0) != nil }
                guard !overlapping.isEmpty else { next.append(variant); continue }
                if !overlapping.contains(where: { domain($0, contains: variant.included) }) {
                    var reduced = variant
                    reduced.excluded.formUnion(overlapping)
                    next.append(reduced)
                }
                for exceptionDomain in overlapping {
                    guard let overlap = intersection(variant.included, exceptionDomain) else { continue }
                    for restored in exception.excluded {
                        guard let intersection = intersection(overlap, restored) else { continue }
                        if variant.excluded.contains(where: { domain($0, contains: intersection) }) { continue }
                        next.append(DomainVariant(included: intersection, excluded: variant.excluded))
                    }
                }
            }
            variants = next
        }
        return variants
    }

    /// Whether a selector tests the `style` attribute anywhere but its subject (`[style] > img`,
    /// `body:not([style]) .x`, `div:has([style])`). One such selector anywhere on a page makes
    /// WebKit give up its lazy inline styles: every `element.style.x = …` is serialized back
    /// into the attribute straight away and run through attribute invalidation, so the page can
    /// re-check the selector. Animations and frameworks that set inline styles pay for that on
    /// every change, on every site, so generic filters like these (a handful, for a few odd
    /// sites) are left out.
    static func readsStyleAttributeAboveSubject(_ selector: String) -> Bool {
        let lowered = selector.lowercased()
        guard lowered.contains("[style") else { return false }
        return styleAttributeAboveSubject(in: lowered[...], nested: false)
    }

    /// Looks at one level of a selector list: brackets and quotes are skipped, each parenthesised
    /// argument is looked at on its own. Inside a pseudo-class (`nested`), a combinator anywhere
    /// near `[style` counts, as does any `[style` inside `:has(…)`.
    private static func styleAttributeAboveSubject(in text: Substring, nested: Bool) -> Bool {
        var depth = 0
        var inBracket = false
        var quote: Character?
        var selectorStart = text.startIndex
        var argumentStart = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if inBracket {
                if ch == "]" { inBracket = false }
            } else if ch == "[" {
                inBracket = true
            } else if ch == "(" {
                if depth == 0 { argumentStart = text.index(after: index) }
                depth += 1
            } else if ch == ")" {
                depth -= 1
                if depth == 0 {
                    let argument = text[argumentStart..<index]
                    let isHas = text[text.startIndex..<argumentStart].hasSuffix(":has(")
                    if isHas, argument.contains("[style") { return true }
                    if styleAttributeAboveSubject(in: argument, nested: true) { return true }
                }
            } else if depth == 0 {
                if ch == "," {
                    selectorStart = text.index(after: index)
                } else if " >+~".contains(ch) {
                    // A combinator: what came before it in this selector is above the subject.
                    let scope = nested ? text[selectorStart...] : text[selectorStart..<index]
                    if scope.contains("[style") { return true }
                }
            }
            index = text.index(after: index)
        }
        return false
    }

    /// The trigger of a hiding rule bound to sites. It fires on document loads only, which is
    /// where WebKit adds a rule's selectors to the page. Without `resource-type`, every image,
    /// script and fetch the page makes runs through each of these rules (~11,000 of them, all
    /// `url-filter: .*`) just to find out the page has them already. That was 40 ms per
    /// Speedometer NewsSite navigation, on a site none of the rules are for.
    private static func domainTrigger(_ variant: DomainVariant, generic: Bool) -> [String: Any] {
        var trigger: [String: Any] = ["url-filter": ".*", "resource-type": ["document"]]
        if !variant.excluded.isEmpty, variant.included != "*" {
            // A host-bound url-filter leaves the one domain-condition slot available for exclusions.
            trigger["url-filter"] = urlRegexes("||\(variant.included)^")?.first ?? ".*"
        } else if !generic || variant.included != "*" {
            trigger["if-domain"] = ["*" + variant.included]
        }
        if !variant.excluded.isEmpty { trigger["unless-domain"] = variant.excluded.sorted().map { "*" + $0 } }
        return trigger
    }

    // MARK: Output

    private static let rulesPerList = 80_000
    private static let selectorsPerRule = 100

    private mutating func finish(validSelectors: ([String]) -> Set<String>) -> Result {
        // Element hiding, first in each list so later exceptions can't cancel it. Site-bound
        // hiding fires on document loads only (`domainTrigger`).
        var allSelectors = Set(genericSelectors)
        for entry in specificSelectors.values { allSelectors.formUnion(entry.selectors) }
        let valid = validSelectors(Array(allSelectors))
        var cosmetic: [Rule] = []
        let hideOff = Set(genericHideOff)
        var plainGeneric: [String] = []
        var complexGeneric: [String: (variant: DomainVariant, selectors: [String])] = [:]
        var seen = Set<String>()
        for selector in genericSelectors where valid.contains(selector) && seen.insert(selector).inserted {
            if Self.readsStyleAttributeAboveSubject(selector) { stats.skipped += 1; continue }
            let exceptions = genericSelectorExceptions[selector] ?? []
            let exclusions = genericExclusions[selector] ?? []
            if exceptions.isEmpty && exclusions.isEmpty {
                plainGeneric.append(selector)
                continue
            }
            let variants = Self.domainVariants(included: ["*"], excluded: exclusions.union(hideOff), exceptions: exceptions)
            for variant in variants {
                let key = variant.included + "|" + variant.excluded.sorted().joined(separator: "|")
                complexGeneric[key, default: (variant, [])].selectors.append(selector)
            }
        }
        // Generic hiding gets a list of its own, with no conditions at all. WebKit then builds it
        // into a single style sheet once per web content process and hands every document that
        // one sheet. Any condition (an `unless-domain` for the `$generichide` sites, say) makes
        // WebKit evaluate each rule on every load instead, and add its ~14,000 selectors to each
        // page and frame one rule at a time, parsing them afresh. `$generichide` sites are
        // switched off by an `ignore-previous-rules` after them, which only reaches rules in its
        // own list (as AdGuard's Safari converter does it).
        var genericList: [Rule] = []
        for batch in stride(from: 0, to: plainGeneric.count, by: Self.selectorsPerRule) {
            let selectors = plainGeneric[batch..<min(batch + Self.selectorsPerRule, plainGeneric.count)]
            genericList.append(["trigger": ["url-filter": ".*"], "action": ["type": "css-display-none", "selector": selectors.joined(separator: ", ")]])
        }
        if !genericList.isEmpty, !hideOff.isEmpty {
            genericList.append(["trigger": ["url-filter": ".*", "if-domain": hideOff.sorted().map { "*" + $0 }],
                                "action": ["type": "ignore-previous-rules"]])
        }
        for entry in complexGeneric.values {
            for batch in stride(from: 0, to: entry.selectors.count, by: Self.selectorsPerRule) {
                let chunk = entry.selectors[batch..<min(batch + Self.selectorsPerRule, entry.selectors.count)]
                cosmetic.append(["trigger": Self.domainTrigger(entry.variant, generic: true),
                                 "action": ["type": "css-display-none", "selector": chunk.joined(separator: ", ")]])
            }
        }
        var resolvedSpecific: [String: (variant: DomainVariant, selectors: [String])] = [:]
        for (_, entry) in specificSelectors.sorted(by: { $0.key < $1.key }) {
            for selector in Set(entry.selectors) where valid.contains(selector) {
                let variants = Self.domainVariants(
                    included: entry.domains, excluded: Set(entry.excluded),
                    exceptions: specificExceptions[selector] ?? []
                )
                for variant in variants {
                    let key = variant.included + "|" + variant.excluded.sorted().joined(separator: "|")
                    resolvedSpecific[key, default: (variant, [])].selectors.append(selector)
                }
            }
        }
        for entry in resolvedSpecific.values {
            let selectors = entry.selectors.sorted()
            for batch in stride(from: 0, to: selectors.count, by: Self.selectorsPerRule) {
                let chunk = selectors[batch..<min(batch + Self.selectorsPerRule, selectors.count)]
                cosmetic.append(["trigger": Self.domainTrigger(entry.variant, generic: false),
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
        if !genericList.isEmpty {
            // Pages with a `$document` exception get no hiding either.
            let list = genericList + pageExceptions
            if let data = try? JSONSerialization.data(withJSONObject: list), let json = String(data: data, encoding: .utf8) {
                lists.append(json)
                total += list.count
            }
        }
        var start = 0
        repeat {
            let chunk = shared[start..<min(start + room, shared.count)]
            let list = Array(chunk) + exceptions + important + pageExceptions
            // WebKit refuses an empty list (only generic hiding, which has its own, was given).
            if !list.isEmpty, let data = try? JSONSerialization.data(withJSONObject: list), let json = String(data: data, encoding: .utf8) {
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
