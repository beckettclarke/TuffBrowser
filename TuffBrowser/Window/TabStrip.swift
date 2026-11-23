import Observation
import SwiftUI

// MARK: - Horizontal layout chrome

/// The top of the window in the horizontal layout: a row of tabs (with the traffic lights at
/// its start), then a toolbar with back / forward, the address and the window's buttons.
struct HorizontalChrome: View {
    @Environment(BrowserState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            TabStrip()
                .frame(height: BrowserWindowController.tabStripHeight)
            HorizontalToolbar()
                .frame(height: BrowserWindowController.toolbarHeight)
            if state.bookmarksBarShowing {
                BookmarksBar()
                    .frame(height: BrowserWindowController.bookmarksBarHeight)
                    .transition(.opacity)
            }
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
                if !favorites.isEmpty && !space.pinnedItems.isEmpty {
                    StripSectionDivider()
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
                    StripSectionDivider()
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
            let tabs = space.tabs.filter { !$0.isHidden }
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

private struct StripSectionDivider: View {
    var body: some View {
        Capsule()
            .fill(.primary.opacity(0.14))
            .frame(width: 1.5, height: 16)
            .padding(.horizontal, 2)
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

            if tab.cameraInUse || tab.microphoneInUse {
                CaptureIndicator(tab: tab, size: 18)
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
        .onMiddleClick { state.close(tab) }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: selected)
        .animation(Motion.snappy, value: tab.isPlayingAudio)
        .help(tab.displayTitle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(tab.accessibilityDescription))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { state.select(tab) }
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
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(tab.accessibilityDescription))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { state.select(tab) }
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
    @Environment(StripDropdownController.self) private var dropdown
    let folder: Folder
    let space: Space
    let selectedID: UUID?
    @State private var hovering = false

    var body: some View {
        let showing = folder.tabs.first { $0.id == selectedID }
        let menuID = StripDropdownController.ID.folder(folder.id)
        let showingMenu = dropdown.open == menuID
        HStack(spacing: TabStrip.gap) {
            Button {
                dropdown.toggle(menuID)
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
                .modifier(StripTile(selected: false, hovering: hovering || showingMenu))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .anchorPreference(key: StripDropdownAnchorKey.self, value: .bounds) { [menuID: $0] }
            .onHover { hovering = $0 }
            .help(folder.name)
            .onDrop(of: [.text], delegate: FolderDropDelegate(folder: folder, space: space, state: state))
            .onDisappear { if dropdown.open == menuID { dropdown.open = nil } }

            if let showing {
                CompactStripTab(tab: showing, section: .pinned, selected: true, space: space, folder: folder)
            }
        }
    }
}

private struct FolderStripMenu: View {
    @Environment(BrowserState.self) private var state
    @Environment(StripDropdownController.self) private var dropdown
    let folder: Folder

    var body: some View {
        ForEach(folder.tabs) { tab in
            StripMenuRow(
                title: tab.displayTitle,
                symbol: tab.favicon == nil ? (tab.url == nil ? "plus.square.dashed" : "globe") : nil,
                image: tab.favicon,
                checked: tab.id == state.currentSpace.selectedTabID
            ) {
                closeThen { state.select(tab) }
            }
        }
        if folder.tabs.isEmpty {
            StripMenuRow(title: "Empty folder", symbol: "folder", disabled: true) {}
        }
        StripMenuDivider()
        StripMenuRow(title: "Rename…", symbol: "pencil") {
            closeThen {
                Task { @MainActor in
                    var prompt = Prompt(symbol: "folder.fill", title: "Rename Folder", confirmTitle: "Rename", fields: [Prompt.Field(placeholder: "Folder name", text: folder.name)])
                    prompt.browser = state
                    let result = await PromptPresenter.ask(prompt)
                    if result.confirmed, let name = result.fields.first { state.rename(folder, to: name) }
                }
            }
        }
        StripMenuRow(title: "Delete Folder", symbol: "trash", destructive: true) {
            closeThen { state.delete(folder) }
        }
    }

    private func closeThen(_ action: @escaping () -> Void) {
        dropdown.open = nil
        DispatchQueue.main.async(execute: action)
    }
}

/// A popover list in the strip's style (folders, spaces, the bookmarks bar's folders).
struct StripPopoverMenu<Content: View>: View {
    let width: CGFloat
    let maxHeight: CGFloat
    let content: Content
    @State private var contentHeight: CGFloat = 0

    init(width: CGFloat, maxHeight: CGFloat = 360, @ViewBuilder content: () -> Content) {
        self.width = width
        self.maxHeight = maxHeight
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 2) { content }
                .padding(5)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollIndicators(.never)
        .frame(width: width)
        .frame(height: min(max(contentHeight, 1), maxHeight))
    }
}

struct StripMenuRow: View {
    @Environment(\.accent) private var accent
    let title: String
    var symbol: String?
    var image: NSImage?
    var shortcut: String?
    var checked = false
    var disabled = false
    var destructive = false
    /// A chevron at the end, for a row that opens a list of its own.
    var disclosure = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Group {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    } else if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .medium))
                    } else {
                        Color.clear
                    }
                }
                .foregroundStyle(destructive ? Color.red : (checked ? accent : .primary.opacity(0.75)))
                .frame(width: 18, height: 18)

                Text(title)
                    .font(.system(size: 13, weight: checked ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(accent)
                }
                if disclosure {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(destructive ? Color.red : .primary)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(checked ? accent.opacity(hovering ? 0.24 : 0.16) : .primary.opacity(hovering && !disabled ? 0.09 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.38 : 1)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

struct StripMenuDivider: View {
    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.1))
            .frame(height: 0.5)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

private struct NewStripTabButton: View {
    @Environment(BrowserState.self) private var state
    @State private var hovering = false

    var body: some View {
        Button {
            state.openNewTab()
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

            // The page menu's page actions, then New Tab, Settings and the rest.
            IconButton(symbol: "ellipsis", size: 14, weight: .semibold, help: "Page Menu, New Tab, Settings…") {
                state.toolbarMenuVisible.toggle()
            }
            .popover(isPresented: $state.toolbarMenuVisible, arrowEdge: .bottom) {
                PageMenu(kind: .toolbar)
            }
        }
        .padding(.horizontal, 8)
    }
}

/// The space on screen, as a button that switches to another.
private struct SpaceMenuButton: View {
    @Environment(BrowserState.self) private var state
    @Environment(StripDropdownController.self) private var dropdown
    @State private var hovering = false

    var body: some View {
        let current = state.currentSpace
        let menuID = StripDropdownController.ID.spaces
        let showingMenu = dropdown.open == menuID
        Button {
            dropdown.toggle(menuID)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: current.icon)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(current.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.primary.opacity(hovering || showingMenu ? 0.9 : 0.62))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(hovering || showingMenu ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .background(SpaceScrollCatcher { [weak state] offset in
            state?.switchSpace(by: offset)
        })
        .anchorPreference(key: StripDropdownAnchorKey.self, value: .bounds) { [menuID: $0] }
        .onHover { hovering = $0 }
        .help("Switch Space  ⌃1–9 · Scroll left/right")
        .accessibilityHint("Scroll left or right to switch spaces")
        .onDisappear { if dropdown.open == menuID { dropdown.open = nil } }
    }
}

private struct SpaceStripMenu: View {
    @Environment(BrowserState.self) private var state
    @Environment(StripDropdownController.self) private var dropdown

    var body: some View {
        ForEach(Array(state.spaces.enumerated()), id: \.element.id) { index, space in
            StripMenuRow(
                title: space.name,
                symbol: space.icon,
                shortcut: index < 9 ? "⌃\(index + 1)" : nil,
                checked: index == state.currentSpaceIndex
            ) {
                closeThen { state.switchSpace(to: index) }
            }
        }
        StripMenuDivider()
        StripMenuRow(title: "New Space", symbol: "plus") {
            closeThen { state.addSpace() }
        }
    }

    private func closeThen(_ action: @escaping () -> Void) {
        dropdown.open = nil
        DispatchQueue.main.async(execute: action)
    }
}

@Observable
final class StripDropdownController {
    enum ID: Hashable {
        case spaces
        case folder(UUID)
    }

    var open: ID?

    func toggle(_ id: ID) {
        open = open == id ? nil : id
    }
}

struct StripDropdownAnchorKey: PreferenceKey {
    static var defaultValue: [StripDropdownController.ID: Anchor<CGRect>] = [:]

    static func reduce(value: inout [StripDropdownController.ID: Anchor<CGRect>], nextValue: () -> [StripDropdownController.ID: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

struct StripDropdownLayer: View {
    @Environment(BrowserState.self) private var state
    @Environment(AppSettings.self) private var settings
    let controller: StripDropdownController
    let anchors: [StripDropdownController.ID: Anchor<CGRect>]
    @State private var cardFrame: CGRect = .zero

    var body: some View {
        GeometryReader { geo in
            if let open = controller.open, let anchor = anchors[open] {
                let button = geo[anchor]
                let width: CGFloat = open == .spaces ? 232 : 260
                let x = max(8, min(button.midX - width / 2, geo.size.width - width - 8))
                let top = button.maxY + 6
                let maxHeight = max(120, min(360, geo.size.height - top - 10))
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { controller.open = nil }
                    menu(open, width: width, maxHeight: maxHeight)
                        .offset(x: x, y: top)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardFrame = CGRect(origin: CGPoint(x: x, y: top), size: $0) }
                        .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
                        .id(open)
                }
                .background(StripDropdownDismissal(cardFrame: cardFrame, buttonFrame: button) {
                    controller.open = nil
                })
                .onExitCommand { controller.open = nil }
            }
        }
        .animation(settings.animationsEnabled ? Motion.snappy : nil, value: controller.open)
        .onDisappear { controller.open = nil }
    }

    @ViewBuilder
    private func menu(_ id: StripDropdownController.ID, width: CGFloat, maxHeight: CGFloat) -> some View {
        switch id {
        case .spaces:
            card(width: width, maxHeight: maxHeight) { SpaceStripMenu() }
        case .folder(let id):
            if let folder = state.spaces.flatMap({ $0.folders }).first(where: { $0.id == id }) {
                card(width: width, maxHeight: maxHeight) { FolderStripMenu(folder: folder) }
            }
        }
    }

    private func card<Content: View>(width: CGFloat, maxHeight: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return StripPopoverMenu(width: width, maxHeight: maxHeight, content: content)
            .background(shape.fill(.regularMaterial))
            .overlay(shape.strokeBorder(.primary.opacity(0.14), lineWidth: 0.5))
            .clipShape(shape)
            .modifier(CardShadow(cornerRadius: 12, opacity: 0.32, radius: 16, y: 6, hollow: true))
    }
}

private struct StripDropdownDismissal: NSViewRepresentable {
    let cardFrame: CGRect
    let buttonFrame: CGRect
    let close: () -> Void

    func makeNSView(context: Context) -> StripDropdownDismissalView {
        let view = StripDropdownDismissalView()
        view.update(cardFrame: cardFrame, buttonFrame: buttonFrame, close: close)
        return view
    }

    func updateNSView(_ view: StripDropdownDismissalView, context: Context) {
        view.update(cardFrame: cardFrame, buttonFrame: buttonFrame, close: close)
    }
}

private final class StripDropdownDismissalView: NSView {
    private var cardFrame: CGRect = .zero
    private var buttonFrame: CGRect = .zero
    private var close: (() -> Void)?
    private var monitor: Any?

    func update(cardFrame: CGRect, buttonFrame: CGRect, close: @escaping () -> Void) {
        self.cardFrame = cardFrame
        self.buttonFrame = buttonFrame
        self.close = close
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        } else if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                if event.type == .keyDown {
                    guard event.keyCode == 53 else { return event }
                    close?()
                    return nil
                }
                let location = convert(event.locationInWindow, from: nil)
                let point = CGPoint(x: location.x, y: bounds.height - location.y)
                guard !cardFrame.contains(point), !buttonFrame.contains(point) else { return event }
                close?()
                return nil
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

private struct SpaceScrollCatcher: NSViewRepresentable {
    let onSwitch: (Int) -> Void

    func makeNSView(context: Context) -> SpaceScrollView {
        let view = SpaceScrollView()
        view.onSwitch = onSwitch
        return view
    }

    func updateNSView(_ view: SpaceScrollView, context: Context) {
        view.onSwitch = onSwitch
    }
}

private final class SpaceScrollView: NSView {
    var onSwitch: ((Int) -> Void)?
    private var monitor: Any?
    private var accumulated: CGFloat = 0
    private var switched = false
    private var lastDiscreteScroll: TimeInterval = 0
    private var lastDiscreteSwitch: TimeInterval = -.infinity

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        } else if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let point = convert(event.locationInWindow, from: nil)
                guard bounds.contains(point) else { return event }
                consume(event)
                return nil
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func consume(_ event: NSEvent) {
        guard event.momentumPhase == [] else { return }
        if event.phase == .began || event.phase == .mayBegin {
            accumulated = 0
            switched = false
        }
        if event.phase == .ended || event.phase == .cancelled {
            accumulated = 0
            switched = false
            return
        }

        let delta = event.scrollingDeltaX
        guard abs(delta) > 0, abs(delta) >= abs(event.scrollingDeltaY) else { return }
        if event.phase == [] {
            let now = event.timestamp
            if now - lastDiscreteScroll > 0.18 { accumulated = 0 }
            lastDiscreteScroll = now
            accumulated += delta
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 18 : 1
            if abs(accumulated) >= threshold, now - lastDiscreteSwitch > 0.3 {
                onSwitch?(accumulated < 0 ? 1 : -1)
                accumulated = 0
                lastDiscreteSwitch = now
            }
        } else if !switched {
            accumulated += delta
            if abs(accumulated) >= 24 {
                switched = true
                onSwitch?(accumulated < 0 ? 1 : -1)
            }
        }
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

/// The camera / microphone in-use indicator on a tab (sidebar rows and horizontal tabs). Red
/// while the page is capturing, grey while paused; its menu pauses, resumes or stops it.
struct CaptureIndicator: View {
    let tab: Tab
    var size: CGFloat = 20

    var body: some View {
        let muted = tab.captureMuted
        let symbol = tab.cameraInUse ? (muted ? "video.slash.fill" : "video.fill") : (muted ? "mic.slash.fill" : "mic.fill")
        let what = tab.cameraInUse && tab.microphoneInUse ? "camera and microphone" : (tab.cameraInUse ? "camera" : "microphone")
        Menu {
            Button(muted ? "Resume \(what.capitalizedFirst)" : "Pause \(what.capitalizedFirst)") { tab.setCaptureMuted(!muted) }
            Button("Stop Using \(what.capitalizedFirst)") { tab.stopCapture() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(muted ? AnyShapeStyle(.primary.opacity(0.55)) : AnyShapeStyle(Color.red))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(muted ? "This page’s \(what) is paused" : "This page is using your \(what)")
        .accessibilityLabel(muted ? "\(what.capitalizedFirst) paused" : "Using \(what)")
        .transition(.scale.combined(with: .opacity))
    }
}

extension String {
    /// "camera and microphone" → "Camera and microphone".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
