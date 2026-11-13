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
    @State private var hovering = false

    var body: some View {
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
            if hovering, url != nil {
                Button {
                    state.copyCurrentURL()
                } label: {
                    Image(systemName: "link")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SquishButtonStyle())
                .help("Copy Link  ⇧⌘C")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.primary.opacity(hovering ? 0.13 : 0.09))
        )
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onTapGesture { state.openCommandBar(.editCurrent) }
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: url)
        .animation(Motion.quick, value: tab?.isNotSecure)
        .help("Search or enter address  ⌘L")
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
        let actions = extensions.actions(for: state.selectedTab)
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
        .contextMenu {
            if action.hasPanel {
                Button(action.panelOpen ? "Close Side Panel" : "Open Side Panel") { SidePanelManager.shared.toggle(action.id) }
                Divider()
            }
            if extensions.hasOptions(id: action.id) {
                Button("Options…") { extensions.openOptions(id: action.id) }
            }
            Menu("Use In") { ExtensionLinkMenuItems(id: action.id) }
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

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        let favorites = state.favorites
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
                            .onDrop(of: [.text], delegate: TabDropDelegate(target: tab, section: .favorites, space: state.currentSpace, state: state))
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
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
        Button {
            state.select(tab)
        } label: {
            ZStack {
                shape.fill(selected ? AnyShapeStyle(accent.opacity(0.22)) : AnyShapeStyle(.primary.opacity(hovering ? 0.13 : 0.08)))
                shape.strokeBorder(accent.opacity(selected ? 0.9 : 0), lineWidth: 1.5)
                TabIcon(tab: tab, size: 18)
                    .opacity(tab.isAwake || selected ? 1 : 0.75)
            }
            .frame(height: 44)
            .contentShape(shape)
        }
        .buttonStyle(SquishButtonStyle(scale: 0.94))
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.snappy, value: selected)
        .help(tab.displayTitle)
        .contextMenu { TabContextMenu(tab: tab, section: .favorites) }
    }
}

/// Favicon, with a spinner while loading and a letter fallback.
struct TabIcon: View {
    let tab: Tab
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            if let icon = tab.favicon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            } else if tab.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            } else {
                Image(systemName: tab.url == nil ? "plus.square.dashed" : "globe")
                    .font(.system(size: size * 0.86, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.55))
            }
        }
        .frame(width: size, height: size)
        .animation(Motion.quick, value: tab.favicon != nil)
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
        VStack(spacing: 0) {
            SpaceHeader(space: space)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(space.pinnedItems) { item in
                        switch item {
                        case .tab(let tab):
                            SidebarTabRow(tab: tab, section: .pinned, selected: tab.id == selectedID, space: space)
                        case .folder(let folder):
                            FolderSection(folder: folder, space: space, selectedID: selectedID)
                                .transition(.scale(scale: 0.92, anchor: .leading).combined(with: .opacity))
                        }
                    }
                    if !space.pinnedItems.isEmpty || state.draggingTab != nil {
                        PinDropZone(space: space, empty: space.pinnedItems.isEmpty)
                    }

                    Rectangle()
                        .fill(.primary.opacity(0.1))
                        .frame(height: 1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)

                    NewTabRow()

                    ForEach(space.tabs) { tab in
                        SidebarTabRow(tab: tab, section: .tabs, selected: tab.id == selectedID, space: space)
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
}

/// A tab row in a space's list that can be dragged and dropped onto.
struct SidebarTabRow: View {
    @Environment(BrowserState.self) private var state
    let tab: Tab
    let section: TabSection
    let selected: Bool
    let space: Space
    var folder: Folder?

    var body: some View {
        TabRow(tab: tab, section: section, selected: selected)
            .onDrag {
                state.draggingTab = tab
                return NSItemProvider(object: tab.id.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: TabDropDelegate(target: tab, section: section, space: space, folder: folder, state: state))
            .transition(
                .asymmetric(
                    insertion: .scale(scale: 0.92, anchor: .leading).combined(with: .opacity),
                    removal: .scale(scale: 0.9, anchor: .leading).combined(with: .opacity)
                )
            )
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

    var body: some View {
        let visible = folder.isOpen ? folder.tabs : folder.tabs.filter { $0.id == selectedID }
        VStack(spacing: 2) {
            FolderRow(folder: folder, space: space)
            ForEach(visible) { tab in
                SidebarTabRow(tab: tab, section: .pinned, selected: tab.id == selectedID, space: space, folder: folder)
                    .padding(.leading, 16)
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
    @Environment(BrowserState.self) private var state
    let tab: Tab
    let section: TabSection
    let selected: Bool
    @State private var hovering = false
    /// The mouse is over the "back to pinned page" icon.
    @State private var hoveringHome = false

    var body: some View {
        let renaming = state.renamingTabID == tab.id
        let away = section != .tabs && tab.isAwayFromHome
        HStack(spacing: 10) {
            if away {
                // Browsed away from the pinned page: the icon takes it back, as in Arc.
                HStack(spacing: 6) {
                    Button {
                        state.returnHome(tab)
                    } label: {
                        TabIcon(tab: tab)
                            .frame(width: 24, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.primary.opacity(hoveringHome ? 0.12 : 0))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SquishButtonStyle())
                    .onHover { hoveringHome = $0 }
                    .help("Back to Pinned Page")
                    .padding(.horizontal, -4)

                    Text("/")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.primary.opacity(0.3))
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
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
                .fill(.primary.opacity(selected ? 0.15 : (hovering ? 0.07 : 0)))
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
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: selected)
        .animation(Motion.snappy, value: tab.isPlayingAudio)
        .animation(Motion.snappy, value: tab.isInPictureInPicture)
        .animation(Motion.quick, value: hoveringHome)
        .animation(Motion.snappy, value: away)
        .contextMenu { TabContextMenu(tab: tab, section: section) }
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
        }
        if section != .tabs, tab.isAwayFromHome {
            Button("Back to Pinned Page") { state.returnHome(tab) }
            Button("Pin Current Page Instead") {
                tab.homeURL = tab.url
                state.scheduleSave()
            }
        }
        Divider()
        Button("Rename…") { state.renamingTabID = tab.id }
        if tab.customTitle != nil {
            Button("Use Page Title") { state.rename(tab, to: "") }
        }
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
        if tab.isInPictureInPicture {
            Button("Exit Picture in Picture") { tab.togglePictureInPicture() }
        } else if tab.isAwake {
            Button("Picture in Picture") {
                tab.togglePictureInPicture { outcome in
                    if outcome == .none { state.show(Toast(symbol: "pip", text: "No video to play in Picture in Picture")) }
                }
            }
        }
        if tab.isAwake, state.selectedTab !== tab {
            Button("Unload to Save Memory") { tab.sleep() }
        }
        if section != .favorites, state.spaces.count > 1 {
            Menu("Move to Space") {
                ForEach(state.spaces) { space in
                    if space !== state.space(containing: tab) {
                        Button {
                            state.move(tab, to: section, in: space)
                        } label: {
                            Label(space.name, systemImage: space.icon)
                        }
                    }
                }
            }
        }
        Divider()
        Button(section == .tabs ? "Close Tab" : "Unload Tab") { state.close(tab) }
        if section == .tabs {
            Button("Close Tabs Below") {
                guard let space = state.space(containing: tab), let index = space.tabs.firstIndex(where: { $0 === tab }) else { return }
                space.tabs.suffix(from: index + 1).forEach { state.close($0) }
            }
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
        guard let dragged = state.draggingTab, dragged !== target else { return }
        // Loose pinned tabs are placed among the folders, so they count in `pinnedItems`.
        let ids: [UUID]
        switch section {
        case .favorites: ids = state.favorites.map(\.id)
        case .pinned: ids = folder?.tabs.map(\.id) ?? space.pinnedItems.map(\.id)
        case .tabs: ids = space.tabs.map(\.id)
        }
        let index = target.flatMap { t in ids.firstIndex(of: t.id) } ?? ids.count
        // Dropping onto the end zone of the list the tab is already last in: nothing to do.
        if target == nil, ids.last == dragged.id { return }
        state.move(dragged, to: section, in: space, folder: folder, at: index)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool { endSidebarDrag(state) }
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

            HStack(spacing: 2) {
                ForEach(Array(state.spaces.enumerated()), id: \.element.id) { index, space in
                    SpaceSwitcherButton(space: space, index: index)
                }
            }
            .animation(Motion.snappy, value: state.currentSpaceIndex)

            Spacer(minLength: 4)

            Menu {
                Button("New Space") { state.addSpace() }
                Button("New Folder") { state.addFolder() }
                Button("New Tab") { state.openCommandBar(.newTab) }
                Divider()
                Button("Extensions…") { AppDelegate.shared?.showSettings(tab: .extensions) }
                Button("Settings…") { AppDelegate.shared?.showSettings(tab: .general) }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.62))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New Space, Settings…")
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
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
        let active = downloads.activeCount > 0
        ZStack {
            IconButton(symbol: "arrow.down.to.line", size: 13, weight: .semibold, help: "Downloads") {
                state.downloadsVisible.toggle()
            }
            if active {
                Circle()
                    .trim(from: 0, to: max(0.04, downloads.overallFraction))
                    .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 24, height: 24)
                    .animation(.easeOut(duration: 0.3), value: downloads.overallFraction)
                    .allowsHitTesting(false)
            }
        }
        .scaleEffect(bounce ? 1.22 : 1)
        .onChange(of: downloads.pulse) { _, _ in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.45)) { bounce = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { bounce = false }
            }
        }
    }
}

struct DownloadsPopover: View {
    @Environment(DownloadManager.self) private var downloads
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.system(size: 13, weight: .semibold))
                if downloads.activeCount > 0, let speed = downloads.totalBytesPerSecond {
                    Text(DownloadStats.speed(speed))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer()
                if downloads.items.contains(where: { $0.state != .running }) {
                    Button("Clear") { withAnimation(Motion.snappy) { downloads.clearFinished() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if downloads.items.isEmpty {
                Text("Nothing downloaded yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(downloads.items) { item in
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
                IconButton(symbol: "xmark", size: 10, side: 22, help: "Cancel") { downloads.cancel(item) }
            case .finished:
                IconButton(symbol: "magnifyingglass", size: 11, side: 22, help: "Show in Finder") { downloads.reveal(item) }
            case .failed:
                EmptyView()
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
