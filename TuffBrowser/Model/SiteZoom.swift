import Foundation
import Observation

/// Zoom remembered per site, as in Safari and Chrome: zooming a page sets it for every page on
/// that host, now and next time. Sites at the default zoom aren't stored, so changing the
/// default in Settings still moves them. Incognito windows keep their own levels in memory,
/// starting from the saved ones, and forget them when Tuff quits.
@Observable
final class SiteZoom {
    static let shared = SiteZoom()

    /// Host → zoom.
    private(set) var saved: [String: Double] = [:]
    @ObservationIgnored private var incognito: [String: Double] = [:]
    @ObservationIgnored private let file = Paths.appSupport.appendingPathComponent("site-zoom.json")

    private init() {
        if let data = try? Data(contentsOf: file), let levels = try? JSONDecoder().decode([String: Double].self, from: data) {
            saved = levels
        }
    }

    static var defaultZoom: Double { AppSettings.shared.advanced.defaultZoom }

    /// What a site's zoom is keyed by: its host ("www." dropped), or the scheme for pages
    /// without one. Nil for blank pages.
    static func key(for url: URL?) -> String? {
        guard let url else { return nil }
        if let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        guard let scheme = url.scheme?.lowercased(), scheme != "about" else { return nil }
        return scheme + ":"
    }

    func zoom(for url: URL?, incognito isIncognito: Bool) -> Double {
        guard let key = Self.key(for: url) else { return Self.defaultZoom }
        if isIncognito, let level = incognito[key] { return level }
        return saved[key] ?? Self.defaultZoom
    }

    func set(_ zoom: Double, for url: URL?, incognito isIncognito: Bool) {
        guard let key = Self.key(for: url) else { return }
        let isDefault = abs(zoom - Self.defaultZoom) < 0.005
        if isIncognito {
            incognito[key] = zoom
            return
        }
        guard saved[key] != (isDefault ? nil : zoom) else { return }
        saved[key] = isDefault ? nil : zoom
        save()
    }

    /// Forgets a site's zoom; its open tabs go back to the default.
    func remove(_ key: String) {
        saved[key] = nil
        save()
        refreshOpenTabs()
    }

    func removeAll() {
        saved.removeAll()
        save()
        refreshOpenTabs()
    }

    /// Re-applies the stored levels to open tabs (after a change in Settings).
    func refreshOpenTabs() {
        for state in BrowserState.all where !state.isPrivate {
            state.allTabs.forEach { $0.applySiteZoom() }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
