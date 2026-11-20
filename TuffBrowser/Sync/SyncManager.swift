import AppKit
import CryptoKit
import Observation

/// What can be synced, by Firefox Sync's collection names.
enum SyncKind: String, CaseIterable, Identifiable, Codable {
    case bookmarks, history, passwords, tabs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bookmarks: "Bookmarks"
        case .history: "History"
        case .passwords: "Passwords"
        case .tabs: "Open tabs"
        }
    }

    var detail: String {
        switch self {
        case .bookmarks: "Your bookmarks bar, and Firefox’s Bookmarks Menu, Other Bookmarks and Mobile Bookmarks."
        case .history: "Pages you visit. Clearing all history here doesn’t clear it on other devices."
        case .passwords: "Saved sign-ins, end-to-end encrypted with your account’s key."
        case .tabs: "See the tabs open on your other devices in the History menu, and let them see yours."
        }
    }

    var symbol: String {
        switch self {
        case .bookmarks: "star.fill"
        case .history: "clock.fill"
        case .passwords: "key.fill"
        case .tabs: "macwindow.on.rectangle"
        }
    }

    /// The record format version Tuff writes (meta/global's engine versions).
    var version: Int { self == .bookmarks ? 2 : 1 }
}

/// Another device on the account and the tabs it has open.
struct SyncDevice: Identifiable, Equatable {
    struct OpenTab: Equatable {
        var title: String
        var url: URL
        var lastUsed: Date
    }

    let id: String
    var name: String
    /// "desktop", "mobile", "tablet"…
    var type: String
    var tabs: [OpenTab] = []

    var symbol: String {
        switch type {
        case "mobile", "phone": "iphone"
        case "tablet": "ipad"
        default: "laptopcomputer"
        }
    }
}

/// What sync keeps between launches besides the account: per-engine progress, the ID mapping
/// between Tuff's items and the server's, and the server's last-agreed copy of each bookmark and
/// password (sealed with the account, since that includes passwords).
struct SyncState: Codable {
    struct Engine: Codable {
        var syncID: String?
        /// Server time of the last change this device has seen.
        var lastSync: Double = 0
    }

    var profileID: UUID?
    /// This browser's record in the clients and tabs collections.
    var clientID = SyncGUID.make()
    var globalSyncID: String?
    var engines: [String: Engine] = [:]
    /// Each kind's switch; missing until the first sync decides it from the account.
    var enabled: [String: Bool] = [:]
    var lastSynced: Date?

    var bookmarkIDs: [UUID: String] = [:]
    /// GUID → the record's cleartext JSON.
    var bookmarkMirror: [String: String] = [:]

    var loginIDs: [UUID: String] = [:]
    var loginMirror: [String: String] = [:]

    /// Address → GUID.
    var historyGUIDs: [String: String] = [:]
    /// Address → the latest visit the server has (seconds).
    var historySynced: [String: Double] = [:]
    /// GUIDs of pages deleted here, still to delete on the server.
    var historyRemoved: [String] = []

    var tabsHash: String?
    var clientHash: String?
    var clientUploaded: Date?
}

/// Firefox Sync: Tuff's bookmarks, history, passwords and open tabs, end-to-end encrypted on
/// Mozilla's servers, shared with Firefox, Zen and every other browser signed in to the same
/// Mozilla account (and other Macs running Tuff).
///
/// Syncs a little after launch, every ten minutes, when Tuff comes forward after a while, and
/// shortly after bookmarks or passwords change. One profile syncs (Settings → Sync).
@MainActor
@Observable
final class SyncManager {
    static let shared = SyncManager()

    enum Status: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    private(set) var account: MozillaAccountState?
    private(set) var status: Status = .idle
    private(set) var lastSynced: Date?
    /// The sign-in tab finished and Tuff is setting the account up.
    private(set) var finishingSignIn = false
    /// The account's token was revoked (password changed, signed out from the web).
    private(set) var needsSignIn = false
    /// The other devices on the account, with their open tabs, newest first.
    private(set) var devices: [SyncDevice] = []
    /// Bumped when the switches or profile change, so views re-read them.
    private(set) var revision = 0

    @ObservationIgnored private var state = SyncState()
    @ObservationIgnored private var signIn: MozillaAccount.SignIn?
    @ObservationIgnored private var storage: SyncStorage?
    @ObservationIgnored private var limitsLoaded = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var running = false
    @ObservationIgnored private var runAgain = false
    /// Set while sync itself changes the stores, so those changes don't start another sync.
    @ObservationIgnored private var applying = false
    @ObservationIgnored private let changes = Debouncer(delay: 15)
    @ObservationIgnored private let vault = SealedFolder(folder: Paths.appSupport.appendingPathComponent("Sync", isDirectory: true))

    private static let accountFile = "account.sealed"
    private static let stateFile = "state.sealed"
    /// Clients and tabs records expire after three weeks without a refresh, as Firefox's do.
    private static let recordTTL = 21 * 24 * 3600

    private init() {
        if let data = vault.read(Self.accountFile) { account = try? JSONDecoder().decode(MozillaAccountState.self, from: data) }
        if account != nil, let data = vault.read(Self.stateFile), let saved = try? JSONDecoder().decode(SyncState.self, from: data) {
            state = saved
        }
        lastSynced = state.lastSynced
    }

    // MARK: Lifecycle

    /// At launch: syncs soon, then on a timer, when Tuff comes forward, and after local changes.
    func start() {
        guard !started, NSClassFromString("XCTestCase") == nil else { return }
        started = true
        let center = NotificationCenter.default
        for name in [BookmarkStore.didChange, PasswordStore.didChange] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SyncManager.shared.localChanged() }
            }
        }
        center.addObserver(forName: HistoryStore.pagesRemoved, object: nil, queue: .main) { note in
            let urls = note.userInfo?["urls"] as? [URL] ?? []
            let profile = note.userInfo?["profileID"] as? UUID
            MainActor.assumeIsolated { SyncManager.shared.historyRemoved(urls, profile: profile) }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let manager = SyncManager.shared
                if (manager.lastSynced ?? .distantPast).timeIntervalSinceNow < -5 * 60 { manager.syncNow() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { SyncManager.shared.syncNow() }
        }
        guard account != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { SyncManager.shared.syncNow() }
    }

    private func localChanged() {
        guard account != nil, !applying else { return }
        changes.schedule { SyncManager.shared.syncNow() }
    }

    private func historyRemoved(_ urls: [URL], profile: UUID?) {
        guard account != nil, !applying, profile == state.profileID, isEnabled(.history) else { return }
        let guids = urls.compactMap { state.historyGUIDs[$0.absoluteString] }
        guard !guids.isEmpty else { return }
        state.historyRemoved += guids
        for url in urls {
            state.historyGUIDs[url.absoluteString] = nil
            state.historySynced[url.absoluteString] = nil
        }
        saveState()
        localChanged()
    }

    // MARK: Settings

    var isSignedIn: Bool { account != nil }

    func isEnabled(_ kind: SyncKind) -> Bool { state.enabled[kind.rawValue] ?? true }

    func setEnabled(_ kind: SyncKind, _ on: Bool) {
        guard isEnabled(kind) != on else { return }
        state.enabled[kind.rawValue] = on
        if !on, kind == .tabs { devices = [] }
        revision += 1
        saveState()
        if on { syncNow() }
    }

    /// The profile whose bookmarks, history and passwords sync.
    var profileID: UUID? {
        get { state.profileID }
        set {
            guard newValue != state.profileID else { return }
            state.profileID = newValue
            // Another profile's items are new to the account: merge them in from scratch.
            for kind in SyncKind.allCases { reset(kind) }
            state.bookmarkIDs = [:]
            state.loginIDs = [:]
            state.historyGUIDs = [:]
            revision += 1
            saveState()
            syncNow()
        }
    }

    // MARK: Signing in

    /// Opens Mozilla's sign-in page in a new tab of the browser window.
    func beginSignIn() {
        let request = MozillaAccount.SignIn()
        signIn = request
        AppDelegate.shared?.showMainWindow()
        BrowserState.shared.newTab(url: request.url)
    }

    /// The sign-in page finished: takes the redirect (which never loads), closes its tab and
    /// sets up the account. False for any other address.
    func handleRedirect(_ url: URL, from tab: Tab?) -> Bool {
        guard MozillaAccount.isRedirect(url), let request = signIn else { return false }
        signIn = nil
        if let tab { DispatchQueue.main.async { tab.browser?.close(tab, force: true) } }
        finishingSignIn = true
        status = .idle
        let settingsWasOpen = AppDelegate.shared?.visibleSettingsWindow != nil
        Task { @MainActor in
            do {
                let account = try await MozillaAccount.finish(request, redirect: url)
                self.finishingSignIn = false
                self.signedIn(account)
                BrowserState.shared.show(Toast(symbol: "arrow.triangle.2.circlepath", text: account.email.isEmpty ? "Signed in · Syncing" : "Signed in as \(account.email)"))
                if settingsWasOpen { AppDelegate.shared?.showSettings(tab: .sync) }
            } catch {
                self.status = .failed(error.localizedDescription)
                BrowserState.shared.show(Toast(symbol: "exclamationmark.triangle.fill", text: "Couldn’t sign in to sync"))
                AppDelegate.shared?.showSettings(tab: .sync)
            }
            self.finishingSignIn = false
        }
        return true
    }

    private func signedIn(_ new: MozillaAccountState) {
        let sameAccount = account?.uid != nil && account?.uid == new.uid
        account = new
        needsSignIn = false
        storage = nil
        limitsLoaded = false
        if !sameAccount {
            // A different account (or the first): start over, keeping the switches.
            let enabled = state.enabled
            state = SyncState()
            state.enabled = enabled
            lastSynced = nil
        }
        if state.profileID == nil { state.profileID = BrowserState.shared.profiles.first?.id }
        if let data = try? JSONEncoder().encode(new) { vault.write(data, to: Self.accountFile) }
        saveState()
        revision += 1
        syncNow()
    }

    #if DEBUG
    /// Signs in to `scripts/fake-sync-server.py` with its fixed key, without the web sign-in.
    func debugSignIn(syncKey: String) {
        signedIn(MozillaAccountState(uid: "debug", email: "sync@example.com", refreshToken: "debug", syncKey: syncKey, keyID: "1-debug"))
    }
    #endif

    /// Forgets the account on this Mac and takes this browser off its device list. What was
    /// synced stays.
    func signOut() {
        if let account { Task { await MozillaAccount.signOut(account) } }
        account = nil
        storage = nil
        signIn = nil
        state = SyncState()
        lastSynced = nil
        devices = []
        status = .idle
        needsSignIn = false
        vault.remove(Self.accountFile)
        vault.remove(Self.stateFile)
        revision += 1
    }

    // MARK: Syncing

    func syncNow() {
        guard account != nil, !needsSignIn, !finishingSignIn else { return }
        if running {
            runAgain = true
            return
        }
        running = true
        status = .syncing
        Task { @MainActor in
            repeat {
                runAgain = false
                do {
                    try await run()
                    status = .idle
                    state.lastSynced = Date()
                    lastSynced = state.lastSynced
                } catch SyncError.conflict {
                    // Someone else was writing; go again in a moment.
                    status = .idle
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { SyncManager.shared.syncNow() }
                } catch SyncError.signedOut {
                    needsSignIn = true
                    status = .failed(SyncError.signedOut.localizedDescription)
                } catch {
                    status = .failed(error.localizedDescription)
                }
                saveState()
            } while runAgain && account != nil && !needsSignIn
            running = false
        }
    }

    private func saveState() {
        guard account != nil, let data = try? JSONEncoder().encode(state) else { return }
        vault.write(data, to: Self.stateFile)
    }

    /// Everything one sync does.
    private func run() async throws {
        guard let account else { return }
        let storage = self.storage ?? SyncStorage(account: account)
        self.storage = storage
        if !limitsLoaded {
            await storage.loadLimits()
            limitsLoaded = true
        }
        let info = try await storage.collections()
        let keys = try await prepare(storage, account: account)
        let session = Session(storage: storage, keys: keys, info: info)

        let clients = try await syncClients(session)
        guard let profile = state.profileID ?? BrowserState.shared.profiles.first?.id else { return }
        if state.profileID == nil { state.profileID = profile }
        for kind in SyncKind.allCases where isEnabled(kind) && !skipped.contains(kind) {
            switch kind {
            case .bookmarks: try await syncBookmarks(session, profile: profile)
            case .history: try await syncHistory(session, profile: profile)
            case .passwords: try await syncPasswords(session, profile: profile)
            case .tabs: try await syncTabs(session, profile: profile, clients: clients)
            }
            saveState()
        }
    }

    /// The keys that open each collection, from crypto/keys.
    struct Keys {
        var fallback: SyncKeyBundle
        var collections: [String: SyncKeyBundle] = [:]
        func bundle(for collection: String) -> SyncKeyBundle { collections[collection] ?? fallback }
    }

    private struct Session {
        let storage: SyncStorage
        let keys: Keys
        let info: [String: Double]

        func decrypt(_ record: SyncRecord, _ collection: String) -> [String: Any]? {
            guard let data = try? keys.bundle(for: collection).decrypt(record.payload) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }

        func encrypt(_ cleartext: [String: Any], _ collection: String) throws -> String {
            try keys.bundle(for: collection).encrypt(JSONSerialization.data(withJSONObject: cleartext))
        }
    }

    /// Kinds the account stores in a newer format than Tuff writes; left alone.
    @ObservationIgnored private var skipped: Set<SyncKind> = []

    // MARK: meta/global and crypto/keys

    /// Reads (or, for an account that has never synced, creates) meta/global and crypto/keys,
    /// starts over any kind another device reset, and adds the kinds this device syncs that the
    /// account doesn't have yet.
    private func prepare(_ storage: SyncStorage, account: MozillaAccountState) async throws -> Keys {
        guard let syncKey = Data(base64URL: account.syncKey).flatMap(SyncKeyBundle.init(syncKey:)) else { throw SyncError.wrongKey }
        guard let metaRecord = try await storage.record("meta", "global") else {
            return try await freshStart(storage, syncKey: syncKey)
        }
        guard var meta = (try? JSONSerialization.jsonObject(with: Data(metaRecord.payload.utf8))) as? [String: Any] else {
            throw SyncError.badRecord
        }
        let version = (meta["storageVersion"] as? NSNumber)?.intValue ?? 0
        if version > 5 { throw SyncError.newerStorage }
        if version < 5 { return try await freshStart(storage, syncKey: syncKey) }
        guard let keysRecord = try await storage.record("crypto", "keys") else {
            return try await freshStart(storage, syncKey: syncKey)
        }
        let keys = try Self.keys(from: keysRecord, syncKey: syncKey)

        let syncID = meta["syncID"] as? String
        if syncID != state.globalSyncID {
            // The account was started over somewhere: everything is new again.
            for kind in SyncKind.allCases { reset(kind) }
            state.globalSyncID = syncID
        }

        var engines = meta["engines"] as? [String: Any] ?? [:]
        var declined = meta["declined"] as? [String] ?? []
        var changed = false
        skipped = []
        for kind in SyncKind.allCases {
            // The first time, follow what the account's other devices chose.
            if state.enabled[kind.rawValue] == nil { state.enabled[kind.rawValue] = !declined.contains(kind.rawValue) }
            guard isEnabled(kind) else { continue }
            if let entry = engines[kind.rawValue] as? [String: Any] {
                if ((entry["version"] as? NSNumber)?.intValue ?? 0) > kind.version {
                    skipped.insert(kind)
                    continue
                }
                let engineID = entry["syncID"] as? String
                if engineID != state.engines[kind.rawValue]?.syncID {
                    reset(kind)
                    state.engines[kind.rawValue] = SyncState.Engine(syncID: engineID)
                }
            } else {
                let engineID = SyncGUID.make()
                engines[kind.rawValue] = ["version": kind.version, "syncID": engineID]
                declined.removeAll { $0 == kind.rawValue }
                reset(kind)
                state.engines[kind.rawValue] = SyncState.Engine(syncID: engineID)
                changed = true
            }
        }
        if engines["clients"] == nil {
            engines["clients"] = ["version": 1, "syncID": SyncGUID.make()]
            changed = true
        }
        if changed {
            meta["engines"] = engines
            meta["declined"] = declined
            let payload = String(decoding: try JSONSerialization.data(withJSONObject: meta), as: UTF8.self)
            try await storage.put("meta", SyncUpload(id: "global", payload: payload), ifUnmodifiedSince: metaRecord.modified)
        }
        revision += 1
        return keys
    }

    private static func keys(from record: SyncRecord, syncKey: SyncKeyBundle) throws -> Keys {
        let data = try syncKey.decrypt(record.payload)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fallback = (object["default"] as? [Any]).flatMap(SyncKeyBundle.init(base64Pair:)) else { throw SyncError.badRecord }
        var keys = Keys(fallback: fallback)
        for (name, pair) in object["collections"] as? [String: Any] ?? [:] {
            if let bundle = (pair as? [Any]).flatMap(SyncKeyBundle.init(base64Pair:)) { keys.collections[name] = bundle }
        }
        return keys
    }

    /// An account with nothing usable on the server: clears it, then sets it up with new keys.
    private func freshStart(_ storage: SyncStorage, syncKey: SyncKeyBundle) async throws -> Keys {
        try await storage.wipe()
        let keys = Keys(fallback: .random())
        let keysPayload = try syncKey.encrypt(JSONSerialization.data(withJSONObject: [
            "id": "keys", "collection": "crypto", "default": keys.fallback.base64Pair, "collections": [String: Any](),
        ]))
        try await storage.put("crypto", SyncUpload(id: "keys", payload: keysPayload))

        let syncID = SyncGUID.make()
        var engines: [String: Any] = ["clients": ["version": 1, "syncID": SyncGUID.make()]]
        var declined: [String] = []
        for kind in SyncKind.allCases {
            reset(kind)
            if isEnabled(kind) {
                let engineID = SyncGUID.make()
                engines[kind.rawValue] = ["version": kind.version, "syncID": engineID]
                state.engines[kind.rawValue] = SyncState.Engine(syncID: engineID)
                state.enabled[kind.rawValue] = true
            } else {
                declined.append(kind.rawValue)
            }
        }
        let meta: [String: Any] = ["syncID": syncID, "storageVersion": 5, "engines": engines, "declined": declined]
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: meta), as: UTF8.self)
        try await storage.put("meta", SyncUpload(id: "global", payload: payload))
        state.globalSyncID = syncID
        state.clientHash = nil
        skipped = []
        return keys
    }

    /// Forgets a kind's progress, so its next sync merges everything (IDs already matched stay).
    private func reset(_ kind: SyncKind) {
        state.engines[kind.rawValue] = nil
        switch kind {
        case .bookmarks: state.bookmarkMirror = [:]
        case .passwords: state.loginMirror = [:]
        case .history:
            state.historySynced = [:]
            state.historyRemoved = []
        case .tabs: state.tabsHash = nil
        }
    }

    private func engine(_ kind: SyncKind) -> SyncState.Engine { state.engines[kind.rawValue] ?? SyncState.Engine() }

    /// The time to make uploads conditional on: the collection's, as last seen.
    private static func since(_ values: Double...) -> Double? {
        let value = values.max() ?? 0
        return value > 0 ? value : nil
    }

    // MARK: Clients

    /// Reads the account's devices, carries out what they asked of this one (open a page), and
    /// keeps this browser's own record fresh. Returns the other devices by client ID.
    private func syncClients(_ session: Session) async throws -> [String: SyncDevice] {
        let (records, modified) = try await session.storage.records("clients", newer: nil)
        var others: [String: SyncDevice] = [:]
        var commands: [[String: Any]] = []
        for record in records {
            guard let object = session.decrypt(record, "clients"), object["deleted"] as? Bool != true else { continue }
            if record.id == state.clientID {
                commands = object["commands"] as? [[String: Any]] ?? []
                continue
            }
            let name = object["name"] as? String ?? "Unnamed device"
            others[record.id] = SyncDevice(id: record.id, name: name, type: object["type"] as? String ?? "desktop")
        }

        for command in commands where command["command"] as? String == "displayURI" {
            let args = command["args"] as? [Any] ?? []
            if let address = args.first as? String, let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                BrowserState.shared.newTab(url: url, select: false)
                BrowserState.shared.show(Toast(symbol: "arrow.down.forward.and.arrow.up.backward", text: "Opened a tab sent from another device"))
            }
        }

        let info = Bundle.main.infoDictionary
        var record: [String: Any] = [
            "id": state.clientID,
            "name": MozillaAccount.deviceName,
            "type": "desktop",
            "commands": [Any](),
            "version": info?["CFBundleShortVersionString"] as? String ?? "0",
            "protocols": ["1.5"],
            "os": "Darwin",
            "appPackage": info?["CFBundleIdentifier"] as? String ?? "ca.beckettclarke.TuffBrowser",
            "application": "Tuff",
            "formfactor": "desktop",
        ]
        if let device = account?.deviceID { record["fxaDeviceId"] = device }
        let hash = Self.hash(record)
        let stale = (state.clientUploaded ?? .distantPast).timeIntervalSinceNow < -7 * 24 * 3600
        if hash != state.clientHash || stale || !commands.isEmpty {
            let upload = SyncUpload(id: state.clientID, payload: try session.encrypt(record, "clients"), ttl: Self.recordTTL)
            try await session.storage.put("clients", upload, ifUnmodifiedSince: Self.since(modified, session.info["clients"] ?? 0))
            state.clientHash = hash
            state.clientUploaded = Date()
        }
        return others
    }

    private static func hash(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)) ?? Data()
        return Data(SHA256.hash(data: data)).base64URL
    }

    // MARK: Tabs

    private func syncTabs(_ session: Session, profile: UUID, clients: [String: SyncDevice]) async throws {
        let (records, _) = try await session.storage.records("tabs", newer: nil)
        var found: [SyncDevice] = []
        for record in records where record.id != state.clientID {
            guard var device = clients[record.id], let object = session.decrypt(record, "tabs"), object["deleted"] as? Bool != true else { continue }
            for tab in object["tabs"] as? [[String: Any]] ?? [] {
                guard let address = (tab["urlHistory"] as? [String])?.first, let url = URL(string: address),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
                let used = Date(timeIntervalSince1970: (tab["lastUsed"] as? NSNumber)?.doubleValue ?? 0)
                device.tabs.append(SyncDevice.OpenTab(title: tab["title"] as? String ?? "", url: url, lastUsed: used))
            }
            guard !device.tabs.isEmpty else { continue }
            device.tabs.sort { $0.lastUsed > $1.lastUsed }
            found.append(device)
        }
        devices = found.sorted { ($0.tabs.first?.lastUsed ?? .distantPast) > ($1.tabs.first?.lastUsed ?? .distantPast) }

        // This browser's tabs: every space on the synced profile, most recently used first.
        let browser = BrowserState.shared
        var open: [Tab] = browser.profiles.first { $0.id == profile }?.favorites ?? []
        for space in browser.spaces where space.profileID == profile { open += space.allPinned + space.tabs }
        let tabs: [[String: Any]] = open
            .filter { $0.url.map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") } == true }
            .sorted { $0.lastActive > $1.lastActive }
            .prefix(250)
            .map { tab in
                [
                    "title": String(tab.displayTitle.prefix(512)),
                    "urlHistory": [tab.url!.absoluteString],
                    "icon": "",
                    "lastUsed": Int(tab.lastActive.timeIntervalSince1970),
                ]
            }
        // Sent again at least weekly, well before the record expires.
        let hash = Self.hash([tabs, Int(Date().timeIntervalSince1970 / (7 * 24 * 3600))])
        guard hash != state.tabsHash else { return }
        let record: [String: Any] = ["id": state.clientID, "clientName": MozillaAccount.deviceName, "tabs": tabs]
        let upload = SyncUpload(id: state.clientID, payload: try session.encrypt(record, "tabs"), ttl: Self.recordTTL)
        // Only this browser writes its own tabs record, so no precondition on the collection.
        try await session.storage.put("tabs", upload)
        state.tabsHash = hash
    }

    // MARK: Bookmarks

    private func syncBookmarks(_ session: Session, profile: UUID) async throws {
        let progress = engine(.bookmarks)
        let (records, modified) = try await session.storage.records("bookmarks", newer: progress.lastSync)

        var baseRecords: [String: [String: Any]] = [:]
        for (id, text) in state.bookmarkMirror {
            if let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] { baseRecords[id] = object }
        }
        var remoteRecords = baseRecords
        for record in records {
            guard let object = session.decrypt(record, "bookmarks") else { continue }
            if object["deleted"] as? Bool == true { remoteRecords[record.id] = nil } else { remoteRecords[record.id] = object }
        }
        remoteRecords[BookmarkMerge.places] = nil
        let base = BookmarkMerge.tree(from: baseRecords)
        let remote = BookmarkMerge.tree(from: remoteRecords)

        let store = BookmarkStore.shared
        let current = store.items(for: profile)
        var ids = state.bookmarkIDs
        var local = BookmarkMerge.localTree(current, base: base, ids: &ids)
        let renames = BookmarkMerge.duplicates(base: base, local: local, remote: remote)
        if !renames.isEmpty {
            local = BookmarkMerge.renamed(local, renames)
            for (uuid, guid) in ids { if let new = renames[guid] { ids[uuid] = new } }
        }
        let merged = BookmarkMerge.merge(base: base, local: local, remote: remote)

        // Tuff shows the result straight away; the server gets the difference.
        let list = BookmarkMerge.tuffList(merged, previous: current, ids: &ids)
        applying = true
        store.replaceAll(list, profile: profile)
        applying = false
        state.bookmarkIDs = ids

        var uploads: [SyncUpload] = []
        var mirror: [String: [String: Any]] = [:]
        for (id, node) in merged {
            let existing = remoteRecords[id] ?? baseRecords[id]
            if remote[id] == node, let existing {
                mirror[id] = existing
                continue
            }
            let record = BookmarkMerge.record(id, node, in: merged, existing: existing)
            mirror[id] = record
            uploads.append(SyncUpload(id: id, payload: try session.encrypt(record, "bookmarks"), sortindex: node.kind == .folder ? 1_000_000 : nil))
        }
        for id in remote.keys where merged[id] == nil {
            uploads.append(SyncUpload(id: id, payload: try session.encrypt(["id": id, "deleted": true], "bookmarks")))
        }
        var lastSync = max(modified, session.info["bookmarks"] ?? 0, progress.lastSync)
        if !uploads.isEmpty {
            lastSync = try await session.storage.upload("bookmarks", uploads, ifUnmodifiedSince: Self.since(lastSync))
        }
        state.bookmarkMirror = mirror.compactMapValues { object in
            (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) }
        }
        state.engines[SyncKind.bookmarks.rawValue] = SyncState.Engine(syncID: progress.syncID, lastSync: lastSync)
    }

    // MARK: History

    private func syncHistory(_ session: Session, profile: UUID) async throws {
        let progress = engine(.history)
        let first = progress.lastSync == 0
        let (records, modified) = try await session.storage.records("history", newer: progress.lastSync, limit: first ? 5000 : 20000)

        var guidToURL: [String: String] = [:]
        for (url, guid) in state.historyGUIDs { guidToURL[guid] = url }
        var incoming: [HistoryEntry] = []
        var deleted: [URL] = []
        for record in records {
            guard let object = session.decrypt(record, "history") else { continue }
            if object["deleted"] as? Bool == true {
                if let address = guidToURL[record.id], let url = URL(string: address) {
                    deleted.append(url)
                    state.historyGUIDs[address] = nil
                    state.historySynced[address] = nil
                }
                continue
            }
            guard let address = object["histUri"] as? String, let url = URL(string: address),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            let dates = (object["visits"] as? [[String: Any]] ?? [])
                .compactMap { ($0["date"] as? NSNumber)?.doubleValue }
                .map { Date(timeIntervalSince1970: $0 / 1_000_000) }
                .sorted()
            guard let latest = dates.last else { continue }
            if let old = state.historyGUIDs[address], old != record.id { guidToURL[old] = nil }
            state.historyGUIDs[address] = record.id
            guidToURL[record.id] = address
            state.historySynced[address] = max(state.historySynced[address] ?? 0, latest.timeIntervalSince1970)
            incoming.append(HistoryEntry(url: url, title: object["title"] as? String ?? "", lastVisit: latest, visits: dates.count, visitDates: dates))
        }
        applying = true
        if !incoming.isEmpty { HistoryStore.shared.merge(incoming, profileID: profile) }
        if !deleted.isEmpty { HistoryStore.shared.delete(deleted, profileID: profile) }
        applying = false

        // Pages visited here since the server last heard about them.
        let changed = HistoryStore.shared.entries(profileID: profile)
            .filter { $0.lastVisit.timeIntervalSince1970 > (state.historySynced[$0.url.absoluteString] ?? 0) + 1 }
            .sorted { $0.lastVisit > $1.lastVisit }
            .prefix(5000)
        var uploads: [SyncUpload] = []
        var assigned: [(String, String, Double)] = []
        for entry in changed {
            let address = entry.url.absoluteString
            guard address.utf8.count <= 65536 else { continue }
            let guid = state.historyGUIDs[address] ?? SyncGUID.make()
            let visits = entry.visitDates.sorted(by: >).prefix(20).map { ["date": Int64($0.timeIntervalSince1970 * 1_000_000), "type": 1] }
            let record: [String: Any] = ["id": guid, "histUri": address, "title": String(entry.title.prefix(2000)), "visits": Array(visits)]
            uploads.append(SyncUpload(id: guid, payload: try session.encrypt(record, "history")))
            assigned.append((address, guid, entry.lastVisit.timeIntervalSince1970))
        }
        let removed = state.historyRemoved
        for guid in Set(removed) {
            uploads.append(SyncUpload(id: guid, payload: try session.encrypt(["id": guid, "deleted": true], "history")))
        }
        var lastSync = max(modified, session.info["history"] ?? 0, progress.lastSync)
        if !uploads.isEmpty {
            lastSync = try await session.storage.upload("history", uploads, ifUnmodifiedSince: Self.since(lastSync))
            for (address, guid, latest) in assigned {
                state.historyGUIDs[address] = guid
                state.historySynced[address] = latest
            }
            state.historyRemoved.removeAll { removed.contains($0) }
        }
        state.engines[SyncKind.history.rawValue] = SyncState.Engine(syncID: progress.syncID, lastSync: lastSync)
    }

    // MARK: Passwords

    private func syncPasswords(_ session: Session, profile: UUID) async throws {
        let progress = engine(.passwords)
        let (records, modified) = try await session.storage.records("passwords", newer: progress.lastSync)

        var base: [String: [String: Any]] = [:]
        for (id, text) in state.loginMirror {
            if let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] { base[id] = object }
        }
        var remote = base
        for record in records {
            guard let object = session.decrypt(record, "passwords") else { continue }
            remote[record.id] = object["deleted"] as? Bool == true ? nil : object
        }

        let store = PasswordStore.shared
        let mine = store.logins.filter { $0.profile == profile }
        var ids = state.loginIDs.filter { id, _ in mine.contains { $0.id == id } }
        var local: [String: SavedLogin] = [:]
        for login in mine { if let guid = ids[login.id] { local[guid] = login } }
        // The first time, a login Tuff and the account both have is the same login.
        for login in mine where ids[login.id] == nil {
            let match = remote.first { guid, record in
                local[guid] == nil && base[guid] == nil && Self.fields(record).map { $0.origin == login.origin && $0.username == login.username } == true
            }?.key
            let guid = match ?? "{\(login.id.uuidString.lowercased())}"
            ids[login.id] = guid
            local[guid] = login
        }

        var upserts: [SavedLogin] = []
        var removals = Set<UUID>()
        var uploads: [SyncUpload] = []
        var mirror: [String: [String: Any]] = [:]
        let now = Date()

        func upload(_ guid: String, _ login: SavedLogin, over existing: [String: Any]?) throws {
            var record = existing ?? [:]
            let previous = existing.flatMap(Self.fields)
            record["id"] = guid
            record.removeValue(forKey: "deleted")
            record["hostname"] = login.origin
            if record["formSubmitURL"] == nil && record["httpRealm"] == nil { record["formSubmitURL"] = login.origin }
            if record["httpRealm"] == nil { record["httpRealm"] = NSNull() }
            record["username"] = login.username
            record["password"] = login.password
            record["usernameField"] = record["usernameField"] ?? ""
            record["passwordField"] = record["passwordField"] ?? ""
            let ms = { (date: Date) in Int64(date.timeIntervalSince1970 * 1000) }
            if record["timeCreated"] == nil { record["timeCreated"] = ms(login.created) }
            if previous?.password != login.password || record["timePasswordChanged"] == nil { record["timePasswordChanged"] = ms(now) }
            record["timeLastUsed"] = ms(login.lastUsed ?? login.created)
            if record["timesUsed"] == nil { record["timesUsed"] = 1 }
            mirror[guid] = record
            uploads.append(SyncUpload(id: guid, payload: try session.encrypt(record, "passwords")))
        }
        func adopt(_ guid: String, _ record: [String: Any], replacing old: SavedLogin?) {
            guard let fields = Self.fields(record) else { return }
            // The GUID's own UUID unless another profile's login already has it.
            let fromGUID = Self.uuid(fromGUID: guid).flatMap { store.login(withID: $0) == nil ? $0 : nil }
            let id = old?.id ?? ids.first { $0.value == guid }?.key ?? fromGUID ?? UUID()
            let date = { (key: String) in (record[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } }
            var login = old ?? SavedLogin(id: id, origin: fields.origin, username: fields.username, password: fields.password, profile: profile)
            login.origin = fields.origin
            login.username = fields.username
            login.password = fields.password
            if old == nil, let created = date("timeCreated") { login.created = created }
            if let used = date("timeLastUsed"), used > (login.lastUsed ?? .distantPast) { login.lastUsed = used }
            ids[login.id] = guid
            upserts.append(login)
            mirror[guid] = record
        }

        for guid in Set(local.keys).union(remote.keys) {
            let l = local[guid], r = remote[guid], b = base[guid]
            let lf = l.map(Self.fields), rf = r.flatMap(Self.fields), bf = b.flatMap(Self.fields)
            // Logins Tuff can't use (not for a web page): left as they are.
            if let r, rf == nil, l == nil {
                mirror[guid] = r
                continue
            }
            switch (l, r) {
            case let (l?, r?):
                if bf != nil, rf == bf {
                    if lf != bf { try upload(guid, l, over: r) } else { mirror[guid] = r }
                } else if rf != lf {
                    // Matched on a first sync with different passwords: the newer one.
                    let remoteChanged = (r["timePasswordChanged"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
                    if bf == nil, let remoteChanged, (l.lastUsed ?? l.created) > remoteChanged {
                        try upload(guid, l, over: r)
                    } else {
                        adopt(guid, r, replacing: l)
                    }
                } else {
                    mirror[guid] = r
                }
            case let (l?, nil):
                if let bf, lf == bf { removals.insert(l.id) } else { try upload(guid, l, over: b) }
            case let (nil, r?):
                if let bf, rf == bf {
                    uploads.append(SyncUpload(id: guid, payload: try session.encrypt(["id": guid, "deleted": true], "passwords")))
                } else {
                    adopt(guid, r, replacing: nil)
                }
            case (nil, nil):
                break
            }
        }

        applying = true
        store.applySync(upserts, removing: removals)
        applying = false
        for id in removals { ids[id] = nil }
        state.loginIDs = ids

        var lastSync = max(modified, session.info["passwords"] ?? 0, progress.lastSync)
        if !uploads.isEmpty {
            lastSync = try await session.storage.upload("passwords", uploads, ifUnmodifiedSince: Self.since(lastSync))
        }
        state.loginMirror = mirror.compactMapValues { object in
            (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) }
        }
        state.engines[SyncKind.passwords.rawValue] = SyncState.Engine(syncID: progress.syncID, lastSync: lastSync)
    }

    private struct LoginFields: Equatable {
        var origin: String
        var username: String
        var password: String
    }

    private static func fields(_ login: SavedLogin) -> LoginFields {
        LoginFields(origin: login.origin, username: login.username, password: login.password)
    }

    /// What a password record says, for a web page's sign-in; nil for anything else.
    private static func fields(_ record: [String: Any]) -> LoginFields? {
        guard let hostname = record["hostname"] as? String, let origin = SitePermissions.origin(of: URL(string: hostname)),
              let password = record["password"] as? String else { return nil }
        return LoginFields(origin: origin, username: record["username"] as? String ?? "", password: password)
    }

    /// Firefox's login GUIDs are UUIDs in braces; reusing them keeps the two sides' IDs alike.
    private static func uuid(fromGUID guid: String) -> UUID? {
        UUID(uuidString: guid.trimmingCharacters(in: CharacterSet(charactersIn: "{}")))
    }
}
