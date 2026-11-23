import AppKit
import Observation
import WebKit

// MARK: - chrome.contentSettings

/// `chrome.contentSettings`, on Tuff's per-site settings: JavaScript and pop-ups
/// (`SiteSettings`, by host), and camera, microphone, location and notifications
/// (`SitePermissions`, by origin). Patterns name one site (`https://*.example.com/*`), or every
/// site (`<all_urls>`, `*://*/*`) for JavaScript and pop-ups, which then changes Settings →
/// Privacy. The other content types report what Tuff does and can't be changed.
///
/// What an extension sets is kept in Tuff's own settings (and shows in Settings → Websites);
/// `clear`, or the extension being turned off or removed, takes it back out.
final class ExtensionContentSettings {
    static let shared = ExtensionContentSettings()

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// One change an extension made, to undo on `clear`.
    private struct Change: Codable, Hashable {
        var type: String
        /// The host (site settings), origin (permissions), or "*" for the global setting.
        var key: String
        var incognito: Bool
        /// The global setting's value before (only for key "*").
        var previous: Bool?
        /// The global string setting's value before (only for key "*" on string-typed settings).
        var previousString: String?
    }

    private var changes: [String: [Change]] = [:]
    private let file = Paths.appSupport.appendingPathComponent("extension-content-settings.json")

    private init() {
        if let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode([String: [Change]].self, from: data) {
            changes = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(changes) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private static let permissionKinds: [String: SitePermissionKind] = [
        "location": .location, "notifications": .notifications, "camera": .camera, "microphone": .microphone,
    ]
    /// What Tuff does for the types it has no per-site setting for.
    private static let fixedSettings: [String: String] = [
        "plugins": "block", "unsandboxedPlugins": "block",
        "autoVerify": "allow",
    ]

    func get(type: String, args: [String: Any]) throws -> [String: Any] {
        let incognito = args["incognito"] as? Bool ?? false
        guard let string = args["primaryUrl"] as? String, let url = URL(string: string) else {
            throw Failure("primaryUrl is required.")
        }
        let privacy = AppSettings.shared.privacy
        switch type {
        case "javascript":
            let allowed = SiteSettings.shared.entry(for: url, incognito: incognito).javaScript ?? privacy.javaScript
            return ["setting": allowed ? "allow" : "block"]
        case "popups":
            let allowed = SiteSettings.shared.entry(for: url, incognito: incognito).popups ?? !privacy.blockPopups
            return ["setting": allowed ? "allow" : "block"]
        case "sound":
            let allowed = SiteSettings.shared.soundAllowed(for: url, incognito: incognito)
            return ["setting": allowed ? "allow" : "block"]
        case "images":
            let allowed = SiteSettings.shared.imagesAllowed(for: url, incognito: incognito)
            return ["setting": allowed ? "allow" : "block"]
        case "cookies":
            return ["setting": SiteSettings.shared.cookiesSetting(for: url, incognito: incognito)]
        case "automaticDownloads":
            return ["setting": SiteSettings.shared.automaticDownloadsSetting(for: url, incognito: incognito)]
        case "clipboard":
            return ["setting": SiteSettings.shared.clipboardSetting(for: url, incognito: incognito)]
        default:
            if let kind = Self.permissionKinds[type] {
                let answer = Self.origin(of: url).flatMap { SitePermissions.shared.decision(origin: $0, kind: kind, incognito: incognito) }
                return ["setting": answer.map { $0 ? "allow" : "block" } ?? "ask"]
            }
            if let setting = Self.fixedSettings[type] { return ["setting": setting] }
            throw Failure("Unknown content type: \(type).")
        }
    }

    func set(type: String, args: [String: Any], extensionID: String) throws {
        guard let pattern = args["primaryPattern"] as? String else { throw Failure("primaryPattern is required.") }
        guard let setting = args["setting"] as? String else { throw Failure("setting is required.") }
        let incognito = (args["scope"] as? String) == "incognito_session_only"
        let site = try Self.parse(pattern)

        switch type {
        case "javascript", "popups", "sound", "images":
            guard setting == "allow" || setting == "block" else { throw Failure("Tuff can’t use “\(setting)” for \(type).") }
            let allow = setting == "allow"
            if site == nil {
                guard !incognito else { throw Failure("Every-site settings can’t be limited to Incognito.") }
                if type == "sound" {
                    let previous = SiteSettings.shared.defaultSound ?? true
                    SiteSettings.shared.defaultSound = allow
                    record(Change(type: type, key: "*", incognito: false, previous: previous), extensionID: extensionID)
                    Self.applySoundToOpenTabs()
                } else if type == "images" {
                    let previous = SiteSettings.shared.defaultImages ?? true
                    SiteSettings.shared.defaultImages = allow
                    record(Change(type: type, key: "*", incognito: false, previous: previous), extensionID: extensionID)
                } else {
                    var privacy = AppSettings.shared.privacy
                    let previous = type == "javascript" ? privacy.javaScript : !privacy.blockPopups
                    if type == "javascript" { privacy.javaScript = allow } else { privacy.blockPopups = !allow }
                    AppSettings.shared.privacy = privacy
                    record(Change(type: type, key: "*", incognito: false, previous: previous), extensionID: extensionID)
                }
            } else if let site {
                SiteSettings.shared.update(key: site.key, incognito: incognito) { entry in
                    if type == "javascript" { entry.javaScript = allow }
                    else if type == "popups" { entry.popups = allow }
                    else if type == "sound" { entry.sound = allow }
                    else { entry.images = allow }
                }
                record(Change(type: type, key: site.key, incognito: incognito), extensionID: extensionID)
                if type == "sound" { Self.applySoundToOpenTabs() }
                if type == "images" { SiteSettings.shared.rebuildContentRules() }
            }
        case "cookies":
            guard ["allow", "block", "session_only"].contains(setting) else {
                throw Failure("Tuff can’t use “\(setting)” for cookies.")
            }
            if site == nil {
                guard !incognito else { throw Failure("Every-site settings can’t be limited to Incognito.") }
                let previous = SiteSettings.shared.defaultCookies ?? "allow"
                SiteSettings.shared.defaultCookies = setting
                record(Change(type: type, key: "*", incognito: false, previousString: previous), extensionID: extensionID)
            } else if let site {
                SiteSettings.shared.update(key: site.key, incognito: incognito) { entry in
                    entry.cookies = setting
                }
                record(Change(type: type, key: site.key, incognito: incognito), extensionID: extensionID)
                SiteSettings.shared.rebuildContentRules()
            }
        case "automaticDownloads":
            guard ["allow", "block", "ask"].contains(setting) else {
                throw Failure("Tuff can’t use “\(setting)” for automaticDownloads.")
            }
            if site == nil {
                guard !incognito else { throw Failure("Every-site settings can’t be limited to Incognito.") }
                let previous = SiteSettings.shared.defaultAutomaticDownloads ?? "ask"
                SiteSettings.shared.defaultAutomaticDownloads = setting
                record(Change(type: type, key: "*", incognito: false, previousString: previous), extensionID: extensionID)
            } else if let site {
                SiteSettings.shared.update(key: site.key, incognito: incognito) { entry in
                    entry.automaticDownloads = setting
                }
                record(Change(type: type, key: site.key, incognito: incognito), extensionID: extensionID)
            }
        case "clipboard":
            guard ["allow", "block", "ask"].contains(setting) else {
                throw Failure("Tuff can’t use “\(setting)” for clipboard.")
            }
            if site == nil {
                guard !incognito else { throw Failure("Every-site settings can’t be limited to Incognito.") }
                let previous = SiteSettings.shared.defaultClipboard ?? "ask"
                SiteSettings.shared.defaultClipboard = setting
                record(Change(type: type, key: "*", incognito: false, previousString: previous), extensionID: extensionID)
            } else if let site {
                SiteSettings.shared.update(key: site.key, incognito: incognito) { entry in
                    entry.clipboard = setting
                }
                record(Change(type: type, key: site.key, incognito: incognito), extensionID: extensionID)
                SiteSettings.shared.rebuildClipboardScript()
            }
        default:
            guard let kind = Self.permissionKinds[type] else {
                if Self.fixedSettings[type] != nil { throw Failure("\(type) can’t be changed per site in Tuff.") }
                throw Failure("Unknown content type: \(type).")
            }
            guard let site else { throw Failure("\(type) can only be set for a site, not every site.") }
            let origin = site.key + (site.port == nil ? ":*" : "")
            switch setting {
            case "allow", "block":
                SitePermissions.shared.record(origin: origin, kind: kind, granted: setting == "allow", remember: true, incognito: incognito)
            case "ask":
                forget(origin: origin, kind: kind, incognito: incognito)
            default:
                throw Failure("Tuff can’t use “\(setting)” for \(type).")
            }
            record(Change(type: type, key: origin, incognito: incognito), extensionID: extensionID)
        }
    }

    func clear(type: String, extensionID: String) {
        let mine = changes[extensionID] ?? []
        for change in mine where change.type == type { undo(change) }
        changes[extensionID] = mine.filter { $0.type != type }
        if changes[extensionID]?.isEmpty == true { changes[extensionID] = nil }
        save()
    }

    func extensionRemoved(_ extensionID: String) {
        guard let mine = changes.removeValue(forKey: extensionID) else { return }
        mine.forEach(undo)
        save()
    }

    private func record(_ change: Change, extensionID: String) {
        var list = changes[extensionID] ?? []
        // The first "before" is the one to go back to.
        if !list.contains(where: { $0.type == change.type && $0.key == change.key && $0.incognito == change.incognito }) {
            list.append(change)
        }
        changes[extensionID] = list
        save()
    }

    private func undo(_ change: Change) {
        switch change.type {
        case "javascript", "popups", "sound", "images":
            if change.key == "*" {
                guard let previous = change.previous else { return }
                if change.type == "sound" {
                    SiteSettings.shared.defaultSound = previous ? nil : false
                    Self.applySoundToOpenTabs()
                } else if change.type == "images" {
                    SiteSettings.shared.defaultImages = previous ? nil : false
                } else {
                    var privacy = AppSettings.shared.privacy
                    if change.type == "javascript" { privacy.javaScript = previous } else { privacy.blockPopups = !previous }
                    AppSettings.shared.privacy = privacy
                }
            } else {
                SiteSettings.shared.update(key: change.key, incognito: change.incognito) { entry in
                    if change.type == "javascript" { entry.javaScript = nil }
                    else if change.type == "popups" { entry.popups = nil }
                    else if change.type == "sound" { entry.sound = nil }
                    else { entry.images = nil }
                }
                if change.type == "sound" { Self.applySoundToOpenTabs() }
                if change.type == "images" { SiteSettings.shared.rebuildContentRules() }
            }
        case "cookies":
            if change.key == "*" {
                let prev = change.previousString ?? "allow"
                SiteSettings.shared.defaultCookies = prev == "allow" ? nil : prev
            } else {
                SiteSettings.shared.update(key: change.key, incognito: change.incognito) { $0.cookies = nil }
                SiteSettings.shared.rebuildContentRules()
            }
        case "automaticDownloads":
            if change.key == "*" {
                let prev = change.previousString ?? "ask"
                SiteSettings.shared.defaultAutomaticDownloads = prev == "ask" ? nil : prev
            } else {
                SiteSettings.shared.update(key: change.key, incognito: change.incognito) { $0.automaticDownloads = nil }
            }
        case "clipboard":
            if change.key == "*" {
                let prev = change.previousString ?? "ask"
                SiteSettings.shared.defaultClipboard = prev == "ask" ? nil : prev
            } else {
                SiteSettings.shared.update(key: change.key, incognito: change.incognito) { $0.clipboard = nil }
                SiteSettings.shared.rebuildClipboardScript()
            }
        default:
            if let kind = Self.permissionKinds[change.type] { forget(origin: change.key, kind: kind, incognito: change.incognito) }
        }
    }

    private static func applySoundToOpenTabs() {
        for tab in BrowserState.shared.allTabs { tab.applySiteSound() }
    }

    private func forget(origin: String, kind: SitePermissionKind, incognito: Bool = false) {
        for granted in [true, false] {
            SitePermissions.shared.remove(SitePermissions.Entry(origin: origin, kind: kind, granted: granted), incognito: incognito)
        }
    }

    private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        let port = url.port.flatMap { explicit in
            explicit != (scheme == "https" ? 443 : 80) ? ":\(explicit)" : nil
        } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    /// The site a content-settings pattern names, or nil for every site.
    static func parse(_ pattern: String) throws -> ContentSettingPattern? {
        if pattern == "<all_urls>" { return nil }
        guard let parsed = ContentSettingPattern(pattern: pattern) else {
            throw Failure("Tuff can’t use the pattern “\(pattern)”.")
        }
        return parsed.isGlobal ? nil : parsed
    }
}

// MARK: - Firefox browser.theme

/// Firefox's `browser.theme` on Tuff's window chrome: an extension's theme colours, background
/// images (`theme_frame`, `headerURL`, `additional_backgrounds`), and layout properties
/// (`additional_backgrounds_alignment`, `additional_backgrounds_tiling`, `color_scheme`) apply
/// over the user's own tint and space colours until reset or disabled.
@Observable
final class ExtensionTheme {
    static let shared = ExtensionTheme()

    struct BackgroundLayer: Equatable {
        let image: NSImage
        let alignment: String
        let tiling: String
    }

    /// The tint an extension's theme sets, if any.
    private(set) var tint: NSColor?
    /// Header / frame background image (`images.theme_frame` / `images.headerURL`).
    private(set) var headerImage: NSImage?
    /// Additional layered background images with alignment & tiling properties.
    private(set) var additionalLayers: [BackgroundLayer] = []
    /// Preferred color scheme (`"light"`, `"dark"`, `"system"`), if set in `properties.color_scheme`.
    private(set) var colorScheme: String?
    @ObservationIgnored private var owner: String?
    @ObservationIgnored private var theme: [String: Any]?

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    func current() -> [String: Any] {
        if let theme { return theme }
        let state = BrowserState.shared
        let tint = state.baseTint
        let text = tint.luminance < 0.55 ? "#ffffff" : "#000000"
        return [
            "colors": [
                "frame": tint.hexString, "toolbar": tint.hexString,
                "tab_background_text": text, "toolbar_text": text, "toolbar_field_text": text,
            ],
            "images": [String: Any](),
            "properties": [String: Any](),
        ]
    }

    func update(_ theme: [String: Any], extensionID: String, resources: URL? = nil) throws {
        let colors = theme["colors"] as? [String: Any] ?? [:]
        let images = theme["images"] as? [String: Any] ?? [:]
        let properties = theme["properties"] as? [String: Any] ?? [:]

        let colorValue = colors["frame"] ?? colors["accentcolor"] ?? colors["toolbar"]
        var parsedTint: NSColor?
        if let colorValue {
            guard let parsed = Self.color(colorValue) else {
                throw Failure("Tuff can’t read the colour \(colorValue).")
            }
            parsedTint = parsed
        }

        let resDir = resources ?? ExtensionManager.shared.resourcesDirectory(forID: extensionID)
        let headerSpec = (images["theme_frame"] as? String) ?? (images["headerURL"] as? String)
        let parsedHeader = headerSpec.flatMap { Self.loadImage($0, resources: resDir) }

        let addSpecs = images["additional_backgrounds"] as? [String] ?? []
        let alignments = properties["additional_backgrounds_alignment"] as? [String] ?? []
        let tilings = properties["additional_backgrounds_tiling"] as? [String] ?? []
        var layers: [BackgroundLayer] = []
        for (idx, spec) in addSpecs.enumerated() {
            guard let img = Self.loadImage(spec, resources: resDir) else { continue }
            let align = idx < alignments.count ? alignments[idx] : (alignments.last ?? "right top")
            let tile = idx < tilings.count ? tilings[idx] : (tilings.last ?? "no-repeat")
            layers.append(BackgroundLayer(image: img, alignment: align, tiling: tile))
        }

        let scheme = (properties["color_scheme"] as? String)?.lowercased()
        guard parsedTint != nil || parsedHeader != nil || !layers.isEmpty || scheme != nil else {
            throw Failure("A theme needs colours, images, or properties for Tuff to use.")
        }

        owner = extensionID
        self.theme = theme
        tint = parsedTint
        headerImage = parsedHeader
        additionalLayers = layers
        colorScheme = scheme
        ExtensionEventPush.shared.emit("theme.onUpdated", args: [["theme": theme]], extra: ["themeWindow": true])
    }

    func reset(extensionID: String) {
        guard owner == extensionID else { return }
        owner = nil
        theme = nil
        tint = nil
        headerImage = nil
        additionalLayers = []
        colorScheme = nil
        ExtensionEventPush.shared.emit("theme.onUpdated", args: [["theme": current()]], extra: ["themeWindow": true])
    }

    static func loadImage(_ spec: String, resources: URL?) -> NSImage? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("data:") {
            guard let comma = trimmed.firstIndex(of: ",") else { return nil }
            let meta = trimmed[..<comma]
            let body = String(trimmed[trimmed.index(after: comma)...])
            let data: Data?
            if meta.contains(";base64") {
                data = Data(base64Encoded: body, options: .ignoreUnknownCharacters)
            } else {
                data = body.removingPercentEncoding?.data(using: .utf8)
            }
            return data.flatMap(NSImage.init(data:))
        }
        guard let resources else { return nil }
        let relative = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        let target = resources.appendingPathComponent(relative).standardizedFileURL
        guard target.path.hasPrefix(resources.standardizedFileURL.path + "/") else { return nil }
        return NSImage(contentsOf: target)
    }

    /// A Firefox theme colour: `#rgb`, `#rrggbb`, `rgb()` / `rgba()`, `[r, g, b]`, or a few names.
    static func color(_ value: Any) -> NSColor? {
        if let parts = value as? [NSNumber], parts.count >= 3 {
            return NSColor(srgbRed: CGFloat(truncating: parts[0]) / 255, green: CGFloat(truncating: parts[1]) / 255,
                           blue: CGFloat(truncating: parts[2]) / 255, alpha: 1)
        }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        let names = ["black": "#000000", "white": "#ffffff", "red": "#ff0000", "green": "#008000", "blue": "#0000ff",
                     "gray": "#808080", "grey": "#808080", "transparent": "#000000"]
        if let hex = names[text] { return NSColor(hex: hex) }
        if text.hasPrefix("#") {
            var hex = String(text.dropFirst())
            if hex.count == 3 || hex.count == 4 { hex = hex.prefix(3).map { "\($0)\($0)" }.joined() }
            guard hex.count >= 6, Int(hex.prefix(6), radix: 16) != nil else { return nil }
            return NSColor(hex: "#" + hex.prefix(6))
        }
        if text.hasPrefix("rgb") {
            let numbers = text.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
                .compactMap(Double.init)
            guard numbers.count >= 3 else { return nil }
            return NSColor(srgbRed: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255, alpha: 1)
        }
        return nil
    }
}

// MARK: - Firefox browser.clipboard

enum ExtensionClipboard {
    static func setImageData(base64: String, type: String) throws {
        guard type == "png" || type == "jpeg" else {
            throw ExtensionTheme.Failure("imageType must be “png” or “jpeg”.")
        }
        guard let data = Data(base64Encoded: base64), let image = NSImage(data: data), image.isValid else {
            throw ExtensionTheme.Failure("The image data couldn’t be read.")
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }
}

// MARK: - Firefox browser.find

/// Firefox's `browser.find`: searches a tab's text, then highlights the matches with the CSS
/// Custom Highlight API (the page's own styles and selection are left alone). Runs in a content
/// world of its own, so the page can't see or disturb it.
enum ExtensionFind {
    private static let world = WKContentWorld.world(name: "TuffExtensionFind")

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func tab(_ index: Any?) throws -> Tab {
        let state = BrowserState.shared
        if let index = index as? Int {
            guard state.allTabs.indices.contains(index) else { throw Failure("Invalid tab id.") }
            return state.allTabs[index]
        }
        guard let tab = state.selectedTab else { throw Failure("No tab to search.") }
        return tab
    }

    static func find(_ args: [String: Any], finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) {
        do {
            let tab = try tab(args["tabIndex"])
            guard let webView = tab.webView else { return finish(["count": 0]) }
            guard let query = args["queryphrase"] as? String, !query.isEmpty else { throw Failure("queryphrase is required.") }
            let options: [String: Any] = [
                "query": query,
                "caseSensitive": args["caseSensitive"] as? Bool ?? false,
                "entireWord": args["entireWord"] as? Bool ?? false,
                "matchDiacritics": args["matchDiacritics"] as? Bool ?? false,
                "rangeData": args["includeRangeData"] as? Bool ?? false,
                "rectData": args["includeRectData"] as? Bool ?? false,
            ]
            webView.callAsyncJavaScript(findScript, arguments: ["o": options], in: nil, in: world) { result in
                switch result {
                case .success(let value): finish(value)
                case .failure(let error): fail(error)
                }
            }
        } catch {
            fail(error)
        }
    }

    static func highlight(_ args: [String: Any], finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) {
        do {
            let tab = try tab(args["tabIndex"])
            guard let webView = tab.webView else { return finish(nil) }
            let options: [String: Any] = ["index": args["rangeIndex"] as? Int ?? -1, "noScroll": args["noScroll"] as? Bool ?? false]
            webView.callAsyncJavaScript(highlightScript, arguments: ["o": options], in: nil, in: world) { result in
                if case .failure(let error) = result { fail(error) } else { finish(nil) }
            }
        } catch {
            fail(error)
        }
    }

    static func removeHighlighting(_ args: [String: Any], finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) {
        do {
            let tab = try tab(args["tabIndex"])
            guard let webView = tab.webView else { return finish(nil) }
            webView.callAsyncJavaScript(clearScript, arguments: [:], in: nil, in: world) { _ in finish(nil) }
        } catch {
            fail(error)
        }
    }

    private static let findScript = #"""
    const fold = (s) => o.matchDiacritics ? s : s.normalize('NFD').replace(/[̀-ͯ]/g, '');
    const nodes = [];
    let text = '';
    const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        const parent = node.parentElement;
        if (!parent || /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE)$/.test(parent.tagName)) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    // Folding diacritics can change a node's length, so offsets are mapped per character.
    const map = [];
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const value = node.nodeValue || '';
      for (let i = 0; i < value.length; i++) {
        const folded = fold(value[i]);
        for (let k = 0; k < folded.length; k++) map.push([nodes.length, i]);
        text += folded;
      }
      nodes.push(node);
    }
    map.push([nodes.length - 1, nodes.length ? (nodes[nodes.length - 1].nodeValue || '').length : 0]);
    const escaped = fold(o.query).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const source = o.entireWord ? '(?<![\\p{L}\\p{N}_])' + escaped + '(?![\\p{L}\\p{N}_])' : escaped;
    const regex = new RegExp(source, 'gu' + (o.caseSensitive ? '' : 'i'));
    const ranges = [];
    const rangeData = [];
    const rectData = [];
    for (const m of text.matchAll(regex)) {
      if (!m[0].length) continue;
      const [startNode, startOffset] = map[m.index];
      const endAt = map[m.index + m[0].length - 1];
      const endNode = endAt[0], endOffset = endAt[1] + 1;
      const range = document.createRange();
      range.setStart(nodes[startNode], startOffset);
      range.setEnd(nodes[endNode], endOffset);
      ranges.push(range);
      if (o.rangeData) rangeData.push({ framePos: 0, startTextNodePos: startNode, startOffset, endTextNodePos: endNode, endOffset });
      if (o.rectData) {
        const rectList = [...range.getClientRects()].map((r) => ({
          top: r.top + scrollY, left: r.left + scrollX, bottom: r.bottom + scrollY, right: r.right + scrollX
        }));
        rectData.push({ rectsAndTexts: { rectList, textList: [range.toString()] }, text: range.toString() });
      }
    }
    window.__tuffFindRanges = ranges;
    const result = { count: ranges.length };
    if (o.rangeData) result.rangeData = rangeData;
    if (o.rectData) result.rectData = rectData;
    return result;
    """#

    private static let highlightScript = #"""
    const ranges = window.__tuffFindRanges || [];
    if (!ranges.length) throw new Error('Nothing found to highlight. Call find() first.');
    if (o.index >= ranges.length) throw new Error('rangeIndex is out of range.');
    if (!document.getElementById('__tuff-find-style')) {
      const style = document.createElement('style');
      style.id = '__tuff-find-style';
      style.textContent = '::highlight(tuff-find){background-color:#fff176;color:#000}::highlight(tuff-find-current){background-color:#ff9632;color:#000}';
      (document.head || document.documentElement).appendChild(style);
    }
    const current = o.index >= 0 ? ranges[o.index] : null;
    if (typeof Highlight === 'function' && CSS.highlights) {
      CSS.highlights.set('tuff-find', new Highlight(...ranges.filter((r) => r !== current)));
      if (current) CSS.highlights.set('tuff-find-current', new Highlight(current));
      else CSS.highlights.delete('tuff-find-current');
    } else if (current) {
      const selection = getSelection();
      selection.removeAllRanges();
      selection.addRange(current);
    }
    const target = current || ranges[0];
    if (!o.noScroll && target) {
      const element = target.startContainer.parentElement;
      if (element) element.scrollIntoView({ block: 'center', inline: 'nearest' });
    }
    """#

    private static let clearScript = #"""
    if (typeof CSS !== 'undefined' && CSS.highlights) {
      CSS.highlights.delete('tuff-find');
      CSS.highlights.delete('tuff-find-current');
    }
    const style = document.getElementById('__tuff-find-style');
    if (style) style.remove();
    """#
}

// MARK: - chrome.omnibox

/// `chrome.omnibox`: an extension's keyword (`"omnibox": {"keyword": "gh"}` in its manifest)
/// typed at the start of the command bar, then a space, hands the rest of the input to the
/// extension. Its suggestions are listed under the field and ↩ sends the text (or the chosen
/// suggestion) back to it with `onInputEntered`.
final class ExtensionOmnibox {
    static let shared = ExtensionOmnibox()

    struct Keyword: Equatable {
        let extensionID: String
        let keyword: String
        let name: String
        let icon: NSImage?

        static func == (a: Keyword, b: Keyword) -> Bool { a.extensionID == b.extensionID && a.keyword == b.keyword }
    }

    struct Suggestion: Equatable {
        let content: String
        let description: String
        let deletable: Bool
    }

    private var defaultSuggestions: [String: String] = [:]
    private var pending: [Int: ([Suggestion]) -> Void] = [:]
    private var nextRequest = 1

    /// The extension keyword the input starts with ("gh react" → gh), and the text after it.
    func match(_ input: String) -> (keyword: Keyword, rest: String)? {
        guard let space = input.firstIndex(of: " ") else { return nil }
        let word = String(input[..<space])
        guard !word.isEmpty, let keyword = keyword(named: word) else { return nil }
        return (keyword, String(input[input.index(after: space)...]))
    }

    private func keyword(named word: String) -> Keyword? {
        for (id, context) in ExtensionManager.shared.contexts {
            guard let omnibox = context.webExtension.manifest["omnibox"] as? [String: Any],
                  let keyword = omnibox["keyword"] as? String, keyword.caseInsensitiveCompare(word) == .orderedSame else { continue }
            return Keyword(
                extensionID: id, keyword: keyword,
                name: context.webExtension.displayShortName ?? context.webExtension.displayName ?? keyword,
                icon: context.webExtension.icon(for: CGSize(width: 32, height: 32))
            )
        }
        return nil
    }

    func defaultSuggestion(for extensionID: String) -> String? { defaultSuggestions[extensionID] }

    func setDefaultSuggestion(_ description: String, extensionID: String) {
        defaultSuggestions[extensionID] = Self.plain(description)
    }

    func started(_ keyword: Keyword) {
        ExtensionEventPush.shared.emit("omnibox.onInputStarted", args: [], to: keyword.extensionID)
    }

    /// Sends the text to the extension; `suggestions` gets what it suggests (if it does).
    func changed(_ keyword: Keyword, text: String, suggestions: @escaping ([Suggestion]) -> Void) {
        let request = nextRequest
        nextRequest += 1
        pending = pending.filter { $0.key > request - 8 }  // only the latest few still matter
        pending[request] = suggestions
        ExtensionEventPush.shared.emit("omnibox.onInputChanged", args: [text], extra: ["suggest": request], to: keyword.extensionID)
    }

    func entered(_ keyword: Keyword, text: String, newTab: Bool) {
        ExtensionEventPush.shared.emit(
            "omnibox.onInputEntered", args: [text, newTab ? "newForegroundTab" : "currentTab"], to: keyword.extensionID
        )
    }

    func cancelled(_ keyword: Keyword) {
        ExtensionEventPush.shared.emit("omnibox.onInputCancelled", args: [], to: keyword.extensionID)
    }

    func deleted(_ keyword: Keyword, description: String) {
        ExtensionEventPush.shared.emit("omnibox.onDeleteSuggestion", args: [description], to: keyword.extensionID)
    }

    /// The extension's answer to `suggest(...)` for one onInputChanged.
    func suggest(request: Int, results: [[String: Any]]) {
        guard let callback = pending.removeValue(forKey: request) else { return }
        let suggestions = results.compactMap { item -> Suggestion? in
            guard let content = item["content"] as? String else { return nil }
            return Suggestion(content: content, description: Self.plain(item["description"] as? String ?? content),
                              deletable: item["deletable"] as? Bool ?? false)
        }
        callback(suggestions)
    }

    /// Omnibox descriptions carry XML-style markup (`<match>`, `<url>`, `<dim>`) and entities.
    static func plain(_ description: String) -> String {
        var text = description.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
    }
}

// MARK: - Action badge colours

/// The badge colours of extension buttons: `action.setBadgeBackgroundColor` (which WebKit keeps
/// but doesn't hand out) and `setBadgeTextColor` (which WebKit lacks). The shim passes both here
/// as well; Tuff draws the badge. A colour set for a tab wins over the extension's own; with no
/// text colour, the text is black or white, whichever reads on the background (as in Chrome).
final class ExtensionBadgeColors {
    static let shared = ExtensionBadgeColors()

    struct Colors {
        var background: NSColor?
        var text: NSColor?
    }

    private struct Entry {
        var global = Colors()
        let tabs = NSMapTable<Tab, Box>.weakToStrongObjects()
    }

    private final class Box {
        var colors = Colors()
    }

    private var colors: [String: Entry] = [:]

    func set(_ kind: String, value: Any?, tab: Tab?, extensionID: String) throws {
        let color: NSColor?
        if let value, !(value is NSNull) {
            guard let parsed = ExtensionTheme.color(value) else { throw ExtensionTheme.Failure("Tuff can’t read the colour \(value).") }
            color = parsed
        } else {
            color = nil
        }
        var entry = colors[extensionID] ?? Entry()
        if let tab {
            let box = entry.tabs.object(forKey: tab) ?? Box()
            if kind == "text" { box.colors.text = color } else { box.colors.background = color }
            entry.tabs.setObject(box, forKey: tab)
        } else if kind == "text" {
            entry.global.text = color
        } else {
            entry.global.background = color
        }
        colors[extensionID] = entry
        ExtensionManager.shared.revision += 1
    }

    /// The colours for an extension's badge in `tab`.
    func colors(for extensionID: String, tab: Tab?) -> Colors {
        guard let entry = colors[extensionID] else { return Colors() }
        let own = tab.flatMap { entry.tabs.object(forKey: $0)?.colors }
        let background = own?.background ?? entry.global.background
        var text = own?.text ?? entry.global.text
        if text == nil, let background { text = background.luminance > 0.6 ? .black : .white }
        return Colors(background: background, text: text)
    }

    /// `getBadgeTextColor`: Chrome's `[r, g, b, a]`.
    func textColor(for extensionID: String, tab: Tab?) -> [Int] {
        let color = (colors(for: extensionID, tab: tab).text ?? .white).usingColorSpace(.sRGB) ?? .white
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent].map { Int(($0 * 255).rounded()) }
    }

    func extensionUnloaded(_ id: String) {
        colors[id] = nil
    }
}
