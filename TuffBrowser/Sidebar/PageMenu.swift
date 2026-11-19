import AppKit
import SwiftUI

/// The page menu that hangs off the address bar, as in Arc and Zen: quick actions for the page
/// (screenshot, share, reader mode, picture in picture), the extensions that aren't pinned to the
/// sidebar, and the site's zoom and connection.
struct PageMenu: View {
    @Environment(BrowserState.self) private var state
    @Environment(ExtensionManager.self) private var extensions

    enum Page { case main, screenshot, site }
    @State private var page: Page = .main

    static let width: CGFloat = 248
    /// The page the menu opens on next (tests open it straight on the screenshot options).
    static var openOn: Page = .main

    var body: some View {
        ZStack(alignment: .top) {
            switch page {
            case .main:
                main
                    .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)).combined(with: .opacity))
            case .screenshot:
                ScreenshotOptions(back: { withAnimation(Motion.snappy) { page = .main } }, pick: capture)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)).combined(with: .opacity))
            case .site:
                SiteSettingsPanel(back: { withAnimation(Motion.snappy) { page = .main } })
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)).combined(with: .opacity))
            }
        }
        .padding(12)
        .frame(width: Self.width)
        .clipped()
        .onAppear {
            page = Self.openOn
            Self.openOn = .main
        }
    }

    // MARK: Main page

    private var main: some View {
        let tab = state.selectedTab
        let canCapture = tab?.isAwake == true && tab?.webView != nil && tab?.pdf == nil
        // Sized from the menu's width rather than left to the layout, which let the tiles shrink
        // to their icons after coming back from a sub-page.
        let count = AppSettings.shared.privacy.blockAds ? 5 : 4
        let side = ((Self.width - 24) - 6 * CGFloat(count - 1)) / CGFloat(count)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                PageMenuTile(side: side, symbol: "camera", help: "Screenshot", disabled: !canCapture) {
                    withAnimation(Motion.snappy) { page = .screenshot }
                }
                let reading = tab?.reader != nil
                PageMenuTile(
                    side: side,
                    symbol: reading ? "doc.plaintext.fill" : "doc.plaintext",
                    help: reading ? "Exit Reader Mode  ⌥⌘R" : "Reader Mode  ⌥⌘R",
                    disabled: !reading && tab?.canUseReader != true,
                    active: reading
                ) {
                    closeThen { tab?.toggleReader() }
                }
                let translated = tab?.translation != nil
                PageMenuTile(
                    side: side,
                    symbol: "translate",
                    help: translated ? "Show Original" : "Translate to \(PageTranslation.name(of: PageTranslation.preferredTarget))",
                    disabled: !(tab?.isAwake ?? false) || tab?.pdf != nil || tab?.url == nil,
                    active: translated
                ) {
                    closeThen { tab?.toggleTranslation() }
                }
                if AppSettings.shared.privacy.blockAds {
                    let host = tab?.url?.host
                    let allowed = ContentBlocker.shared.isAllowed(host: host)
                    PageMenuTile(
                        side: side,
                        symbol: allowed ? "shield.slash" : "shield.lefthalf.filled",
                        help: allowed ? "Block Ads on This Site" : "Allow Ads on This Site",
                        disabled: host == nil || tab?.pdf != nil
                    ) {
                        closeThen {
                            guard let host else { return }
                            ContentBlocker.shared.toggleAllowed(host: host, reloading: tab)
                            state.show(Toast(symbol: allowed ? "shield.lefthalf.filled" : "shield.slash",
                                             text: allowed ? "Blocking ads on \(host)" : "Allowing ads on \(host)"))
                        }
                    }
                }
                PageMenuTile(
                    side: side,
                    symbol: tab?.isInPictureInPicture == true ? "pip.exit" : "pip.enter",
                    help: tab?.isInPictureInPicture == true ? "Exit Picture in Picture" : "Picture in Picture",
                    disabled: !(tab?.isAwake ?? false)
                ) {
                    closeThen {
                        tab?.togglePictureInPicture { outcome in
                            if outcome == .none { state.show(Toast(symbol: "pip", text: "No video to play in Picture in Picture")) }
                        }
                    }
                }
            }

            if !state.isPrivate {
                PageMenuExtensions(close: closeThen)
            }

            PageMenuFooter(tab: tab, openSite: { withAnimation(Motion.snappy) { page = .site } })
        }
    }

    // MARK: Actions

    /// Closes the menu, then runs `action` once the popover is gone (so whatever it opens —
    /// a share sheet, an extension's popup, the area picker — isn't fighting the popover).
    private func closeThen(_ action: @escaping () -> Void) {
        state.pageMenuVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: action)
    }

    private func capture(_ mode: ScreenshotMode) {
        closeThen { Screenshotter.start(mode, in: state) }
    }

    /// The anchor popups opened from the menu hang off: the address bar it came from.
    static weak var anchor: NSView?

}

/// A square button in the menu's top row. The row shares its width between however many tiles
/// it has, and each tile stays square at that width.
private struct PageMenuTile: View {
    @Environment(\.accent) private var accent
    let side: CGFloat
    let symbol: String
    let help: String
    var disabled = false
    /// What it turns on is on (reader mode): lit in the accent colour.
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.primary.opacity(disabled ? 0.28 : 0.88))
                .frame(width: side, height: side)
                .background(
                    shape.fill(active
                        ? AnyShapeStyle(accent.opacity(hovering ? 0.34 : 0.26))
                        : AnyShapeStyle(.primary.opacity(hovering && !disabled ? 0.15 : 0.08)))
                )
                .overlay(shape.strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
                .contentShape(shape)
        }
        .buttonStyle(SquishButtonStyle(scale: 0.94))
        .disabled(disabled)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help(help)
    }
}

// MARK: - Extensions

private struct PageMenuExtensions: View {
    @Environment(BrowserState.self) private var state
    @Environment(ExtensionManager.self) private var extensions
    let close: (@escaping () -> Void) -> Void

    /// Six to a row, the same size as the tiles in the top row.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    var body: some View {
        let _ = extensions.revision
        let _ = SidePanelManager.shared.revision
        let unpinned = extensions.actions(for: state.selectedTab).filter { !$0.pinned }
        VStack(alignment: .leading, spacing: 8) {
            PageMenuHeading("Extensions")
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(unpinned) { action in
                    PageMenuExtensionTile(action: action) {
                        close { extensions.performAction(id: action.id, anchoredTo: PageMenu.anchor) }
                    }
                }
                PageMenuAddTile {
                    close { AppDelegate.shared?.showSettings(tab: .extensions) }
                }
            }
        }
    }
}

private struct PageMenuHeading: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.55))
            .padding(.leading, 2)
    }
}

private struct PageMenuExtensionTile: View {
    @Environment(ExtensionManager.self) private var extensions
    @Environment(\.accent) private var accent
    let action: ExtensionActionInfo
    let perform: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Button(action: perform) {
            ZStack(alignment: .topTrailing) {
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
                .opacity(action.enabled ? 1 : 0.4)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)

                if !action.badge.isEmpty {
                    Text(action.badge)
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.red))
                        .offset(x: 3, y: -3)
                }
            }
            .background(
                shape.fill(action.panelOpen
                    ? AnyShapeStyle(accent.opacity(hovering ? 0.34 : 0.26))
                    : AnyShapeStyle(.primary.opacity(hovering ? 0.15 : 0.08)))
            )
            .overlay(shape.strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
            .contentShape(shape)
        }
        .buttonStyle(SquishButtonStyle(scale: 0.94))
        .overlay(alignment: .topLeading) {
            if hovering {
                // Pin it back to the sidebar.
                Button {
                    withAnimation(Motion.snappy) { extensions.setPinned(true, id: action.id) }
                } label: {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.8))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.regularMaterial))
                        .overlay(Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                        .contentShape(Circle())
                }
                .buttonStyle(SquishButtonStyle())
                .help("Pin to Sidebar")
                .offset(x: -6, y: -6)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help(action.name)
        .contextMenu {
            Button("Pin to Sidebar") { extensions.setPinned(true, id: action.id) }
            if action.hasPanel {
                Button(action.panelOpen ? "Close Side Panel" : "Open Side Panel") { SidePanelManager.shared.toggle(action.id) }
            }
            if extensions.hasOptions(id: action.id) {
                Button("Options…") { extensions.openOptions(id: action.id) }
            }
            Divider()
            Button("Manage Extensions…") { AppDelegate.shared?.showSettings(tab: .extensions) }
        }
    }
}

private struct PageMenuAddTile: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary.opacity(hovering ? 0.85 : 0.6))
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(shape.fill(.primary.opacity(hovering ? 0.15 : 0.08)))
                .overlay(shape.strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
                .contentShape(shape)
        }
        .buttonStyle(SquishButtonStyle(scale: 0.94))
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help("Add Extensions…")
    }
}

// MARK: - Footer

/// The connection (which opens the site's settings and permissions) and the page's zoom.
private struct PageMenuFooter: View {
    let tab: Tab?
    let openSite: () -> Void
    /// `Tab.pageZoom` isn't observed, so the label keeps its own copy.
    @State private var zoom: CGFloat = 1
    @State private var hoveringSite = false

    var body: some View {
        let insecure = tab?.isNotSecure == true
        let web = tab?.url.map { $0.scheme == "http" || $0.scheme == "https" } ?? false
        let hasSite = SiteSettings.key(for: tab?.url) != nil
        HStack(spacing: 8) {
            Button(action: openSite) {
                HStack(spacing: 6) {
                    Image(systemName: insecure ? "lock.open.fill" : (web ? "lock.fill" : "info.circle"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(insecure ? Color(red: 0.93, green: 0.36, blue: 0.30) : .primary.opacity(0.7))
                    Text(insecure ? "Not Secure" : (web ? "Secure" : "Tuff Page"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.85))
                    if hasSite {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.primary.opacity(0.4))
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(hoveringSite && hasSite ? 0.14 : 0.08)))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(SquishButtonStyle(scale: 0.97))
            .disabled(!hasSite)
            .onHover { hoveringSite = $0 }
            .animation(Motion.quick, value: hoveringSite)
            .help(hasSite
                  ? (insecure ? "Your connection to this site isn’t encrypted. Site settings and permissions" : "Your connection to this site is encrypted. Site settings and permissions")
                  : "")

            Spacer(minLength: 0)

            if tab?.pdf == nil, tab?.webView != nil {
                HStack(spacing: 0) {
                    ZoomStep(symbol: "minus", help: "Zoom Out  ⌘−") { change { AppDelegate.shared?.zoomOut(nil) } }
                    Button {
                        change { AppDelegate.shared?.zoomReset(nil) }
                    } label: {
                        Text("\(Int((zoom * 100).rounded()))%")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.primary.opacity(0.8))
                            .frame(minWidth: 40)
                            .contentTransition(.numericText())
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Actual Size  ⌘0")
                    ZoomStep(symbol: "plus", help: "Zoom In  ⌘+") { change { AppDelegate.shared?.zoomIn(nil) } }
                }
                .padding(.horizontal, 3)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.08)))
            }
        }
        .onAppear { zoom = tab?.pageZoom ?? 1 }
    }

    private func change(_ action: () -> Void) {
        action()
        withAnimation(Motion.quick) { zoom = tab?.pageZoom ?? 1 }
    }
}

private struct ZoomStep: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.primary.opacity(hovering ? 0.9 : 0.6))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(SquishButtonStyle())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help(help)
    }
}

// MARK: - Screenshot options

private struct ScreenshotOptions: View {
    let back: () -> Void
    let pick: (ScreenshotMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                IconButton(symbol: "chevron.left", size: 11, weight: .bold, side: 24, help: "Back", action: back)
                Text("Screenshot")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }
            .padding(.leading, -4)

            VStack(spacing: 6) {
                ScreenshotOptionRow(mode: .area, pick: pick)
                ScreenshotOptionRow(mode: .visible, pick: pick)
                ScreenshotOptionRow(mode: .fullPage, pick: pick)
            }

            Text("Annotate, then copy it or save it to Downloads.")
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.45))
                .padding(.leading, 2)
        }
    }
}

private struct ScreenshotOptionRow: View {
    @Environment(\.accent) private var accent
    let mode: ScreenshotMode
    let pick: (ScreenshotMode) -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button { pick(mode) } label: {
            HStack(spacing: 12) {
                ScreenshotModeGlyph(mode: mode, highlight: hovering ? accent : .primary.opacity(0.6))
                    .frame(width: 40, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.92))
                    Text(mode.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.5))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.primary.opacity(hovering ? 0.6 : 0.25))
            }
            .padding(.horizontal, 10)
            .frame(height: 52)
            .background(shape.fill(.primary.opacity(hovering ? 0.14 : 0.07)))
            .overlay(shape.strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
            .contentShape(shape)
        }
        .buttonStyle(SquishButtonStyle(scale: 0.97))
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

/// A little drawing of what each mode captures: a browser window with the captured part lit.
struct ScreenshotModeGlyph: View {
    let mode: ScreenshotMode
    let highlight: Color

    var body: some View {
        let frame = RoundedRectangle(cornerRadius: 5, style: .continuous)
        ZStack {
            frame.fill(.primary.opacity(0.06))
            frame.strokeBorder(.primary.opacity(0.35), lineWidth: 1.2)
            switch mode {
            case .area:
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(highlight, style: StrokeStyle(lineWidth: 1.4, dash: [2.5, 2]))
                    .background(RoundedRectangle(cornerRadius: 2).fill(highlight.opacity(0.18)))
                    .frame(width: 20, height: 13)
                    .offset(x: 3, y: 2)
            case .visible:
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(highlight.opacity(0.3))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(highlight, lineWidth: 1.4))
                    .padding(4)
            case .fullPage:
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(highlight.opacity(0.3))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(highlight, lineWidth: 1.4))
                    .frame(width: 22)
                    .padding(.vertical, -5)
                    .mask(Rectangle().padding(.vertical, -8))
                Image(systemName: "arrow.up.and.down")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(highlight)
            }
        }
        .animation(Motion.quick, value: highlight)
    }
}
