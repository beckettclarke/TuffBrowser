import SwiftUI

struct Suggestion: Identifiable, Equatable {
    enum Kind: Equatable {
        case go(URL)
        case search(String)
        case history(URL)
        case tab(UUID)
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let symbol: String
    var icon: NSImage?

    static func == (a: Suggestion, b: Suggestion) -> Bool { a.id == b.id }
}

/// Dimmed scrim + the floating command bar (⌘T / ⌘L).
struct CommandBarOverlay: View {
    @Environment(BrowserState.self) private var state
    let mode: CommandBarMode
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(appeared ? 0.22 : 0)
                .contentShape(Rectangle())
                .onTapGesture { state.closeCommandBar() }

            CommandBarView(mode: mode)
                .scaleEffect(appeared ? 1 : 0.96, anchor: .top)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : -8)
                .padding(.top, 120)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { appeared = true }
        }
    }
}

struct CommandBarView: View {
    @Environment(BrowserState.self) private var state
    @Environment(AppSettings.self) private var settings
    @Environment(\.accent) private var accent
    let mode: CommandBarMode

    @State private var text = ""
    @State private var initialText = ""
    @State private var local: [Suggestion] = []
    @State private var remote: [Suggestion] = []
    @State private var selection = 0
    @State private var fetchTask: Task<Void, Never>?

    private var suggestions: [Suggestion] {
        var seen = Set<String>()
        return (local + remote).filter { seen.insert($0.id).inserted }.prefix(8).map { $0 }
    }

    var body: some View {
        let items = suggestions
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: mode == .newTab ? "magnifyingglass" : "globe")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                KeyTextField(
                    text: $text,
                    placeholder: mode == .newTab ? "Search or enter address…" : "Search or enter address…",
                    fontSize: 18, fontWeight: .regular,
                    selectAllOnFocus: true,
                    onSubmit: submit,
                    onCancel: { state.closeCommandBar() },
                    onMoveUp: { move(-1, count: items.count) },
                    onMoveDown: { move(1, count: items.count) },
                    onTab: { move(1, count: items.count) }
                )
                .frame(height: 26)
                if mode == .newTab {
                    Text("New Tab")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.primary.opacity(0.08)))
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 58)

            if !items.isEmpty {
                Rectangle().fill(.primary.opacity(0.1)).frame(height: 1)
                VStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        SuggestionRow(item: item, selected: index == selection, accent: accent)
                            .onTapGesture { activate(item) }
                            .onHover { if $0 { selection = index } }
                    }
                }
                .padding(8)
                .transition(.opacity)
            }
        }
        .frame(width: 640)
        .background(
            ZStack {
                VisualEffect(material: .hudWindow, blending: .withinWindow)
                Color(nsColor: state.currentTint).opacity(0.55)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 40, y: 18)
        .animation(Motion.quick, value: items.count)
        .onAppear {
            if mode == .editCurrent, let url = state.selectedTab?.url {
                text = url.absoluteString
                initialText = text
            }
        }
        .onChange(of: text) { _, new in refresh(for: new) }
        .onDisappear { fetchTask?.cancel() }
    }

    // MARK: Behaviour

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func submit() {
        let items = suggestions
        if items.indices.contains(selection), !text.trimmed.isEmpty, text != initialText || selection > 0 {
            activate(items[selection])
        } else if !text.trimmed.isEmpty {
            let input = text
            state.closeCommandBar()
            state.open(input: input, mode: mode)
        } else {
            state.closeCommandBar()
        }
    }

    private func activate(_ item: Suggestion) {
        state.closeCommandBar()
        switch item.kind {
        case .go(let url), .history(let url):
            state.open(url: url, mode: mode)
        case .search(let query):
            state.open(url: settings.general.searchEngine.searchURL(for: query), mode: mode)
        case .tab(let id):
            if let tab = state.allTabs.first(where: { $0.id == id }) { state.select(tab) }
        }
    }

    private func refresh(for input: String) {
        let query = input.trimmed
        selection = 0
        fetchTask?.cancel()
        guard !query.isEmpty, input != initialText else {
            local = []
            remote = []
            return
        }
        let engine = settings.general.searchEngine

        // Instant, local results.
        var items: [Suggestion] = []
        let resolved = BrowserState.resolve(query, engine: engine)
        let isSearch = resolved == engine.searchURL(for: query)
        if isSearch {
            items.append(Suggestion(id: "search:" + query, kind: .search(query), title: query, subtitle: "Search \(engine.label)", symbol: "magnifyingglass"))
        } else {
            items.append(Suggestion(id: "go:" + resolved.absoluteString, kind: .go(resolved), title: query, subtitle: "Open", symbol: "arrow.up.right"))
        }

        let needle = query.lowercased()
        let openTabs = !settings.search.openTabSuggestions ? [] : state.allTabs.filter { tab in
            tab !== state.selectedTab
                && (tab.displayTitle.lowercased().contains(needle) || (tab.url?.absoluteString.lowercased().contains(needle) ?? false))
        }
        for tab in openTabs.prefix(2) {
            items.append(Suggestion(
                id: "tab:" + tab.id.uuidString, kind: .tab(tab.id), title: tab.displayTitle,
                subtitle: "Switch to Tab", symbol: "rectangle.on.rectangle", icon: tab.favicon
            ))
        }

        let openURLs = Set(openTabs.prefix(2).compactMap { $0.url?.absoluteString })
        let history = settings.search.historySuggestions ? HistoryStore.shared.search(query, limit: 3) : []
        for entry in history where !openURLs.contains(entry.url.absoluteString) {
            items.append(Suggestion(
                id: "history:" + entry.url.absoluteString, kind: .history(entry.url),
                title: entry.title.isEmpty ? entry.url.displayHost : entry.title,
                subtitle: entry.url.displayHost + (entry.url.path.count > 1 ? entry.url.path : ""),
                symbol: "clock", icon: FaviconStore.shared.cachedIcon(for: entry.url)
            ))
        }
        local = items

        // Search engine suggestions, debounced.
        guard settings.general.searchSuggestions, let url = engine.suggestURL(for: query) else {
            remote = []
            return
        }
        fetchTask = Task {
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 4
            guard let (data, _) = try? await URLSession.shared.data(for: request), !Task.isCancelled else { return }
            // OpenSearch JSON: ["query", ["suggestion", …], …]. Some engines answer in Latin-1.
            let json = (try? JSONSerialization.jsonObject(with: data))
                ?? String(data: data, encoding: .isoLatin1).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
            guard let array = json as? [Any], array.count > 1, let list = array[1] as? [String] else { return }
            let results = list.filter { $0.lowercased() != needle }.prefix(4).map {
                Suggestion(id: "search:" + $0, kind: .search($0), title: $0, subtitle: "", symbol: "magnifyingglass")
            }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                remote = Array(results)
            }
        }
    }
}

struct SuggestionRow: View {
    let item: Suggestion
    let selected: Bool
    let accent: Color

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = item.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Image(systemName: item.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 22)

            Text(item.title)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)

            if !item.subtitle.isEmpty {
                Text("— " + item.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? AnyShapeStyle(accent.opacity(0.28)) : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.1), value: selected)
    }
}
