import SwiftUI

// Settings → Websites → a site: everything one site may do, as in Chrome's site settings.
// Each permission is Ask, Allow or Deny; JavaScript, pop-ups, autoplay and zoom follow the
// overall settings unless the site has its own.

/// The sites that have settings of their own, as origins (`https://example.com`): answers kept
/// in `SitePermissions` (by origin) plus sites with their own JavaScript, pop-ups, autoplay
/// (`SiteSettings`) or zoom (`SiteZoom`), both kept by host without "www.".
enum SiteList {
    static func origins() -> [String] {
        var origins = SitePermissions.shared.origins
        var hosts = Set(origins.compactMap { SiteSettings.key(for: URL(string: $0)) })
        let keys = SiteSettings.shared.sites.keys.sorted() + SiteZoom.shared.saved.keys.sorted()
        for key in keys {
            // Patterns an extension set (`https://*.example.com`) are listed as they are.
            if key.contains("://") {
                if !origins.contains(key) { origins.append(key) }
                continue
            }
            // Zoom for pages without a host is kept by scheme ("file:").
            guard !key.hasSuffix(":"), hosts.insert(key).inserted else { continue }
            origins.append("https://" + key)
        }
        return origins.sorted { SitePermissions.displayName($0) < SitePermissions.displayName($1) }
    }

    /// What `SiteSettings` keeps a site's JavaScript, pop-ups and autoplay under.
    static func settingsKey(for origin: String) -> String? {
        origin.contains("*") ? origin : SiteSettings.key(for: URL(string: origin))
    }

    /// The site's icon from the favicon cache, if it has been visited.
    static func icon(for origin: String) -> NSImage? {
        guard !origin.contains("*"), let url = URL(string: origin) else { return nil }
        if let icon = FaviconStore.shared.cachedIcon(for: url) { return icon }
        guard let host = url.host(percentEncoded: false), !host.hasPrefix("www.") else { return nil }
        return URL(string: "https://www." + host).flatMap(FaviconStore.shared.cachedIcon(for:))
    }

    /// "Camera allowed · Location denied · JavaScript off · Zoom 125%".
    static func summary(for origin: String) -> String {
        var parts: [String] = []
        for kind in SitePermissionKind.perSite {
            switch SitePermissions.shared.setting(origin: origin, kind: kind, incognito: false) {
            case .allow: parts.append("\(kind.label) allowed")
            case .deny: parts.append("\(kind.label) denied")
            case .ask: break
            }
        }
        if let key = settingsKey(for: origin), let entry = SiteSettings.shared.sites[key] {
            if let js = entry.javaScript { parts.append("JavaScript \(js ? "on" : "off")") }
            if let popups = entry.popups { parts.append("Pop-ups \(popups ? "allowed" : "blocked")") }
            if let autoplay = entry.autoplay { parts.append("Autoplay: \(autoplay.label)") }
        }
        if let key = SiteZoom.key(for: URL(string: origin)), let zoom = SiteZoom.shared.saved[key] {
            parts.append("Zoom \(Int((zoom * 100).rounded()))%")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - The list, on the Websites page

/// Every site with its own settings; clicking one opens its page.
struct SiteListGroup: View {
    @Environment(SettingsRouter.self) private var router: SettingsRouter?
    @State private var query = ""
    private var permissions = SitePermissions.shared
    private var siteSettings = SiteSettings.shared
    private var siteZoom = SiteZoom.shared

    var body: some View {
        let all = SiteList.origins()
        let q = query.trimmed.lowercased()
        let shown = q.isEmpty ? all : all.filter { $0.lowercased().contains(q) }
        SettingsGroup(title: "Sites", footer: "Click a site to set each permission to Ask, Allow or Deny, and to give it its own JavaScript, pop-up, autoplay and zoom settings.") {
            if all.count > 8 {
                TuffTextField(placeholder: "Search sites", text: $query, width: nil)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            if all.isEmpty {
                SettingsRow(title: "No sites with their own settings", detail: "Sites you allow or deny, or change from the page menu, appear here.")
            } else if shown.isEmpty {
                SettingsRow(title: "No sites match")
            }
            ForEach(shown, id: \.self) { origin in
                SiteListRow(origin: origin) { router?.site = origin }
            }
            SettingsRow(title: "Add a site", detail: "Choose a site’s permissions before it asks.") {
                Button("Add Site…", action: addSite).buttonStyle(TuffButtonStyle())
                if !all.isEmpty {
                    ConfirmButton(title: "Reset All", confirmTitle: "Reset all sites?") {
                        withAnimation(Motion.snappy) {
                            permissions.removeAll()
                            siteSettings.removeSites()
                            siteZoom.removeAll()
                        }
                    }
                }
            }
        }
    }

    private func addSite() {
        Task { @MainActor in
            let result = await PromptPresenter.ask(Prompt(
                host: .settings, symbol: "globe",
                title: "Add a site",
                message: "Type the site’s address. You can then choose what it may do.",
                confirmTitle: "Add",
                fields: [Prompt.Field(placeholder: "example.com")]
            ))
            guard result.confirmed, var text = result.fields.first?.trimmed.lowercased(), !text.isEmpty else { return }
            if !text.contains("://") { text = "https://" + text }
            guard let origin = SitePermissions.origin(of: URL(string: text)) else { return }
            router?.site = origin
        }
    }
}

private struct SiteListRow: View {
    let origin: String
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let summary = SiteList.summary(for: origin)
        Button(action: open) {
            HStack(spacing: 12) {
                SiteIcon(origin: origin, side: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(SitePermissions.displayName(origin))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.head)
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.primary.opacity(0.48))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.primary.opacity(hovering ? 0.6 : 0.35))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            .background(Rectangle().fill(.primary.opacity(hovering ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

private struct SiteIcon: View {
    let origin: String
    var side: CGFloat

    var body: some View {
        Group {
            if let icon = SiteList.icon(for: origin) {
                Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(side * 0.14)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: side * 0.55, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.6))
            }
        }
        .frame(width: side, height: side)
        .background(RoundedRectangle(cornerRadius: side * 0.26, style: .continuous).fill(.primary.opacity(0.08)))
    }
}

// MARK: - One site's page

struct SiteDetailPage: View {
    let origin: String
    @Environment(AppSettings.self) private var settings
    @Environment(SettingsRouter.self) private var router: SettingsRouter?
    private var permissions = SitePermissions.shared
    private var siteSettings = SiteSettings.shared
    private var siteZoom = SiteZoom.shared

    init(origin: String) { self.origin = origin }

    private static let zoomOptions: [Double?] = [nil, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        let name = SitePermissions.displayName(origin)
        let key = SiteList.settingsKey(for: origin)
        let entry = key.flatMap { siteSettings.sites[$0] } ?? SiteSettings.Entry()
        let privacy = settings.privacy
        SettingsPage(title: name, subtitle: name == origin ? nil : origin, back: SettingsBack(title: "Websites") { router?.site = nil }) {
            SettingsGroup(title: "Permissions", footer: "Ask: the site asks you each time it wants one. Changes apply the next time the site asks.") {
                ForEach(SitePermissionKind.perSite, id: \.self) { kind in
                    SettingsRow(title: kind.label, symbol: kind.symbols.first) {
                        TuffMenu(selection: permissionBinding(kind), options: PermissionSetting.allCases) { $0.label }
                    }
                }
            }

            if let key {
                SettingsGroup(title: "Content", footer: "Default follows the settings on the Websites page. Changes apply the next time a page of this site loads.") {
                    SettingsRow(title: "JavaScript", symbol: "curlybraces") {
                        TuffMenu(selection: contentBinding(key, \.javaScript), options: [nil, true, false]) {
                            Self.allowLabel($0, fallback: privacy.javaScript)
                        }
                    }
                    SettingsRow(title: "Pop-ups", symbol: "macwindow.on.rectangle") {
                        TuffMenu(selection: contentBinding(key, \.popups), options: [nil, true, false]) {
                            Self.allowLabel($0, fallback: !privacy.blockPopups)
                        }
                    }
                    SettingsRow(title: "Autoplay", symbol: "play.rectangle") {
                        TuffMenu(selection: contentBinding(key, \.autoplay), options: [nil] + AutoplayPolicy.allCases) {
                            $0?.label ?? "Default (\(privacy.autoplay.label))"
                        }
                    }
                }
            }

            if let zoomKey = SiteZoom.key(for: URL(string: origin)), !origin.contains("*") {
                SettingsGroup(title: "Zoom") {
                    SettingsRow(title: "Page zoom", symbol: "plus.magnifyingglass") {
                        TuffMenu(selection: zoomBinding(zoomKey), options: Self.zoomOptions) {
                            $0.map { "\(Int(($0 * 100).rounded()))%" } ?? "Default (\(Int((SiteZoom.defaultZoom * 100).rounded()))%)"
                        }
                    }
                }
            }

            SettingsGroup {
                SettingsRow(title: "Reset permissions", detail: "Puts every setting for \(name) back to Ask or Default.", symbol: "arrow.counterclockwise") {
                    Button("Reset…", action: reset).buttonStyle(TuffButtonStyle())
                }
                if !origin.contains("*") {
                    SettingsRow(title: "Clear website data", detail: "Removes \(name)’s cookies and site storage.", symbol: "trash") {
                        Button("Clear…", action: clearData).buttonStyle(TuffButtonStyle(kind: .destructive))
                    }
                }
            }
        }
    }

    private static func allowLabel(_ value: Bool?, fallback: Bool) -> String {
        value.map { $0 ? "Allow" : "Block" } ?? "Default (\(fallback ? "Allow" : "Block"))"
    }

    private func permissionBinding(_ kind: SitePermissionKind) -> Binding<PermissionSetting> {
        Binding(
            get: { permissions.setting(origin: origin, kind: kind, incognito: false) },
            set: { value in withAnimation(Motion.snappy) { permissions.set(value, origin: origin, kind: kind, incognito: false) } }
        )
    }

    private func contentBinding<Value>(_ key: String, _ path: WritableKeyPath<SiteSettings.Entry, Value?>) -> Binding<Value?> {
        Binding(
            get: { siteSettings.sites[key]?[keyPath: path] ?? nil },
            set: { value in siteSettings.update(key: key, incognito: false) { $0[keyPath: path] = value } }
        )
    }

    private func zoomBinding(_ key: String) -> Binding<Double?> {
        Binding(
            get: { siteZoom.saved[key] },
            set: { value in
                siteZoom.set(value ?? SiteZoom.defaultZoom, for: URL(string: origin), incognito: false)
                siteZoom.refreshOpenTabs()
            }
        )
    }

    private func reset() {
        let name = SitePermissions.displayName(origin)
        Task { @MainActor in
            let confirmed = await PromptPresenter.present(Prompt(
                host: .settings, icon: SiteList.icon(for: origin), symbol: "arrow.counterclockwise", symbolColor: .red,
                title: "Reset \(name)’s permissions?",
                message: "Its permissions go back to Ask, and its JavaScript, pop-ups, autoplay and zoom follow your overall settings again.",
                confirmTitle: "Reset", destructive: true
            ))
            guard confirmed else { return }
            withAnimation(Motion.snappy) {
                permissions.removeAll(origin: origin)
                if let key = SiteList.settingsKey(for: origin) { siteSettings.remove(site: key) }
                if let key = SiteZoom.key(for: URL(string: origin)), siteZoom.saved[key] != nil { siteZoom.remove(key) }
            }
        }
    }

    private func clearData() {
        let url = URL(string: origin)
        WebsiteData.siteName(for: url) { site in
            let label = site ?? SitePermissions.displayName(origin)
            Task { @MainActor in
                guard let site else {
                    _ = await PromptPresenter.present(Prompt(
                        host: .settings, icon: SiteList.icon(for: origin), symbol: "checkmark",
                        title: "\(label) has no data stored", confirmTitle: "OK", cancelTitle: nil
                    ))
                    return
                }
                let confirmed = await PromptPresenter.present(Prompt(
                    host: .settings, icon: SiteList.icon(for: origin), symbol: "trash.fill", symbolColor: .red,
                    title: "Clear \(site)’s website data?",
                    message: "Its cookies and site storage are removed in every profile. You may be signed out of \(site).",
                    confirmTitle: "Clear", destructive: true
                ))
                guard confirmed else { return }
                WebsiteData.remove(site: site)
            }
        }
    }
}
