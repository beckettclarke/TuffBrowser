import SwiftUI

/// Settings › Import: bring history, bookmarks and spaces over from another browser.
struct ImportPage: View {
    @Environment(BrowserState.self) private var state
    @Environment(AppSettings.self) private var settings
    @Environment(\.accent) private var accent

    @State private var sources: [BrowserSource] = []
    @State private var selected: BrowserSource?
    @State private var profiles: [BrowserProfile] = []
    @State private var profile: BrowserProfile?
    @State private var kinds: Set<ImportKind> = Set(ImportKind.allCases)
    @State private var phase: Phase = .idle

    private enum Phase: Equatable {
        case idle
        case importing
        case done(String)
        case failed(String, needsAccess: Bool)
    }

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 10)]

    var body: some View {
        SettingsPage(title: "Import", subtitle: "Bring your history, bookmarks and spaces over from another browser.") {
            SettingsGroup(title: "Browser") {
                if sources.isEmpty {
                    SettingsRow(title: "No other browsers found", detail: "Tuff looks for Safari, Chrome, Arc, Zen, Firefox, Edge, Brave, Dia, Vivaldi and Opera.", symbol: "magnifyingglass")
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(sources) { source in
                            BrowserTile(source: source, selected: source == selected) { pick(source) }
                        }
                    }
                    .padding(12)
                }
            }

            if let source = selected {
                SettingsGroup(title: "From \(source.name)", footer: footer(for: source)) {
                    if profiles.count > 1, let current = profile {
                        SettingsRow(title: "Profile", symbol: "person.crop.circle") {
                            TuffMenu(
                                selection: Binding(get: { current }, set: { profile = $0; phase = .idle }),
                                options: profiles
                            ) { $0.name }
                        }
                    }
                    ForEach(ImportKind.allCases.filter { source.kinds.contains($0) }) { kind in
                        SwitchRow(
                            title: title(for: kind),
                            detail: detail(for: kind, source: source),
                            symbol: symbol(for: kind),
                            isOn: Binding(
                                get: { kinds.contains(kind) },
                                set: { on in
                                    if on { kinds.insert(kind) } else { kinds.remove(kind) }
                                    if phase != .importing { phase = .idle }
                                }
                            )
                        )
                    }
                    importRow(source)
                }
            }
        }
        .onAppear(perform: refresh)
    }

    // MARK: Rows

    @ViewBuilder
    private func importRow(_ source: BrowserSource) -> some View {
        let chosen = kinds.intersection(source.kinds)
        switch phase {
        case .idle:
            SettingsRow(title: "Ready to import", detail: chosen.isEmpty ? "Turn on something to import." : nil) {
                Button("Import") { run(source) }
                    .buttonStyle(TuffButtonStyle(kind: .prominent))
                    .disabled(chosen.isEmpty || profile == nil)
                    .keyboardShortcut(.defaultAction)
            }
        case .importing:
            SettingsRow(title: "Importing from \(source.name)…", detail: "Copying and reading its data. Large histories take a few seconds.") {
                ProgressView().controlSize(.small)
            }
        case .done(let text):
            SettingsRow(title: "Done", detail: text, symbol: "checkmark.circle.fill") {
                Button("Show History") { AppDelegate.shared?.showHistory(nil) }
                    .buttonStyle(TuffButtonStyle())
            }
        case .failed(let text, let needsAccess):
            SettingsRow(title: needsAccess ? "Tuff needs access" : "Couldn’t import", detail: text, symbol: "exclamationmark.triangle.fill") {
                if needsAccess {
                    Button("Open Privacy Settings") { openFullDiskAccess() }
                        .buttonStyle(TuffButtonStyle())
                }
                Button("Try Again") { run(source) }
                    .buttonStyle(TuffButtonStyle(kind: .prominent))
            }
        }
    }

    private func title(for kind: ImportKind) -> String {
        switch kind {
        case .history: "History"
        case .bookmarks: "Bookmarks"
        case .spaces: "Spaces & pinned tabs"
        }
    }

    private func symbol(for kind: ImportKind) -> String {
        switch kind {
        case .history: "clock.arrow.circlepath"
        case .bookmarks: "bookmark"
        case .spaces: "square.stack.3d.up"
        }
    }

    private func detail(for kind: ImportKind, source: BrowserSource) -> String {
        switch kind {
        case .history:
            let limit = BrowserImporter.historyLimit.formatted()
            return "Up to the \(limit) most recent pages, for the History page (⌘Y) and command bar suggestions."
        case .bookmarks:
            return "Added as a new “\(source.shortName) Bookmarks” space: the bookmarks bar pinned, every folder a folder."
        case .spaces:
            return source.id == "arc"
                ? "Each Arc space becomes a space with its pinned tabs and folders. Favorites join your favorites grid."
                : "Each workspace becomes a space with its pinned tabs and folders. Essentials join your favorites grid."
        }
    }

    private func footer(for source: BrowserSource) -> String {
        var lines: [String] = []
        if source.engine == .safari {
            lines.append("Safari keeps its data private: Tuff needs Full Disk Access (System Settings › Privacy & Security) to read it.")
        }
        lines.append("Tuff reads copies and never changes \(source.name)’s data. Spaces are added to the “\(state.currentProfile.name)” profile.")
        if settings.privacy.clearHistoryOnQuit {
            lines.append("“Clear history when Tuff quits” is on, so imported history is removed when you quit.")
        }
        lines.append("Passwords aren’t imported: \(source.name) can export them for your password manager.")
        return lines.joined(separator: " ")
    }

    // MARK: Actions

    private func refresh() {
        let found = BrowserImporter.detect()
        sources = found
        if let selected, let same = found.first(where: { $0 == selected }) {
            pick(same, resetPhase: false)
        } else if let first = found.first {
            pick(first)
        }
    }

    private func pick(_ source: BrowserSource, resetPhase: Bool = true) {
        let changed = source != selected
        withAnimation(Motion.snappy) { selected = source }
        if changed || profiles.isEmpty {
            profiles = BrowserImporter.profiles(for: source)
            profile = profiles.first
        }
        if resetPhase, phase != .importing { phase = .idle }
    }

    private func run(_ source: BrowserSource) {
        guard let profile, phase != .importing else { return }
        let chosen = kinds.intersection(source.kinds)
        guard !chosen.isEmpty else { return }
        withAnimation(Motion.snappy) { phase = .importing }
        Task.detached(priority: .userInitiated) {
            let bundle = BrowserImporter.read(source, profile: profile, kinds: chosen)
            await MainActor.run {
                let summary = BrowserImporter.apply(bundle, from: source, to: state)
                withAnimation(Motion.snappy) { phase = outcome(of: bundle, summary: summary, source: source, chosen: chosen) }
            }
        }
    }

    private func outcome(of bundle: ImportBundle, summary: ImportSummary, source: BrowserSource, chosen: Set<ImportKind>) -> Phase {
        let failed = chosen.filter { bundle.problems[$0] != nil }
        if bundle.needsAccess, summary.isEmpty {
            let how = source.engine == .safari
                ? "Turn on Tuff in System Settings › Privacy & Security › Full Disk Access, then try again."
                : "macOS kept Tuff out of \(source.name)’s data. Allow it when asked, or turn on Tuff under Full Disk Access, then try again."
            return .failed(how, needsAccess: true)
        }
        if !failed.isEmpty, summary.isEmpty {
            let reasons = failed.compactMap { kind -> String? in
                switch bundle.problems[kind] {
                case .missing: "\(title(for: kind)): \(source.name) hasn’t saved any yet in this profile."
                case .unreadable(let why): "\(title(for: kind)): \(why)"
                case .noAccess: "\(title(for: kind)): no access."
                case nil: nil
                }
            }
            return .failed(reasons.joined(separator: " "), needsAccess: false)
        }
        var text = summary.text
        if !failed.isEmpty {
            let names = failed.map { title(for: $0).lowercased() }.sorted().joined(separator: " and ")
            text += " Couldn’t read \(names)."
        }
        if source.engine == .chromium || source.engine == .firefox, NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleIDs.first ?? "").isEmpty == false {
            text += " \(source.name) is open, so changes from the last few seconds may be missing."
        }
        return .done(text)
    }

    private func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// A browser's app icon and name, picked like a tile.
private struct BrowserTile: View {
    @Environment(\.accent) private var accent
    let source: BrowserSource
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(nsImage: source.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 38, height: 38)
                Text(source.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? AnyShapeStyle(accent.opacity(0.2)) : AnyShapeStyle(.primary.opacity(hovering ? 0.07 : 0.035)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected ? accent.opacity(0.85) : .primary.opacity(0.06), lineWidth: selected ? 1.5 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.snappy, value: selected)
    }
}
