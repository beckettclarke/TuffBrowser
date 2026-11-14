import SwiftUI

// MARK: - Horizontal layout chrome

/// The top of the window in the horizontal layout: a row of tabs (with the traffic lights at
/// its start), then a toolbar with back / forward, the address and the window's buttons.
struct HorizontalChrome: View {
    var body: some View {
        VStack(spacing: 0) {
            TabStrip()
                .frame(height: BrowserWindowController.tabStripHeight)
            HorizontalToolbar()
                .frame(height: BrowserWindowController.toolbarHeight)
        }
        .background(WindowDragArea())
    }
}

/// Tabs across the top: favourites and pinned tabs as icon-only tiles, then the space's tabs,
/// each a separate rounded rectangle that shares out the width left.
struct TabStrip: View {
    @Environment(BrowserState.self) private var state

    static let height: CGFloat = 30
    static let gap: CGFloat = 5
    static let minWidth: CGFloat = 96
    static let maxWidth: CGFloat = 220

    var body: some View {
        let space = state.spaces.isEmpty ? nil : state.currentSpace
        // Worked out once and handed down, as the sidebar does (see `SpacePage`).
        let selectedID = space?.selectedTabID
        let favorites = state.favorites
        HStack(spacing: Self.gap) {
            // Room for the traffic lights, which the window controller centres in this row.
            Color.clear.frame(width: state.isFullscreen ? 2 : 70, height: 1)

            if let space {
                ForEach(favorites) { tab in
                    CompactStripTab(tab: tab, section: .favorites, selected: tab.id == selectedID, space: space)
                }
                ForEach(space.pinnedItems) { item in
                    switch item {
                    case .tab(let tab):
                        CompactStripTab(tab: tab, section: .pinned, selected: tab.id == selectedID, space: space)
                    case .folder(let folder):
                        StripFolder(folder: folder, space: space, selectedID: selectedID)
                    }
                }
                if !favorites.isEmpty || !space.pinnedItems.isEmpty {
                    Capsule()
                        .fill(.primary.opacity(0.14))
                        .frame(width: 1.5, height: 16)
                        .padding(.horizontal, 2)
                }
                RegularStripTabs(space: space, selectedID: selectedID)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.top, 4)
        .frame(maxHeight: .infinity)
        .animation(Motion.snappy, value: space?.tabs.map(\.id))
        .animation(Motion.snappy, value: space?.pinnedItems.map(\.id))
        .animation(Motion.snappy, value: favorites.map(\.id))
    }
}

/// The space's regular tabs and the new-tab button. The tabs share out the room there is,
/// between `minWidth` and `maxWidth` each; past that the row scrolls.
private struct RegularStripTabs: View {
    @Environment(BrowserState.self) private var state
    let space: Space
    let selectedID: UUID?

    var body: some View {
        GeometryReader { geo in
            let tabs = space.tabs
            let plus = TabStrip.height + TabStrip.gap
            let room = geo.size.width - plus
            let count = CGFloat(max(tabs.count, 1))
            let fitted = (room - TabStrip.gap * (count - 1)) / count
            let width = min(TabStrip.maxWidth, max(TabStrip.minWidth, fitted.rounded(.down)))
            let overflows = fitted < TabStrip.minWidth

            let row = HStack(spacing: TabStrip.gap) {
                ForEach(tabs) { tab in
                    StripTab(tab: tab, selected: tab.id == selectedID, space: space)
                        .frame(width: width)
                        .id(tab.id)
                }
                NewStripTabButton()
                // The rest of the row drops a tab at the end of the list.
                Color.clear
                    .frame(width: overflows ? 8 : max(0, room - (width + TabStrip.gap) * CGFloat(tabs.count)), height: TabStrip.height)
                    .contentShape(Rectangle())
                    .onDrop(of: [.text], delegate: TabDropDelegate(target: nil, section: .tabs, space: space, state: state))
                    .allowsHitTesting(state.draggingTab != nil)
            }
            .frame(height: geo.size.height)

            if overflows {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) { row }
                        .onChange(of: selectedID) { _, id in
                            guard let id else { return }
                            withAnimation(Motion.snappy) { proxy.scrollTo(id) }
                        }
                        .onAppear { if let selectedID { proxy.scrollTo(selectedID) } }
                }
            } else {
                row
            }
        }
    }
}

/// The look shared by every tile in the strip: a rounded rectangle standing on its own, filled
/// faintly at rest, more on hover, and raised when it is the tab on screen.
private struct StripTile: ViewModifier {
    let selected: Bool
    let hovering: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        content
            .frame(height: TabStrip.height)
            .background(
                shape
                    .fill(.primary.opacity(selected ? 0.17 : (hovering ? 0.10 : 0.05)))
                    .shadow(color: .black.opacity(selected ? 0.14 : 0), radius: 2.5, y: 1)
            )
            .overlay(shape.strokeBorder(.primary.opacity(selected ? 0.08 : 0), lineWidth: 0.5))
            .contentShape(shape)
    }
}

/// A regular tab: icon, title, and a close button on hover (or always on the tab on screen).
struct StripTab: View {
    @Environment(BrowserState.self) private var state
    let tab: Tab
    let selected: Bool
    let space: Space
    @State private var hovering = false

    var body: some View {
        let renaming = state.renamingTabID == tab.id
        let showClose = hovering || selected || AppSettings.shared.tabs.alwaysShowCloseButton
        HStack(spacing: 7) {
            TabIcon(tab: tab, size: 15)
                .opacity(tab.isAwake || selected ? 1 : 0.7)

            if renaming {
                InlineRenameField(
                    initial: tab.displayTitle, placeholder: tab.pageTitle,
                    commit: { state.rename(tab, to: $0) },
                    cancel: { state.renamingTabID = nil }
                )
                .font(.system(size: 12.5, weight: .medium))
            } else {
                Text(tab.displayTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary.opacity(selected ? 0.95 : (tab.isAwake ? 0.75 : 0.55)))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .mask(
                        LinearGradient(
                            stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
            }

            if tab.isPlayingAudio || tab.isMuted {
                Button {
                    tab.setMuted(!tab.isMuted)
                } label: {
                    Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.65))
                        .symbolEffect(.variableColor.iterative, isActive: tab.isPlayingAudio && !tab.isMuted)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SquishButtonStyle())
                .help(tab.isMuted ? "Unmute" : "Mute")
                .transition(.scale.combined(with: .opacity))
            }

            if showClose, !renaming {
                Button {
                    state.close(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.65))
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.primary.opacity(hovering ? 0.1 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(SquishButtonStyle())
                .help("Close Tab  ⌘W")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, showClose ? 6 : 10)
        .modifier(StripTile(selected: selected, hovering: hovering))
        .onTapGesture {
            guard !renaming else { return }
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                state.renamingTabID = tab.id
            } else {
                state.select(tab)
            }
        }
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: selected)
        .animation(Motion.snappy, value: tab.isPlayingAudio)
        .help(tab.displayTitle)
        .contextMenu { TabContextMenu(tab: tab, section: .tabs) }
        .onDrag {
            state.draggingTab = tab
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .modifier(TabDropTarget(tab: tab, section: .tabs, space: space, axis: .horizontal, cornerRadius: 9))
        .transition(.scale(scale: 0.85, anchor: .leading).combined(with: .opacity))
    }
}

/// A favourite or pinned tab: just its icon, in a square tile.
struct CompactStripTab: View {
    @Environment(BrowserState.self) private var state
    let tab: Tab
    let section: TabSection
    let selected: Bool
    let space: Space
    var folder: Folder?
    @State private var hovering = false

    var body: some View {
        TabIcon(tab: tab, size: 15)
            .opacity(tab.isAwake || selected ? 1 : 0.7)
            .frame(width: 36)
            .overlay(alignment: .bottom) {
                // A pinned tab that has wandered from its page, as the sidebar's "/" shows.
                if section != .tabs, tab.isAwayFromHome {
                    Capsule().fill(.primary.opacity(0.45)).frame(width: 10, height: 2).offset(y: -3)
                }
            }
            .modifier(StripTile(selected: selected, hovering: hovering))
            .onTapGesture { state.select(tab) }
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .animation(Motion.quick, value: selected)
            .help(tab.displayTitle)
            .contextMenu { TabContextMenu(tab: tab, section: section) }
            .onDrag {
                state.draggingTab = tab
                return NSItemProvider(object: tab.id.uuidString as NSString)
            }
            .modifier(TabDropTarget(tab: tab, section: section, space: space, folder: folder, axis: .horizontal, cornerRadius: 9))
            .transition(.scale(scale: 0.7).combined(with: .opacity))
    }
}

/// A folder of pinned tabs: a tile that opens a menu of its tabs. The tab on screen, if it is in
/// the folder, shows beside it so the page showing is never missing from the strip.
struct StripFolder: View {
    @Environment(BrowserState.self) private var state
    let folder: Folder
    let space: Space
    let selectedID: UUID?
    @State private var hovering = false

    var body: some View {
        let showing = folder.tabs.first { $0.id == selectedID }
        HStack(spacing: TabStrip.gap) {
            Menu {
                ForEach(folder.tabs) { tab in
                    Button {
                        state.select(tab)
                    } label: {
                        if let icon = tab.favicon {
                            Label { Text(tab.displayTitle) } icon: { Image(nsImage: icon) }
                        } else {
                            Label(tab.displayTitle, systemImage: "globe")
                        }
                    }
                }
                if folder.tabs.isEmpty { Text("Empty folder") }
                Divider()
                Button("Rename…") {
                    // Renaming happens in the sidebar's row; here, ask with a card.
                    Task { @MainActor in
                        var prompt = Prompt(symbol: "folder.fill", title: "Rename Folder", confirmTitle: "Rename", fields: [Prompt.Field(placeholder: "Folder name", text: folder.name)])
                        prompt.browser = state
                        let result = await PromptPresenter.ask(prompt)
                        if result.confirmed, let name = result.fields.first { state.rename(folder, to: name) }
                    }
                }
                Button("Delete Folder", role: .destructive) { state.delete(folder) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(folder.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: 90, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.5))
                }
                .foregroundStyle(.primary.opacity(0.75))
                .padding(.horizontal, 10)
                .modifier(StripTile(selected: false, hovering: hovering))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { hovering = $0 }
            .help(folder.name)
            .onDrop(of: [.text], delegate: FolderDropDelegate(folder: folder, space: space, state: state))

            if let showing {
                CompactStripTab(tab: showing, section: .pinned, selected: true, space: space, folder: folder)
            }
        }
    }
}

private struct NewStripTabButton: View {
    @Environment(BrowserState.self) private var state
    @State private var hovering = false

    var body: some View {
        Button {
            state.openCommandBar(.newTab)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary.opacity(hovering ? 0.85 : 0.55))
                .frame(width: TabStrip.height, height: TabStrip.height)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(SquishButtonStyle())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help("New Tab  ⌘T")
    }
}

// MARK: - Toolbar

struct HorizontalToolbar: View {
    @Environment(BrowserState.self) private var state

    var body: some View {
        @Bindable var state = state
        let tab = state.selectedTab
        HStack(spacing: 2) {
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

            URLPill(height: 30)
                // The command bar opens right on top of it (`DockedCommandBar`).
                .opacity(state.commandBar == nil ? 1 : 0)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: URLPillFrameKey.self, value: geo.frame(in: .named(RootView.space)))
                })
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 6)

            if state.isPrivate {
                IncognitoBadge()
                    .padding(.trailing, 4)
            } else {
                InlineExtensionActions()
            }

            DownloadsButton()
                .popover(isPresented: $state.downloadsVisible, arrowEdge: .bottom) {
                    DownloadsPopover()
                }

            if !state.isPrivate, state.spaces.count > 1 {
                SpaceMenuButton()
            }

            Menu {
                Button("New Tab") { state.openCommandBar(.newTab) }
                Button("New Incognito Window") { AppDelegate.shared?.openIncognitoWindow() }
                if !state.isPrivate {
                    Button("New Space") { state.addSpace() }
                    Button("New Folder") { state.addFolder() }
                }
                Divider()
                if !state.isPrivate {
                    Button("Extensions…") { AppDelegate.shared?.showSettings(tab: .extensions) }
                }
                Button("Settings…") { AppDelegate.shared?.showSettings() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.62))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New Tab, Settings…")
        }
        .padding(.horizontal, 8)
    }
}

/// The space on screen, as a button that switches to another.
private struct SpaceMenuButton: View {
    @Environment(BrowserState.self) private var state
    @State private var hovering = false

    var body: some View {
        let current = state.currentSpace
        Menu {
            ForEach(Array(state.spaces.enumerated()), id: \.element.id) { index, space in
                Toggle(isOn: Binding(get: { index == state.currentSpaceIndex }, set: { _ in state.switchSpace(to: index) })) {
                    Label(space.name, systemImage: space.icon)
                }
            }
            Divider()
            Button("New Space") { state.addSpace() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: current.icon)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(current.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.primary.opacity(hovering ? 0.9 : 0.62))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(hovering ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Switch Space  ⌃1–9")
    }
}

/// Extension buttons in a row, for the toolbar.
private struct InlineExtensionActions: View {
    @Environment(BrowserState.self) private var state
    @Environment(ExtensionManager.self) private var extensions

    var body: some View {
        let _ = extensions.revision
        let _ = SidePanelManager.shared.revision
        let actions = extensions.actions(for: state.selectedTab).filter(\.pinned)
        if !actions.isEmpty {
            HStack(spacing: 3) {
                ForEach(actions.prefix(8)) { action in
                    ExtensionActionButton(action: action)
                }
            }
            .padding(.trailing, 4)
        }
    }
}

/// Says the window is Incognito.
struct IncognitoBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "eyeglasses")
                .font(.system(size: 12, weight: .semibold))
            Text("Incognito")
                .font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(.primary.opacity(0.75))
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Capsule().fill(.primary.opacity(0.1)))
        .help("Pages you see in this window aren’t saved to history, and cookies and site data are forgotten when it closes.")
    }
}
