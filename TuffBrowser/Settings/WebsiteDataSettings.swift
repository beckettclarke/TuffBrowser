import SwiftUI

/// Settings → Websites: the "Always allow {site} to open {App} links" answers, each removable.
struct OpenInAppAnswersGroup: View {
    /// Bumped to re-read the answers after one is removed (they live in UserDefaults).
    @State private var revision = 0

    var body: some View {
        let _ = revision
        let answers = ExternalAppLinks.savedAnswers.map { Answer(origin: $0.origin, scheme: $0.scheme) }
        SettingsGroup(title: "Links that open apps", footer: "Sites you let open another app (Zoom, Slack, VS Code…) without asking each time.") {
            if answers.isEmpty {
                SettingsRow(title: "No sites may open apps without asking")
            } else {
                ForEach(answers, id: \.self) { answer in
                    let app = ExternalAppLinks.appName(for: answer.scheme)
                    SettingsRow(
                        title: Self.siteName(answer.origin),
                        detail: "Opens \(app.map { "\($0) (\(answer.scheme): links)" } ?? "\(answer.scheme): links")",
                        symbol: "arrow.up.forward.app"
                    ) {
                        IconButton(symbol: "xmark", size: 10, side: 24, help: "Forget") {
                            withAnimation(Motion.snappy) {
                                ExternalAppLinks.remove(origin: answer.origin, scheme: answer.scheme)
                                revision += 1
                            }
                        }
                    }
                }
            }
        }
    }

    private struct Answer: Hashable { let origin: String; let scheme: String }

    /// "https://zoom.us" → "zoom.us".
    private static func siteName(_ origin: String) -> String {
        URL(string: origin)?.displayHost ?? origin
    }
}

/// Settings → Privacy → Website data: every site that keeps cookies or storage, searchable, each
/// removable on its own (instead of only "Remove All").
struct WebsiteDataSitesRow: View {
    let onChange: () -> Void
    @State private var expanded = false
    @State private var sites: [WebsiteData.Site]?
    @State private var query = ""

    var body: some View {
        SettingsRow(title: "Data by site", detail: "See which sites keep data, and remove one site’s.") {
            Button(expanded ? "Hide" : "Show Sites…") {
                withAnimation(Motion.snappy) { expanded.toggle() }
                if expanded { reload() }
            }
            .buttonStyle(TuffButtonStyle())
        }
        if expanded {
            VStack(alignment: .leading, spacing: 6) {
                TuffTextField(placeholder: "Search sites", text: $query, width: nil)
                if let sites {
                    let shown = filtered(sites)
                    if shown.isEmpty {
                        Text(sites.isEmpty ? "No website data." : "No sites match.")
                            .font(.system(size: 12))
                            .foregroundStyle(.primary.opacity(0.5))
                            .padding(.vertical, 6)
                    }
                    ForEach(shown.prefix(200)) { site in
                        HStack(spacing: 10) {
                            Image(systemName: "globe")
                                .font(.system(size: 12))
                                .foregroundStyle(.primary.opacity(0.5))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(site.name).font(.system(size: 12.5, weight: .medium))
                                Text(site.kinds.joined(separator: ", "))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.primary.opacity(0.5))
                            }
                            Spacer(minLength: 8)
                            IconButton(symbol: "trash", size: 11, side: 24, help: "Remove \(site.name)’s data") {
                                remove(site)
                            }
                        }
                        .padding(.vertical, 3)
                        .transition(.opacity)
                    }
                    if shown.count > 200 {
                        Text("\(shown.count - 200) more — search to find them.")
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.5))
                    }
                } else {
                    ProgressView().controlSize(.small).padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .transition(.opacity)
        }
    }

    private func filtered(_ list: [WebsiteData.Site]) -> [WebsiteData.Site] {
        let q = query.trimmed.lowercased()
        return q.isEmpty ? list : list.filter { $0.name.lowercased().contains(q) }
    }

    private func reload() {
        WebsiteData.sites { list in withAnimation(Motion.snappy) { sites = list } }
    }

    private func remove(_ site: WebsiteData.Site) {
        Task { @MainActor in
            let confirmed = await PromptPresenter.present(Prompt(
                host: .settings, symbol: "trash.fill", symbolColor: .red,
                title: "Remove \(site.name)’s data?",
                message: "Its cookies and site storage are removed in every profile. You may be signed out of \(site.name).",
                confirmTitle: "Remove", destructive: true
            ))
            guard confirmed else { return }
            WebsiteData.remove(site: site.name) {
                withAnimation(Motion.snappy) { sites?.removeAll { $0 == site } }
                onChange()
            }
        }
    }
}
