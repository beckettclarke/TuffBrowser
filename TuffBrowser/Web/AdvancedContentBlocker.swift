import Foundation
import WebKit

/// The part of the built-in blocker that WebKit content rule lists cannot express: page-world
/// scriptlets, isolated-world scriptlets and procedural cosmetic filters. The scripts are the
/// maintained, precompiled uBlock Origin Lite rulesets, downloaded and cached like filter lists.
final class AdvancedContentBlocker {
    struct Sources {
        var main: String
        var isolated: String
        var cosmetic: String
    }

    private var sources: Sources?
    private var scripts: [WKUserScript] = []
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private let skipped = NSHashTable<WKUserContentController>.weakObjects()
    private var started = false
    private var folder: URL?
    private var settingsKey = ""

    private var enabled: Bool { AppSettings.shared.privacy.blockAds }
    private var isolatedWorld: WKContentWorld { .world(name: "Tuff content blocker") }

    func start(in folder: URL) {
        guard !started else { return }
        started = true
        self.folder = folder
        guard let sources = Self.read(from: folder) else { return }
        self.sources = sources
        rebuildScripts()
    }

    func attach(_ controller: WKUserContentController) {
        controllers.add(controller)
        guard enabled, !skipped.contains(controller) else { return }
        scripts.forEach(controller.addUserScript)
    }

    func prepare(_ controller: WKUserContentController, for url: URL) {
        guard enabled else { return }
        let allowed = ContentBlocker.shared.isAllowed(host: url.host)
        if allowed, !skipped.contains(controller) {
            scripts.forEach { remove($0, from: controller) }
            skipped.add(controller)
        } else if !allowed, skipped.contains(controller) {
            scripts.forEach(controller.addUserScript)
            skipped.remove(controller)
        }
    }

    func settingsChanged() {
        let key = "\(enabled)|\(AppSettings.shared.privacy.adBlockAllowlist.joined(separator: ","))"
        guard key != settingsKey else { return }
        if !enabled { skipped.removeAllObjects() }
        rebuildScripts()
    }

    func activate(_ sources: Sources) {
        self.sources = sources
        settingsKey = ""
        rebuildScripts()
        if let folder { Self.save(sources, to: folder) }
        ExtensionManager.shared.trace("blocker: advanced scripts active (main \(sources.main.count), isolated \(sources.isolated.count), cosmetic \(sources.cosmetic.count) chars)")
    }

    private func rebuildScripts() {
        for controller in controllers.allObjects {
            for script in scripts { remove(script, from: controller) }
        }
        scripts = []
        settingsKey = "\(enabled)|\(AppSettings.shared.privacy.adBlockAllowlist.joined(separator: ","))"
        guard enabled, let sources else { return }
        let guardPrefix = Self.allowlistGuard(AppSettings.shared.privacy.adBlockAllowlist)
        #if DEBUG
        let disabled = Set((ProcessInfo.processInfo.environment["TUFF_BLOCKER_DISABLE"] ?? "").split(separator: ",").map(String.init))
        #endif
        scripts = [
            (name: "main", source: sources.main, world: WKContentWorld.page),
            (name: "isolated", source: sources.isolated, world: isolatedWorld),
            (name: "cosmetic", source: sources.cosmetic, world: isolatedWorld),
        ].filter { entry in
            if entry.source.isEmpty { return false }
            #if DEBUG
            if disabled.contains(entry.name) { return false }
            #endif
            return true
        }.map { entry in
            WKUserScript(
                source: guardPrefix + entry.source + "\n})();\n", injectionTime: .atDocumentStart,
                forMainFrameOnly: false, in: entry.world
            )
        }
        for controller in controllers.allObjects where !skipped.contains(controller) {
            scripts.forEach(controller.addUserScript)
        }
    }

    private func remove(_ script: WKUserScript, from controller: WKUserContentController) {
        guard controller.responds(to: Self.removeSelector) else { return }
        controller.perform(Self.removeSelector, with: script)
    }

    private static let removeSelector = NSSelectorFromString("_removeUserScript:")

    private static func allowlistGuard(_ hosts: [String]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: hosts.map { $0.lowercased() })
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        (() => {
        if (!/^https?:$/.test(location.protocol)) return;
        const allowed = \(json);
        let hostname = location.hostname.toLowerCase();
        try {
          const origins = document.location.ancestorOrigins;
          if (origins && origins.length) hostname = new URL(origins[origins.length - 1]).hostname.toLowerCase();
        } catch (e) {}
        for (const domain of allowed) {
          if (hostname === domain || hostname.endsWith('.' + domain)) return;
        }

        """
    }

    // MARK: Cached sources

    private static func read(from folder: URL) -> Sources? {
        func read(_ name: String) -> String? {
            try? String(contentsOf: folder.appendingPathComponent(name + ".js"), encoding: .utf8)
        }
        guard let main = read("main"), let isolated = read("isolated"), let cosmetic = read("cosmetic") else { return nil }
        return Sources(main: main, isolated: isolated, cosmetic: cosmetic)
    }

    private static func save(_ sources: Sources, to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, source) in [("main", sources.main), ("isolated", sources.isolated), ("cosmetic", sources.cosmetic)] {
            try? source.write(to: folder.appendingPathComponent(name + ".js"), atomically: true, encoding: .utf8)
        }
    }

    // MARK: uBO Lite's maintained filtering scripts

    private static let root = "https://raw.githubusercontent.com/uBlockOrigin/uBOL-home/main/chromium/"
    private static let rulesetIDs = ["ublock-filters", "easyprivacy", "easylist", "ublock-badware", "ublock-unbreak"]

    static func download() async -> Sources? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let scriptletData = await fetch("rulesets/scriptlet-details.json", session: session),
              let rulesetData = await fetch("rulesets/ruleset-details.json", session: session),
              let availability = scriptletAvailability(scriptletData),
              let specific = specificRulesets(rulesetData) else { return nil }

        async let main = downloadWorld("main", available: availability["MAIN"] ?? [], session: session)
        async let isolated = downloadWorld("isolated", available: availability["ISOLATED"] ?? [], session: session)
        async let cosmetic = downloadCosmetic(specific: specific, session: session)
        guard let mainSource = await main, let isolatedSource = await isolated, let cosmeticSource = await cosmetic else { return nil }
        return Sources(main: mainSource, isolated: isolatedSource, cosmetic: cosmeticSource)
    }

    private static func fetch(_ path: String, session: URLSession) async -> Data? {
        guard let url = URL(string: root + path) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.setValue("Tuff", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              !data.isEmpty, data.count < 20_000_000 else { return nil }
        return data
    }

    private static func scriptletAvailability(_ data: Data) -> [String: Set<String>]? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return nil }
        var result: [String: Set<String>] = [:]
        for entry in entries {
            guard entry.count == 2, let id = entry[0] as? String,
                  let worlds = entry[1] as? [String: Any] else { continue }
            for world in ["MAIN", "ISOLATED"] {
                if let hosts = worlds[world] as? [String], !hosts.isEmpty {
                    result[world, default: []].insert(id)
                }
            }
        }
        return result
    }

    private static func specificRulesets(_ data: Data) -> Set<String>? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return Set(entries.compactMap { entry in
            guard let id = entry["id"] as? String, rulesetIDs.contains(id),
                  let css = entry["css"] as? [String: Any],
                  let count = css["specific"] as? Int, count > 0 else { return nil }
            return id
        })
    }

    private static func downloadWorld(_ world: String, available: Set<String>, session: URLSession) async -> String? {
        let base = "rulesets/scripting/scriptlet/\(world)/"
        guard let beginData = await fetch(base + "scriptlet-begin.js", session: session),
              let endData = await fetch(base + "scriptlet-end.js", session: session),
              let begin = String(data: beginData, encoding: .utf8),
              let end = String(data: endData, encoding: .utf8),
              begin.contains("scriptletGlobals.functionRefs"), end.contains("scriptletFrameworkEnd") else { return nil }
        var parts = [begin]
        for id in rulesetIDs where available.contains(id) {
            guard let data = await fetch(base + id + ".js", session: session),
                  let source = String(data: data, encoding: .utf8), source.contains("const arglists") else { return nil }
            parts.append(source)
        }
        parts.append(end)
        let secrets = parts.compactMap(scriptletSecret)
        guard parts.count > 2, secrets.count == parts.count, Set(secrets).count == 1 else { return nil }
        return compactingDataLiterals(parts.joined(separator: "\n"))
    }

    /// These scripts run in every frame of every page, and most of their bulk is data: arrays of
    /// thousands of hostnames and arguments (`const scriptletHostnames = /* 14236 */ ["*", …];`).
    /// JavaScriptCore turns each element of an array literal into a node of its own, twice (a
    /// syntax check when the script is read, a full parse when the function runs), for every
    /// frame. The same array as one JSON string handed to `JSON.parse` is a single token to the
    /// parser, and only built if the code reaches it. Only lines that are plain JSON change.
    static func compactingDataLiterals(_ source: String) -> String {
        var changed = false
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard line.count > 2048, let replacement = compactDataLine(line) else { return line }
            changed = true
            return Substring(replacement)
        }
        return changed ? lines.joined(separator: "\n") : source
    }

    /// `const name = /* count */ [json];` → `const name = /* count */ JSON.parse("json");`
    private static func compactDataLine(_ line: Substring) -> String? {
        guard let declaration = line.range(of: #"^\s*const [A-Za-z_$][\w$]* = (/\* \d+ \*/ )?"#, options: .regularExpression),
              line.hasSuffix("];") else { return nil }
        let literal = line[declaration.upperBound..<line.index(before: line.endIndex)]
        guard literal.first == "[",
              let data = literal.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              array.allSatisfy({ $0 is String || $0 is NSNumber }),
              let encoded = try? JSONSerialization.data(withJSONObject: String(literal), options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let string = String(data: encoded, encoding: .utf8) else { return nil }
        return line[..<declaration.upperBound] + "JSON.parse(" + string + ");"
    }

    private static func scriptletSecret(_ source: String) -> String? {
        guard let start = source.range(of: "})(\"", options: .backwards)?.upperBound,
              let end = source[start...].firstIndex(of: "\"") else { return nil }
        return String(source[start..<end])
    }

    private static func downloadCosmetic(specific: Set<String>, session: URLSession) async -> String? {
        guard let apiData = await fetch("js/scripting/css-procedural-api.js", session: session),
              let api = String(data: apiData, encoding: .utf8), api.contains("self.ProceduralFiltererAPI") else { return nil }
        var sets: [String] = []
        for id in rulesetIDs where specific.contains(id) {
            guard let data = await fetch("rulesets/scripting/specific/\(id).json", session: session),
                  let filtered = proceduralOnly(data) else { return nil }
            if filtered.isEmpty { continue }
            sets.append(filtered)
        }
        return cosmeticScript(api: api, dataSets: sets)
    }

    /// Drops ordinary selectors (already handled natively) and reindexes the compressed selector
    /// lists so the remaining procedural filters keep their exact per-host exceptions.
    static func proceduralOnly(_ data: Data) -> String? {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let selectors = object["selectors"] as? [String],
              let lists = object["selectorLists"] as? [String] else { return nil }
        var remap: [Int: Int] = [:]
        var kept: [String] = []
        for (index, selector) in selectors.enumerated() where selector.hasPrefix("{") {
            remap[index] = kept.count
            kept.append(selector)
        }
        guard !kept.isEmpty else { return "" }
        let remapped = lists.map { list in
            list.split(separator: ",").compactMap { token -> String? in
                guard let ref = Int(token) else { return nil }
                let old = ref < 0 ? ~ref : ref
                guard let new = remap[old] else { return nil }
                return String(ref < 0 ? ~new : new)
            }.joined(separator: ",")
        }
        object["selectors"] = kept
        object["selectorLists"] = remapped
        guard let output = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: output, encoding: .utf8)
    }

    /// What the cosmetic script looks up, worked out once here instead of in every frame: the
    /// rulesets' hostname → selector-list indirection resolved and merged into one table.
    struct CosmeticIndex: Equatable {
        /// Procedural filters (uBO's JSON), each once.
        var selectors: [String] = []
        /// Hostname or entity (`example.*`) → selector indices; an exception is stored as `~index`.
        var hosts: [String: [Int]] = [:]
        /// Hostname substring, regex, selector indices.
        var regexes: [(needle: String, pattern: String, refs: [Int])] = []

        static func == (a: Self, b: Self) -> Bool {
            a.selectors == b.selectors && a.hosts == b.hosts
                && a.regexes.map { "\($0.needle)\t\($0.pattern)\t\($0.refs)" } == b.regexes.map { "\($0.needle)\t\($0.pattern)\t\($0.refs)" }
        }
    }

    /// Merges uBO Lite's per-ruleset data (as `proceduralOnly` leaves it).
    static func cosmeticIndex(_ dataSets: [String]) -> CosmeticIndex {
        var index = CosmeticIndex()
        var position: [String: Int] = [:]
        func number(_ value: Any?) -> Int? {
            if let n = value as? Int { return n }
            if let s = value as? String { return Int(s) }
            return nil
        }
        for text in dataSets {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  let selectors = object["selectors"] as? [String],
                  let lists = object["selectorLists"] as? [String] else { continue }
            // One ruleset's list (by index) → signed indices into the merged selectors.
            func refs(_ listIndex: Int?) -> [Int] {
                guard let listIndex, lists.indices.contains(listIndex) else { return [] }
                return lists[listIndex].split(separator: ",").compactMap { token -> Int? in
                    guard let local = Int(token) else { return nil }
                    let exception = local < 0
                    let slot = exception ? ~local : local
                    guard selectors.indices.contains(slot) else { return nil }
                    let selector = selectors[slot]
                    let merged: Int
                    if let known = position[selector] {
                        merged = known
                    } else {
                        merged = index.selectors.count
                        position[selector] = merged
                        index.selectors.append(selector)
                    }
                    return exception ? ~merged : merged
                }
            }
            let hostnames = object["hostnames"] as? [String] ?? []
            let listRefs = object["selectorListRefs"] as? [Any] ?? []
            for (i, host) in hostnames.enumerated() where i < listRefs.count {
                guard !host.isEmpty, !host.contains("\n"), !host.contains("\t") else { continue }
                let found = refs(number(listRefs[i]))
                if !found.isEmpty { index.hosts[host, default: []].append(contentsOf: found) }
            }
            let regexes = object["regexes"] as? [Any] ?? []
            for i in stride(from: 0, to: regexes.count - 2, by: 3) {
                guard let needle = regexes[i] as? String, let pattern = regexes[i + 1] as? String else { continue }
                let found = refs(number(regexes[i + 2]))
                if !found.isEmpty { index.regexes.append((needle, pattern, found)) }
            }
        }
        return index
    }

    /// The isolated-world script that applies the procedural filters for the frame's host.
    ///
    /// It runs in every frame, and most frames have no such filters, so it is kept light: the
    /// table is one string searched for `\nhost\t`, the filters stay a JSON string until a host
    /// matches, and uBO's procedural engine is only evaluated then.
    static func cosmeticScript(api: String, dataSets: [String]) -> String {
        let index = cosmeticIndex(dataSets)
        func jsString(_ text: String) -> String {
            let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        }
        func json(_ value: Any) -> String {
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        func refs(_ list: [Int]) -> String { list.map(String.init).joined(separator: ",") }
        var table = "\n"
        for host in index.hosts.keys.sorted() {
            table += host + "\t" + refs(index.hosts[host]!) + "\n"
        }
        let regexes = index.regexes.flatMap { [$0.needle, $0.pattern, refs($0.refs)] }
        return """
        (() => {
        const table = \(jsString(table));
        const regexes = \(json(regexes));
        const hostname = location.hostname.toLowerCase();
        if (!hostname) return;
        const hostnames = [hostname];
        for (let pos = hostname.indexOf('.'); pos !== -1; pos = hostname.indexOf('.', pos + 1)) {
          hostnames.push(hostname.slice(pos + 1));
        }
        hostnames.push('*');
        const needles = hostnames.slice();
        for (const hn of hostnames) {
          let value = hn;
          for (;;) {
            const pos = value.lastIndexOf('.');
            if (pos === -1) break;
            value = value.slice(0, pos);
            needles.push(value + '.*');
          }
        }
        let refs = '';
        const add = (list) => { if (list) refs += (refs ? ',' : '') + list; };
        for (const needle of needles) {
          const key = '\\n' + needle + '\\t';
          const at = table.indexOf(key);
          if (at === -1) continue;
          const start = at + key.length;
          add(table.slice(start, table.indexOf('\\n', start)));
        }
        for (let i = 0; i < regexes.length; i += 3) {
          try {
            if (hostname.includes(regexes[i]) && new RegExp(regexes[i + 1]).test(hostname)) add(regexes[i + 2]);
          } catch (e) {}
        }
        if (!refs) return;
        const selectors = JSON.parse(\(jsString(json(index.selectors))));
        const selected = new Set();
        const exceptions = new Set();
        for (const token of refs.split(',')) {
          const ref = Number(token);
          const selector = selectors[ref < 0 ? ~ref : ref];
          if (selector === undefined) continue;
          (ref < 0 ? exceptions : selected).add(selector);
        }
        for (const selector of exceptions) selected.delete(selector);
        const filters = [];
        for (const encoded of selected) {
          try { filters.push(JSON.parse(encoded)); } catch (e) {}
        }
        if (!filters.length) return;
        if (!self.chrome) self.chrome = { dom: {}, runtime: { sendMessage: () => Promise.resolve() } };
        self.cssAPI = { insert(css) {
          try {
            const sheet = new CSSStyleSheet();
            sheet.replaceSync(css);
            document.adoptedStyleSheets.push(sheet);
          } catch (e) {
            const style = document.createElement('style');
            style.textContent = css;
            (document.head || document.documentElement).appendChild(style);
          }
        }};
        (() => {
        \(api)
        })();
        if (typeof self.ProceduralFiltererAPI !== 'function') return;
        const filterer = new self.ProceduralFiltererAPI();
        const declaratives = filters.filter(filter => filter.cssable);
        const procedurals = filters.filter(filter => !filter.cssable);
        if (declaratives.length) filterer.addDeclaratives(declaratives);
        if (procedurals.length) filterer.addProcedurals(procedurals);
        })();
        """
    }
}
