import AppKit
import CommonCrypto
import CryptoKit
import WebKit

/// One kind of data a backup can hold. Each is a switch in Settings → Backup & Restore.
enum BackupItem: String, CaseIterable, Identifiable, Codable {
    case settings, spaces, tabs, bookmarks, history, passwords, cookies, extensions, sites, downloads
    var id: String { rawValue }

    var title: String {
        switch self {
        case .settings: "Settings & appearance"
        case .spaces: "Spaces, profiles & pinned tabs"
        case .tabs: "Open tabs"
        case .bookmarks: "Bookmarks"
        case .history: "History"
        case .passwords: "Passwords"
        case .cookies: "Cookies & logins"
        case .extensions: "Extensions"
        case .sites: "Site permissions & settings"
        case .downloads: "Downloads list"
        }
    }

    var detail: String {
        switch self {
        case .settings: "Every setting, the theme and the layout."
        case .spaces: "Spaces, profiles, favourites, folders and pinned tabs."
        case .tabs: "Each space’s open tabs, their back / forward history and recently closed tabs."
        case .bookmarks: "Every profile’s bookmarks and folders."
        case .history: "Every profile’s browsing history."
        case .passwords: "Saved logins, with the key that unlocks them."
        case .cookies: "Cookies of every profile, so you stay signed in to sites."
        case .extensions: "Installed extensions and their settings, not what they store inside pages."
        case .sites: "Camera, location and other permissions, zoom levels and per-site settings."
        case .downloads: "The list of downloads, not the downloaded files."
        }
    }

    var symbol: String {
        switch self {
        case .settings: "gearshape"
        case .spaces: "square.stack.3d.up"
        case .tabs: "square.on.square"
        case .bookmarks: "bookmark"
        case .history: "clock.arrow.circlepath"
        case .passwords: "key"
        case .cookies: "lock.open"
        case .extensions: "puzzlepiece.extension"
        case .sites: "hand.raised"
        case .downloads: "arrow.down.circle"
        }
    }

    /// Anyone holding the backup could sign in as you with this: it deserves a password.
    var isSensitive: Bool { self == .passwords || self == .cookies }

    /// Files and folders in Application Support that this item replaces, relative to it.
    /// Settings, open tabs and cookies live elsewhere or inside another item's file.
    var paths: [String] {
        switch self {
        case .settings, .tabs, .cookies: []
        case .spaces: ["session.json"]
        case .bookmarks: ["bookmarks.json", "reading-list.json"]
        case .history: ["history.json"]
        case .passwords: ["passwords.sealed", "passwords.key"]
        case .extensions: [
            "extensions.json", "Extensions", "Unpacked", "extension-settings.json", "extension-commands.json",
            "extension-content-settings.json", "extension-declarative-content.json",
            "extension-dnr-disabled.json", "pkcs11-modules.json", "ManagedStorage", "PKCS11Modules",
        ]
        case .sites: ["site-permissions.json", "site-settings.json", "site-zoom.json"]
        case .downloads: ["downloads.json"]
        }
    }

    /// Open tabs go with the spaces they are in.
    var requires: BackupItem? { self == .tabs ? .spaces : nil }
}

/// What is inside a backup file (`manifest.json`).
struct BackupManifest: Codable {
    struct ProfileInfo: Codable {
        var id: UUID
        var name: String
    }

    static let currentFormat = 1

    var format = Self.currentFormat
    var appVersion: String
    var created: Date
    var items: [BackupItem]
    /// A short line per item ("142 bookmarks") for the restore list.
    var summaries: [String: String]
    var profiles: [ProfileInfo]
}

struct BackupCookie: Codable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Double?
    var secure: Bool
    var httpOnly: Bool
    var sameSite: String?

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        expires = cookie.expiresDate?.timeIntervalSince1970
        secure = cookie.isSecure
        httpOnly = cookie.isHTTPOnly
        sameSite = cookie.sameSitePolicy?.rawValue
    }

    var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path,
        ]
        if let expires {
            let date = Date(timeIntervalSince1970: expires)
            guard date > Date() else { return nil }
            properties[.expires] = date
        }
        if secure { properties[.secure] = "TRUE" }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let sameSite { properties[.sameSitePolicy] = HTTPCookieStringPolicy(rawValue: sameSite) }
        return HTTPCookie(properties: properties)
    }
}

/// One profile's cookies.
struct BackupCookieSet: Codable {
    var profile: UUID
    /// The profile used the browser's original website data store.
    var shared: Bool
    var cookies: [BackupCookie]
}

enum BackupError: LocalizedError {
    case notABackup
    case newerFormat
    case wrongPassword
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notABackup: "That file isn’t a Tuff backup."
        case .newerFormat: "This backup was made by a newer Tuff. Update Tuff to open it."
        case .wrongPassword: "That password is wrong."
        case .failed(let reason): reason
        }
    }
}

// MARK: - Password protection

/// A backup protected with a password: `TUFFBKUP`, a version byte, a salt, then the zip sealed
/// with AES-GCM under a key derived from the password.
enum BackupCrypto {
    private static let magic = Data("TUFFBKUP".utf8)
    private static let saltLength = 16
    private static let rounds: UInt32 = 250_000

    static func isProtected(_ data: Data) -> Bool { data.starts(with: magic) }

    static func seal(_ zip: Data, password: String) throws -> Data {
        var salt = Data(count: saltLength)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, saltLength, $0.baseAddress!) }
        guard status == errSecSuccess else { throw BackupError.failed("Couldn’t protect the backup.") }
        let box = try AES.GCM.seal(zip, using: try key(password: password, salt: salt))
        guard let combined = box.combined else { throw BackupError.failed("Couldn’t protect the backup.") }
        return magic + Data([1]) + salt + combined
    }

    static func open(_ data: Data, password: String) throws -> Data {
        let header = magic.count + 1 + saltLength
        guard isProtected(data), data.count > header + 28 else { throw BackupError.notABackup }
        let salt = data.subdata(in: (magic.count + 1)..<header)
        do {
            let box = try AES.GCM.SealedBox(combined: data.subdata(in: header..<data.count))
            return try AES.GCM.open(box, using: try key(password: password, salt: salt))
        } catch {
            throw BackupError.wrongPassword
        }
    }

    private static func key(password: String, salt: Data) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count,
                saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &derived, derived.count
            )
        }
        guard status == kCCSuccess else { throw BackupError.failed("Couldn’t read the password.") }
        return SymmetricKey(data: derived)
    }
}

// MARK: - Zip

private enum Zip {
    static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BackupError.failed(text.trimmed.isEmpty ? "Couldn’t pack the files." : text.trimmed)
        }
    }

    static func compress(_ folder: URL, to file: URL) throws {
        try run(["-c", "-k", "--norsrc", folder.path, file.path])
    }

    static func extract(_ file: URL, to folder: URL) throws {
        try run(["-x", "-k", file.path, folder.path])
    }
}

// MARK: - Creating

enum BackupBuilder {
    /// Writes a backup of `items` to `destination`; with a `password`, the file is encrypted.
    @MainActor
    static func create(items requested: Set<BackupItem>, to destination: URL, password: String?) async throws {
        var items = requested
        if items.contains(.tabs) { items.insert(.spaces) }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("tuff-backup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // What is on disk must be what is in memory.
        let state = BrowserState.shared
        state.saveNow(synchronously: true)
        BookmarkStore.shared.saveNow(synchronously: true)
        HistoryStore.shared.saveNow(synchronously: true)
        DownloadManager.shared.saveNow()
        AppSettings.shared.saveNow()

        var summaries: [String: String] = [:]
        let files = staging.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: files, withIntermediateDirectories: true)

        for item in BackupItem.allCases where items.contains(item) {
            for path in item.paths {
                let source = Paths.appSupport.appendingPathComponent(path)
                guard fm.fileExists(atPath: source.path) else { continue }
                let target = files.appendingPathComponent(path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: target)
            }
        }

        // The session file holds spaces and open tabs together; without the tabs, they come out.
        if items.contains(.spaces), !items.contains(.tabs) {
            let file = files.appendingPathComponent("session.json")
            if let data = try? Data(contentsOf: file), let stripped = BackupSession.withoutOpenTabs(data) {
                try stripped.write(to: file, options: .atomic)
            }
        }

        if items.contains(.settings), let data = AppSettings.shared.exportData() {
            try data.write(to: staging.appendingPathComponent("settings.json"))
        }
        if items.contains(.sites) {
            let answers = UserDefaults.standard.stringArray(forKey: ExternalAppLinks.defaultsKey) ?? []
            try JSONEncoder().encode(answers).write(to: staging.appendingPathComponent("external-app-links.json"))
        }

        let profiles = state.profiles.filter { !$0.isPrivate }
        if items.contains(.cookies) {
            var sets: [BackupCookieSet] = []
            for profile in profiles {
                let cookies = await profile.dataStore.httpCookieStore.allCookies()
                sets.append(BackupCookieSet(profile: profile.id, shared: profile.usesSharedStore, cookies: cookies.map(BackupCookie.init)))
            }
            try JSONEncoder().encode(sets).write(to: staging.appendingPathComponent("cookies.json"))
            summaries[BackupItem.cookies.rawValue] = plural(sets.reduce(0) { $0 + $1.cookies.count }, "cookie")
        }

        if items.contains(.settings) { summaries[BackupItem.settings.rawValue] = "Settings and theme" }
        if items.contains(.spaces) {
            summaries[BackupItem.spaces.rawValue] = "\(plural(state.spaces.count, "space")), \(plural(profiles.count, "profile"))"
        }
        if items.contains(.tabs) {
            summaries[BackupItem.tabs.rawValue] = plural(state.spaces.flatMap(\.tabs).filter { $0.url != nil }.count, "tab")
        }
        if items.contains(.bookmarks) {
            let count = BookmarkStore.shared.lists.values.reduce(0) { $0 + $1.flatMap { $0.isFolder ? $0.pages : [$0] }.count }
            summaries[BackupItem.bookmarks.rawValue] = plural(count, "bookmark")
        }
        if items.contains(.history) { summaries[BackupItem.history.rawValue] = plural(HistoryStore.shared.count, "page") }
        if items.contains(.passwords) { summaries[BackupItem.passwords.rawValue] = plural(PasswordStore.shared.logins.count, "login") }
        if items.contains(.extensions) { summaries[BackupItem.extensions.rawValue] = plural(ExtensionManager.shared.records.count, "extension") }

        let manifest = BackupManifest(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            created: Date(),
            items: BackupItem.allCases.filter(items.contains),
            summaries: summaries,
            profiles: profiles.map { .init(id: $0.id, name: $0.name) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))

        try await Task.detached(priority: .userInitiated) {
            let zip = fm.temporaryDirectory.appendingPathComponent("tuff-backup-\(UUID().uuidString).zip")
            defer { try? fm.removeItem(at: zip) }
            try Zip.compress(staging, to: zip)
            var data = try Data(contentsOf: zip)
            if let password, !password.isEmpty { data = try BackupCrypto.seal(data, password: password) }
            try data.write(to: destination, options: .atomic)
        }.value
    }

    private static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

enum BackupSession {
    /// The saved session without any space's open tabs and without recently closed tabs.
    static func withoutOpenTabs(_ data: Data) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if var spaces = root["spaces"] as? [[String: Any]] {
            for index in spaces.indices { spaces[index]["tabs"] = [Any]() }
            root["spaces"] = spaces
        }
        root.removeValue(forKey: "closedTabs")
        return try? JSONSerialization.data(withJSONObject: root)
    }
}

// MARK: - Opening

/// A backup file unpacked into a temporary folder, ready to be restored from.
struct OpenedBackup {
    let manifest: BackupManifest
    let folder: URL

    func discard() { try? FileManager.default.removeItem(at: folder) }
}

enum BackupReader {
    /// Whether the file needs a password.
    static func isProtected(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        return BackupCrypto.isProtected((try? handle.read(upToCount: 8)) ?? Data())
    }

    /// A backup is somebody's file: nothing in it may point outside its folder.
    private static func containsSymbolicLink(_ folder: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return false }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            return true
        }
        return false
    }

    static func open(_ file: URL, password: String?) async throws -> OpenedBackup {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let folder = fm.temporaryDirectory.appendingPathComponent("tuff-restore-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                var zip = file
                var temporary: URL?
                defer { if let temporary { try? fm.removeItem(at: temporary) } }
                let data = try Data(contentsOf: file)
                if BackupCrypto.isProtected(data) {
                    let plain = try BackupCrypto.open(data, password: password ?? "")
                    let copy = fm.temporaryDirectory.appendingPathComponent("tuff-restore-\(UUID().uuidString).zip")
                    try plain.write(to: copy)
                    zip = copy
                    temporary = copy
                } else if !data.starts(with: Data("PK".utf8)) {
                    throw BackupError.notABackup
                }
                do { try Zip.extract(zip, to: folder) } catch { throw BackupError.notABackup }

                guard !containsSymbolicLink(folder) else { throw BackupError.notABackup }
                guard let manifestData = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")) else { throw BackupError.notABackup }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                guard let manifest = try? decoder.decode(BackupManifest.self, from: manifestData) else { throw BackupError.notABackup }
                guard manifest.format <= BackupManifest.currentFormat else { throw BackupError.newerFormat }
                return OpenedBackup(manifest: manifest, folder: folder)
            } catch {
                try? fm.removeItem(at: folder)
                throw error
            }
        }.value
    }
}

// MARK: - Restoring

/// A restore is staged, then applied while Tuff starts, before anything has read the files it
/// replaces. Replacing them under a running browser would only have it write its own copies
/// back over them at quit.
enum BackupRestore {
    private struct Plan: Codable {
        var items: [BackupItem]
        /// Paths in Application Support the restore replaces (removed if the backup has none).
        var replace: [String]
    }

    private static var pending: URL { Paths.appSupport.appendingPathComponent("PendingRestore", isDirectory: true) }
    /// What the last restore replaced, kept until the next one.
    private static var beforeRestore: URL { Paths.appSupport.appendingPathComponent("Before Restore", isDirectory: true) }

    /// Profiles in the backup that this Tuff doesn't have: per-profile data (bookmarks, history,
    /// passwords, cookies) restored without the spaces and profiles would have no place to show.
    static func missingProfiles(in backup: OpenedBackup, restoring items: Set<BackupItem>) -> [String] {
        guard !items.contains(.spaces) else { return [] }
        let known = Set(BrowserState.shared.profiles.map(\.id))
        let perProfile: Set<BackupItem> = [.bookmarks, .history, .passwords, .cookies]
        guard !items.isDisjoint(with: perProfile) else { return [] }
        return backup.manifest.profiles.filter { !known.contains($0.id) }.map(\.name)
    }

    /// Stages `items` from `backup` for the next launch.
    static func stage(_ backup: OpenedBackup, items requested: Set<BackupItem>) throws {
        var items = requested.intersection(backup.manifest.items)
        if !items.contains(.spaces) { items.remove(.tabs) }
        let fm = FileManager.default
        try? fm.removeItem(at: pending)
        let files = pending.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: files, withIntermediateDirectories: true)

        var replace: [String] = []
        for item in BackupItem.allCases where items.contains(item) {
            for path in item.paths {
                replace.append(path)
                let source = backup.folder.appendingPathComponent("files/" + path)
                guard fm.fileExists(atPath: source.path) else { continue }
                let target = files.appendingPathComponent(path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: target)
            }
        }
        // Open tabs left out of a backup that holds them.
        if items.contains(.spaces), !items.contains(.tabs) {
            let file = files.appendingPathComponent("session.json")
            if let data = try? Data(contentsOf: file), let stripped = BackupSession.withoutOpenTabs(data) {
                try stripped.write(to: file, options: .atomic)
            }
        }

        func carry(_ name: String) throws {
            let source = backup.folder.appendingPathComponent(name)
            if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: pending.appendingPathComponent(name)) }
        }
        if items.contains(.settings) { try carry("settings.json") }
        if items.contains(.sites) { try carry("external-app-links.json") }
        if items.contains(.cookies) { try carry("cookies.json") }

        try JSONEncoder().encode(Plan(items: BackupItem.allCases.filter(items.contains), replace: replace))
            .write(to: pending.appendingPathComponent("plan.json"))
    }

    /// First thing at launch: moves the staged files into place, keeping what they replace.
    static func applyPendingFiles() {
        let fm = FileManager.default
        let planFile = pending.appendingPathComponent("plan.json")
        guard let data = try? Data(contentsOf: planFile), let plan = try? JSONDecoder().decode(Plan.self, from: data) else {
            // A restore that was cut short while staging.
            if fm.fileExists(atPath: pending.path), !fm.fileExists(atPath: planFile.path) { try? fm.removeItem(at: pending) }
            return
        }
        try? fm.removeItem(at: beforeRestore)
        try? fm.createDirectory(at: beforeRestore, withIntermediateDirectories: true)
        for path in plan.replace {
            let current = Paths.appSupport.appendingPathComponent(path)
            let staged = pending.appendingPathComponent("files/" + path)
            if fm.fileExists(atPath: current.path) {
                let kept = beforeRestore.appendingPathComponent(path)
                try? fm.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.moveItem(at: current, to: kept)
            }
            if fm.fileExists(atPath: staged.path) {
                try? fm.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.moveItem(at: staged, to: current)
            }
        }
        if plan.replace.contains("session.json") {
            // The copy kept from the last launch would otherwise win if the new file can't be read.
            try? fm.removeItem(at: Paths.appSupport.appendingPathComponent("session.backup.json"))
        }
        let linksFile = pending.appendingPathComponent("external-app-links.json")
        if let answers = (try? Data(contentsOf: linksFile)).flatMap({ try? JSONDecoder().decode([String].self, from: $0) }) {
            UserDefaults.standard.set(answers, forKey: ExternalAppLinks.defaultsKey)
        }
        try? fm.removeItem(at: linksFile)
        try? fm.removeItem(at: pending.appendingPathComponent("files"))
        // Only what must wait for the app to be running stays: settings and cookies.
        try? fm.removeItem(at: planFile)
        finishIfDone()
    }

    /// Before the session is restored: puts the backed-up settings in.
    static func applyPendingSettings() {
        let file = pending.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: file) else { return }
        AppSettings.shared.importData(data)
        AppSettings.shared.saveNow()
        try? FileManager.default.removeItem(at: file)
        finishIfDone()
    }

    /// Once profiles exist: puts the backed-up cookies into their profiles' stores.
    @MainActor
    static func applyPendingCookies() async {
        let file = pending.appendingPathComponent("cookies.json")
        guard let data = try? Data(contentsOf: file), let sets = try? JSONDecoder().decode([BackupCookieSet].self, from: data) else { return }
        let profiles = BrowserState.shared.profiles
        for set in sets {
            let store: WKWebsiteDataStore
            if let profile = profiles.first(where: { $0.id == set.profile }) {
                store = profile.dataStore
            } else if set.shared {
                store = DataStores.website
            } else {
                continue
            }
            let cookieStore = store.httpCookieStore
            for old in await cookieStore.allCookies() { await cookieStore.deleteCookie(old) }
            let restored = set.cookies.compactMap(\.httpCookie)
            for cookie in restored { await cookieStore.setCookie(cookie) }
            NSLog("Tuff: restored \(restored.count) cookies into \(set.profile)")
        }
        try? FileManager.default.removeItem(at: file)
        finishIfDone()
    }

    private static func finishIfDone() {
        let fm = FileManager.default
        let left = (try? fm.contentsOfDirectory(atPath: pending.path)) ?? []
        if left.filter({ $0 != ".DS_Store" }).isEmpty { try? fm.removeItem(at: pending) }
    }

    /// Quits Tuff, then opens it again, which applies what is staged.
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \"$2\"",
            "tuff-relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath,
        ]
        try? process.run()
        AppDelegate.shared?.quitWithoutAsking()
    }
}
