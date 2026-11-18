import Foundation
import WebKit

/// Content scripts that an extension registers at run time with *code* rather than files:
/// Firefox's `contentScripts.register` and `userScripts.register`, and Chrome's MV3
/// `userScripts.register`. WebKit implements none of these (its `scripting.registerContentScripts`
/// only takes files from the extension's bundle), so Tuff adds the code to every tab itself, as a
/// `WKUserScript` limited to the URLs the extension asked for.
///
/// uBlock Origin depends on this: it delivers its scriptlets (the small page-world scripts that
/// strip ads out of YouTube's player data, among many others) through `contentScripts.register`
/// with `world: 'MAIN'`. A user script runs before any of the page's own scripts and is not
/// subject to the page's Content Security Policy or Trusted Types, which is what injecting a
/// `<script>` element (uBO's fallback) runs into on YouTube.
///
/// Scripts in the page's world use `WKContentWorld.page`. Isolated ones get a world of their own
/// per extension: WebKit doesn't expose the world its own content scripts run in, so these
/// scripts can touch the page's DOM but not the extension APIs.
final class ExtensionContentScripts {
    static let shared = ExtensionContentScripts()

    private struct Registration {
        let id: String
        let extensionID: String
        /// Chrome `userScripts` id (unique per extension), or nil for handle-based Firefox calls.
        let userScriptID: String?
        /// What the extension passed in, returned by `userScripts.getScripts`.
        let details: [String: Any]
        let scripts: [WKUserScript]
    }

    /// In registration order: user scripts are injected in the order they were added.
    private var registrations: [Registration] = []
    /// Every tab's content controller (each web view configuration has its own).
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private var nextID = 1

    struct RegistrationError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // MARK: Tabs

    /// Gives a new tab's configuration every script registered so far, and later ones as they come.
    func attach(_ controller: WKUserContentController) {
        controllers.add(controller)
        for registration in registrations {
            for script in registration.scripts { controller.addUserScript(script) }
        }
    }

    // MARK: Registering

    /// Firefox `contentScripts.register` / `userScripts.register` (MV2): registers and returns the
    /// id of the handle the shim gives back (`handle.unregister()` sends it back here).
    func register(_ details: [String: Any], extensionID: String, resources: URL?, defaultWorld: String) throws -> String {
        let id = "\(extensionID):\(nextID)"
        nextID += 1
        let scripts = try makeScripts(details, extensionID: extensionID, resources: resources, defaultWorld: defaultWorld)
        add(Registration(id: id, extensionID: extensionID, userScriptID: nil, details: details, scripts: scripts))
        return id
    }

    func unregister(handle id: String) {
        remove { $0.id == id }
    }

    /// Chrome `userScripts.register(scripts)` (MV3). Ids are the extension's own and must be new.
    func registerUserScripts(_ list: [[String: Any]], extensionID: String, resources: URL?) throws {
        var seen = Set(registrations.filter { $0.extensionID == extensionID }.compactMap(\.userScriptID))
        var made: [Registration] = []
        for details in list {
            guard let scriptID = details["id"] as? String, !scriptID.isEmpty else { throw RegistrationError("A user script needs an id.") }
            guard !seen.contains(scriptID) else { throw RegistrationError("Duplicate script ID '\(scriptID)'.") }
            seen.insert(scriptID)
            let scripts = try makeScripts(details, extensionID: extensionID, resources: resources, defaultWorld: "USER_SCRIPT")
            made.append(Registration(id: "\(extensionID):\(nextID)", extensionID: extensionID, userScriptID: scriptID, details: details, scripts: scripts))
            nextID += 1
        }
        made.forEach(add)
    }

    /// Chrome `userScripts.update(scripts)`: each entry's fields replace those of the script with its id.
    func updateUserScripts(_ list: [[String: Any]], extensionID: String, resources: URL?) throws {
        var replacements: [(old: String, new: Registration)] = []
        for changes in list {
            guard let scriptID = changes["id"] as? String,
                  let existing = registrations.first(where: { $0.extensionID == extensionID && $0.userScriptID == scriptID }) else {
                throw RegistrationError("Invalid script ID '\(changes["id"] as? String ?? "")'.")
            }
            let details = existing.details.merging(changes) { _, new in new }
            let scripts = try makeScripts(details, extensionID: extensionID, resources: resources, defaultWorld: "USER_SCRIPT")
            replacements.append((existing.id, Registration(id: existing.id, extensionID: extensionID, userScriptID: scriptID, details: details, scripts: scripts)))
        }
        for (old, new) in replacements {
            remove { $0.id == old }
            add(new)
        }
    }

    /// Chrome `userScripts.unregister({ids})`; no ids removes all of the extension's user scripts.
    func unregisterUserScripts(ids: [String]?, extensionID: String) {
        remove { registration in
            guard registration.extensionID == extensionID, let scriptID = registration.userScriptID else { return false }
            return ids?.contains(scriptID) ?? true
        }
    }

    /// Chrome `userScripts.getScripts({ids})`.
    func userScripts(ids: [String]?, extensionID: String) -> [[String: Any]] {
        registrations
            .filter { $0.extensionID == extensionID && $0.userScriptID != nil }
            .filter { ids == nil || ids!.contains($0.userScriptID!) }
            .map(\.details)
    }

    /// Drops everything an extension registered (it was disabled, removed or reloaded).
    func extensionUnloaded(_ extensionID: String) {
        remove { $0.extensionID == extensionID }
    }

    private func add(_ registration: Registration) {
        registrations.append(registration)
        for controller in controllers.allObjects {
            for script in registration.scripts { controller.addUserScript(script) }
        }
    }

    private func remove(where predicate: (Registration) -> Bool) {
        let gone = registrations.filter(predicate)
        guard !gone.isEmpty else { return }
        registrations.removeAll(where: predicate)
        let scripts = gone.flatMap(\.scripts)
        // `_removeUserScript:` is private but has been in WebKit for years; without it a removed
        // script stays in tabs that already have it until they are reopened.
        for controller in controllers.allObjects where controller.responds(to: Self.removeSelector) {
            for script in scripts { controller.perform(Self.removeSelector, with: script) }
        }
    }

    // MARK: Building scripts

    private func makeScripts(_ details: [String: Any], extensionID: String, resources: URL?, defaultWorld: String) throws -> [WKUserScript] {
        let include = Self.patterns(details["matches"])
        let exclude = Self.patterns(details["excludeMatches"])
        let includeGlobs = details["includeGlobs"] as? [String] ?? []
        let excludeGlobs = details["excludeGlobs"] as? [String] ?? []
        guard !include.isEmpty else { throw RegistrationError("matches is required.") }

        let world: WKContentWorld
        switch ((details["world"] as? String) ?? defaultWorld).uppercased() {
        case "MAIN": world = .page
        case "USER_SCRIPT": world = .world(name: "Tuff user scripts \(extensionID)")
        default: world = .world(name: "Tuff content scripts \(extensionID)")
        }
        let time: WKUserScriptInjectionTime = (details["runAt"] as? String) == "document_start" ? .atDocumentStart : .atDocumentEnd
        let mainFrameOnly = !((details["allFrames"] as? Bool) ?? false)
        let idle = (details["runAt"] as? String ?? "document_idle") == "document_idle"

        var sources: [String] = []
        for entry in details["css"] as? [[String: Any]] ?? [] {
            sources.append(Self.styleInjector(try Self.text(of: entry, in: resources)))
        }
        for entry in details["js"] as? [[String: Any]] ?? [] {
            var code = try Self.text(of: entry, in: resources)
            // document_idle: after DOMContentLoaded, once the page has had a moment to itself.
            if idle { code = "setTimeout(function () {\n\(code)\n}, 0);" }
            sources.append(code)
        }
        guard !sources.isEmpty else { throw RegistrationError("At least one js or css entry is required.") }
        return sources.map { source in
            let guarded: String
            if includeGlobs.isEmpty && excludeGlobs.isEmpty {
                guarded = source
            } else {
                guarded = "if (\(Self.globTest(include: includeGlobs, exclude: excludeGlobs))) {\n\(source)\n}"
            }
            return Self.makeScript(source: guarded, time: time, mainFrameOnly: mainFrameOnly, include: include, exclude: exclude, world: world)
        }
    }

    static func globRegex(_ glob: String) -> String {
        "^" + NSRegularExpression.escapedPattern(for: glob)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".") + "$"
    }

    private static func globTest(include: [String], exclude: [String]) -> String {
        let encode = { (list: [String]) in
            (try? JSONSerialization.data(withJSONObject: list.map(globRegex))).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        return "(function(u){var t=function(l){return l.some(function(r){return new RegExp(r).test(u);});};return (!\(encode(include)).length||t(\(encode(include))))&&!t(\(encode(exclude)));})(location.href)"
    }

    /// `{code}` as given, or `{file}` read from the extension's own files.
    private static func text(of entry: [String: Any], in resources: URL?) throws -> String {
        if let code = entry["code"] as? String { return code }
        if let path = entry["file"] as? String, let resources {
            let url = resources.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).standardizedFileURL
            guard url.path.hasPrefix(resources.standardizedFileURL.path),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw RegistrationError("Could not load file '\(path)'.")
            }
            return text
        }
        throw RegistrationError("Each js / css entry needs code or file.")
    }

    private static func styleInjector(_ css: String) -> String {
        let literal = (try? JSONSerialization.data(withJSONObject: [css])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return """
        (function () {
          var style = document.createElement('style');
          style.textContent = \(literal)[0];
          (document.head || document.documentElement).appendChild(style);
        })();
        """
    }

    /// WebKit's match-pattern parser knows `http`, `https`, `file` and `<all_urls>`; Chrome's
    /// `*://` scheme (http and https) is spelt out.
    private static func patterns(_ value: Any?) -> [String] {
        let list = value as? [String] ?? []
        return list.flatMap { pattern -> [String] in
            if pattern.hasPrefix("*://") {
                let rest = pattern.dropFirst(4)
                return ["http://" + rest, "https://" + rest]
            }
            return [pattern]
        }
    }

    // MARK: WebKit

    private static let removeSelector = NSSelectorFromString("_removeUserScript:")
    private static let initSelector = NSSelectorFromString(
        "_initWithSource:injectionTime:forMainFrameOnly:includeMatchPatternStrings:excludeMatchPatternStrings:associatedURL:contentWorld:")
    private typealias PatternInit = @convention(c) (
        AnyObject, Selector, NSString, Int, Bool, NSArray, NSArray, NSURL?, WKContentWorld
    ) -> Unmanaged<WKUserScript>

    /// A user script limited to `include` minus `exclude`. WebKit's public initializer has no
    /// URL patterns (its own extension content scripts use this private one), so the fallback
    /// checks the URL in the script itself.
    private static func makeScript(
        source: String, time: WKUserScriptInjectionTime, mainFrameOnly: Bool,
        include: [String], exclude: [String], world: WKContentWorld
    ) -> WKUserScript {
        if let method = class_getInstanceMethod(WKUserScript.self, initSelector),
           let allocMethod = class_getClassMethod(WKUserScript.self, NSSelectorFromString("alloc")) {
            // alloc's +1 is handed to the initializer, which consumes it and returns its own +1.
            typealias Alloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
            let allocated = unsafeBitCast(method_getImplementation(allocMethod), to: Alloc.self)(
                WKUserScript.self, NSSelectorFromString("alloc")).takeUnretainedValue()
            let initialize = unsafeBitCast(method_getImplementation(method), to: PatternInit.self)
            return initialize(allocated, initSelector, source as NSString, time.rawValue, mainFrameOnly,
                              include as NSArray, exclude as NSArray, nil, world).takeRetainedValue()
        }
        let guarded = "if (\(urlTest(include: include, exclude: exclude))) {\n\(source)\n}"
        return WKUserScript(source: guarded, injectionTime: time, forMainFrameOnly: mainFrameOnly, in: world)
    }

    /// A JavaScript condition matching `location.href` against the patterns (fallback only).
    private static func urlTest(include: [String], exclude: [String]) -> String {
        func regex(_ pattern: String) -> String {
            if pattern == "<all_urls>" { return "^(https?|file|ftp)://" }
            guard let schemeEnd = pattern.range(of: "://") else { return "$^" }
            let scheme = pattern[..<schemeEnd.lowerBound]
            var rest = pattern[schemeEnd.upperBound...]
            let slash = rest.firstIndex(of: "/") ?? rest.endIndex
            let host = rest[..<slash]
            rest = rest[slash...]
            let escape = { (s: Substring) in NSRegularExpression.escapedPattern(for: String(s)).replacingOccurrences(of: "\\*", with: ".*") }
            var hostRegex = escape(host)
            if host == "*" { hostRegex = "[^/]*" } else if host.hasPrefix("*.") { hostRegex = "([^/]*\\.)?" + escape(host.dropFirst(2)) }
            return "^" + escape(scheme) + "://" + hostRegex + (rest.isEmpty ? "/" : escape(rest)) + "$"
        }
        let encode = { (list: [String]) in
            (try? JSONSerialization.data(withJSONObject: list.map(regex))).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        return "(function(u){var t=function(l){return l.some(function(r){return new RegExp(r).test(u);});};return t(\(encode(include)))&&!t(\(encode(exclude)));})(location.href)"
    }
}
