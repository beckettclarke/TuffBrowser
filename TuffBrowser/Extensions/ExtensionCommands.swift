import AppKit
import WebKit

/// Firefox's `commands.update` and `commands.reset`: an extension changing its own keyboard
/// shortcuts and their descriptions. WebKit lets the app set a command's keys but leaves keeping
/// them to the app, so changes are saved here and put back each time the extension loads.
/// WebKit's command titles can't be changed, so a new description is applied by the shim, to what
/// `commands.getAll` reports.
final class ExtensionCommands {
    static let shared = ExtensionCommands()

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// What an extension changed about one command; nil fields are as the manifest says.
    private struct Change: Codable {
        /// Set when the shortcut was changed; "" for none.
        var key: String?
        var modifiers: UInt?
        var description: String?
    }

    struct Keys: Equatable {
        var key: String?
        var modifiers: NSEvent.ModifierFlags
    }

    /// extension id -> command name -> its changes.
    private var changes: [String: [String: Change]] = [:]
    /// extension id -> command name -> the manifest's keys, to reset to.
    private var defaults: [String: [String: Keys]] = [:]
    private let file = Paths.appSupport.appendingPathComponent("extension-commands.json")

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: [String: Change]].self, from: data) {
            changes = saved
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(changes.filter { !$0.value.isEmpty }) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// Notes the manifest's shortcuts and puts back the extension's changes.
    func extensionLoaded(_ context: WKWebExtensionContext, id: String) {
        defaults[id] = Dictionary(context.commands.map { ($0.id, Keys(key: $0.activationKey, modifiers: $0.modifierFlags)) }) { first, _ in first }
        for command in context.commands {
            guard let change = changes[id]?[command.id], let key = change.key else { continue }
            command.activationKey = key.isEmpty ? nil : key
            command.modifierFlags = NSEvent.ModifierFlags(rawValue: change.modifiers ?? 0)
        }
    }

    func extensionUninstalled(_ id: String) {
        defaults[id] = nil
        guard changes.removeValue(forKey: id) != nil else { return }
        save()
    }

    // MARK: The API

    func update(_ details: [String: Any], context: WKWebExtensionContext, id: String) throws {
        guard let name = details["name"] as? String else { throw Failure("commands.update needs the command’s name.") }
        guard let command = context.commands.first(where: { $0.id == name }) else { throw Failure("Unknown command “\(name)”.") }
        var change = changes[id]?[name] ?? Change()
        if let shortcut = details["shortcut"] as? String {
            let keys = try Self.parse(shortcut)
            command.activationKey = keys.key
            command.modifierFlags = keys.modifiers
            change.key = keys.key ?? ""
            change.modifiers = keys.modifiers.rawValue
        }
        if let description = details["description"] as? String { change.description = description }
        changes[id, default: [:]][name] = change
        save()
    }

    func reset(_ name: String, context: WKWebExtensionContext, id: String) throws {
        guard let command = context.commands.first(where: { $0.id == name }) else { throw Failure("Unknown command “\(name)”.") }
        if let keys = defaults[id]?[name] {
            command.activationKey = keys.key
            command.modifierFlags = keys.modifiers
        }
        guard changes[id]?.removeValue(forKey: name) != nil else { return }
        save()
    }

    /// Command name -> the description the extension gave it.
    func descriptions(id: String) -> [String: String] {
        (changes[id] ?? [:]).compactMapValues(\.description)
    }

    // MARK: Shortcuts

    /// Firefox's shortcut strings ("Ctrl+Shift+U", "Alt+Comma", "MacCtrl+F5"), with its Mac
    /// meanings: Ctrl and Command are ⌘, MacCtrl is ⌃. "" means no shortcut.
    static func parse(_ shortcut: String) throws -> Keys {
        let parts = shortcut.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty else { return Keys(key: nil, modifiers: []) }
        let invalid = Failure("Invalid shortcut: “\(shortcut)”.")
        var modifiers: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part.lowercased() {
            case "ctrl", "command": modifiers.insert(.command)
            case "macctrl": modifiers.insert(.control)
            case "alt": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            default: throw invalid
            }
        }
        guard let key = key(named: last) else { throw invalid }
        // As in Firefox: a shortcut needs a modifier other than Shift, except on a function key.
        let isFunctionKey = key.unicodeScalars.first.map { (0xF704...0xF70F).contains($0.value) } ?? false
        guard isFunctionKey || !modifiers.subtracting(.shift).isEmpty else { throw invalid }
        return Keys(key: key, modifiers: modifiers)
    }

    /// The key as WebKit stores it: the character for letters, digits and punctuation, AppKit's
    /// function-key character for the rest.
    private static func key(named name: String) -> String? {
        if name.count == 1, let character = name.lowercased().first, character.isLetter || character.isNumber, character.isASCII {
            return String(character)
        }
        let named: [String: Int] = [
            "comma": 0x2C, "period": 0x2E, "space": 0x20,
            "up": NSUpArrowFunctionKey, "down": NSDownArrowFunctionKey, "left": NSLeftArrowFunctionKey, "right": NSRightArrowFunctionKey,
            "home": NSHomeFunctionKey, "end": NSEndFunctionKey, "pageup": NSPageUpFunctionKey, "pagedown": NSPageDownFunctionKey,
            "insert": NSInsertFunctionKey, "delete": NSDeleteFunctionKey,
        ]
        let lower = name.lowercased()
        if let code = named[lower] { return UnicodeScalar(code).map { String(Character($0)) } }
        if lower.hasPrefix("f"), let number = Int(lower.dropFirst()), (1...12).contains(number) {
            return UnicodeScalar(NSF1FunctionKey + number - 1).map { String(Character($0)) }
        }
        return nil
    }
}
