import Foundation

/// Read-only enterprise/administrator policy storage behind `chrome.storage.managed` and
/// Firefox's `browser.storage.managed`.
///
/// Looks up policy data in order from lowest to highest precedence:
/// 1. macOS managed preferences (`com.google.Chrome.extensions.<id>`, `com.tuffbrowser.Tuff.extensions.<id>`)
/// 2. `/Library/Application Support/Mozilla/ManagedStorage/<id>.json`
/// 3. `~/Library/Application Support/Mozilla/ManagedStorage/<id>.json`
/// 4. `/Library/Application Support/Tuff/ManagedStorage/<id>.json`
/// 5. `<Paths.appSupport>/ManagedStorage/<id>.json`
///
/// Each JSON file may be either Firefox's native manifest shape (`{ "type": "storage", "data": { … } }`)
/// or a plain JSON object mapping storage keys to values.
final class ExtensionManagedStorage {
    static let shared = ExtensionManagedStorage()

    private let directories: [URL]
    private let readPreferences: Bool
    private let emitEvents: Bool

    /// extensionID -> last seen managed storage snapshot (for `storage.managed.onChanged`).
    private var snapshots: [String: [String: Any]] = [:]
    private var watchSources: [DispatchSourceFileSystemObject] = []
    private var watchFDs: [Int32] = []
    private var monitoring = false

    init(
        directories: [URL]? = nil,
        readPreferences: Bool = true,
        emitEvents: Bool = true
    ) {
        if let directories {
            self.directories = directories
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.directories = [
                URL(fileURLWithPath: "/Library/Application Support/Mozilla/ManagedStorage", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/Mozilla/ManagedStorage", isDirectory: true),
                URL(fileURLWithPath: "/Library/Application Support/Tuff/ManagedStorage", isDirectory: true),
                Paths.appSupport.appendingPathComponent("ManagedStorage", isDirectory: true),
            ]
        }
        self.readPreferences = readPreferences
        self.emitEvents = emitEvents
    }

    deinit {
        stopMonitoring()
    }

    // MARK: Reading

    /// All managed policy keys and values currently visible to `extensionID`.
    func loadAll(extensionID: String, manifest: [String: Any]?) -> [String: Any] {
        let candidateIDs = Self.candidateIdentifiers(extensionID: extensionID, manifest: manifest)
        var merged: [String: Any] = [:]

        if readPreferences {
            for id in candidateIDs {
                for suite in ["com.google.Chrome.extensions.\(id)", "com.tuffbrowser.Tuff.extensions.\(id)"] {
                    if let prefs = Self.readManagedPreferences(suite: suite) {
                        for (k, v) in prefs { merged[k] = v }
                    }
                }
            }
        }

        for dir in directories {
            for id in candidateIDs {
                guard let file = Self.safeManifestURL(for: id, in: dir),
                      let dict = Self.readPolicyFile(at: file) else { continue }
                for (k, v) in dict { merged[k] = v }
            }
        }

        return merged
    }

    /// `storage.managed.get(keys?)`: nil/NSNull returns all; String returns `{ key: val }`;
    /// `[String]` returns matching keys; `[String: Any]` returns defaults overridden by stored values.
    func get(keys: Any?, extensionID: String, manifest: [String: Any]?) -> [String: Any] {
        let all = loadAll(extensionID: extensionID, manifest: manifest)
        if keys == nil || keys is NSNull {
            return all
        }
        if let key = keys as? String {
            if let value = all[key] { return [key: value] }
            return [:]
        }
        if let list = keys as? [String] {
            var result: [String: Any] = [:]
            for key in list {
                if let value = all[key] { result[key] = value }
            }
            return result
        }
        if let defaults = keys as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, fallback) in defaults {
                result[key] = all[key] ?? fallback
            }
            return result
        }
        return all
    }

    func getKeys(extensionID: String, manifest: [String: Any]?) -> [String] {
        loadAll(extensionID: extensionID, manifest: manifest).keys.sorted()
    }

    /// Chrome's `getBytesInUse(keys?)`: sum of UTF-8 lengths of each key and its JSON value.
    func getBytesInUse(keys: Any?, extensionID: String, manifest: [String: Any]?) -> Int {
        let all = loadAll(extensionID: extensionID, manifest: manifest)
        let selected: [String]
        if keys == nil || keys is NSNull {
            selected = Array(all.keys)
        } else if let key = keys as? String {
            selected = all[key] != nil ? [key] : []
        } else if let list = keys as? [String] {
            selected = list.filter { all[$0] != nil }
        } else {
            selected = Array(all.keys)
        }
        var total = 0
        for key in selected {
            guard let value = all[key] else { continue }
            total += key.utf8.count
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) {
                total += data.count
            }
        }
        return total
    }

    // MARK: Change monitoring

    func startMonitoring(extensionID: String, manifest: [String: Any]?) {
        snapshots[extensionID] = loadAll(extensionID: extensionID, manifest: manifest)
        guard !monitoring else { return }
        monitoring = true
        // Ensure Tuff's user-level ManagedStorage directory exists so edits trigger notifications.
        if let localDir = directories.last {
            try? FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        }
        for dir in directories {
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            watchFDs.append(fd)
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .extend, .attrib],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                self?.checkForChanges()
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            watchSources.append(source)
        }
    }

    func stopMonitoring() {
        for source in watchSources { source.cancel() }
        watchSources.removeAll()
        watchFDs.removeAll()
        monitoring = false
    }

    func extensionUnloaded(_ extensionID: String) {
        snapshots.removeValue(forKey: extensionID)
    }

    /// Re-reads policies for watched extensions and returns `{ extID: changes }` (and emits events).
    @discardableResult
    func checkForChanges(manifests: [String: [String: Any]]? = nil) -> [String: [String: [String: Any]]] {
        var emitted: [String: [String: [String: Any]]] = [:]
        for (extID, old) in snapshots {
            let manifest = manifests?[extID] ?? ExtensionManager.shared.contexts[extID]?.webExtension.manifest
            let now = loadAll(extensionID: extID, manifest: manifest)
            let diff = Self.diff(old: old, new: now)
            snapshots[extID] = now
            guard !diff.isEmpty else { continue }
            emitted[extID] = diff
            if emitEvents {
                ExtensionEventPush.shared.emit("storage.managed.onChanged", args: [diff], to: extID)
            }
        }
        return emitted
    }

    static func diff(old: [String: Any], new: [String: Any]) -> [String: [String: Any]] {
        var changes: [String: [String: Any]] = [:]
        for key in Set(old.keys).union(new.keys) {
            let a = old[key]
            let b = new[key]
            if Self.jsonEqual(a, b) { continue }
            var entry: [String: Any] = [:]
            if let a { entry["oldValue"] = a }
            if let b { entry["newValue"] = b }
            changes[key] = entry
        }
        return changes
    }

    // MARK: Helpers

    static func candidateIdentifiers(extensionID: String, manifest: [String: Any]?) -> [String] {
        var ids = [extensionID]
        if let gecko = Self.geckoID(from: manifest), !gecko.isEmpty, gecko != extensionID {
            ids.append(gecko)
        }
        return ids
    }

    static func geckoID(from manifest: [String: Any]?) -> String? {
        guard let manifest else { return nil }
        for root in ["browser_specific_settings", "applications"] {
            if let sub = manifest[root] as? [String: Any],
               let gecko = sub["gecko"] as? [String: Any],
               let id = gecko["id"] as? String, !id.isEmpty {
                return id
            }
        }
        return nil
    }

    private static func safeManifestURL(for id: String, in directory: URL) -> URL? {
        guard !id.isEmpty, !id.contains("/"), !id.contains("\\"), !id.contains("\0"), id != ".", id != ".." else {
            return nil
        }
        let candidate = directory.appendingPathComponent("\(id).json").standardizedFileURL
        let base = directory.standardizedFileURL.path
        guard candidate.path.hasPrefix(base + "/") else { return nil }
        return candidate
    }

    private static func readPolicyFile(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let raw = (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) as? [String: Any] else {
            return nil
        }
        if (raw["type"] as? String) == "storage", let nested = raw["data"] as? [String: Any] {
            return nested
        }
        return raw
    }

    private static func readManagedPreferences(suite: String) -> [String: Any]? {
        guard let keys = CFPreferencesCopyKeyList(suite as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
              !keys.isEmpty else {
            return nil
        }
        var dict: [String: Any] = [:]
        for key in keys {
            if let value = CFPreferencesCopyAppValue(key as CFString, suite as CFString),
               let jsonSafe = sanitizePreferenceValue(value) {
                dict[key] = jsonSafe
            }
        }
        return dict.isEmpty ? nil : dict
    }

    private static func sanitizePreferenceValue(_ value: Any) -> Any? {
        if value is String || value is NSNumber || value is Bool || value is NSNull { return value }
        if let arr = value as? [Any] { return arr.compactMap(sanitizePreferenceValue) }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                if let clean = sanitizePreferenceValue(v) { out[k] = clean }
            }
            return out
        }
        return nil
    }

    private static func jsonEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case let (a?, b?):
            guard let da = try? JSONSerialization.data(withJSONObject: a, options: [.fragmentsAllowed, .sortedKeys]),
                  let db = try? JSONSerialization.data(withJSONObject: b, options: [.fragmentsAllowed, .sortedKeys]) else {
                return false
            }
            return da == db
        }
    }
}
