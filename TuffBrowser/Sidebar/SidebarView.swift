import SwiftUI
import UniformTypeIdentifiers

private struct AccentKey: EnvironmentKey {
    static let defaultValue: Color = .accentColor
}

extension EnvironmentValues {
    /// The current space's accent colour, derived from its tint.
    var accent: Color {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
}

struct SidebarView: View {
    @Environment(BrowserState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            TopControls()
            URLPill()
                .padding(.horizontal, 10)
            ExtensionBar()
            FavoritesGrid()
            SpacePager()
            BottomBar()
        }
        .background(WindowDragArea())
    }
}

// MARK: - Top row

struct TopControls: View {
    @Environment(BrowserState.self) private var state

    var body: some View {
        let tab = state.selectedTab
        HStack(spacing: 2) {
            // Room for the traffic lights, which the window controller centres in this row.
            Color.clear.frame(width: state.isFullscreen ? 4 : 74, height: 1)
            IconButton(symbol: "sidebar.left", size: 14, help: "Hide Sidebar  ⌘S") { state.toggleSidebar() }
            Spacer(minLength: 0)
            IconButton(symbol: "arrow.left", size: 13, weight: .semibold, help: "Back", disabled: !(tab?.canGoBack ?? false)) {
                tab?.goBack()
            }
            IconButton(symbol: "arrow.right", size: 13, weight: .semibold, help: "Forward", disabled: !(tab?.canGoForward ?? false)) {
                tab?.goForward()
            }
            IconButton(
                symbol: (tab?.isLoading ?? false) ? "xmark" : "arrow.clockwise", size: 13, weight: .semibold,
                help: (tab?.isLoading ?? false) ? "Stop" : "Reload", disabled: tab == nil
            ) {
                if tab?.isLoading ?? false { tab?.stop() } else { tab?.reload() }
            }
            .contentTransition(.symbolEffect(.replace))
        }
        .padding(.horizontal, 8)
        .frame(height: BrowserWindowController.topBarHeight)
    }
}

// MARK: - URL pill

struct URLPill: View {
    @Environment(BrowserState.self) private var state
    @Environment(ExtensionManager.self) private var extensions
    var height: CGFloat = 36
    @State private var hovering = false

    var body: some View {
        @Bindable var state = state
        let tab = state.selectedTab
        let url = tab?.url
        HStack(spacing: 0) {
            if let url, tab?.isExtensionPage == true {
                HStack(spacing: 6) {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.45))
                    Text(extensions.displayName(forPage: url) ?? "Extension")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.92))
                        .lineLimit(1)
                }
            } else if let url, url.host != nil {
                if tab?.isNotSecure == true {
                    NotSecureBadge(mixedContent: url.scheme?.lowercased() == "https")
                        .padding(.trailing, 6)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                let parts = url.hostParts
                (Text(parts.prefix).foregroundStyle(.primary.opacity(0.45))
                    + Text(parts.domain).foregroundStyle(.primary.opacity(0.92)))
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.head)
            } else {
                Text(tab == nil ? "Search or enter address" : (url?.absoluteString ?? "New Tab"))
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            let showButtons = hovering || state.pageMenuVisible
            HStack(spacing: 2) {
                if let tab, !tab.blockedPopups.isEmpty {
                    BlockedPopupsButton(tab: tab, side: height > 32 ? 24 : 22)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                // Stays in the bar while reader mode is on, so it's plain how to leave it.
                if let tab, tab.reader != nil {
                    PillButton(
                        symbol: "doc.plaintext.fill", size: 11, side: height > 32 ? 24 : 22,
                        help: "Exit Reader Mode  ⌥⌘R", active: true
                    ) {
                        tab.closeReader()
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                if showButtons, url != nil {
                    PillButton(symbol: "link", size: 11, side: height > 32 ? 24 : 22, help: "Copy Link  ⇧⌘C") {
                        state.copyCurrentURL()
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                if showButtons, tab != nil {
                    PillButton(
                        symbol: "slider.horizontal.3", size: 11.5, side: height > 32 ? 24 : 22,
                        help: "Page Menu", active: state.pageMenuVisible
                    ) {
                        state.pageMenuVisible.toggle()
                    }
                    .popover(isPresented: $state.pageMenuVisible, arrowEdge: .bottom) {
                        PageMenu()
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: height)
        // Popups opened from the page menu (share, extensions) hang off the address bar.
        .background(AnchorView { PageMenu.anchor = $0 })
        .background(
            RoundedRectangle(cornerRadius: height * 0.3, style: .continuous)
                .fill(.primary.opacity(hovering ? 0.13 : 0.09))
        )
        .contentShape(RoundedRectangle(cornerRadius: height * 0.3, style: .continuous))
        .onTapGesture { state.openCommandBar(.editCurrent) }
        .contextMenu {
            Button("Paste and Go") { state.pasteAndGo() }
                .disabled(state.pasteAndGoText == nil)
            Button("Paste and Go in New Tab") { state.pasteAndGo(inNewTab: true) }
                .disabled(state.pasteAndGoText == nil)
            Divider()
            Button("Copy Link") { state.copyCurrentURL() }
                .disabled(url == nil)
            Button("Edit Address") { state.openCommandBar(.editCurrent) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(url.map { "Address: \($0.absoluteString)" } ?? "Search or enter address")
        .accessibilityAddTraits(.isButton)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: url)
        .animation(Motion.quick, value: tab?.isNotSecure)
        .animation(Motion.quick, value: state.pageMenuVisible)
        .animation(Motion.quick, value: tab?.reader != nil)
        .animation(Motion.quick, value: tab?.blockedPopups.isEmpty)
        .help("Search or enter address  ⌘L")
    }
}

/// A small button inside the address bar, with a soft square behind it on hover (and while
/// what it opens is showing).
struct PillButton: View {
    let symbol: String
    var size: CGFloat = 11
    var side: CGFloat = 22
    var help = ""
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.primary.opacity(hovering || active ? 0.9 : 0.6))
                .frame(width: side, height: side)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.primary.opacity(active ? 0.16 : (hovering ? 0.11 : 0)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SquishButtonStyle())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: active)
        .help(help)
        .accessibilityLabel(Text(IconButton.accessibleName(help: help, symbol: symbol)))
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Open padlock in front of the address when the connection isn't encrypted.
struct NotSecureBadge: View {
    var mixedContent = false

    var body: some View {
        Image(systemName: "lock.open.fill")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color(red: 0.93, green: 0.36, blue: 0.30))
            .frame(width: 14, height: 14)
            .accessibilityLabel("Not Secure")
            .help(mixedContent
                ? "Not Secure — parts of this page load over an unencrypted connection"
                : "Not Secure — your connection to this site isn’t encrypted")
    }
}

// MARK: - Extension toolbar actions

struct ExtensionBar: View {
    @Environment(BrowserState.self) private var state
    @Environment(ExtensionManager.self) private var extensions

    var body: some View {
        // Reading `revision` re-evaluates this view when icons / badges change.
        let _ = extensions.revision
        let _ = SidePanelManager.shared.revision
        // Extensions don't run in Incognito windows.
        // Unpinned ones live in the page menu instead.
        let actions = state.isPrivate ? [] : extensions.actions(for: state.selectedTab).filter(\.pinned)
        if !actions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(actions) { action in
                        ExtensionActionButton(action: action)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(height: 30)
            .padding(.top, 6)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

struct ExtensionActionButton: View {
    @Environment(ExtensionManager.self) private var extensions
    @Environment(\.accent) private var accent
    let action: ExtensionActionInfo
    @State private var hovering = false

    var body: some View {
        Button {
            extensions.performAction(id: action.id)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let icon = action.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "puzzlepiece.extension.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.primary.opacity(0.7))
                    }
                }
                .frame(width: 28, height: 28)
                .opacity(action.enabled ? 1 : 0.4)

                if !action.badge.isEmpty {
                    Text(action.badge)
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.red))
                        .offset(x: 2, y: 1)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(action.panelOpen ? AnyShapeStyle(accent.opacity(hovering ? 0.34 : 0.26)) : AnyShapeStyle(.primary.opacity(hovering ? 0.12 : 0.06)))
            )
            .background(AnchorView { extensions.setAnchor($0, for: action.id) })
            .contentShape(Rectangle())
        }
        .buttonStyle(SquishButtonStyle())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: action.panelOpen)
        .help(action.name)
        .accessibilityLabel(Text(action.badge.isEmpty ? action.name : "\(action.name), \(action.badge)"))
        .contextMenu {
            if action.hasPanel {
                Button(action.panelOpen ? "Close Side Panel" : "Open Side Panel") { SidePanelManager.shared.toggle(action.id) }
                Divider()
            }
            if extensions.hasOptions(id: action.id) {
                Button("Options…") { extensions.openOptions(id: action.id) }
            }
            Menu("Use In") { ExtensionLinkMenuItems(id: action.id) }
            Button("Unpin") {
                withAnimation(Motion.snappy) { extensions.setPinned(false, id: action.id) }
            }
            Button("Manage Extensions…") { AppDelegate.shared?.showSettings(tab: .extensions) }
            Divider()
            Button("Remove “\(action.name)”", role: .destructive) { extensions.uninstall(id: action.id) }
        }
    }
}

/// Hands the backing `NSView` to a callback, so AppKit popovers can be anchored to SwiftUI views.
struct AnchorView: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        onResolve(nsView)
    }
}

// MARK: - Favourites grid

struct FavoritesGrid: View {
    @Environment(BrowserState.self) private var state

    /// Up to four favourites sit in one row. Past that they wrap into rows that stay as even
    /// as possible: 5–6 in threes, 7–8 in fours, and four across from then on.
    static func columnCount(for count: Int) -> Int {
        count <= 4 ? max(count, 1) : min(4, (count + 1) / 2)
    }

    var body: some View {
        let favorites = state.favorites
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: Self.columnCount(for: favorites.count))
        // Worked out once here and handed down: a tile that looked up the selected tab itself
        // would be re-evaluated whenever any tab list or selection changed.
        let selectedID = state.spaces.isEmpty ? nil : state.currentSpace.selectedTabID
        Group {
            if !favorites.isEmpty {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(favorites) { tab in
                        FavoriteTile(tab: tab, selected: tab.id == selectedID)
                            .onDrag {
                                state.draggingTab = tab
                                return NSItemProvider(object: tab.id.uuidString as NSString)
                            }
                            .modifier(TabDropTarget(tab: tab, section: .favorites, space: state.currentSpace, axis: .horizontal, cornerRadius: 12))
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .animation(Motion.snappy, value: columns.count)
            } else if state.draggingTab != nil {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(height: 44)
                    .overlay(
                        Text(state.profiles.count > 1 ? "Drop here to favourite in \(state.currentProfile.name)" : "Drop here to favourite")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    )
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .onDrop(of: [.text], delegate: TabDropDelegate(target: nil, section: .favorites, space: state.currentSpace, state: state))
                    .transition(.opacity)
            }
        }
    }
}

struct FavoriteTile: View {
    @Environment(BrowserState.self) private var state
    @Environment(\.accent) private var accent
    let tab: Tab
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        // Selected, the tile takes on its favicon's colours, as in Arc and Zen.
        let colors = selected ? FaviconColors.palette(for: tab.favicon) : nil
        Button {
            state.select(tab)
        } label: {
            ZStack {
                shape.fill(.primary.opacity(selected ? 0.14 : (hovering ? 0.13 : 0.08)))
                if let colors {
                    shape.fill(LinearGradient(colors: colors.map { Color(nsColor: $0).opacity(0.13) }, startPoint: .topLeading, endPoint: .bottomTrailing))
                    shape.strokeBorder(
                        LinearGradient(colors: colors.map { Color(nsColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 2
                    )
                } else {
                    // A favicon without colour (black, white, grey): a plain light outline.
                    shape.strokeBorder(.primary.opacity(selected ? 0.55 : 0), lineWidth: 1.5)
                }
                TabIcon(tab: tab, size: 18)
                    .opacity(tab.isAwake || selected ? 1 : 0.75)
            }
            .frame(height: 44)
            .contentShape(shape)
        }
        .buttonStyle(SquishButtonStyle(scale: 0.94))
        .onHover { hovering = $0 }
        // As with the rows: unloads the favourite (its "Unload Tab").
        .onMiddleClick { state.close(tab) }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.snappy, value: selected)
        .animation(Motion.quick, value: tab.favicon)
        .help(tab.displayTitle)
        .accessibilityLabel(Text(tab.accessibilityDescription))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu { TabContextMenu(tab: tab, section: .favorites) }
    }
}

/// Favicon, swapped for a spinning ring while the page loads, with a symbol fallback.
struct TabIcon: View {
    let tab: Tab
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            if tab.isLoading {
                LoadingSpinner(size: size)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            } else if let icon = tab.favicon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            } else {
                Image(systemName: tab.url == nil ? "plus.square.dashed" : "globe")
                    .font(.system(size: size * 0.86, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.55))
            }
        }
        .frame(width: size, height: size)
        .animation(Motion.quick, value: tab.favicon != nil)
        .animation(.easeOut(duration: 0.25), value: tab.isLoading)
    }
}

/// A ring whose tail fades out as it spins. Driven by a timeline rather than a repeating
/// animation, so it can't pick up (or leak into) the row's own layout animations, and it only
/// exists while a tab is loading.
struct LoadingSpinner: View {
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var size: CGFloat = 16

    var body: some View {
        let inset = size * 0.12
        let line = max(1.6, size * 0.13)
        TimelineView(.animation(paused: reduceMotion)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8) / 0.8
            Circle()
                .trim(from: 0, to: 0.8)
                .stroke(
                    AngularGradient(
                        colors: [accent.opacity(0), accent.opacity(0.45), accent],
                        center: .center,
                        startAngle: .degrees(0), endAngle: .degrees(288)
                    ),
                    style: StrokeStyle(lineWidth: line, lineCap: .round)
                )
                .rotationEffect(.degrees(turn * 360))
        }
        .padding(inset)
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}

// MARK: - Space pager

struct SpacePager: View {
    @Environment(BrowserState.self) private var state

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            HStack(alignment: .top, spacing: 0) {
                ForEach(state.spaces) { space in
                    SpacePage(space: space)
                        .frame(width: width)
                        // Neighbouring pages sit off to the side, over the web page. Clipping
                        // only hides them — they must also be barred from taking mouse events.
                        .allowsHitTesting(space === state.currentSpace)
                }
            }
            .offset(x: -CGFloat(state.pagerPosition) * width)
            .frame(width: width, alignment: .leading)
        }
        .clipped()
        .contentShape(Rectangle())
        .padding(.top, 6)
    }
}

struct SpacePage: View {
    @Environment(BrowserState.self) private var state
    let space: Space

    var body: some View {
        // The selected row is worked out here, once, and handed to the rows. A row is selected
        // only while its space is the one showing.
        let selectedID = !state.spaces.isEmpty && state.currentSpace === space ? space.selectedTabID : nil
        // The other side of a split showing with the selected tab.
        let partnerID = space.split?.partner(of: selectedID)
        VStack(spacing: 0) {
            SpaceHeader(space: space)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    let pinnedPair = SplitTabRow.Pair(in: space.pinned, split: space.split)
                    ForEach(space.pinnedItems) { item in
                        switch item {
                        case .tab(let tab):
                            if let pair = pinnedPair, tab === pair.first {
                                SplitTabRow(pair: pair, section: .pinned, space: space, selectedID: selectedID)
                            } else if pinnedPair?.second !== tab {
                                SidebarTabRow(tab: tab, section: .pinned, selected: tab.id == selectedID, space: space, split: split(tab))
                            }
                        case .folder(let folder):
                            FolderSection(folder: folder, space: space, selectedID: selectedID, partnerID: partnerID)
                                .transition(.scale(scale: 0.92, anchor: .leading).combined(with: .opacity))
                        }
                    }
                    if !space.pinnedItems.isEmpty || state.draggingTab != nil {
                        PinDropZone(space: space, empty: space.pinnedItems.isEmpty)
                    }

                    TabsDivider(space: space)

                    NewTabRow()

                    let tabsPair = SplitTabRow.Pair(in: space.tabs, split: space.split)
                    ForEach(space.tabs) { tab in
                        // A split's two tabs share one row, where the first of them is.
                        if let pair = tabsPair, tab === pair.first {
                            SplitTabRow(pair: pair, section: .tabs, space: space, selectedID: selectedID)
                        } else if tabsPair?.second !== tab {
                            SidebarTabRow(tab: tab, section: .tabs, selected: tab.id == selectedID, space: space, split: split(tab))
                        }
                    }

                    // Drop target for "move to the end of the list".
                    Color.clear
                        .frame(height: 60)
                        .contentShape(Rectangle())
                        .onDrop(of: [.text], delegate: TabDropDelegate(target: nil, section: .tabs, space: space, state: state))
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }

    /// How a row shows its place in the space's split.
    private func split(_ tab: Tab) -> TabRow.SplitRole {
        guard space.split?.contains(tab.id) == true else { return .none }
        let selectedID = !state.spaces.isEmpty && state.currentSpace === space ? space.selectedTabID : nil
        return space.split?.partner(of: selectedID) == tab.id ? .showing : .paired
    }
}

/// A tab row in a space's list that can be dragged and dropped onto.
struct SidebarTabRow: View {
    @Environment(BrowserState.self) private var state
    let tab: Tab
    let section: TabSection
    let selected: Bool
    let space: Space
    var folder: Folder?
    var split: TabRow.SplitRole = .none

    var body: some View {
        TabRow(tab: tab, section: section, selected: selected, split: split)
            .onDrag {
                state.draggingTab = tab
                return NSItemProvider(object: tab.id.uuidString as NSString)
            }
            .modifier(TabDropTarget(tab: tab, section: section, space: space, folder: folder, axis: .vertical))
            .transition(
                .asymmetric(
                    insertion: .scale(scale: 0.92, anchor: .leading).combined(with: .opacity),
                    removal: .scale(scale: 0.9, anchor: .leading).combined(with: .opacity)
                )
            )
    }
}

/// A split's two tabs on one row, as Arc shows them: left and right halves in the order they
/// sit on screen. Each half selects, closes, drags and right-clicks as its own tab; dragging one
/// to another place in the list takes it out of the split.
struct SplitTabRow: View {
    /// The two tabs of a space's split when both are in the same list: `first` / `second` in
    /// list order (the row stands where `first` is), `leading` / `trailing` on screen.
    struct Pair {
        let first: Tab
        let second: Tab
        let leading: Tab
        let trailing: Tab

        init?(in list: [Tab], split: SplitPair?) {
            guard let split,
                  let l = list.firstIndex(where: { $0.id == split.leading }),
                  let t = list.firstIndex(where: { $0.id == split.trailing }) else { return nil }
            leading = list[l]
            trailing = list[t]
            first = list[min(l, t)]
            second = list[max(l, t)]
        }
    }

    @Environment(BrowserState.self) private var state
    let pair: Pair
    let section: TabSection
    let space: Space
    var folder: Folder?
    /// The space's selected tab while it is the space showing.
    let selectedID: UUID?

    var body: some View {
        let showing = selectedID == pair.leading.id || selectedID == pair.trailing.id
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 0) {
            SplitTabHalf(tab: pair.leading, section: section, focused: selectedID == pair.leading.id)
            Rectangle()
                .fill(.primary.opacity(0.14))
                .frame(width: 1, height: 16)
            SplitTabHalf(tab: pair.trailing, section: section, focused: selectedID == pair.trailing.id)
        }
        .frame(height: AppSettings.shared.tabs.compactRows ? 30 : 36)
        .background(shape.fill(.primary.opacity(showing ? 0.08 : 0.04)))
        .overlay(shape.strokeBorder(.primary.opacity(0.06), lineWidth: 0.5).allowsHitTesting(false))
        .modifier(TabDropTarget(tab: pair.first, section: section, space: space, folder: folder, axis: .vertical, pairedWith: pair.second))
        .animation(Motion.quick, value: showing)
        .transition(
            .asymmetric(
                insertion: .scale(scale: 0.92, anchor: .leading).combined(with: .opacity),
                removal: .scale(scale: 0.9, anchor: .leading).combined(with: .opacity)
            )
        )
    }
}

/// One side of a `SplitTabRow`.
private struct SplitTabHalf: View {
    @Environment(BrowserState.self) private var state
    let tab: Tab
    let section: TabSection
    /// The side with the keyboard.
    let focused: Bool
    @State private var hovering = false

    var body: some View {
        let renaming = state.renamingTabID == tab.id
        HStack(spacing: 7) {
            TabIcon(tab: tab)
                .opacity(tab.isAwake || focused ? 1 : 0.7)
            if renaming {
                InlineRenameField(
                    initial: tab.displayTitle, placeholder: tab.pageTitle,
                    commit: { state.rename(tab, to: $0) },
                    cancel: { state.renamingTabID = nil }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(tab.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(focused ? 0.96 : (tab.isAwake ? 0.82 : 0.6)))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .mask(
                        LinearGradient(
                            stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
            }
            if tab.cameraInUse || tab.microphoneInUse {
                CaptureIndicator(tab: tab, size: 18)
            }
            if tab.isMuted || tab.isPlayingAudio, !hovering {
                Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.6))
                    .transition(.opacity)
            }
            if hovering, !renaming {
                Button {
                    state.close(tab)
                } label: {
                    Image(systemName: section == .tabs ? "xmark" : "minus")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.7))
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.primary.opacity(0.1)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(SquishButtonStyle())
                .help(section == .tabs ? "Close Tab" : "Unload Tab")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(focused ? 0.14 : (hovering ? 0.07 : 0)))
                .shadow(color: .black.opacity(focused ? 0.12 : 0), radius: 3, y: 1)
                .padding(2)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard !renaming else { return }
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                state.renamingTabID = tab.id
            } else {
                state.select(tab)
            }
        }
        .onHover { hovering = $0 }
        .onMiddleClick { state.close(tab) }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: focused)
        .help(tab.displayTitle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(tab.accessibilityDescription))
        .accessibilityAddTraits(focused ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { state.select(tab) }
        .contextMenu { TabContextMenu(tab: tab, section: section) }
        .onDrag {
            state.draggingTab = tab
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
    }
}

// MARK: - Folders

/// A folder of pinned tabs: its header row, then its tabs, indented. A collapsed folder still
/// shows the tab that is open, as Arc does, so the page on screen never vanishes from the list.
struct FolderSection: View {
    @Environment(BrowserState.self) private var state
    let folder: Folder
    let space: Space
    let selectedID: UUID?
    /// The other side of a split showing with the selected tab.
    var partnerID: UUID?

    var body: some View {
        let visible = folder.isOpen ? folder.tabs : folder.tabs.filter { $0.id == selectedID || $0.id == partnerID }
        let pair = SplitTabRow.Pair(in: visible, split: space.split)
        VStack(spacing: 2) {
            FolderRow(folder: folder, space: space)
            ForEach(visible) { tab in
                if let pair, tab === pair.first {
                    SplitTabRow(pair: pair, section: .pinned, space: space, folder: folder, selectedID: selectedID)
                        .padding(.leading, 16)
                } else if pair?.second !== tab {
                    SidebarTabRow(
                        tab: tab, section: .pinned, selected: tab.id == selectedID, space: space, folder: folder,
                        split: space.split?.contains(tab.id) == true ? (tab.id == partnerID ? .showing : .paired) : .none
                    )
                    .padding(.leading, 16)
                }
            }
            if folder.isOpen, folder.tabs.isEmpty {
                Text(state.draggingTab == nil ? "Empty folder" : "Drop here to add")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 42)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                    .onDrop(of: [.text], delegate: FolderDropDelegate(folder: folder, space: space, state: state))
                    .transition(.opacity)
            }
        }
    }
}

/// A text box that edits a name in place in the sidebar. Return or clicking away keeps what
/// was typed; Esc cancels.
struct InlineRenameField: View {
    let initial: String
    var placeholder = "Name"
    var weight: Font.Weight = .medium
    let commit: (String) -> Void
    let cancel: () -> Void
    @State private var draft = ""
    @State private var finished = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 13.5, weight: weight))
            .focused($focused)
            .onSubmit { finish { commit(draft) } }
            .onExitCommand { finish(cancel) }
            .onAppear {
                draft = initial
                DispatchQueue.main.async { focused = true }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { finish { commit(draft) } }
            }
    }

    private func finish(_ action: () -> Void) {
        guard !finished else { return }
        finished = true
        action()
    }
}

struct FolderRow: View {
    @Environment(BrowserState.self) private var state
    let folder: Folder
    let space: Space
    @State private var hovering = false

    var body: some View {
        let renaming = state.renamingFolderID == folder.id
        HStack(spacing: 10) {
            Image(systemName: folder.isOpen ? "folder" : "folder.fill")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 16, height: 16)
                .contentTransition(.symbolEffect(.replace))
            if renaming {
                InlineRenameField(
                    initial: folder.name, placeholder: "Folder name", weight: .semibold,
                    commit: { state.rename(folder, to: $0) },
                    cancel: { state.renamingFolderID = nil }
                )
            } else {
                Text(folder.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if !folder.isOpen, !folder.tabs.isEmpty, !renaming {
                Text("\(folder.tabs.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.4))
                    .transition(.opacity)
            }
        }
        .foregroundStyle(.primary.opacity(0.82))
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .frame(height: AppSettings.shared.tabs.compactRows ? 30 : 36)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.primary.opacity(hovering && !renaming ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture { if !renaming { state.toggle(folder) } }
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.snappy, value: folder.isOpen)
        .help(folder.isOpen ? "Collapse Folder" : "Expand Folder")
        .onDrag {
            state.draggingFolder = folder
            return NSItemProvider(object: folder.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: FolderDropDelegate(folder: folder, space: space, state: state))
        .contextMenu {
            Button(folder.isOpen ? "Collapse" : "Expand") { state.toggle(folder) }
            Button("Rename…") { state.renamingFolderID = folder.id }
            Divider()
            Button("Move Up") { state.move(folder, by: -1) }
                .disabled(space.pinnedItems.first?.id == folder.id)
            Button("Move Down") { state.move(folder, by: 1) }
                .disabled(space.pinnedItems.last?.id == folder.id)
            if state.spaces.count > 1 {
                Menu("Move to Space") {
                    ForEach(state.spaces) { other in
                        if other !== space {
                            Button {
                                state.move(folder, toSpace: other)
                            } label: {
                                Label(other.name, systemImage: other.icon)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("New Folder") { state.addFolder(in: space) }
            Button("Delete Folder", role: .destructive) { state.delete(folder) }
        }
    }
}

/// Dragging over a folder's header: a tab from elsewhere goes into the folder (opening it); one
/// of the folder's own tabs comes out, just above it; another folder takes its place.
struct FolderDropDelegate: DropDelegate {
    let folder: Folder
    let space: Space
    let state: BrowserState

    func validateDrop(info: DropInfo) -> Bool { state.draggingTab != nil || state.draggingFolder != nil }

    func dropEntered(info: DropInfo) {
        if let dragged = state.draggingFolder {
            guard dragged !== folder, let index = space.pinnedIndex(of: folder.id) else { return }
            state.move(dragged, to: index)
            return
        }
        guard let dragged = state.draggingTab else { return }
        if folder.tabs.contains(where: { $0 === dragged }) {
            state.move(dragged, to: .pinned, in: space, at: space.pinnedIndex(of: folder.id))
        } else {
            if !folder.isOpen { state.toggle(folder) }
            state.move(dragged, to: .pinned, in: space, folder: folder)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool { endSidebarDrag(state) }
}

/// Clears what is being dragged once it is dropped.
@discardableResult
func endSidebarDrag(_ state: BrowserState) -> Bool {
    withAnimation(Motion.quick) {
        state.draggingTab = nil
        state.draggingFolder = nil
        state.splitDropTargetID = nil
    }
    return true
}

struct PinDropZone: View {
    @Environment(BrowserState.self) private var state
    let space: Space
    let empty: Bool

    var body: some View {
        Group {
            if empty {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(height: 34)
                    .overlay(
                        Text("Drop here to pin")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    )
                    .padding(.horizontal, 2)
            } else {
                Color.clear.frame(height: 6)
            }
        }
        .contentShape(Rectangle())
        .onDrop(of: [.text], delegate: TabDropDelegate(target: nil, section: .pinned, space: space, state: state))
    }
}

struct SpaceHeader: View {
    @Environment(BrowserState.self) private var state
    let space: Space
    @State private var hovering = false

    var body: some View {
        let editing = Binding<Bool>(
            get: { state.editingSpaceID == space.id },
            set: { state.editingSpaceID = $0 ? space.id : nil }
        )
        HStack(spacing: 9) {
            Image(systemName: space.icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 16)
            Text(space.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if state.profiles.count > 1 {
                let profile = state.profile(for: space)
                HStack(spacing: 3) {
                    Image(systemName: profile.icon).font(.system(size: 8.5, weight: .bold))
                    Text(profile.name).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                }
                .padding(.horizontal, 6)
                .frame(height: 17)
                .background(Capsule().fill(.primary.opacity(0.08)))
                .help("Profile: \(profile.name)")
            }
            Spacer(minLength: 0)
            if hovering {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .transition(.opacity)
            }
        }
        .foregroundStyle(.primary.opacity(0.55))
        .padding(.horizontal, 18)
        .frame(height: 32)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { state.editingSpaceID = space.id }
        .animation(Motion.quick, value: hovering)
        .popover(isPresented: editing, arrowEdge: .trailing) {
            SpaceEditor(space: space)
        }
        .contextMenu {
            Button("Edit Space…") { state.editingSpaceID = space.id }
            Button("New Space") { state.addSpace() }
            Button("New Folder") { state.addFolder(in: space) }
            Menu("Profile") {
                ForEach(state.profiles) { profile in
                    Toggle(isOn: Binding(get: { space.profileID == profile.id }, set: { _ in state.setProfile(profile, for: space) })) {
                        Label(profile.name, systemImage: profile.icon)
                    }
                }
                Divider()
                Button("New Profile…") {
                    state.setProfile(state.addProfile(), for: space)
                    state.editingSpaceID = space.id
                }
            }
            Divider()
            Button("Delete Space…", role: .destructive) { state.confirmDelete(space) }
                .disabled(state.spaces.count < 2)
        }
    }
}

struct SpaceEditor: View {
    @Environment(BrowserState.self) private var state
    @Bindable var space: Space

    private let iconColumns = Array(repeating: GridItem(.fixed(30), spacing: 8), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Space name", text: $space.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, weight: .medium))

            VStack(alignment: .leading, spacing: 6) {
                Text("Profile").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                SpaceProfilePicker(space: space)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Icon").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: iconColumns, spacing: 6) {
                    ForEach(Space.icons, id: \.self) { icon in
                        Button {
                            withAnimation(Motion.snappy) { space.icon = icon }
                        } label: {
                            Image(systemName: icon)
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 30, height: 30)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(.primary.opacity(space.icon == icon ? 0.16 : 0.05))
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(SquishButtonStyle())
                    }
                }
            }

            SpaceColorPicker(hex: space.colorHex) { space.colorHex = $0 }

            HStack {
                Button("Delete Space…", role: .destructive) {
                    // Close the editor popover first, or it would sit on top of the card.
                    state.editingSpaceID = nil
                    state.confirmDelete(space)
                }
                .disabled(state.spaces.count < 2)
                Spacer()
                Button("Done") { state.editingSpaceID = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 260)
        .onChange(of: space.name) { _, _ in state.scheduleSave() }
        .onChange(of: space.icon) { _, _ in state.scheduleSave() }
        .onChange(of: space.colorHex) { _, _ in state.scheduleSave() }
    }
}

// MARK: - Rows

/// The line between pinned tabs and the tab list. Hovering it shows "Clear", which closes the
/// tab list except the selected tab.
struct TabsDivider: View {
    @Environment(BrowserState.self) private var state
    let space: Space
    @State private var hovering = false
    @State private var hoveringButton = false

    var body: some View {
        let clearable = space.tabs.contains { $0.id != space.selectedTabID }
        HStack(spacing: 8) {
            Rectangle()
                .fill(.primary.opacity(0.1))
                .frame(height: 1)
            if hovering, clearable {
                Button {
                    state.clearTabs(in: space)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Clear")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(.primary.opacity(hoveringButton ? 0.85 : 0.45))
                    .contentShape(Rectangle())
                }
                .buttonStyle(SquishButtonStyle(scale: 0.94))
                .onHover { hoveringButton = $0 }
                .help("Close all tabs below except the current one")
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, hovering && clearable ? 4 : 12)
        .frame(height: 15)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: hoveringButton)
    }
}

struct NewTabRow: View {
    @Environment(BrowserState.self) private var state
    @State private var hovering = false

    var body: some View {
        Button {
            state.openCommandBar(.newTab)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 16, height: 16)
                Text("New Tab")
                    .font(.system(size: 13.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary.opacity(hovering ? 0.8 : 0.5))
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(SquishButtonStyle(scale: 0.98))
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

struct TabRow: View {
    /// The "back to pinned page" section: as wide as the row's padding, icon and gap, so the icon
    /// stays where it was.
    static let homeSectionWidth: CGFloat = 36

    /// A row's part in its space's split view.
    enum SplitRole {
        case none
        /// One side of the space's split.
        case paired
        /// The other side of the split on screen now, beside the selected tab.
        case showing
    }

    @Environment(BrowserState.self) private var state
    let tab: Tab
    let section: TabSection
    let selected: Bool
    var split: SplitRole = .none
    @State private var hovering = false
    /// The mouse is over the "back to pinned page" icon.
    @State private var hoveringHome = false

    var body: some View {
        let renaming = state.renamingTabID == tab.id
        let away = section != .tabs && tab.isAwayFromHome
        HStack(spacing: 10) {
            if away {
                // Browsed away from the pinned page: the icon takes it back, as in Arc. It sits
                // in its own section of the row, cut off by a line, running to the row's edges.
                Button {
                    state.returnHome(tab)
                } label: {
                    TabIcon(tab: tab)
                        .frame(width: Self.homeSectionWidth)
                        .frame(maxHeight: .infinity)
                        .background(
                            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, style: .continuous)
                                .fill(.primary.opacity(hoveringHome ? 0.1 : 0))
                        )
                        .overlay(alignment: .trailing) {
                            // A plain "/" between icon and title; hovered, it becomes the line
                            // that cuts the section off.
                            ZStack {
                                Text("/")
                                    .font(.system(size: 14, weight: .regular))
                                    .foregroundStyle(.primary.opacity(0.3))
                                    .fixedSize()
                                    .opacity(hoveringHome ? 0 : 1)
                                    .offset(x: 1)
                                Rectangle()
                                    .fill(.primary.opacity(0.2))
                                    .frame(width: 1)
                                    .frame(maxHeight: .infinity)
                                    .opacity(hoveringHome ? 1 : 0)
                            }
                            .frame(width: 1)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(HomeSectionButtonStyle())
                .onHover { hoveringHome = $0 }
                .help("Back to Pinned Page")
                // Cancel the row's leading padding so the section reaches its edge.
                .padding(.leading, -10)
                .transition(.opacity)
            } else {
                TabIcon(tab: tab)
                    .opacity(tab.isAwake || selected ? 1 : 0.7)
            }

            if renaming {
                InlineRenameField(
                    initial: tab.displayTitle, placeholder: tab.pageTitle,
                    commit: { state.rename(tab, to: $0) },
                    cancel: { state.renamingTabID = nil }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(tab.displayTitle)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.primary.opacity(selected ? 0.96 : (tab.isAwake ? 0.82 : 0.6)))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if away, hoveringHome {
                        Text("Back to pinned URL")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.5))
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .mask(
                    LinearGradient(
                        stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
            }

            if split != .none, !hovering {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary.opacity(selected || split == .showing ? 0.65 : 0.4))
                    .frame(width: 20, height: 20)
                    .help("In Split View")
                    .transition(.scale.combined(with: .opacity))
            }

            if tab.isInPictureInPicture {
                Button {
                    tab.togglePictureInPicture()
                } label: {
                    Image(systemName: "pip.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.65))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SquishButtonStyle())
                .help("Exit Picture in Picture")
                .transition(.scale.combined(with: .opacity))
            }

            if tab.cameraInUse || tab.microphoneInUse {
                CaptureIndicator(tab: tab)
            }

            if tab.isPlayingAudio || tab.isMuted {
                Button {
                    tab.setMuted(!tab.isMuted)
                } label: {
                    Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.65))
                        .symbolEffect(.variableColor.iterative, isActive: tab.isPlayingAudio && !tab.isMuted)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SquishButtonStyle())
                .help(tab.isMuted ? "Unmute" : "Mute")
                .transition(.scale.combined(with: .opacity))
            }

            if hovering || (AppSettings.shared.tabs.alwaysShowCloseButton && section == .tabs) {
                Button {
                    state.close(tab)
                } label: {
                    Image(systemName: section == .tabs ? "xmark" : "minus")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.7))
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(0.1)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(SquishButtonStyle())
                .help(section == .tabs ? "Close Tab" : "Unload Tab")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: AppSettings.shared.tabs.compactRows ? 30 : 36)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.primary.opacity(selected ? 0.15 : (split == .showing ? 0.09 : (hovering ? 0.07 : 0))))
                .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 3, y: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard !renaming else { return }
            // A single-click gesture fires on each click, so selecting stays instant; the second
            // click of a double-click starts renaming.
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                state.renamingTabID = tab.id
            } else {
                state.select(tab)
            }
        }
        .onHover { hovering = $0 }
        .onMiddleClick { state.close(tab) }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: selected)
        .animation(Motion.quick, value: split)
        .animation(Motion.snappy, value: tab.isPlayingAudio)
        .animation(Motion.snappy, value: tab.cameraInUse || tab.microphoneInUse)
        .animation(Motion.snappy, value: tab.isInPictureInPicture)
        .animation(Motion.quick, value: hoveringHome)
        .animation(Motion.snappy, value: away)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(tab.accessibilityDescription))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { state.select(tab) }
        .contextMenu { TabContextMenu(tab: tab, section: section) }
    }
}

/// Darkens the "back to pinned page" section while it's pressed. (A squish would pull it away
/// from the row's edges.)
private struct HomeSectionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, style: .continuous)
                    .fill(.primary.opacity(configuration.isPressed ? 0.08 : 0))
                    .padding(.trailing, 1)
            )
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

struct TabContextMenu: View {
    @Environment(BrowserState.self) private var state
    let tab: Tab
    let section: TabSection

    var body: some View {
        if section == .tabs {
            Button("Pin Tab") { state.move(tab, to: .pinned) }
            Button("Add to Favourites") { state.move(tab, to: .favorites) }
        } else if section == .pinned {
            Button("Unpin Tab") { state.move(tab, to: .tabs) }
            Button("Add to Favourites") { state.move(tab, to: .favorites) }
        } else {
            Button("Remove from Favourites") { state.move(tab, to: .tabs, in: state.currentSpace) }
        }
        if section != .favorites, let space = state.space(containing: tab) {
            let current = space.folder(containing: tab)
            Menu("Add to Folder") {
                ForEach(space.folders) { folder in
                    if folder !== current {
                        Button {
                            state.move(tab, to: .pinned, in: space, folder: folder)
                        } label: {
                            Label(folder.name, systemImage: "folder")
                        }
                    }
                }
                if space.folders.contains(where: { $0 !== current }) { Divider() }
                Button("New Folder") { state.addFolder(in: space, with: tab) }
            }
            if current != nil {
                Button("Remove from Folder") { state.move(tab, to: .pinned, in: space) }
            }
            if state.spaces.count > 1 {
                Menu("Move to Space") {
                    ForEach(state.spaces) { other in
                        if other !== space {
                            Button {
                                // A tab in a folder lands loose in the other space's pinned section.
                                state.move(tab, to: section, in: other)
                            } label: {
                                Label(other.name, systemImage: other.icon)
                            }
                        }
                    }
                }
            }
        }
        if section != .tabs, tab.isAwayFromHome {
            Button("Back to Pinned Page") { state.returnHome(tab) }
            Button("Pin Current Page Instead") {
                tab.homeURL = tab.url
                state.scheduleSave()
            }
        }
        Divider()
        if state.visibleSplit?.contains(tab.id) == true {
            Button("Close Split View") { state.closeSplit() }
            Button("Swap Split Sides") { state.swapSplitSides() }
        } else if state.canSplit(with: tab) {
            Button("Open in Split View") { state.split(with: tab) }
        }
        Divider()
        Button("Rename…") { state.renamingTabID = tab.id }
        if tab.customTitle != nil {
            Button("Use Page Title") { state.rename(tab, to: "") }
        }
        Button("Reload") { tab.reload() }
            .disabled(tab.url == nil)
        Button("Duplicate") { state.duplicate(tab) }
            .disabled(tab.url == nil)
        Button("Copy Link") {
            guard let url = tab.url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            state.show(Toast(symbol: "link", text: "Copied link"))
        }
        .disabled(tab.url == nil)
        Button(tab.isMuted ? "Unmute" : "Mute") { tab.setMuted(!tab.isMuted) }
        if tab.cameraInUse || tab.microphoneInUse {
            Button("Stop Camera and Microphone") { tab.stopCapture() }
        }
        if tab.isInPictureInPicture {
            Button("Exit Picture in Picture") { tab.togglePictureInPicture() }
        } else if tab.isAwake {
            Button("Picture in Picture") {
                tab.togglePictureInPicture { outcome in
                    if outcome == .none { state.show(Toast(symbol: "pip", text: "No video to play in Picture in Picture")) }
                }
            }
        }
        if tab.isAwake, !state.isOnScreen(tab) {
            Button("Unload to Save Memory") { tab.sleep() }
        }
        Divider()
        Button(section == .tabs ? "Close Tab" : "Unload Tab") { state.close(tab) }
        if section == .tabs {
            Button("Close Tabs Below") {
                guard let space = state.space(containing: tab), let index = space.tabs.firstIndex(where: { $0 === tab }) else { return }
                space.tabs.suffix(from: index + 1).forEach { state.close($0) }
            }
            Button("Close Other Tabs") {
                // The space's other regular tabs; pinned tabs and favourites stay.
                guard let space = state.space(containing: tab) else { return }
                if space.selectedTabID != tab.id { state.select(tab) }
                space.tabs.filter { $0 !== tab }.forEach { state.close($0) }
            }
            .disabled((state.space(containing: tab)?.tabs.count ?? 0) < 2)
        }
    }
}

struct TabDropDelegate: DropDelegate {
    let target: Tab?
    let section: TabSection
    let space: Space
    /// Set when the target row is inside a folder.
    var folder: Folder? = nil
    let state: BrowserState
    /// The direction the row's list runs in. With it (and `size`), the row is cut in three: a
    /// tab dropped on the middle shows beside the row's tab in a split, and the ends place it
    /// before or after. Without it, a tab takes the row's place as soon as it is dragged over.
    var axis: Axis? = nil
    /// The row's size, for those zones.
    var size: CGSize = .zero
    /// The other tab of a split row (`SplitTabRow`, whose `target` is its first tab): dragging
    /// either of its own tabs over it does nothing, and it isn't paired with.
    var pairedWith: Tab? = nil

    private enum Zone { case before, after, split }

    /// Folders can only be dropped among the loose items of the pinned section.
    private var takesFolders: Bool { section == .pinned && folder == nil }

    func validateDrop(info: DropInfo) -> Bool {
        state.draggingTab != nil || (state.draggingFolder != nil && takesFolders)
    }

    func dropEntered(info: DropInfo) {
        if let dragged = state.draggingFolder {
            guard takesFolders else { return }
            state.move(dragged, to: target.flatMap { space.pinnedIndex(of: $0.id) } ?? space.pinnedItems.count)
            return
        }
        guard let dragged = state.draggingTab, dragged !== target, dragged !== pairedWith else { return }
        if zone(info) != nil {
            update(dragged, info)
            return
        }
        let ids = listIDs
        let index = target.flatMap { t in ids.firstIndex(of: t.id) } ?? ids.count
        // Dropping onto the end zone of the list the tab is already last in: nothing to do.
        if target == nil, ids.last == dragged.id { return }
        move(dragged, at: index)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if state.draggingFolder == nil, let dragged = state.draggingTab, dragged !== target, dragged !== pairedWith,
           zone(info) != nil {
            update(dragged, info)
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if let target, state.splitDropTargetID == target.id { state.splitDropTargetID = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        if let target, let dragged = state.draggingTab, state.splitDropTargetID == target.id, zone(info) == .split {
            state.pair(dragged, with: target)
        }
        return endSidebarDrag(state)
    }

    /// The tabs (and, among pinned ones, folders) of the list the row is in, in order.
    private var listIDs: [UUID] {
        switch section {
        case .favorites: state.favorites.map(\.id)
        // Loose pinned tabs are placed among the folders, so they count in `pinnedItems`.
        case .pinned: folder?.tabs.map(\.id) ?? space.pinnedItems.map(\.id)
        case .tabs: space.tabs.map(\.id)
        }
    }

    private func zone(_ info: DropInfo) -> Zone? {
        guard target != nil, let axis else { return nil }
        let length = axis == .vertical ? size.height : size.width
        guard length > 0 else { return nil }
        let fraction = (axis == .vertical ? info.location.y : info.location.x) / length
        if fraction > 0.3, fraction < 0.7, pairedWith == nil, let dragged = state.draggingTab, let target,
           state.canPair(dragged, with: target) {
            return .split
        }
        return fraction < 0.5 ? .before : .after
    }

    /// Outlines the row for a split, or puts the dragged tab just before or after it.
    private func update(_ dragged: Tab, _ info: DropInfo) {
        guard let target, let zone = zone(info) else { return }
        if zone == .split {
            if state.splitDropTargetID != target.id { state.splitDropTargetID = target.id }
            return
        }
        if state.splitDropTargetID == target.id { state.splitDropTargetID = nil }
        let ids = listIDs
        var others = ids.filter { $0 != dragged.id }
        // A split row stands for both its tabs: "after" goes past the second.
        let second = pairedWith.flatMap { p in others.contains(p.id) ? p : nil }
        let anchor = zone == .before ? target : (second ?? target)
        guard let i = others.firstIndex(of: anchor.id) else { return }
        let index = zone == .before ? i : i + 1
        others.insert(dragged.id, at: index)
        // Already there: moving it again would only shuffle the rows under the pointer.
        guard others != ids else { return }
        move(dragged, at: index)
    }

    private func move(_ dragged: Tab, at index: Int) {
        // A tab dragged to a new place in the list leaves its split.
        if state.spaces.contains(where: { $0.split?.contains(dragged.id) == true }) { state.leaveSplit(dragged) }
        state.move(dragged, to: section, in: space, folder: folder, at: index)
    }
}

/// Makes a tab row a drop target that knows its own size, so a tab dropped on its middle can
/// pair with it in a split (see `TabDropDelegate`), and outlines it while that would happen.
struct TabDropTarget: ViewModifier {
    @Environment(BrowserState.self) private var state
    @Environment(\.accent) private var accent
    let tab: Tab
    let section: TabSection
    let space: Space
    var folder: Folder? = nil
    let axis: Axis
    var cornerRadius: CGFloat = 10
    var pairedWith: Tab? = nil
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        let outlined = state.splitDropTargetID == tab.id
        content
            .overlay {
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                shape.fill(accent.opacity(outlined ? 0.14 : 0))
                    .overlay(shape.strokeBorder(accent.opacity(outlined ? 0.9 : 0), lineWidth: 2))
                    .overlay(alignment: axis == .vertical ? .trailing : .topTrailing) {
                        if outlined {
                            Image(systemName: "rectangle.split.2x1.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(accent)
                                .padding(axis == .vertical ? 8 : 4)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .allowsHitTesting(false)
                    .animation(Motion.quick, value: outlined)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .onDrop(of: [.text], delegate: TabDropDelegate(
                target: tab, section: section, space: space, folder: folder, state: state,
                axis: axis, size: size, pairedWith: pairedWith
            ))
    }
}

// MARK: - Bottom bar

struct BottomBar: View {
    @Environment(BrowserState.self) private var state
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.accent) private var accent

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 0) {
            DownloadsButton()
                .popover(isPresented: $state.downloadsVisible, arrowEdge: .top) {
                    DownloadsPopover()
                }

            Spacer(minLength: 4)

            if state.isPrivate {
                IncognitoBadge()
            } else {
                HStack(spacing: 2) {
                    ForEach(Array(state.spaces.enumerated()), id: \.element.id) { index, space in
                        SpaceSwitcherButton(space: space, index: index)
                    }
                }
                .animation(Motion.snappy, value: state.currentSpaceIndex)
            }

            Spacer(minLength: 4)

            Menu {
                if !state.isPrivate { Button("New Space") { state.addSpace() } }
                Button("New Folder") { state.addFolder() }
                Button("New Tab") { state.openCommandBar(.newTab) }
                Button("New Incognito Window") { AppDelegate.shared?.openIncognitoWindow() }
                Divider()
                if !state.isPrivate { Button("Extensions…") { AppDelegate.shared?.showSettings(tab: .extensions) } }
                Button("Settings…") { AppDelegate.shared?.showSettings() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .modifier(HoverPlate())
            .help("New Space, Settings…")
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }
}

/// The soft rounded square behind an icon button on hover, for controls (like a `Menu`) that
/// can't be an `IconButton`.
struct HoverPlate: ViewModifier {
    var cornerRadius: CGFloat = 8
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.primary.opacity(hovering ? 0.95 : 0.62))
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.1 : 0))
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// One space icon in the bottom bar, with a soft rounded background on hover.
struct SpaceSwitcherButton: View {
    @Environment(BrowserState.self) private var state
    let space: Space
    let index: Int
    @State private var hovering = false

    var body: some View {
        let active = index == state.currentSpaceIndex
        Button {
            state.switchSpace(to: index)
        } label: {
            Image(systemName: space.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(active || hovering ? 0.95 : 0.4))
                .scaleEffect(active ? 1.08 : 1)
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.primary.opacity(hovering ? 0.1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SquishButtonStyle())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help("\(space.name)  ⌃\(index + 1)")
        .contextMenu {
            Button("Edit Space…") {
                state.switchSpace(to: index)
                state.editingSpaceID = space.id
            }
            Button("Delete Space…", role: .destructive) { state.confirmDelete(space) }
                .disabled(state.spaces.count < 2)
        }
    }
}

struct DownloadsButton: View {
    @Environment(BrowserState.self) private var state
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.accent) private var accent
    @State private var bounce = false

    var body: some View {
        let active = downloads.activeCount(isPrivate: state.isPrivate) > 0
        let fraction = downloads.overallFraction(isPrivate: state.isPrivate)
        ZStack {
            IconButton(symbol: "arrow.down.to.line", size: 13, weight: .semibold, help: "Downloads") {
                state.downloadsVisible.toggle()
            }
            if active {
                Circle()
                    .trim(from: 0, to: max(0.04, fraction))
                    .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 24, height: 24)
                    .animation(.easeOut(duration: 0.3), value: fraction)
                    .allowsHitTesting(false)
            }
        }
        .scaleEffect(bounce ? 1.22 : 1)
        .onChange(of: downloads.pulse(isPrivate: state.isPrivate)) { _, _ in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.45)) { bounce = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { bounce = false }
            }
        }
    }
}

struct DownloadsPopover: View {
    @Environment(BrowserState.self) private var state
    @Environment(DownloadManager.self) private var downloads
    @State private var listHeight: CGFloat = 0

    var body: some View {
        // A normal window lists its own downloads; an Incognito window only Incognito ones.
        let items = downloads.items(isPrivate: state.isPrivate)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.system(size: 13, weight: .semibold))
                if downloads.activeCount(isPrivate: state.isPrivate) > 0, let speed = downloads.totalBytesPerSecond(isPrivate: state.isPrivate) {
                    Text(DownloadStats.speed(speed))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer()
                if items.contains(where: { $0.state != .running }) {
                    Button("Clear") { withAnimation(Motion.snappy) { downloads.clearFinished(isPrivate: state.isPrivate) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if items.isEmpty {
                Text("Nothing downloaded yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(items) { item in
                            DownloadRow(item: item)
                        }
                    }
                    .padding(6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                // An exact height, not just a max: with only `maxHeight` the popover keeps the size
                // it opened at, so rows added while it's open get cut off.
                .frame(height: min(max(listHeight, 1), 280))
            }
        }
        .frame(width: 320)
    }
}

/// Text for the sizes, speeds and times shown in the downloads list.
enum DownloadStats {
    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private static let duration: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.hour, .minute, .second]
        f.maximumUnitCount = 2
        return f
    }()

    static func size(_ count: Int64) -> String { bytes.string(fromByteCount: max(0, count)) }

    static func speed(_ bytesPerSecond: Double) -> String { "\(size(Int64(bytesPerSecond)))/s" }

    static func time(_ seconds: TimeInterval) -> String {
        duration.string(from: max(1, seconds.rounded())) ?? ""
    }

    /// "12.3 MB of 45.6 MB", or just what's arrived when the server didn't say how big it is.
    static func progress(_ item: DownloadItem) -> String {
        item.totalBytes > 0
            ? "\(size(item.bytesReceived)) of \(size(item.totalBytes))"
            : size(item.bytesReceived)
    }

    /// "2.1 MB/s · 15s left". Empty until the first speed sample is in.
    static func rate(_ item: DownloadItem) -> String {
        guard let speed = item.bytesPerSecond else { return "" }
        guard speed >= 1 else { return "Stalled" }
        var parts = [self.speed(speed)]
        if item.totalBytes > 0 {
            parts.append("\(time(Double(item.totalBytes - item.bytesReceived) / speed)) left")
        }
        return parts.joined(separator: " · ")
    }

    /// "45.6 MB · 12s · 3.8 MB/s" for a finished download.
    static func summary(_ item: DownloadItem) -> String {
        var parts = [size(item.totalBytes)]
        if let end = item.finishedAt {
            let elapsed = end.timeIntervalSince(item.startedAt)
            parts.append(time(elapsed))
            if elapsed > 0.5, item.totalBytes > 0 {
                parts.append(speed(Double(item.totalBytes) / elapsed))
            }
        }
        return parts.joined(separator: " · ")
    }
}

struct DownloadRow: View {
    @Environment(DownloadManager.self) private var downloads
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                switch item.state {
                case .running:
                    Group {
                        if item.totalBytes > 0 {
                            ProgressView(value: item.fraction)
                        } else {
                            ProgressView()  // Unknown size: indeterminate bar.
                        }
                    }
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    HStack(spacing: 6) {
                        Text(DownloadStats.progress(item))
                        Spacer(minLength: 0)
                        Text(DownloadStats.rate(item))
                    }
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                case .finished:
                    Text(DownloadStats.summary(item))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                case .failed(let reason):
                    Text(reason).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            switch item.state {
            case .running:
                IconButton(symbol: "xmark", size: 10, side: 22, help: "Stop") { downloads.cancel(item) }
            case .finished:
                IconButton(symbol: "magnifyingglass", size: 11, side: 22, help: "Show in Finder") { downloads.reveal(item) }
            case .failed:
                if downloads.canRetry(item) {
                    IconButton(
                        symbol: "arrow.clockwise", size: 11, side: 22,
                        help: item.resumeData != nil ? "Resume" : "Try Again"
                    ) { downloads.retry(item) }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if item.state == .finished, let url = item.destination { NSWorkspace.shared.open(url) }
        }
    }

    private var icon: String {
        switch item.state {
        case .running: "arrow.down.circle"
        case .finished: "doc.fill"
        case .failed: "exclamationmark.triangle"
        }
    }
}
