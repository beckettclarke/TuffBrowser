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
        Group {
            if !favorites.isEmpty {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(favorites) { tab in
                        FavoriteTile(tab: tab)
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
    @State private var hovering = false

    var body: some View {
        let selected = state.selectedTab === tab
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
        VStack(spacing: 0) {
            SpaceHeader(space: space)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(space.pinned) { tab in
                        row(tab, section: .pinned)
                    }
                    if !space.pinned.isEmpty || state.draggingTab != nil {
                        PinDropZone(space: space, empty: space.pinned.isEmpty)
                    }

                    Rectangle()
                        .fill(.primary.opacity(0.1))
                        .frame(height: 1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)

                    NewTabRow()

                    ForEach(space.tabs) { tab in
                        row(tab, section: .tabs)
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

    private func row(_ tab: Tab, section: TabSection) -> some View {
        TabRow(tab: tab, section: section)
            .onDrag {
                state.draggingTab = tab
                return NSItemProvider(object: tab.id.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: TabDropDelegate(target: tab, section: section, space: space, state: state))
            .transition(
                .asymmetric(
                    insertion: .scale(scale: 0.92, anchor: .leading).combined(with: .opacity),
                    removal: .scale(scale: 0.9, anchor: .leading).combined(with: .opacity)
                )
            )
    }
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
    @State private var hovering = false

    var body: some View {
        let selected = state.selectedTab === tab
        HStack(spacing: 10) {
            TabIcon(tab: tab)
                .opacity(tab.isAwake || selected ? 1 : 0.7)

            Text(tab.displayTitle)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.primary.opacity(selected ? 0.96 : (tab.isAwake ? 0.82 : 0.6)))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .mask(
                    LinearGradient(
                        stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )

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
        .onTapGesture { state.select(tab) }
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: selected)
        .animation(Motion.snappy, value: tab.isPlayingAudio)
        .animation(Motion.snappy, value: tab.isInPictureInPicture)
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
        if section != .tabs, tab.url != tab.homeURL, tab.url != nil {
            Button("Use Current Page as Home") {
                tab.homeURL = tab.url
                state.scheduleSave()
            }
        }
        Divider()
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
    let state: BrowserState

    func validateDrop(info: DropInfo) -> Bool { state.draggingTab != nil }

    func dropEntered(info: DropInfo) {
        guard let dragged = state.draggingTab, dragged !== target else { return }
        let list: [Tab]
        switch section {
        case .favorites: list = state.favorites
        case .pinned: list = space.pinned
        case .tabs: list = space.tabs
        }
        let index = target.flatMap { t in list.firstIndex { $0 === t } } ?? list.count
        // Dropping onto the end zone of the list the tab is already last in: nothing to do.
        if target == nil, list.last === dragged { return }
        state.move(dragged, to: section, in: space, at: index)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        withAnimation(Motion.quick) { state.draggingTab = nil }
        return true
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

            HStack(spacing: 2) {
                ForEach(Array(state.spaces.enumerated()), id: \.element.id) { index, space in
                    SpaceSwitcherButton(space: space, index: index)
                }
            }
            .animation(Motion.snappy, value: state.currentSpaceIndex)

            Spacer(minLength: 4)

            Menu {
                Button("New Space") { state.addSpace() }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.system(size: 13, weight: .semibold))
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
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 300)
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
                    ProgressView(value: item.fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                case .finished:
                    Text("Done").font(.system(size: 11)).foregroundStyle(.secondary)
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
