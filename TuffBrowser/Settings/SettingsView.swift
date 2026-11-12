import SwiftUI
import UniformTypeIdentifiers
import WebKit

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, tabs, spaces, search, privacy, downloads, extensions, shortcuts, advanced, about
    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .tabs: "Tabs"
        case .spaces: "Spaces"
        case .search: "Search"
        case .privacy: "Privacy & Security"
        case .downloads: "Downloads"
        case .extensions: "Extensions"
        case .shortcuts: "Shortcuts"
        case .advanced: "Advanced"
        case .about: "About Tuff"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintpalette.fill"
        case .tabs: "square.on.square"
        case .spaces: "square.stack.3d.up.fill"
        case .search: "magnifyingglass"
        case .privacy: "hand.raised.fill"
        case .downloads: "arrow.down.circle.fill"
        case .extensions: "puzzlepiece.extension.fill"
        case .shortcuts: "command"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle.fill"
        }
    }

    /// Extra words the sidebar search matches.
    var keywords: String {
        switch self {
        case .general: "startup restore session quit default browser motion animations"
        case .appearance: "theme glass blur grain sheen transparency colour color tint dark light sidebar width corner radius preset"
        case .tabs: "new tab close idle archive unload sleep memory compact foreground links picture in picture pip video"
        case .spaces: "space workspace profile icon colour color order"
        case .search: "engine google duckduckgo kagi suggestions custom history"
        case .privacy: "history cookies website data cache https javascript camera microphone permissions autoplay fraud"
        case .downloads: "folder location save ask open files"
        case .extensions: "add-ons chrome firefox store install"
        case .shortcuts: "keyboard keys hotkeys"
        case .advanced: "zoom font size user agent inspector developer gestures swipe export import reset"
        case .about: "version update"
        }
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmed.lowercased()
        return q.isEmpty || label.lowercased().contains(q) || keywords.contains(q)
    }

    /// Sidebar groups, separated by a little space.
    static let groups: [[SettingsTab]] = [
        [.general, .appearance],
        [.tabs, .spaces, .search],
        [.privacy, .downloads],
        [.extensions, .shortcuts, .advanced],
        [.about],
    ]
}

@Observable
final class SettingsRouter {
    var tab: SettingsTab = .general
}

// MARK: - Window

/// The Settings window wears the same tinted glass as the browser window.
final class SettingsWindowController: NSObject {
    let window: NSWindow
    private let router = SettingsRouter()
    private let state: BrowserState
    private let settings = AppSettings.shared
    private var hostingView: NSHostingView<AnyView>!

    init(state: BrowserState) {
        self.state = state
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        super.init()
        window.title = "Tuff Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 720, height: 460)
        // An empty unified toolbar makes the title bar tall enough to centre the traffic lights
        // beside the sidebar's search field.
        window.toolbar = NSToolbar(identifier: "TuffSettings")
        window.toolbarStyle = .unified

        let root = SettingsView(router: router)
            .environment(state)
            .environment(settings)
            .environment(ExtensionManager.shared)
            .environment(DownloadManager.shared)
        hostingView = NSHostingView(rootView: AnyView(root))
        hostingView.sizingOptions = []
        hostingView.safeAreaRegions = []
        window.contentView = hostingView
        window.center()
        window.setFrameAutosaveName("TuffSettingsWindow")
        observe()
    }

    func show(_ tab: SettingsTab) {
        router.tab = tab
        let wasVisible = window.isVisible
        window.makeKeyAndOrderFront(nil)
        applyTheme()
        // SwiftUI focuses the search field on open; leave it unfocused until clicked.
        if !wasVisible { DispatchQueue.main.async { self.window.makeFirstResponder(nil) } }
    }

    private func observe() {
        withObservationTracking {
            _ = settings.theme
            _ = state.currentSpaceIndex
            _ = state.spaces.map(\.colorHex)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.applyTheme()
                self?.observe()
            }
        }
    }

    private func applyTheme() {
        let theme = settings.theme
        WindowBlur.setRadius(theme.style == .glass ? theme.blurRadius : 0, for: window)
        let dark = settings.chromeScheme(for: state.currentTint) == .dark
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if hostingView.appearance?.name != appearance?.name { hostingView.appearance = appearance }
        window.appearance = appearance
        window.invalidateShadow()
    }
}

// MARK: - Root

struct SettingsView: View {
    @Bindable var router: SettingsRouter
    @Environment(BrowserState.self) private var state
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let tint = state.currentTint
        let theme = settings.theme
        let inset = CGFloat(max(6, theme.cardInset))
        let shape = RoundedRectangle(cornerRadius: CGFloat(theme.cardRadius), style: .continuous)

        HStack(spacing: 0) {
            SettingsSidebar(router: router)
                .frame(width: 228)

            ZStack {
                page(router.tab)
                    .id(router.tab)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                ZStack {
                    Color(nsColor: tint).opacity(theme.style == .solid ? 0 : 0.5)
                    Rectangle().fill(.primary.opacity(0.035))
                }
            )
            .clipShape(shape)
            .overlay(shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.18), radius: 7, y: 2)
            .padding([.top, .bottom, .trailing], inset)
            .animation(settings.animationsEnabled ? Motion.quick : nil, value: router.tab)
        }
        .background(WindowBackground(tint: Color(nsColor: tint)))
        .overlay {
            if let prompt = state.prompt, prompt.host == .settings {
                PromptOverlay(prompt: prompt)
                    .id(prompt.id)
                    .transition(.opacity)
            }
        }
        .environment(\.accent, Color(nsColor: tint.derivedAccent))
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralPage()
        case .appearance: AppearancePage()
        case .tabs: TabsPage()
        case .spaces: SpacesPage()
        case .search: SearchPage()
        case .privacy: PrivacyPage()
        case .downloads: DownloadsPage()
        case .extensions: ExtensionsPage()
        case .shortcuts: ShortcutsPage()
        case .advanced: AdvancedPage()
        case .about: AboutPage()
        }
    }
}

// MARK: - Sidebar

struct SettingsSidebar: View {
    @Bindable var router: SettingsRouter
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 52)

            searchField
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if query.trimmed.isEmpty {
                        ForEach(Array(SettingsTab.groups.enumerated()), id: \.offset) { index, group in
                            if index > 0 { Color.clear.frame(height: 10) }
                            ForEach(group) { row($0) }
                        }
                    } else {
                        let results = SettingsTab.allCases.filter { $0.matches(query) }
                        if results.isEmpty {
                            Text("No results")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.primary.opacity(0.45))
                                .padding(.horizontal, 10)
                                .padding(.top, 6)
                        }
                        ForEach(results) { row($0) }
                    }
                }
            }
            .scrollIndicators(.never)

            Text(AboutPage.versionString)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary.opacity(0.32))
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
        }
        .padding(.horizontal, 10)
        .background(WindowDragArea())
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.45))
            TextField("Search settings", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .focused($searchFocused)
                .onSubmit {
                    if let first = SettingsTab.allCases.first(where: { $0.matches(query) }) { router.tab = first }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(searchFocused ? 0.12 : 0.08)))
        .animation(Motion.quick, value: query.isEmpty)
        .animation(Motion.quick, value: searchFocused)
    }

    private func row(_ tab: SettingsTab) -> some View {
        SidebarRow(tab: tab, selected: router.tab == tab) {
            router.tab = tab
        }
    }
}

private struct SidebarRow: View {
    @Environment(ExtensionManager.self) private var extensions
    let tab: SettingsTab
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary.opacity(selected ? 0.95 : 0.55))
                    .frame(width: 20)
                Text(tab.label)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.primary.opacity(selected ? 0.96 : 0.78))
                Spacer(minLength: 0)
                if tab == .extensions, !extensions.records.isEmpty {
                    Text("\(extensions.records.count)")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.5))
                        .padding(.horizontal, 6)
                        .frame(height: 17)
                        .background(Capsule().fill(.primary.opacity(0.08)))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.primary.opacity(selected ? 0.15 : (hovering ? 0.07 : 0)))
                    .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 3, y: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(SquishButtonStyle(scale: 0.98))
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: selected)
    }
}

// MARK: - General

struct GeneralPage: View {
    @Environment(AppSettings.self) private var settings
    @State private var isDefault = GeneralPage.checkDefault()

    var body: some View {
        @Bindable var settings = settings
        SettingsPage(title: "General", subtitle: "How Tuff starts, quits and moves.") {
            SettingsGroup(title: "Default browser") {
                SettingsRow(
                    title: isDefault ? "Tuff is your default browser" : "Tuff isn’t your default browser",
                    detail: isDefault ? "Links from other apps open here." : "Links from other apps open somewhere else.",
                    symbol: isDefault ? "checkmark.seal.fill" : "globe"
                ) {
                    if !isDefault {
                        Button("Make Default") { makeDefault() }
                            .buttonStyle(TuffButtonStyle(kind: .prominent))
                    }
                }
            }

            SettingsGroup(title: "Startup & quitting") {
                SwitchRow(title: "Restore tabs and spaces", detail: "Pick up where you left off when Tuff opens.", isOn: $settings.general.restoreSession)
                SwitchRow(title: "Ask before quitting", detail: "Confirm ⌘Q so a stray keystroke doesn’t close everything.", isOn: $settings.behavior.confirmQuit)
            }

            SettingsGroup(title: "Motion", footer: "Tuff also follows Reduce Motion in System Settings › Accessibility.") {
                SwitchRow(title: "Reduce animations", detail: "Switch tabs and spaces without springs and fades.", isOn: $settings.general.reduceMotion)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isDefault = Self.checkDefault()
        }
    }

    static func checkDefault() -> Bool {
        guard let probe = URL(string: "https://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    private func makeDefault() {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in
                DispatchQueue.main.async { isDefault = Self.checkDefault() }
            }
        }
    }
}

// MARK: - Appearance

struct AppearancePage: View {
    @Environment(AppSettings.self) private var settings
    @Environment(BrowserState.self) private var state

    private let presetColumns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        @Bindable var settings = settings
        SettingsPage(title: "Appearance", subtitle: "The glass, the colour and the shape of the window.") {
            SettingsGroup(title: "Presets") {
                LazyVGrid(columns: presetColumns, spacing: 8) {
                    ForEach(ThemePreset.all) { preset in
                        PresetTile(preset: preset)
                    }
                }
                .padding(10)
            }

            SettingsGroup(title: "Window") {
                SettingsRow(title: "Background") {
                    TuffSegmented(selection: $settings.theme.style, options: BackgroundStyle.allCases) { $0.label }
                }
                if settings.theme.style != .solid {
                    SliderRow(title: "Transparency", value: Binding(
                        get: { 1 - settings.theme.tintOpacity },
                        set: { settings.theme.tintOpacity = 1 - $0 }
                    ), range: 0...1)
                }
                if settings.theme.style == .glass {
                    SliderRow(
                        title: "Blur",
                        detail: WindowBlur.isAvailable ? nil : "Not available on this version of macOS. Try Vibrancy.",
                        value: $settings.theme.blurRadius, range: 0...80, format: { "\(Int($0)) pt" }
                    )
                }
                SliderRow(title: "Grain", value: $settings.theme.grain, range: 0...1)
                SliderRow(title: "Sheen", value: $settings.theme.sheen, range: 0...1)
            }

            SettingsGroup(title: "Colour") {
                SwitchRow(title: "Each space has its own colour", isOn: $settings.theme.useSpaceColors)
                if settings.theme.useSpaceColors {
                    SettingsRow(title: "“\(state.currentSpace.name)” colour") {
                        SwatchPicker(selected: state.currentSpace.colorHex) { hex in
                            withAnimation(Motion.smooth) { state.currentSpace.colorHex = hex }
                            state.scheduleSave()
                        }
                    }
                } else {
                    SettingsRow(title: "Tint") {
                        SwatchPicker(selected: settings.theme.tintHex) { hex in
                            withAnimation(Motion.smooth) { settings.theme.tintHex = hex }
                        }
                    }
                }
                SettingsRow(title: "Sidebar text", detail: "Match Tint picks light or dark text to suit the colour.") {
                    TuffMenu(selection: $settings.theme.appearance, options: AppearanceMode.allCases) { $0.label }
                }
            }

            SettingsGroup(title: "Sidebar") {
                SliderRow(title: "Width", value: $settings.general.sidebarWidth, range: 200...420, step: 1, format: { "\(Int($0)) pt" })
                SwitchRow(
                    title: "Show when the pointer reaches the edge",
                    detail: "With the sidebar hidden (⌘S), touch the window’s left edge to float it over the page.",
                    isOn: $settings.behavior.peekSidebarOnEdge
                )
            }

            SettingsGroup(title: "Page") {
                SliderRow(title: "Corner radius", value: $settings.theme.cardRadius, range: 0...24, step: 1, format: { "\(Int($0)) pt" })
                SliderRow(title: "Border gap", value: $settings.theme.cardInset, range: 0...20, step: 1, format: { "\(Int($0)) pt" })
            }

            HStack {
                Spacer()
                Button("Reset Appearance") { withAnimation(Motion.smooth) { settings.resetTheme() } }
                    .buttonStyle(TuffButtonStyle())
            }
        }
    }
}

private struct PresetTile: View {
    @Environment(AppSettings.self) private var settings
    @Environment(BrowserState.self) private var state
    let preset: ThemePreset
    @State private var hovering = false

    var body: some View {
        var sample = settings.theme
        preset.apply(&sample)
        let selected = sample == settings.theme
        let tint = Color(nsColor: state.currentTint)
        return Button {
            withAnimation(Motion.smooth) { preset.apply(&settings.theme) }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack {
                    LinearGradient(colors: [.white.opacity(0.35), .black.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    tint.opacity(sample.style == .solid ? 1 : sample.tintOpacity)
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.14 * sample.sheen), location: 0),
                            .init(color: .clear, location: 0.5),
                            .init(color: .black.opacity(0.14 * sample.sheen), location: 1),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Image(nsImage: Grain.image).resizable(resizingMode: .tile).opacity(sample.grain * 0.5).blendMode(.overlay)
                    HStack(spacing: 3) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(0..<3) { _ in Capsule().fill(.white.opacity(0.28)).frame(width: 18, height: 3) }
                        }
                        .frame(width: 22)
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white.opacity(0.75))
                    }
                    .padding(5)
                }
                .frame(height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? AnyShapeStyle(.primary.opacity(0.85)) : AnyShapeStyle(.primary.opacity(0.12)), lineWidth: selected ? 2 : 0.5)
                )
                Text(preset.name)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.primary.opacity(selected ? 0.95 : 0.7))
                    .padding(.leading, 2)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.primary.opacity(hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(SquishButtonStyle(scale: 0.97))
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

// MARK: - Tabs

struct TabsPage: View {
    @Environment(AppSettings.self) private var settings

    private static let idleOptions = [0, 12, 24, 168, 720]
    private static func idleLabel(_ hours: Int) -> String {
        switch hours {
        case 0: "Never"
        case 12: "12 hours"
        case 24: "1 day"
        case 168: "1 week"
        case 720: "30 days"
        default: "\(hours) hours"
        }
    }

    private static let sleepOptions = [10, 30, 60, 180, 0]
    private static func sleepLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: "Never"
        case 60: "1 hour"
        case 180: "3 hours"
        default: "\(minutes) minutes"
        }
    }

    var body: some View {
        @Bindable var settings = settings
        SettingsPage(title: "Tabs", subtitle: "Opening, closing and tidying up.") {
            SettingsGroup(title: "Opening") {
                SettingsRow(title: "New tabs go at the", detail: "Links opened from a page go right after it.") {
                    TuffSegmented(selection: $settings.tabs.newTabPosition, options: NewTabPosition.allCases) { $0.label }
                }
                SwitchRow(
                    title: "Switch to tabs opened with ⌘-click",
                    detail: "Hold ⇧ while clicking to do the opposite.",
                    isOn: $settings.tabs.foregroundLinks
                )
            }

            SettingsGroup(title: "Closing", footer: "Pinned tabs and favourites are never closed automatically. ⇧⌘T brings a closed tab back.") {
                SettingsRow(title: "After closing a tab, show") {
                    TuffMenu(selection: $settings.tabs.afterClose, options: AfterCloseSelection.allCases) { $0.label }
                }
                SettingsRow(title: "Close tabs I haven’t viewed in", detail: "Keeps the sidebar tidy, like an automatic archive.") {
                    TuffMenu(selection: $settings.tabs.closeIdleAfterHours, options: Self.idleOptions, label: Self.idleLabel)
                }
            }

            SettingsGroup(title: "Video", footer: "⌃⌘P puts the current tab’s video in Picture in Picture, or brings it back.") {
                SwitchRow(
                    title: "Picture in Picture when switching tabs",
                    detail: "A video playing with sound keeps playing in a floating window when you leave its tab, and goes back when you return.",
                    isOn: $settings.tabs.autoPictureInPicture
                )
            }

            SettingsGroup(title: "Memory", footer: "Unloaded tabs stay in the sidebar and reload where you left off when you click them. Tabs playing audio or a video in Picture in Picture are never unloaded.") {
                SettingsRow(title: "Unload background tabs after") {
                    TuffMenu(selection: $settings.general.sleepAfterMinutes, options: Self.sleepOptions, label: Self.sleepLabel)
                }
            }

            SettingsGroup(title: "Sidebar rows") {
                SwitchRow(title: "Always show close buttons", detail: "Otherwise they appear when you point at a tab.", isOn: $settings.tabs.alwaysShowCloseButton)
                SwitchRow(title: "Compact rows", detail: "Fit more tabs in the sidebar.", isOn: $settings.tabs.compactRows)
            }
        }
    }
}

// MARK: - Spaces

struct SpacesPage: View {
    @Environment(BrowserState.self) private var state

    var body: some View {
        SettingsPage(title: "Spaces", subtitle: "Separate sets of tabs, each with its own colour.") {
            SettingsGroup(
                title: "Profiles",
                footer: "Every space belongs to a profile. Spaces on the same profile share cookies, sign-ins and the favourites at the top of the sidebar; each profile signs in to sites separately. Extensions can be limited to a profile in Extensions."
            ) {
                ForEach(state.profiles) { profile in
                    ProfileSettingsRow(profile: profile)
                }
            }
            HStack {
                Spacer()
                Button {
                    state.addProfile()
                } label: {
                    Label("New Profile", systemImage: "plus")
                }
                .buttonStyle(TuffButtonStyle(kind: .prominent))
            }
            SettingsGroup(title: "Spaces", footer: "Switch spaces with ⌃1–9, or swipe sideways with two fingers on the sidebar.") {
                ForEach(Array(state.spaces.enumerated()), id: \.element.id) { index, space in
                    SpaceSettingsRow(space: space, index: index)
                }
            }
            HStack {
                Spacer()
                Button {
                    state.addSpace(select: false)
                } label: {
                    Label("New Space", systemImage: "plus")
                }
                .buttonStyle(TuffButtonStyle(kind: .prominent))
            }
        }
    }
}

private struct SpaceSettingsRow: View {
    @Environment(BrowserState.self) private var state
    @Bindable var space: Space
    let index: Int
    @State private var editingLook = false

    private let iconColumns = Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8)

    var body: some View {
        let current = state.currentSpace === space
        HStack(spacing: 12) {
            Button { editingLook = true } label: {
                Image(systemName: space.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(space.color.luminance > 0.55 ? Color.black.opacity(0.75) : .white)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: space.color)))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.primary.opacity(0.18), lineWidth: 0.5))
            }
            .buttonStyle(SquishButtonStyle())
            .help("Change icon and colour")
            .popover(isPresented: $editingLook, arrowEdge: .bottom) { lookEditor }

            TuffTextField(placeholder: "Space name", text: $space.name, width: 170)

            if current {
                Text("Showing")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.5))
                    .padding(.horizontal, 7)
                    .frame(height: 19)
                    .background(Capsule().fill(.primary.opacity(0.08)))
                    .fixedSize()
            }

            Spacer(minLength: 8)

            Text("\(space.pinned.count + space.tabs.count) tabs")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.42))

            TuffMenu(
                selection: Binding(
                    get: { space.profileID },
                    set: { id in if let p = state.profiles.first(where: { $0.id == id }) { state.setProfile(p, for: space) } }
                ),
                options: state.profiles.map(\.id),
                label: { id in state.profiles.first { $0.id == id }?.name ?? "—" }
            )
            .help("Profile")

            HStack(spacing: 0) {
                IconButton(symbol: "chevron.up", size: 11, side: 24, help: "Move Up", disabled: index == 0) {
                    state.moveSpace(from: index, to: index - 1)
                }
                IconButton(symbol: "chevron.down", size: 11, side: 24, help: "Move Down", disabled: index == state.spaces.count - 1) {
                    state.moveSpace(from: index, to: index + 1)
                }
                IconButton(symbol: "trash", size: 11, side: 24, help: "Delete Space and Its Tabs", disabled: state.spaces.count < 2) {
                    state.confirmDelete(space, from: .settings)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: space.name) { _, _ in state.scheduleSave() }
        .onChange(of: space.icon) { _, _ in state.scheduleSave() }
        .onChange(of: space.colorHex) { _, _ in state.scheduleSave() }
    }

    private var lookEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Icon").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: iconColumns, spacing: 6) {
                ForEach(Space.icons, id: \.self) { icon in
                    Button {
                        withAnimation(Motion.snappy) { space.icon = icon }
                    } label: {
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(space.icon == icon ? 0.16 : 0.05)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SquishButtonStyle())
                }
            }
            SpaceColorPicker(hex: space.colorHex) { space.colorHex = $0 }
                .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 8 * 30 + 7 * 6 + 32)
    }
}

// MARK: - Search

struct SearchPage: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let engine = settings.general.searchEngine
        let hasSuggestions = engine.suggestURL(for: "a") != nil
        SettingsPage(title: "Search", subtitle: "What happens when you type something that isn’t an address.") {
            SettingsGroup {
                SettingsRow(title: "Search engine") {
                    TuffMenu(selection: $settings.general.searchEngine, options: SearchEngine.allCases) { $0.label }
                }
                if engine == .custom {
                    let template = settings.search.customTemplate
                    let valid = SearchEngine.isValidTemplate(template)
                    SettingsRow(
                        title: "Search URL",
                        detail: template.isEmpty ? "Use %s where the search terms go." : (valid ? "Looks good." : "Needs to be an http(s) address containing %s. Google is used until then.")
                    ) {
                        TuffTextField(placeholder: "https://example.com/search?q=%s", text: $settings.search.customTemplate, width: 250, monospaced: true)
                    }
                }
            }

            SettingsGroup(
                title: "Suggestions in the command bar",
                footer: hasSuggestions ? "Search suggestions send what you type to \(engine.label) as you type." : "\(engine.label) doesn’t offer search suggestions."
            ) {
                SwitchRow(title: "Search suggestions", detail: "From \(engine.label).", isOn: $settings.general.searchSuggestions)
                    .disabled(!hasSuggestions)
                SwitchRow(title: "Pages from your history", isOn: $settings.search.historySuggestions)
                SwitchRow(title: "Open tabs", detail: "Jump to a tab that’s already open instead of opening it again.", isOn: $settings.search.openTabSuggestions)
            }
        }
    }
}

// MARK: - Privacy & Security

struct PrivacyPage: View {
    @Environment(AppSettings.self) private var settings
    @State private var historyCount = HistoryStore.shared.count
    @State private var siteCount: Int?
    private var permissions = SitePermissions.shared

    var body: some View {
        @Bindable var settings = settings
        SettingsPage(title: "Privacy & Security", subtitle: "What Tuff keeps, and what websites can do.") {
            SettingsGroup(title: "History") {
                SwitchRow(title: "Save browsing history", detail: "Used for suggestions in the command bar.", isOn: $settings.privacy.saveHistory)
                SwitchRow(title: "Clear history when Tuff quits", isOn: $settings.privacy.clearHistoryOnQuit)
                SettingsRow(title: "History", detail: historyCount == 1 ? "1 page" : "\(historyCount) pages") {
                    ConfirmButton(title: "Clear History") {
                        HistoryStore.shared.clear()
                        BrowserState.shared.forgetClosedTabs()
                        historyCount = 0
                    }
                }
            }

            SettingsGroup(title: "Website data", footer: "Removing website data signs you out of most sites, in every profile.") {
                SettingsRow(title: "Cookies and site data", detail: siteCountText) {
                    ConfirmButton(title: "Remove All") {
                        let group = DispatchGroup()
                        for store in DataStores.all {
                            group.enter()
                            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { group.leave() }
                        }
                        group.notify(queue: .main) { refreshSiteCount() }
                    }
                }
                SettingsRow(title: "Cache", detail: "Copies of pages and images that make sites load faster.") {
                    ConfirmButton(title: "Empty Cache", confirmTitle: "Empty?") {
                        let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache]
                        for store in DataStores.all { store.removeData(ofTypes: types, modifiedSince: .distantPast) {} }
                    }
                }
            }

            SettingsGroup(title: "Security", footer: "HTTPS upgrades apply to tabs opened from now on.") {
                SwitchRow(title: "Upgrade to HTTPS", detail: "Use secure connections for sites known to support them.", isOn: $settings.privacy.upgradeToHTTPS)
                SwitchRow(title: "Warn about fraudulent websites", isOn: $settings.privacy.fraudWarnings)
                SwitchRow(title: "Allow JavaScript", detail: "Most sites need it. Takes effect on the next page load.", isOn: $settings.privacy.javaScript)
            }

            SettingsGroup(title: "Camera & microphone") {
                SwitchRow(
                    title: "Remember my choice by default",
                    detail: "Starts the “Remember for this site” switch on when a site asks.",
                    isOn: $settings.privacy.rememberMediaPermissions
                )
                if permissions.saved.isEmpty {
                    SettingsRow(title: "No saved choices", detail: "Sites you allow or block will appear here.")
                } else {
                    ForEach(permissions.saved) { entry in
                        SettingsRow(title: entry.host, detail: entry.kind.label, symbol: entry.kind.symbols.first) {
                            Text(entry.granted ? "Allowed" : "Blocked")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(entry.granted ? Color.green : Color.red)
                                .padding(.horizontal, 8)
                                .frame(height: 20)
                                .background(Capsule().fill((entry.granted ? Color.green : Color.red).opacity(0.14)))
                            IconButton(symbol: "xmark", size: 10, side: 24, help: "Forget") {
                                withAnimation(Motion.snappy) { permissions.remove(entry) }
                            }
                        }
                    }
                    SettingsRow(title: "Forget all saved choices") {
                        ConfirmButton(title: "Forget All") { withAnimation(Motion.snappy) { permissions.removeAll() } }
                    }
                }
            }

            SettingsGroup(title: "Media", footer: "Applies to tabs opened from now on.") {
                SettingsRow(title: "Autoplay video and audio") {
                    TuffSegmented(selection: $settings.privacy.autoplay, options: AutoplayPolicy.allCases) { $0.label }
                }
            }
        }
        .onAppear(perform: refreshSiteCount)
    }

    private var siteCountText: String {
        guard let siteCount else { return "Counting…" }
        return siteCount == 1 ? "1 website stores data" : "\(siteCount) websites store data"
    }

    private func refreshSiteCount() {
        // The same site signed in on two profiles counts once.
        var sites = Set<String>()
        let group = DispatchGroup()
        for store in DataStores.all {
            group.enter()
            store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                sites.formUnion(records.map(\.displayName))
                group.leave()
            }
        }
        group.notify(queue: .main) { siteCount = sites.count }
    }
}

// MARK: - Downloads

struct DownloadsPage: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        @Bindable var settings = settings
        let folder = settings.downloads.folder
        SettingsPage(title: "Downloads", subtitle: "Where files go and what happens next.") {
            SettingsGroup(title: "Location") {
                SettingsRow(title: "Save files to", detail: (folder.path as NSString).abbreviatingWithTildeInPath, symbol: "folder.fill") {
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        .buttonStyle(TuffButtonStyle())
                    Button("Change…", action: chooseFolder)
                        .buttonStyle(TuffButtonStyle())
                }
                SwitchRow(title: "Ask where to save each file", isOn: $settings.downloads.askWhereToSave)
            }

            SettingsGroup(title: "During and after") {
                SwitchRow(title: "Show the downloads list when a download starts", isOn: $settings.downloads.showPanelOnStart)
                SwitchRow(title: "Open safe files after downloading", detail: "PDFs, pictures, audio, video and text files.", isOn: $settings.downloads.openSafeFiles)
            }

            SettingsGroup(title: "This session") {
                let finished = downloads.items.filter { $0.state != .running }.count
                SettingsRow(
                    title: "Downloads list",
                    detail: downloads.items.isEmpty ? "Nothing downloaded yet." : "\(downloads.activeCount) in progress, \(finished) finished"
                ) {
                    Button("Clear Finished") { withAnimation(Motion.snappy) { downloads.clearFinished() } }
                        .buttonStyle(TuffButtonStyle())
                        .disabled(finished == 0)
                }
            }

            if !settings.downloads.folderPath.isEmpty {
                HStack {
                    Spacer()
                    Button("Use Downloads Folder") { settings.downloads.folderPath = "" }
                        .buttonStyle(TuffButtonStyle())
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.downloads.folder
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.downloads.folderPath = url.path
    }
}

// MARK: - Advanced

struct AdvancedPage: View {
    @Environment(AppSettings.self) private var settings
    @State private var importFailed = false

    private static let zoomOptions: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]
    private static let fontOptions: [Double] = [0, 9, 10, 11, 12, 14, 16, 18, 20, 24]

    var body: some View {
        @Bindable var settings = settings
        SettingsPage(title: "Advanced", subtitle: "For tinkerers.") {
            SettingsGroup(title: "Pages", footer: "Default zoom applies to new tabs. ⌘0 resets a tab to it.") {
                SettingsRow(title: "Default zoom") {
                    TuffMenu(selection: $settings.advanced.defaultZoom, options: Self.zoomOptions) { "\(Int(($0 * 100).rounded()))%" }
                }
                SettingsRow(title: "Never use font sizes smaller than") {
                    TuffMenu(selection: $settings.advanced.minimumFontSize, options: Self.fontOptions) { $0 == 0 ? "No minimum" : "\(Int($0)) pt" }
                }
            }

            SettingsGroup(title: "Trackpad & mouse") {
                SwitchRow(title: "Swipe between pages", detail: "Two-finger swipe on the page to go back and forward.", isOn: $settings.advanced.swipeNavigation)
                SwitchRow(title: "Link previews", detail: "Force click a link to peek at it.", isOn: $settings.advanced.linkPreviews)
            }

            SettingsGroup(title: "Developer") {
                SwitchRow(title: "Web Inspector", detail: "⌥⌘I, or right-click › Inspect Element.", isOn: $settings.advanced.webInspector)
            }

            SettingsGroup(title: "User agent", footer: "Some sites change what they show depending on the browser they think you use. Safari is the best match for Tuff’s engine.") {
                SettingsRow(title: "Identify as") {
                    TuffSegmented(selection: $settings.advanced.userAgent, options: UserAgentMode.allCases) { $0.label }
                }
                if settings.advanced.userAgent == .custom {
                    SettingsRow(title: "Custom string") {
                        TuffTextField(placeholder: "Mozilla/5.0 …", text: $settings.advanced.customUserAgent, width: 280, monospaced: true)
                    }
                }
            }

            SettingsGroup(title: "Settings", footer: importFailed ? "That file isn’t a Tuff settings export." : "Exports include appearance and every setting on these pages, but not tabs, history or extensions.") {
                SettingsRow(title: "Back up or move your settings") {
                    Button("Import…", action: importSettings).buttonStyle(TuffButtonStyle())
                    Button("Export…", action: exportSettings).buttonStyle(TuffButtonStyle())
                }
                SettingsRow(title: "Reset all settings", detail: "Spaces, tabs and extensions are kept.") {
                    ConfirmButton(title: "Reset…", confirmTitle: "Reset everything?") {
                        withAnimation(Motion.smooth) { settings.resetAll() }
                    }
                }
            }
        }
    }

    private func exportSettings() {
        guard let data = settings.exportData() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Tuff Settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        withAnimation(Motion.smooth) { importFailed = !settings.importData(data) }
    }
}

// MARK: - Shortcuts

struct ShortcutsPage: View {
    private struct Shortcut: Identifiable {
        var title: String
        var keys: [[String]]
        var id: String { title }
    }

    private struct Section: Identifiable {
        var title: String
        var shortcuts: [Shortcut]
        var id: String { title }
    }

    /// Read from the menu bar, so the list is always what the app actually does.
    private var sections: [Section] {
        guard let menu = NSApp.mainMenu else { return [] }
        return menu.items.compactMap { top -> Section? in
            guard let submenu = top.submenu else { return nil }
            var list: [Shortcut] = []
            for item in submenu.items where !item.isSeparatorItem && !item.keyEquivalent.isEmpty {
                let caps = Self.caps(for: item)
                if let i = list.firstIndex(where: { $0.title == item.title }) {
                    list[i].keys.append(caps)
                } else {
                    list.append(Shortcut(title: item.title, keys: [caps]))
                }
            }
            // "Tab 1…8" and "Space 1…9" read better as one line each.
            list = Self.collapseNumbered(list, prefix: "Tab ", modifiers: "⌘", label: "Go to tab 1–8")
            list = Self.collapseNumbered(list, prefix: "Space ", modifiers: "⌃", label: "Go to space 1–9")
            return list.isEmpty ? nil : Section(title: top.title, shortcuts: list)
        }
    }

    var body: some View {
        SettingsPage(title: "Shortcuts", subtitle: "Every keyboard shortcut, straight from the menus.") {
            ForEach(sections) { section in
                SettingsGroup(title: section.title) {
                    ForEach(section.shortcuts) { shortcut in
                        SettingsRow(title: shortcut.title) {
                            HStack(spacing: 10) {
                                ForEach(Array(shortcut.keys.enumerated()), id: \.offset) { index, caps in
                                    if index > 0 {
                                        Text("or").font(.system(size: 11)).foregroundStyle(.primary.opacity(0.4))
                                    }
                                    HStack(spacing: 3) { ForEach(Array(caps.enumerated()), id: \.offset) { KeyCap(text: $0.element) } }
                                }
                            }
                        }
                    }
                }
            }
            SettingsGroup(title: "Gestures") {
                SettingsRow(title: "Switch spaces", detail: "Swipe sideways with two fingers on the sidebar.", symbol: "hand.draw")
                SettingsRow(title: "Back and forward", detail: "Swipe sideways with two fingers on the page.", symbol: "hand.point.left")
                SettingsRow(title: "Show the hidden sidebar", detail: "Move the pointer to the window’s left edge.", symbol: "sidebar.left")
            }
        }
    }

    private static func caps(for item: NSMenuItem) -> [String] {
        var caps: [String] = []
        let m = item.keyEquivalentModifierMask
        if m.contains(.control) { caps.append("⌃") }
        if m.contains(.option) { caps.append("⌥") }
        if m.contains(.shift) { caps.append("⇧") }
        if m.contains(.command) { caps.append("⌘") }
        caps.append(keyName(item.keyEquivalent))
        return caps
    }

    private static func keyName(_ key: String) -> String {
        guard let scalar = key.unicodeScalars.first else { return key }
        switch Int(scalar.value) {
        case NSUpArrowFunctionKey: return "↑"
        case NSDownArrowFunctionKey: return "↓"
        case NSLeftArrowFunctionKey: return "←"
        case NSRightArrowFunctionKey: return "→"
        case 0x09: return "⇥"
        case 0x0D: return "↩"
        case 0x1B: return "⎋"
        case 0x20: return "Space"
        default: return key.uppercased()
        }
    }

    private static func collapseNumbered(_ list: [Shortcut], prefix: String, modifiers: String, label: String) -> [Shortcut] {
        let numbered = list.filter { $0.title.hasPrefix(prefix) && Int($0.title.dropFirst(prefix.count)) != nil }
        guard numbered.count > 2, let firstIndex = list.firstIndex(where: { $0.id == numbered[0].id }) else { return list }
        let last = numbered.map { Int($0.title.dropFirst(prefix.count)) ?? 0 }.max() ?? 9
        var result = list.filter { item in !numbered.contains { $0.id == item.id } }
        result.insert(Shortcut(title: label, keys: [Array(modifiers.map(String.init)) + ["1–\(last)"]]), at: min(firstIndex, result.count))
        return result
    }
}

// MARK: - Extensions

struct ExtensionsPage: View {
    @Environment(ExtensionManager.self) private var extensions
    @Environment(BrowserState.self) private var state
    @State private var manualInput = ""

    var body: some View {
        SettingsPage(title: "Extensions", subtitle: "Chrome and Firefox extensions, running on WebKit.") {
            SettingsGroup(
                title: "Add extensions",
                footer: "Open an extension’s page in either store and click “Add to Tuff” where the store’s own install button usually is. Chrome (Manifest V2 and V3) and Firefox extensions run on WebKit’s WebExtensions engine; a few Chrome-only APIs are unavailable."
            ) {
                HStack(spacing: 8) {
                    StoreTile(title: "Chrome Web Store", symbol: "bag.fill") { open("https://chromewebstore.google.com/category/extensions") }
                    StoreTile(title: "Firefox Add-ons", symbol: "flame.fill") { open("https://addons.mozilla.org/firefox/extensions/") }
                    StoreTile(title: "Load Unpacked…", symbol: "shippingbox.fill") { loadUnpacked() }
                }
                .padding(10)
                HStack(spacing: 8) {
                    TuffTextField(placeholder: "Store link or Chrome extension ID", text: $manualInput, width: nil, onSubmit: installManual)
                    Button("Add", action: installManual)
                        .buttonStyle(TuffButtonStyle(kind: .prominent))
                        .disabled(ExtensionManager.source(from: manualInput) == nil)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                if let status = extensions.status {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(status).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.6))
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }

            SettingsGroup(title: "Installed") {
                if extensions.records.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.25))
                        Text("No extensions yet")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.45))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                }
                ForEach(extensions.records) { record in
                    ExtensionRow(record: record)
                }
            }
        }
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        state.newTab(url: url)
        state.window?.makeKeyAndOrderFront(nil)
    }

    private func installManual() {
        guard let source = ExtensionManager.source(from: manualInput) else { return }
        manualInput = ""
        extensions.install(source)
    }

    private func loadUnpacked() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder, .zip, UTType(filenameExtension: "crx"), UTType(filenameExtension: "xpi")].compactMap { $0 }
        panel.message = "Choose an unpacked extension folder, or a .crx / .xpi / .zip package."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        extensions.install(isDirectory.boolValue ? .folder(url) : .archive(url))
    }
}

private struct StoreTile: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.75))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(hovering ? 0.12 : 0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(SquishButtonStyle(scale: 0.97))
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

struct ExtensionRow: View {
    @Environment(ExtensionManager.self) private var extensions
    let record: ExtensionRecord

    var body: some View {
        // Loading / unloading as spaces change bumps `revision`; the subtitle depends on it.
        let _ = extensions.revision
        HStack(spacing: 12) {
            Group {
                if let icon = extensions.icon(for: record) {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.primary.opacity(0.5))
                }
            }
            .frame(width: 28, height: 28)
            .opacity(record.enabled ? 1 : 0.45)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(record.enabled ? 0.92 : 0.55))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(record.lastError == nil ? AnyShapeStyle(.primary.opacity(0.48)) : AnyShapeStyle(Color.red))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)

            Menu {
                ExtensionLinkMenuItems(id: record.id)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: extensions.linkSummary(record) == nil ? "square.stack.3d.up" : "link")
                        .font(.system(size: 10, weight: .semibold))
                    Text(extensions.linkSummary(record) ?? "All Spaces")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .frame(maxWidth: 130)
                        .fixedSize()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.45))
                }
                .foregroundStyle(.primary.opacity(0.85))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(0.08)))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Where this extension runs")

            Menu {
                if extensions.hasOptions(id: record.id) {
                    Button("Options…") { extensions.openOptions(id: record.id) }
                }
                if record.source == .unpacked {
                    Button("Reload") { extensions.reload(id: record.id) }
                } else if record.storeID != nil {
                    Button("Update from Store") { extensions.updateFromStore(id: record.id) }
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([extensions.directory(for: record)])
                }
                Divider()
                Button("Remove", role: .destructive) { extensions.uninstall(id: record.id) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.6))
                    .frame(width: 26, height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(0.08)))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()

            TuffSwitch(isOn: Binding(
                get: { record.enabled },
                set: { extensions.setEnabled($0, id: record.id) }
            ))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        if let error = record.lastError { return error }
        let source: String
        switch record.source {
        case .chrome: source = "Chrome Web Store"
        case .firefox: source = "Firefox Add-ons"
        case .unpacked: source = "Unpacked"
        }
        var text = record.version.isEmpty ? source : "Version \(record.version) · \(source)"
        if record.enabled, extensions.linkSummary(record) != nil, extensions.contexts[record.id] == nil {
            text += " · Off in this space"
        }
        return text
    }
}

// MARK: - About

struct AboutPage: View {
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "Tuff \(short) (\(build))"
    }

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
                .scaleEffect(appeared ? 1 : 0.88)
                .padding(.bottom, 18)
            Text("Tuff")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text(Self.versionString.replacingOccurrences(of: "Tuff ", with: "Version "))
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.5))
                .padding(.top, 4)
            Text("A light, glassy browser built on WebKit.")
                .font(.system(size: 13.5))
                .foregroundStyle(.primary.opacity(0.65))
                .padding(.top, 14)
            Button("Check for Updates…") { AppDelegate.shared?.checkForUpdates(nil) }
                .buttonStyle(TuffButtonStyle(kind: .prominent))
                .padding(.top, 22)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { appeared = true } }
    }
}
