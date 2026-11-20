import AppKit
import Flint

/// Anonymous usage counts sent to PostHog: how many people open Tuff each day, on which version,
/// update channel and macOS, which versions they update from and to, and how the main settings
/// are set. Nothing about pages, searches, tabs' contents
/// or the person: no URLs, no titles, no account, no hardware IDs. The only ID is a random one
/// made on this Mac, which lets a day's opens count as one user; turning the setting off
/// (Settings → Privacy & Security) stops sending and forgets it.
///
/// Release builds only, like the updater. Talks to PostHog's capture endpoint directly, so
/// there is no SDK (and none of its autocapture or device properties).
@MainActor
enum Analytics {
    /// The PostHog project's API key (`phc_…`). It is a public, write-only key, made to be
    /// shipped in apps. Empty sends nothing.
    private static let projectKey = "phc_r0npcFJURhQDqmuHut0uUifgFbigkTfH3j2NM7bGhFT"
    /// `https://eu.i.posthog.com` for a project in the EU region.
    private static let host = URL(string: "https://us.i.posthog.com")!

    private nonisolated static let idKey = "tuff.analyticsID"
    private nonisolated static let lastDayKey = "tuff.analyticsLastDay"
    /// The version that ran last time, kept whether or not sharing is on, so turning it on
    /// later doesn't report an update that didn't just happen.
    private static let lastVersionKey = "tuff.analyticsLastVersion"

    private static var enabled: Bool {
        #if DEBUG
        false
        #else
        !projectKey.isEmpty && AppSettings.shared.privacy.shareUsageStats && Paths.testDataDirectory == nil
        #endif
    }

    /// No cookies, no cache, nothing kept between requests.
    private static let session = URLSession(configuration: .ephemeral)

    /// Sends the launch (and the update, if this version is new), then a daily ping whenever
    /// Tuff comes forward on a new day (a browser is often left open for weeks).
    static func start() {
        let previous = UserDefaults.standard.string(forKey: lastVersionKey)
        UserDefaults.standard.set(appVersion, forKey: lastVersionKey)
        if let previous, previous != appVersion {
            capture("app_updated", ["from_version": previous, "to_version": appVersion])
        }
        capture("app_launched", settingsProperties)
        sendDailyIfNeeded()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { sendDailyIfNeeded() }
        }
    }

    /// Forgets the random ID, so turning sharing back on later starts a new one.
    nonisolated static func forgetID() {
        UserDefaults.standard.removeObject(forKey: idKey)
        UserDefaults.standard.removeObject(forKey: lastDayKey)
    }

    static func capture(_ event: String, _ properties: [String: Any] = [:]) {
        guard enabled else { return }
        var props = baseProperties
        props.merge(properties) { _, new in new }
        let body: [String: Any] = [
            "api_key": projectKey,
            "event": event,
            "distinct_id": installID,
            "properties": props,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: host.appendingPathComponent("i/v0/e/"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        // A lost event isn't worth retrying.
        session.dataTask(with: request).resume()
    }

    private static func sendDailyIfNeeded() {
        guard enabled else { return }
        let today = Date().formatted(.iso8601.year().month().day())
        guard UserDefaults.standard.string(forKey: lastDayKey) != today else { return }
        UserDefaults.standard.set(today, forKey: lastDayKey)
        capture("daily_active", settingsProperties)
    }

    /// How the main settings are set: choices and switches only, never anything typed in
    /// (a custom search URL or user agent is just "custom").
    private static var settingsProperties: [String: Any] {
        let s = AppSettings.shared
        return [
            "tab_layout": s.tabs.layout.rawValue,
            "incognito_tab_layout": s.tabs.incognitoLayout.rawValue,
            "background_style": s.theme.style.rawValue,
            "appearance": s.theme.appearance.rawValue,
            "space_colors": s.theme.useSpaceColors,
            "search_engine": s.general.searchEngine.rawValue,
            "search_suggestions": s.general.searchSuggestions,
            "restore_session": s.general.restoreSession,
            "tab_sleep_minutes": s.general.sleepAfterMinutes,
            "reduce_motion": s.general.reduceMotion,
            "new_tab_position": s.tabs.newTabPosition.rawValue,
            "new_tab_page": s.tabs.newTabPage(for: s.tabs.layout),
            "bookmarks_bar": s.tabs.showBookmarksBar,
            "compact_rows": s.tabs.compactRows,
            "close_idle_tabs_hours": s.tabs.closeIdleAfterHours,
            "block_ads": s.privacy.blockAds,
            "save_history": s.privacy.saveHistory,
            "https_only": s.privacy.httpsOnly,
            "passwords": s.privacy.passwords,
            "translation_fallback": s.privacy.translationFallback.rawValue,
            "user_agent": s.advanced.userAgent.rawValue,
            "bangs": s.mods.bangs,
        ]
    }

    private static var installID: String {
        if let id = UserDefaults.standard.string(forKey: idKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: idKey)
        return id
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private static var baseProperties: [String: Any] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return [
            // The project is shared with the website; this tells the two apart.
            "product": "tuff",
            "$app_version": appVersion,
            // The build's own channel, and the one the user follows for updates.
            "channel": appVersion.contains("nightly") ? "nightly" : "stable",
            "update_channel": Updater.app.channel.name,
            "auto_update": Updater.app.automaticallyChecksForUpdates,
            "$os": "macOS",
            "$os_version": "\(os.majorVersion).\(os.minorVersion)",
            // No person profiles, and no city or country looked up from the connection's address.
            "$process_person_profile": false,
            "$geoip_disable": true,
        ]
    }
}
