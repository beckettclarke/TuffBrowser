import SwiftUI

struct Suggestion: Identifiable, Equatable {
    enum Kind: Equatable {
        case go(URL)
        case search(String)
        case history(URL)
        case bookmark(URL)
        case tab(UUID)
        /// Text for an extension's omnibox keyword (`chrome.omnibox`).
        case keyword(String)
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let symbol: String
    var icon: NSImage?

    static func == (a: Suggestion, b: Suggestion) -> Bool { a.id == b.id }

    /// The page of a history suggestion (which can be removed from history).
    var historyURL: URL? {
        if case .history(let url) = kind { return url }
        return nil
    }
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

            // A fresh bar when ⌘T / ⌘L switches the mode of an open one: it is filled (with the
            // current address for ⌘L, empty for ⌘T) and focused only when it first appears.
            CommandBarView(mode: mode)
                .id(mode)
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

/// The horizontal layout's command bar: typed into right where the address bar is, with the
/// suggestions dropping down under it, as in Safari and Chrome.
struct DockedCommandBar: View {
    @Environment(BrowserState.self) private var state
    let mode: CommandBarMode
    /// The address bar's frame in `RootView.space`; the field sits exactly over it.
    let frame: CGRect

    static let minWidth: CGFloat = 380

    var body: some View {
        let width = max(frame.width, Self.minWidth)
        ZStack(alignment: .topLeading) {
            // A click anywhere else puts the address back.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { state.closeCommandBar() }

            CommandBarView(mode: mode, docked: true, fieldHeight: frame.height)
                .id(mode)
                .frame(width: width)
                .offset(x: frame.minX, y: frame.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // No fade of its own: one that waited on `onAppear` could leave the field invisible
        // while the address bar under it was hidden. `RootView` fades it in.
    }
}

/// Where the toolbar's address bar is, so the docked command bar can sit on it.
struct URLPillFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct CommandBarView: View {
    @Environment(BrowserState.self) private var state
    @Environment(AppSettings.self) private var settings
    @Environment(\.accent) private var accent
    let mode: CommandBarMode
    /// Drawn in the toolbar's address bar (horizontal layout) rather than floating mid-window.
    var docked = false
    /// The docked field's height: the address bar's.
    var fieldHeight: CGFloat = 30

    @State private var text = ""
    @State private var initialText = ""
    @State private var local: [Suggestion] = []
    @State private var remote: [Suggestion] = []
    @State private var selection = 0
    @State private var fetchTask: Task<Void, Never>?
    /// A leading `!bang` that has been typed and turned into a chip; `text` is then just the query.
    @State private var chip: Bang?
    /// The site the typed text completes to inline ("git" → "github.com"), from history.
    @State private var completedText: String?
    /// Set by ⌫: no completion again until something is typed (else deleting the completion
    /// would bring it straight back).
    @State private var suppressCompletion = false
    @State private var lastLength = 0
    /// An extension's omnibox keyword that has been typed ("gh "): the rest of the input goes to it.
    @State private var keyword: ExtensionOmnibox.Keyword?
    /// Set once the input has been sent to the keyword's extension, so closing isn't a cancel.
    @State private var keywordEntered = false
    /// Which onInputChanged the suggestions showing answer, so a late answer can't replace a newer one.
    @State private var keywordRequest = 0

    /// The completion shown, selected, after the typed text.
    private var completionSuffix: String? {
        guard let full = completedText, chip == nil, keyword == nil, !text.isEmpty, full.count > text.count,
              full.lowercased().hasPrefix(text.lowercased()) else { return nil }
        return String(full.dropFirst(text.count))
    }

    /// The bang this search goes to: the chip, one typed at the end (`cats !yt`), or one being
    /// typed at the start that hasn't had its space yet (`!yt`).
    private var activeBang: BangMatch? { bangMatch(for: text) }

    private func bangMatch(for input: String) -> BangMatch? {
        if keyword != nil { return nil }
        if let chip { return BangMatch(bang: chip, query: input.trimmed, position: .leading) }
        guard settings.mods.bangs else { return nil }
        return BangStore.shared.match(input)
    }

    private var chipAnimation: Animation? {
        settings.animationsEnabled ? .spring(response: 0.34, dampingFraction: 0.7) : nil
    }

    private var suggestions: [Suggestion] {
        var seen = Set<String>()
        return (local + remote).filter { seen.insert($0.id).inserted }.prefix(8).map { $0 }
    }

    var body: some View {
        let items = suggestions
        let trailingBang = activeBang.flatMap { chip == nil && $0.position == .trailing ? $0.bang : nil }
        let radius: CGFloat = docked ? 10 : 18
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: docked ? 8 : 12) {
                Image(systemName: mode == .newTab ? "magnifyingglass" : mode == .splitTab ? "rectangle.split.2x1" : "globe")
                    .font(.system(size: docked ? 12 : 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: docked ? 16 : 22)
                if let chip {
                    BangChip(bang: chip, compact: docked, animated: settings.animationsEnabled)
                        .id(chip.trigger)
                        .transition(BangChip.transition(edge: .leading))
                }
                if let keyword {
                    ExtensionKeywordChip(keyword: keyword, compact: docked)
                        .transition(BangChip.transition(edge: .leading))
                }
                KeyTextField(
                    text: $text,
                    placeholder: chip.map { "Search \($0.name)…" } ?? keyword.map { "Ask \($0.name)…" } ?? "Search or enter address…",
                    fontSize: docked ? 13.5 : 18, fontWeight: docked ? .medium : .regular,
                    selectAllOnFocus: true,
                    onSubmit: submit,
                    onCancel: { state.closeCommandBar() },
                    onMoveUp: { move(-1, count: items.count) },
                    onMoveDown: { move(1, count: items.count) },
                    onTab: { move(1, count: items.count) },
                    onDeleteAtStart: chip == nil && keyword == nil ? nil : removeChip,
                    completionSuffix: completionSuffix,
                    onDelete: {
                        suppressCompletion = true
                        if completedText != nil {
                            completedText = nil
                            // Deleting just the completion leaves `text` as it was.
                            DispatchQueue.main.async { refresh(for: text) }
                        }
                    },
                    onShiftDelete: { removeSelectedHistory(items) }
                )
                .frame(height: docked ? 20 : 26)
                if let trailingBang {
                    BangChip(bang: trailingBang, compact: docked, animated: settings.animationsEnabled)
                        .id(trailingBang.trigger)
                        .transition(BangChip.transition(edge: .trailing))
                }
                if mode != .editCurrent {
                    Text(mode == .splitTab ? "Split View" : "New Tab")
                        .font(.system(size: docked ? 10.5 : 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, docked ? 7 : 8)
                        .padding(.vertical, docked ? 2 : 4)
                        .background(Capsule().fill(.primary.opacity(0.08)))
                }
            }
            .padding(.leading, docked ? 10 : 18)
            .padding(.trailing, docked ? 8 : 18)
            .frame(height: docked ? fieldHeight : 58)
            .animation(chipAnimation, value: chip)
            .animation(chipAnimation, value: keyword)
            .animation(chipAnimation, value: trailingBang)

            if !items.isEmpty {
                Rectangle().fill(.primary.opacity(0.1)).frame(height: 1)
                VStack(spacing: docked ? 1 : 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        SuggestionRow(
                            item: item, selected: index == selection, accent: accent, compact: docked,
                            onRemove: item.historyURL == nil ? nil : { remove(item) }
                        )
                            .onTapGesture { activate(item) }
                            .onHover { if $0 { selection = index } }
                    }
                }
                .padding(docked ? 5 : 8)
                .transition(.opacity)
            }
        }
        .frame(width: docked ? nil : 640)
        .background(
            ZStack {
                VisualEffect(material: .hudWindow, blending: .withinWindow)
                Color(nsColor: state.currentTint).opacity(docked ? 0.7 : 0.55)
            }
        )
        .clipShape(shape)
        .overlay(shape.strokeBorder(.primary.opacity(docked ? 0 : 0.14), lineWidth: 1))
        .modifier(CardShadow(
            cornerRadius: radius, opacity: docked ? (items.isEmpty ? 0.12 : 0.3) : 0.4,
            radius: docked ? 16 : 40, y: docked ? 8 : 18, hollow: true
        ))
        .animation(Motion.quick, value: items.count)
        .onAppear {
            if settings.mods.bangs { BangStore.shared.prepare() }
            if mode == .editCurrent, let url = state.selectedTab?.url {
                text = url.absoluteString
                initialText = text
            }
            refresh(for: text)
        }
        .onChange(of: text) { _, new in
            // "gh " — an extension's omnibox keyword and a space — hands the input to it.
            if chip == nil, keyword == nil, mode != .splitTab, let match = ExtensionOmnibox.shared.match(new) {
                keyword = match.keyword
                ExtensionOmnibox.shared.started(match.keyword)
                text = match.rest
                return
            }
            // "!yt " — a known bang finished with a space — becomes a chip.
            if chip == nil, keyword == nil, settings.mods.bangs, let token = BangStore.shared.leadingToken(new) {
                chip = token.bang
                text = token.rest
                return
            }
            refresh(for: new)
        }
        .onChange(of: chip) { refresh(for: text) }
        .onDisappear {
            fetchTask?.cancel()
            if let keyword, !keywordEntered { ExtensionOmnibox.shared.cancelled(keyword) }
        }
    }

    /// Fetches search suggestions with no cookies and nothing kept on disk. `URLSession.shared`
    /// keeps a cookie jar of its own, outside every profile's website data, that "Remove All"
    /// never cleared and that Incognito windows shared with normal ones.
    private static let suggestionSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    // MARK: Behaviour

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    /// ⌫ at the start of the field: an empty field gets the bang back as text to edit; otherwise
    /// the chip just goes and the query stays.
    private func removeChip() {
        if let current = keyword {
            keyword = nil
            ExtensionOmnibox.shared.cancelled(current)
            if text.isEmpty { text = current.keyword } else { refresh(for: text) }
            return
        }
        guard let bang = chip else { return }
        chip = nil
        if text.isEmpty { text = "!" + bang.trigger }
    }

    private func submit() {
        let items = suggestions
        if keyword != nil {
            activate(items.indices.contains(selection) ? items[selection]
                     : Suggestion(id: "keyword:", kind: .keyword(text), title: text, subtitle: "", symbol: "puzzlepiece.extension"))
            return
        }
        let hasInput = !text.trimmed.isEmpty || chip != nil
        if items.indices.contains(selection),
           (hasInput && (text != initialText || selection > 0 || chip != nil) || !hasInput && mode == .newTab) {
            activate(items[selection])
        } else if hasInput {
            let input = chip.map { "!\($0.trigger) " + text } ?? text
            state.closeCommandBar()
            state.open(input: input, mode: mode)
        } else {
            state.closeCommandBar()
        }
    }

    /// ⇧⌫ on a history suggestion: forget that page.
    private func removeSelectedHistory(_ items: [Suggestion]) -> Bool {
        guard items.indices.contains(selection), items[selection].historyURL != nil else { return false }
        remove(items[selection])
        return true
    }

    /// Removes a history suggestion's page from history and from the list.
    private func remove(_ item: Suggestion) {
        guard let url = item.historyURL else { return }
        HistoryStore.shared.delete([url], profileID: state.currentProfile.id)
        let keep = selection
        refresh(for: text)
        selection = min(keep, max(0, suggestions.count - 1))
    }

    private func activate(_ item: Suggestion) {
        if case .keyword(let content) = item.kind, let keyword {
            keywordEntered = true
            state.closeCommandBar()
            ExtensionOmnibox.shared.entered(keyword, text: content, newTab: mode == .newTab)
            return
        }
        state.closeCommandBar()
        switch item.kind {
        case .go(let url), .history(let url), .bookmark(let url):
            state.open(url: url, mode: mode)
        case .search(let query):
            let url = activeBang?.bang.url(for: query) ?? settings.general.searchEngine.searchURL(for: query)
            state.open(url: url, mode: mode)
        case .tab(let id):
            guard let tab = state.allTabs.first(where: { $0.id == id }) else { return }
            // Switching away from an empty New Tab page leaves no empty tab behind.
            let blank = mode == .newTab ? state.selectedTab.flatMap { $0.showsNewTabPage ? $0 : nil } : nil
            if mode == .splitTab { state.split(with: tab) } else { state.select(tab) }
            if let blank, blank !== tab { state.close(blank, force: true) }
        case .keyword:
            break
        }
    }

    /// Keyword mode: the typed text as the first row (with the extension's default
    /// suggestion), then what the extension suggests for it, when it answers.
    private func refreshKeyword(_ keyword: ExtensionOmnibox.Keyword, input: String) {
        selection = 0
        fetchTask?.cancel()
        completedText = nil
        let omnibox = ExtensionOmnibox.shared
        let fallback = omnibox.defaultSuggestion(for: keyword.extensionID)
            .map { $0.replacingOccurrences(of: "%s", with: input) } ?? keyword.name
        local = [Suggestion(
            id: "keyword:" + input, kind: .keyword(input), title: input.isEmpty ? keyword.name : input,
            subtitle: fallback, symbol: "puzzlepiece.extension", icon: keyword.icon
        )]
        keywordRequest += 1
        let request = keywordRequest
        omnibox.changed(keyword, text: input) { results in
            guard request == keywordRequest, self.keyword == keyword else { return }
            remote = results.prefix(7).map { result in
                Suggestion(
                    id: "keyword:" + result.content, kind: .keyword(result.content),
                    title: result.description, subtitle: result.description == result.content ? "" : result.content,
                    symbol: "puzzlepiece.extension", icon: keyword.icon
                )
            }
        }
    }

    private func zeroStateSuggestions() -> [Suggestion] {
        let recentTabs = state.allTabs
            .filter { $0 !== state.selectedTab && !$0.showsNewTabPage }
            .sorted { $0.lastActive > $1.lastActive }
            .prefix(4)
        var items = recentTabs.map { tab in
            Suggestion(
                id: "tab:" + tab.id.uuidString, kind: .tab(tab.id), title: tab.displayTitle,
                subtitle: "Recent Tab", symbol: "rectangle.on.rectangle", icon: tab.favicon
            )
        }
        let openURLs = Set(recentTabs.compactMap(\.url))
        if settings.search.historySuggestions {
            for site in HistoryStore.shared.topSites(limit: 8, profileID: state.currentProfile.id) {
                guard let address = site["url"] as? String, let url = URL(string: address), !openURLs.contains(url) else { continue }
                let title = (site["title"] as? String)?.trimmed
                items.append(Suggestion(
                    id: "history:" + address, kind: .history(url),
                    title: title?.isEmpty == false ? title! : url.displayHost,
                    subtitle: "Top Site", symbol: "clock", icon: FaviconStore.shared.cachedIcon(for: url)
                ))
            }
        }
        return Array(items.prefix(8))
    }

    private func refresh(for input: String) {
        if let keyword {
            refreshKeyword(keyword, input: input)
            return
        }
        let bang = bangMatch(for: input)
        let query = (bang?.query ?? input).trimmed
        selection = 0
        fetchTask?.cancel()
        // Inline completion: only while typing forwards, and not over a bang or a search.
        let grew = input.count > lastLength
        lastLength = input.count
        if grew { suppressCompletion = false }
        completedText = nil
        if bang == nil, chip == nil, !suppressCompletion, settings.search.historySuggestions,
           input != initialText, input == input.trimmed {
            completedText = HistoryStore.shared.hostCompletion(for: input, profileID: state.currentProfile.id)
        }
        guard bang != nil || (!query.isEmpty && input != initialText) else {
            local = query.isEmpty && mode == .newTab ? zeroStateSuggestions() : []
            remote = []
            return
        }
        let engine = settings.general.searchEngine

        // Instant, local results.
        var items: [Suggestion] = []
        if let bang {
            let icon = bang.bang.homeURL.flatMap { FaviconStore.shared.cachedIcon(for: $0) }
            if query.isEmpty, let home = bang.bang.homeURL {
                // Just the chip: ↩ opens the site.
                local = [Suggestion(id: "go:" + home.absoluteString, kind: .go(home), title: bang.bang.name, subtitle: bang.bang.domain, symbol: "arrow.up.right", icon: icon)]
                remote = []
                return
            }
            items.append(Suggestion(id: "bang:" + query, kind: .search(query), title: query, subtitle: "Search \(bang.bang.name)", symbol: "magnifyingglass", icon: icon))
        } else if let completedText {
            // ↩ opens the completed site.
            let resolved = BrowserState.resolve(completedText, engine: engine)
            items.append(Suggestion(id: "go:" + resolved.absoluteString, kind: .go(resolved), title: completedText, subtitle: "Open", symbol: "arrow.up.right", icon: FaviconStore.shared.cachedIcon(for: resolved)))
        } else {
            let resolved = BrowserState.resolve(query, engine: engine)
            if resolved == engine.searchURL(for: query) {
                items.append(Suggestion(id: "search:" + query, kind: .search(query), title: query, subtitle: "Search \(engine.label)", symbol: "magnifyingglass"))
            } else {
                items.append(Suggestion(id: "go:" + resolved.absoluteString, kind: .go(resolved), title: query, subtitle: "Open", symbol: "arrow.up.right"))
            }
        }

        let needle = query.lowercased()
        // In a split, only the current space's tabs can go beside this one.
        let candidates = mode == .splitTab ? state.allTabs.filter { state.canSplit(with: $0) } : state.allTabs
        let openTabs = !settings.search.openTabSuggestions ? [] : candidates.filter { tab in
            tab !== state.selectedTab && !tab.showsNewTabPage
                && (tab.displayTitle.lowercased().contains(needle) || (tab.url?.absoluteString.lowercased().contains(needle) ?? false))
        }
        for tab in openTabs.prefix(2) {
            items.append(Suggestion(
                id: "tab:" + tab.id.uuidString, kind: .tab(tab.id), title: tab.displayTitle,
                subtitle: mode == .splitTab ? "Open in Split View" : "Switch to Tab",
                symbol: mode == .splitTab ? "rectangle.split.2x1" : "rectangle.on.rectangle", icon: tab.favicon
            ))
        }

        // Tuff's own pages, by name ("hist" → History).
        if needle.count >= 3 {
            for page in InternalPage.allCases where page != .source && page.title.lowercased().hasPrefix(needle) {
                items.append(Suggestion(
                    id: "page:" + page.rawValue, kind: .go(page.url), title: page.title,
                    subtitle: "Tuff", symbol: page.symbol
                ))
            }
        }

        var openURLs = Set(openTabs.prefix(2).compactMap { $0.url?.absoluteString })
        let bookmarks = settings.search.bookmarkSuggestions
            ? state.bookmarksProfileID.map { BookmarkStore.shared.search(query, limit: 3, profile: $0) } ?? [] : []
        for bookmark in bookmarks {
            guard let url = bookmark.url, !openURLs.contains(url.absoluteString) else { continue }
            openURLs.insert(url.absoluteString)
            items.append(Suggestion(
                id: "bookmark:" + url.absoluteString, kind: .bookmark(url), title: bookmark.displayTitle,
                subtitle: "Bookmark · " + url.displayHost + (url.path.count > 1 ? url.path : ""),
                symbol: "star", icon: FaviconStore.shared.cachedIcon(for: url)
            ))
        }
        let history = settings.search.historySuggestions ? HistoryStore.shared.search(query, limit: 3, profileID: state.currentProfile.id) : []
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
            guard let (data, _) = try? await Self.suggestionSession.data(for: request), !Task.isCancelled else { return }
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

/// A `!bang` the command bar recognised: the site's icon and name in an accent capsule. It
/// pops in with a little blur-to-sharp spring, then a single sheen runs across it.
struct BangChip: View {
    @Environment(\.accent) private var accent
    let bang: Bang
    var compact = false
    var animated = true
    @State private var icon: NSImage?
    @State private var sheen: CGFloat = -0.6

    var body: some View {
        HStack(spacing: compact ? 4 : 5) {
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .clipShape(RoundedRectangle(cornerRadius: compact ? 3 : 3.5, style: .continuous))
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                } else {
                    Text("!")
                        .font(.system(size: compact ? 11 : 12.5, weight: .heavy, design: .rounded))
                        .foregroundStyle(accent)
                        .transition(.opacity)
                }
            }
            .frame(width: compact ? 13 : 15, height: compact ? 13 : 15)
            Text(bang.name)
                .font(.system(size: compact ? 12 : 13.5, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: compact ? 140 : 180, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.leading, compact ? 5 : 6)
        .padding(.trailing, compact ? 8 : 10)
        .frame(height: compact ? 20 : 26)
        .background(Capsule().fill(accent.opacity(0.22)))
        .overlay(Capsule().strokeBorder(accent.opacity(0.5), lineWidth: 0.75))
        .overlay {
            GeometryReader { geo in
                LinearGradient(colors: [.white.opacity(0), .white.opacity(0.32), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.45)
                    .offset(x: sheen * geo.size.width)
            }
            .clipShape(Capsule())
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        }
        .help("!\(bang.trigger) — \(bang.domain)")
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 0.75).delay(0.12)) { sheen = 1.2 }
        }
        .task(id: bang.domain) {
            if let home = bang.homeURL, let cached = FaviconStore.shared.cachedIcon(for: home) {
                icon = cached
                return
            }
            let domain = bang.domain
            let image = await withCheckedContinuation { done in
                FaviconStore.shared.icon(forHost: domain) { done.resume(returning: $0) }
            }
            guard !Task.isCancelled, let image else { return }
            withAnimation(animated ? Motion.snappy : nil) { icon = image }
        }
    }

    static func transition(edge: HorizontalEdge) -> AnyTransition {
        let anchor: UnitPoint = edge == .leading ? .leading : .trailing
        return .asymmetric(
            insertion: .modifier(
                active: ChipPop(scale: 0.55, blur: 5, opacity: 0, anchor: anchor),
                identity: ChipPop(scale: 1, blur: 0, opacity: 1, anchor: anchor)
            ),
            removal: .modifier(
                active: ChipPop(scale: 0.8, blur: 3, opacity: 0, anchor: anchor),
                identity: ChipPop(scale: 1, blur: 0, opacity: 1, anchor: anchor)
            )
        )
    }

    private struct ChipPop: ViewModifier {
        let scale: CGFloat
        let blur: CGFloat
        let opacity: Double
        let anchor: UnitPoint

        func body(content: Content) -> some View {
            content
                .scaleEffect(scale, anchor: anchor)
                .blur(radius: blur)
                .opacity(opacity)
        }
    }
}

/// An extension's omnibox keyword, as a chip in the command bar: its icon and name.
struct ExtensionKeywordChip: View {
    @Environment(\.accent) private var accent
    let keyword: ExtensionOmnibox.Keyword
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 4 : 5) {
            Group {
                if let icon = keyword.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: compact ? 10 : 11.5, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
            .frame(width: compact ? 13 : 15, height: compact ? 13 : 15)
            Text(keyword.name)
                .font(.system(size: compact ? 12 : 13.5, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: compact ? 140 : 180, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.leading, compact ? 5 : 6)
        .padding(.trailing, compact ? 8 : 10)
        .frame(height: compact ? 20 : 26)
        .background(Capsule().fill(accent.opacity(0.22)))
        .overlay(Capsule().strokeBorder(accent.opacity(0.5), lineWidth: 0.75))
        .help("\(keyword.keyword) — \(keyword.name)")
    }
}

struct SuggestionRow: View {
    let item: Suggestion
    let selected: Bool
    let accent: Color
    /// Smaller rows, for the dropdown under the docked address bar.
    var compact = false
    /// A history row can be removed (its × shows while it is selected; ⇧⌫ does the same).
    var onRemove: (() -> Void)?

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
                .font(.system(size: compact ? 13 : 14, weight: .medium))
                .lineLimit(1)

            if !item.subtitle.isEmpty {
                Text("— " + item.subtitle)
                    .font(.system(size: compact ? 12 : 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if selected, let onRemove {
                IconButton(symbol: "xmark", size: 9, weight: .bold, side: 20, help: "Remove from History  ⇧⌫", action: onRemove)
                    .transition(.opacity)
            } else if selected {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, compact ? 8 : 10)
        .frame(height: compact ? 32 : 38)
        .background(
            RoundedRectangle(cornerRadius: compact ? 7 : 10, style: .continuous)
                .fill(selected ? AnyShapeStyle(accent.opacity(0.28)) : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.1), value: selected)
    }
}
