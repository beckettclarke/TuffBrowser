import CryptoKit
import Foundation
import Observation

/// A saved sign-in for one site.
struct SavedLogin: Codable, Identifiable, Equatable {
    var id = UUID()
    /// `scheme://host[:port]`, as `SitePermissions.origin(of:)` makes it.
    var origin: String
    var username: String
    var password: String
    var profile: UUID
    var created = Date()
    var lastUsed: Date?

    var host: String { URL(string: origin)?.host(percentEncoded: false) ?? origin }
    /// The host without "www.", for lists.
    var displayName: String { URL(string: origin)?.displayHost ?? origin }
}

/// Saved passwords, per profile (Incognito windows use the main window's, as for bookmarks).
///
/// They are kept encrypted (AES-GCM) in `passwords.sealed`, with the key in `passwords.key`
/// beside it, readable by this user only. That is Firefox's arrangement without a primary
/// password. The keychain would protect the key better, but Tuff is signed ad hoc, so the
/// keychain treats every update as a new app and would ask for the login password after each
/// one. Showing or exporting passwords in Settings asks for Touch ID or the Mac's password
/// (`PasswordsPage`).
@Observable
final class PasswordStore {
    static let shared = PasswordStore()

    private(set) var logins: [SavedLogin] = []
    /// Sites never to offer saving for (origins).
    private(set) var never: [String] = []

    @ObservationIgnored private let file: URL
    @ObservationIgnored private let keyFile: URL
    @ObservationIgnored private lazy var key: SymmetricKey? = loadKey()
    @ObservationIgnored private let queue = DispatchQueue(label: "tuff.passwords-save")

    private struct Vault: Codable {
        var logins: [SavedLogin] = []
        var never: [String] = []
    }

    init(folder: URL = Paths.appSupport) {
        file = folder.appendingPathComponent("passwords.sealed")
        keyFile = folder.appendingPathComponent("passwords.key")
        guard let sealed = try? Data(contentsOf: file), let key,
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let data = try? AES.GCM.open(box, using: key),
              let vault = try? JSONDecoder().decode(Vault.self, from: data) else { return }
        logins = vault.logins
        never = vault.never
    }

    // MARK: Lookup

    /// Logins for a page's origin: those saved for exactly that origin first, then ones from
    /// other parts of the same site (accounts.example.com for www.example.com) over the same
    /// scheme, most recently used first.
    func logins(for origin: String, profile: UUID) -> [SavedLogin] {
        guard let url = URL(string: origin), let scheme = url.scheme else { return [] }
        let site = url.hostParts.domain
        let mine = logins.filter { $0.profile == profile }
        let exact = mine.filter { $0.origin == origin }
        let sameSite = mine.filter {
            $0.origin != origin && URL(string: $0.origin).map { $0.scheme == scheme && $0.hostParts.domain == site } == true
        }
        let recent: (SavedLogin, SavedLogin) -> Bool = { ($0.lastUsed ?? $0.created) > ($1.lastUsed ?? $1.created) }
        return exact.sorted(by: recent) + sameSite.sorted(by: recent)
    }

    func login(withID id: UUID) -> SavedLogin? { logins.first { $0.id == id } }

    func isNever(_ origin: String) -> Bool { never.contains(origin) }

    // MARK: Changes

    /// Saves a sign-in, replacing the password of the same username on the same site.
    @discardableResult
    func save(origin: String, username: String, password: String, profile: UUID) -> SavedLogin {
        if let index = logins.firstIndex(where: { $0.origin == origin && $0.username == username && $0.profile == profile }) {
            logins[index].password = password
            logins[index].lastUsed = Date()
            persist()
            return logins[index]
        }
        let login = SavedLogin(origin: origin, username: username, password: password, profile: profile)
        logins.append(login)
        never.removeAll { $0 == origin }
        persist()
        return login
    }

    func update(_ id: UUID, username: String, password: String) {
        guard let index = logins.firstIndex(where: { $0.id == id }) else { return }
        logins[index].username = username
        logins[index].password = password
        persist()
    }

    func markUsed(_ id: UUID) {
        guard let index = logins.firstIndex(where: { $0.id == id }) else { return }
        logins[index].lastUsed = Date()
        persist()
    }

    func remove(_ id: UUID) {
        logins.removeAll { $0.id == id }
        persist()
    }

    /// Removes saved logins matching the browsingData filter (optional `since` date, `origins` or `excludeOrigins`).
    func remove(since: Date? = nil, origins: Set<String>? = nil, excludeOrigins: Set<String>? = nil) {
        let before = logins.count
        let normalizedOrigins = origins.map { Set($0.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }) }
        let normalizedExcluded = excludeOrigins.map { Set($0.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }) }
        logins.removeAll { login in
            if let since, login.created < since { return false }
            let origin = login.origin.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let normalizedOrigins, !normalizedOrigins.contains(origin) { return false }
            if let normalizedExcluded, normalizedExcluded.contains(origin) { return false }
            return true
        }
        if logins.count != before { persist() }
    }

    func neverSave(_ origin: String) {
        guard !never.contains(origin) else { return }
        never.append(origin)
        never.sort()
        persist()
    }

    func removeNever(_ origin: String) {
        never.removeAll { $0 == origin }
        persist()
    }

    /// A deleted profile's passwords go to the profile that takes its place, as its bookmarks do.
    /// A login the other profile already has for the same site and username keeps that one.
    func moveAll(from old: UUID, to new: UUID) {
        guard logins.contains(where: { $0.profile == old }) else { return }
        let kept = Set(logins.filter { $0.profile == new }.map { "\($0.origin)|\($0.username)" })
        logins.removeAll { $0.profile == old && kept.contains("\($0.origin)|\($0.username)") }
        for index in logins.indices where logins[index].profile == old { logins[index].profile = new }
        persist()
    }

    /// What sync brought: logins to add or replace (by ID), and ones deleted elsewhere.
    func applySync(_ upserts: [SavedLogin], removing removals: Set<UUID>) {
        guard !upserts.isEmpty || !removals.isEmpty else { return }
        logins.removeAll { removals.contains($0.id) }
        for login in upserts {
            if let index = logins.firstIndex(where: { $0.id == login.id }) { logins[index] = login } else { logins.append(login) }
        }
        persist()
    }

    /// Posted whenever passwords change (sync uploads the changes).
    static let didChange = Notification.Name("TuffPasswordsChanged")

    // MARK: CSV

    /// Reads the CSV Chrome, Safari, Firefox and 1Password export (a header row naming the
    /// columns: url / website, username / login, password). Returns how many were added or
    /// changed.
    @discardableResult
    func importCSV(_ text: String, profile: UUID) -> Int {
        let rows = CSV.parse(text)
        guard let header = rows.first?.map({ $0.lowercased().trimmed }) else { return 0 }
        func column(_ names: [String]) -> Int? { header.firstIndex { names.contains($0) } }
        guard let urlColumn = column(["url", "website", "login_uri", "web site", "origin"]),
              let userColumn = column(["username", "login", "login_username", "user name", "email"]),
              let passwordColumn = column(["password", "login_password"]) else { return 0 }
        var count = 0
        for row in rows.dropFirst() where row.count > max(urlColumn, userColumn, passwordColumn) {
            let address = row[urlColumn].trimmed
            let url = URL(string: address.contains("://") ? address : "https://" + address)
            guard let origin = SitePermissions.origin(of: url), !row[passwordColumn].isEmpty else { continue }
            let username = row[userColumn].trimmed
            if let existing = logins.first(where: { $0.origin == origin && $0.username == username && $0.profile == profile }),
               existing.password == row[passwordColumn] { continue }
            if let index = logins.firstIndex(where: { $0.origin == origin && $0.username == username && $0.profile == profile }) {
                logins[index].password = row[passwordColumn]
            } else {
                logins.append(SavedLogin(origin: origin, username: username, password: row[passwordColumn], profile: profile))
            }
            count += 1
        }
        if count > 0 { persist() }
        return count
    }

    /// A profile's passwords in the CSV format the import reads (and Chrome writes).
    func exportCSV(profile: UUID) -> String {
        var lines = ["name,url,username,password"]
        for login in logins where login.profile == profile {
            lines.append([login.displayName, login.origin + "/", login.username, login.password].map(CSV.escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Disk

    private func persist() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
        guard let key, let data = try? JSONEncoder().encode(Vault(logins: logins, never: never)),
              let sealed = try? AES.GCM.seal(data, using: key).combined else { return }
        let file = file
        queue.async {
            do {
                try sealed.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch {
                NSLog("Tuff: couldn't save passwords: \(error.localizedDescription)")
            }
        }
    }

    private func loadKey() -> SymmetricKey? {
        if let data = try? Data(contentsOf: keyFile), data.count == 32 { return SymmetricKey(data: data) }
        // A sealed file without its key can't be read again; never replace that key.
        if FileManager.default.fileExists(atPath: file.path) { return nil }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        do {
            try data.write(to: keyFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        } catch {
            NSLog("Tuff: couldn't save the passwords key: \(error.localizedDescription)")
            return nil
        }
        return key
    }
}

/// Just enough CSV for password exports: quoted fields, doubled quotes, newlines inside quotes.
enum CSV {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n", "\r":
                    row.append(field); field = ""
                    if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                    row = []
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
