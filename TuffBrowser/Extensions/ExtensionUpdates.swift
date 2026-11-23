import Foundation

/// Keeps store-installed extensions current, the way Chrome and Firefox do: a check shortly
/// after launch and then every few hours, asking each store for the latest version and
/// reinstalling (keeping the extension's data, links and pin) only when it is newer.
extension ExtensionManager {
    /// How often installed extensions are checked against their store.
    static let updateInterval: TimeInterval = 5 * 60 * 60

    private static let lastCheckKey = "ExtensionsLastUpdateCheck"

    /// Starts the periodic check. Safe to call more than once.
    func scheduleUpdateChecks() {
        guard updateTimer == nil else { return }
        #if DEBUG
        if ProcessInfo.processInfo.environment["TUFF_NO_EXTENSION_UPDATES"] != nil { return }
        #endif
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        // Don't compete with launch: the first check waits a minute, or until the interval is up.
        let firstDelay = max(60, Self.updateInterval - Date().timeIntervalSince(last))
        updateTimer = Timer.scheduledTimer(withTimeInterval: firstDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.checkForUpdates() }
            self.updateTimer = Timer.scheduledTimer(withTimeInterval: Self.updateInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.checkForUpdates() }
            }
        }
    }

    /// Checks every store extension and installs the newer ones. Returns the names updated.
    @MainActor @discardableResult
    func checkForUpdates() async -> [String] {
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        var updated: [String] = []
        for record in records where record.storeID != nil && record.source != .unpacked {
            guard let latest = await Self.latestVersion(of: record),
                  Self.isVersion(latest, newerThan: record.version) else {
                Self.forgetAnnouncedUpdate(record.id)
                continue
            }
            if offerUpdate(record, version: latest) { continue }
            if await updateNow(record) { updated.append(record.name) }
        }
        return updated
    }

    // MARK: runtime.onUpdateAvailable

    private static let announcedKey = "ExtensionsAnnouncedUpdates"
    /// extension id -> the version it was told about this run, which waits for `runtime.reload()`.
    private static var waitingUpdates: [String: String] = [:]

    /// Chrome lets an extension that listens for `runtime.onUpdateAvailable` choose its moment: it
    /// is told about the new version, which is installed when it calls `runtime.reload()` or when
    /// the browser next starts. Returns whether the update waits.
    @MainActor
    func offerUpdate(_ record: ExtensionRecord, version: String) -> Bool {
        if Self.waitingUpdates[record.id] != nil { return true }
        var announced = UserDefaults.standard.dictionary(forKey: Self.announcedKey) as? [String: String] ?? [:]
        // Told before Tuff last quit: this is the restart it was waiting for.
        if announced[record.id] != nil {
            Self.forgetAnnouncedUpdate(record.id)
            return false
        }
        guard ExtensionEventPush.shared.isListening(extensionID: record.id, to: "runtime.onUpdateAvailable") else { return false }
        Self.waitingUpdates[record.id] = version
        announced[record.id] = version
        UserDefaults.standard.set(announced, forKey: Self.announcedKey)
        ExtensionEventPush.shared.emit("runtime.onUpdateAvailable", args: [["version": version]], to: record.id)
        return true
    }

    /// An extension with an update waiting reloaded itself (`runtime.reload()`): installs the
    /// update, which reloads it again on the new version. Returns whether there was one.
    func installWaitingUpdate(id: String) -> Bool {
        guard Self.waitingUpdates.removeValue(forKey: id) != nil,
              let record = records.first(where: { $0.id == id }) else { return false }
        Self.forgetAnnouncedUpdate(id)
        Task { @MainActor in await updateNow(record) }
        return true
    }

    private static func forgetAnnouncedUpdate(_ id: String) {
        guard var announced = UserDefaults.standard.dictionary(forKey: announcedKey) as? [String: String],
              announced.removeValue(forKey: id) != nil else { return }
        UserDefaults.standard.set(announced, forKey: announcedKey)
    }

    /// The menu's "Check for Update": installs a newer version if the store has one, and says
    /// so either way.
    func updateFromStore(id: String) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        if record.source == .unpacked { reload(id: id); return }
        guard record.storeID != nil else { return }
        Task { @MainActor in
            status = "Checking for updates…"
            let latest = await Self.latestVersion(of: record)
            status = nil
            if let latest, !Self.isVersion(latest, newerThan: record.version) {
                BrowserState.shared.show(Toast(symbol: "checkmark.circle", text: "\(record.name) is up to date (\(record.version))"))
                return
            }
            // A newer version, or the store couldn't say: reinstall from the store.
            await updateNow(record)
        }
    }

    @MainActor @discardableResult
    private func updateNow(_ record: ExtensionRecord) async -> Bool {
        guard let storeID = record.storeID else { return false }
        switch record.source {
        case .chrome: return await installNow(.chrome(id: storeID), confirm: false)
        case .firefox: return await installNow(.firefox(slug: storeID), confirm: false)
        case .unpacked: return false
        }
    }

    // MARK: Asking the stores

    /// The version the extension's store currently offers, or nil if it couldn't be found out.
    static func latestVersion(of record: ExtensionRecord) async -> String? {
        guard let storeID = record.storeID else { return nil }
        switch record.source {
        case .chrome: return await chromeLatestVersion(id: storeID, installed: record.version)
        case .firefox: return await firefoxLatestVersion(slug: storeID)
        case .unpacked: return nil
        }
    }

    /// Chrome's update service answers an `updatecheck` with XML naming the newest version
    /// (`status="ok" version="…"`) or `status="noupdate"`.
    private static func chromeLatestVersion(id: String, installed: String) async -> String? {
        let v = installed.isEmpty ? "0.0.0.0" : installed
        let x = "id%3D\(id)%26v%3D\(v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v)%26installsource%3Dondemand%26uc"
        guard let url = URL(string: "https://clients2.google.com/service/update2/crx?response=updatecheck&os=mac&arch=\(chromeArch)&os_arch=\(chromeArch)&prod=chromecrx&prodchannel=stable&prodversion=\(chromeProdVersion)&acceptformat=crx3&x=\(x)"),
              let xml = await fetchText(url) else { return nil }
        guard let check = xml.range(of: "<updatecheck[^>]*>", options: .regularExpression).map({ String(xml[$0]) }) else { return nil }
        return updateCheckVersion(in: check, installed: installed)
    }

    /// The version an `<updatecheck …>` tag offers (the installed one for `noupdate`).
    static func updateCheckVersion(in tag: String, installed: String) -> String? {
        if tag.contains("status=\"noupdate\"") { return installed }
        return attribute("version", in: tag)
    }

    /// addons.mozilla.org's API reports the listed add-on's current version.
    private static func firefoxLatestVersion(slug: String) async -> String? {
        let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        guard let url = URL(string: "https://addons.mozilla.org/api/v5/addons/addon/\(encoded)/"),
              let text = await fetchText(url),
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let current = json["current_version"] as? [String: Any] else { return nil }
        return current["version"] as? String
    }

    private static func fetchText(_ url: URL) async -> String? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(AdvancedSettings.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        // A whole attribute name: `version=`, not the end of `prodversion=`.
        guard let range = tag.range(of: "\\s\(name)=\"[^\"]*\"", options: .regularExpression) else { return nil }
        return String(tag[range].dropFirst(name.count + 3).dropLast())
    }

    // MARK: Versions

    /// Compares dotted versions part by part as numbers ("1.10" is newer than "1.9"). Firefox
    /// suffixes such as "2.0b1" compare by their leading number; a missing part counts as 0.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { part in Int(part.prefix(while: \.isNumber)) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
