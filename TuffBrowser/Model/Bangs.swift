import AppKit
import Observation

/// A DuckDuckGo "!bang": a shortcut that sends a search straight to one site (`!yt cats`).
struct Bang: Codable, Equatable, Hashable {
    /// What follows the `!`, e.g. "yt".
    let trigger: String
    /// The site's name, e.g. "YouTube".
    let name: String
    /// Search URL with `{{{s}}}` where the query goes.
    let template: String
    /// The site's host, e.g. "www.youtube.com". A bang with no query opens it.
    let domain: String

    var homeURL: URL? { URL(string: "https://" + domain) }

    func url(for query: String) -> URL? {
        let q = query.trimmed
        guard !q.isEmpty else { return homeURL }
        // encodeURIComponent's set: the query can't break out of the path or the parameter.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        let encoded = q.addingPercentEncoding(withAllowedCharacters: allowed) ?? q
        return URL(string: template.replacingOccurrences(of: "{{{s}}}", with: encoded)) ?? homeURL
    }
}

/// A bang found in what was typed, and the search it applies to.
struct BangMatch: Equatable {
    enum Position { case leading, trailing }
    let bang: Bang
    /// What was typed, without the bang.
    let query: String
    let position: Position

    var url: URL? { bang.url(for: query) }
}

/// DuckDuckGo's list of bangs, kept on disk and refreshed weekly, plus a handful built in so
/// the common ones work on first launch and offline. Bangs resolve locally: the search goes
/// straight to the site, without a stop at DuckDuckGo.
@Observable
final class BangStore {
    static let shared = BangStore()

    private(set) var count = 0
    private(set) var updated: Date?
    private(set) var isUpdating = false
    private(set) var lastError: String?

    @ObservationIgnored private var bangs: [String: Bang] = [:]
    @ObservationIgnored private var loaded = false

    private static let sourceURL = URL(string: "https://duckduckgo.com/bang.js")!
    private static let maxAge: TimeInterval = 7 * 24 * 3600
    private var cacheFile: URL { Paths.caches.appendingPathComponent("bangs.json") }

    private init() {
        bangs = Dictionary(Self.builtIn.map { ($0.trigger, $0) }, uniquingKeysWith: { a, _ in a })
        count = bangs.count
    }

    /// Reads the cached list (off the main thread) and refreshes it when it is a week old.
    /// Cheap to call again: only the first call does anything.
    func prepare() {
        guard !loaded else { return }
        loaded = true
        let file = cacheFile
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let parsed = (try? Data(contentsOf: file)).flatMap(Self.parse)
            DispatchQueue.main.async {
                guard let self else { return }
                if let parsed { self.install(parsed, date: date) }
                if parsed == nil || date.map({ Date().timeIntervalSince($0) > Self.maxAge }) ?? true {
                    self.update()
                }
            }
        }
    }

    /// Downloads the list from DuckDuckGo now.
    func update() {
        guard !isUpdating else { return }
        isUpdating = true
        lastError = nil
        var request = URLRequest(url: Self.sourceURL)
        request.timeoutInterval = 30
        let file = cacheFile
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            let parsed = ok ? data.flatMap(Self.parse) : nil
            if let data, parsed != nil { try? data.write(to: file, options: .atomic) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isUpdating = false
                if let parsed {
                    self.install(parsed, date: Date())
                } else {
                    self.lastError = error?.localizedDescription ?? "DuckDuckGo’s list couldn’t be read."
                }
            }
        }.resume()
    }

    private func install(_ list: [Bang], date: Date?) {
        var all = Dictionary(list.map { ($0.trigger, $0) }, uniquingKeysWith: { a, _ in a })
        for bang in Self.builtIn where all[bang.trigger] == nil { all[bang.trigger] = bang }
        bangs = all
        count = all.count
        updated = date
    }

    /// DuckDuckGo's format: `[{"t": trigger, "s": name, "u": template, "d": domain, …}, …]`.
    private static func parse(_ data: Data) -> [Bang]? {
        struct Raw: Decodable { let t: String; let s: String; let u: String; let d: String }
        guard let raw = try? JSONDecoder().decode([Raw].self, from: data), raw.count > 100 else { return nil }
        return raw.map { Bang(trigger: $0.t.lowercased(), name: $0.s, template: $0.u, domain: $0.d) }
    }

    func bang(for trigger: String) -> Bang? {
        prepare()
        return bangs[trigger.lowercased()]
    }

    /// The bang token at the start (`!yt cats`) or end (`cats !yt`) of what was typed.
    func match(_ input: String) -> BangMatch? {
        let tokens = input.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return nil }
        if let bang = bang(fromToken: tokens[0]) {
            return BangMatch(bang: bang, query: tokens.dropFirst().joined(separator: " "), position: .leading)
        }
        if tokens.count > 1, let bang = bang(fromToken: tokens[tokens.count - 1]) {
            return BangMatch(bang: bang, query: tokens.dropLast().joined(separator: " "), position: .trailing)
        }
        return nil
    }

    /// A leading bang finished with a space (`"!yt "`), ready to become a chip, and the rest.
    func leadingToken(_ input: String) -> (bang: Bang, rest: String)? {
        guard input.hasPrefix("!"),
              let space = input.firstIndex(where: \.isWhitespace),
              let bang = bang(fromToken: String(input[..<space])) else { return nil }
        let rest = input[space...].drop(while: \.isWhitespace)
        return (bang, String(rest))
    }

    private func bang(fromToken token: String) -> Bang? {
        guard token.count > 1, token.hasPrefix("!") else { return nil }
        return bang(for: String(token.dropFirst()))
    }

    /// The URL a typed search goes to, when it carries a bang and the Bangs mod is on.
    static func resolve(_ input: String) -> URL? {
        guard AppSettings.shared.mods.bangs else { return nil }
        return shared.match(input)?.url
    }

    // MARK: Built in

    static let builtIn: [Bang] = [
        Bang(trigger: "g", name: "Google", template: "https://www.google.com/search?q={{{s}}}", domain: "www.google.com"),
        Bang(trigger: "gi", name: "Google Images", template: "https://www.google.com/search?tbm=isch&q={{{s}}}", domain: "www.google.com"),
        Bang(trigger: "gm", name: "Google Maps", template: "https://www.google.com/maps/search/{{{s}}}", domain: "www.google.com"),
        Bang(trigger: "maps", name: "Google Maps", template: "https://www.google.com/maps/search/{{{s}}}", domain: "www.google.com"),
        Bang(trigger: "ddg", name: "DuckDuckGo", template: "https://duckduckgo.com/?q={{{s}}}", domain: "duckduckgo.com"),
        Bang(trigger: "yt", name: "YouTube", template: "https://www.youtube.com/results?search_query={{{s}}}", domain: "www.youtube.com"),
        Bang(trigger: "w", name: "Wikipedia", template: "https://en.wikipedia.org/wiki/Special:Search?search={{{s}}}", domain: "en.wikipedia.org"),
        Bang(trigger: "gh", name: "GitHub", template: "https://github.com/search?q={{{s}}}", domain: "github.com"),
        Bang(trigger: "a", name: "Amazon", template: "https://www.amazon.com/s?k={{{s}}}", domain: "www.amazon.com"),
        Bang(trigger: "r", name: "Reddit", template: "https://www.reddit.com/search?q={{{s}}}", domain: "www.reddit.com"),
        Bang(trigger: "x", name: "X", template: "https://x.com/search?q={{{s}}}", domain: "x.com"),
        Bang(trigger: "so", name: "Stack Overflow", template: "https://stackoverflow.com/search?q={{{s}}}", domain: "stackoverflow.com"),
        Bang(trigger: "mdn", name: "MDN", template: "https://developer.mozilla.org/search?q={{{s}}}", domain: "developer.mozilla.org"),
        Bang(trigger: "npm", name: "npm", template: "https://www.npmjs.com/search?q={{{s}}}", domain: "www.npmjs.com"),
        Bang(trigger: "imdb", name: "IMDb", template: "https://www.imdb.com/find?q={{{s}}}", domain: "www.imdb.com"),
        Bang(trigger: "spotify", name: "Spotify", template: "https://open.spotify.com/search/{{{s}}}", domain: "open.spotify.com"),
        Bang(trigger: "wa", name: "Wolfram Alpha", template: "https://www.wolframalpha.com/input/?i={{{s}}}", domain: "www.wolframalpha.com"),
        Bang(trigger: "t", name: "Thesaurus.com", template: "https://www.thesaurus.com/browse/{{{s}}}", domain: "www.thesaurus.com"),
        Bang(trigger: "d", name: "Dictionary.com", template: "https://www.dictionary.com/browse/{{{s}}}", domain: "www.dictionary.com"),
        Bang(trigger: "kagi", name: "Kagi", template: "https://kagi.com/search?q={{{s}}}", domain: "kagi.com"),
        Bang(trigger: "pplx", name: "Perplexity", template: "https://www.perplexity.ai/search?q={{{s}}}", domain: "www.perplexity.ai"),
        Bang(trigger: "hn", name: "Hacker News", template: "https://hn.algolia.com/?q={{{s}}}", domain: "news.ycombinator.com"),
    ]
}
