import SwiftUI
import WebKit

/// The whole window: tinted glass background, sidebar, the rounded web "card", and overlays.
struct RootView: View {
    @Environment(BrowserState.self) private var state
    @Environment(AppSettings.self) private var settings
    /// Where the horizontal toolbar's address bar is (see `URLPillFrameKey`).
    @State private var pillFrame: CGRect = .zero

    /// The coordinate space the address bar's frame is measured in.
    static let space = "tuff.root"

    var body: some View {
        let theme = state.theme
        let horizontal = state.tabLayout == .horizontal
        let width = CGFloat(settings.general.sidebarWidth)
        // Seamless runs the page into the window's edges and its chrome.
        let inset = theme.style == .seamless ? 0 : CGFloat(theme.cardInset)
        let docked = state.sidebarVisible && !horizontal
        let shown = docked || (state.sidebarPeeking && !horizontal)
        let chromeHeight = BrowserWindowController.tabStripHeight + BrowserWindowController.toolbarHeight
            + (state.bookmarksBarShowing ? BrowserWindowController.bookmarksBarHeight : 0)

        ZStack(alignment: .topLeading) {
            WindowBackground(tint: Color(nsColor: state.currentTint), theme: theme)

            // One page area for both layouts, so switching keeps the same web view host. (Two
            // hosts, one fading out, would fight over the web view and could leave it in the
            // one going away.)
            VStack(spacing: 0) {
                if horizontal {
                    HorizontalChrome()
                        .transition(.opacity)
                }
                PageArea(inset: inset)
                    .padding(.leading, horizontal ? inset : (docked ? width : inset))
                    .padding([.bottom, .trailing], inset)
                    .padding(.top, horizontal ? max(0, inset - 4) : inset)
            }

            if !horizontal {
                SidebarView()
                    .frame(width: width)
                    .background {
                        if !docked { FloatingSidebarBackdrop(tint: Color(nsColor: state.currentTint)) }
                    }
                    .padding(docked ? 0 : BrowserWindowController.floatingSidebarMargin)
                    // The sidebar slides and fades as one piece. Without this, SwiftUI re-places
                    // every row, icon and label inside it on each frame of the peek / dock animation.
                    .geometryGroup()
                    .offset(x: shown ? 0 : -(width + 40))
                    .opacity(shown ? 1 : 0)

                if docked {
                    SidebarResizeHandle()
                        .offset(x: width - 4)
                }
            }

            if let mode = state.commandBar {
                if horizontal, pillFrame != .zero {
                    // Horizontal tabs: type in the address bar itself.
                    DockedCommandBar(mode: mode, frame: pillFrame)
                        .transition(.opacity)
                        .zIndex(10)
                } else {
                    CommandBarOverlay(mode: mode)
                        .transition(.opacity)
                        .zIndex(10)
                }
            }

            if let toast = state.toast {
                ToastView(toast: toast)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, (horizontal ? chromeHeight : inset) + 14)
                    .padding(.leading, docked ? width : 0)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(11)
                    .allowsHitTesting(false)
            }

            if let screenshot = state.screenshot {
                ScreenshotEditor(session: screenshot)
                    .id(screenshot.id)
                    .transition(.opacity)
                    .zIndex(11.5)
            }

            if !state.isPrivate, Onboarding.shared.isShowing {
                OnboardingOverlay()
                    .transition(.opacity)
                    .zIndex(11.8)
            }

            if let prompt = state.prompt, prompt.host == .browser {
                PromptOverlay(prompt: prompt)
                    .id(prompt.id)
                    .transition(.opacity)
                    .zIndex(12)
            }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(URLPillFrameKey.self) { pillFrame = $0 }
        .environment(\.accent, Color(nsColor: state.currentTint.derivedAccent))
        .animation(settings.animationsEnabled ? Motion.snappy : nil, value: horizontal)
        .animation(settings.animationsEnabled ? Motion.snappy : nil, value: state.bookmarksBarShowing)
        .ignoresSafeArea()
    }
}

/// The web page card (two side by side in a split), with an extension's side panel beside it
/// when one is open.
private struct PageArea: View {
    @Environment(BrowserState.self) private var state
    @Environment(AppSettings.self) private var settings
    let inset: CGFloat

    var body: some View {
        let panels = SidePanelManager.shared
        // Extension side panels belong to the main window; Incognito windows have no extensions.
        let panel = state.isPrivate ? nil : panels.openID.flatMap { id in panels.host.map { (id, $0) } }
        let selected = state.selectedTab
        let split = state.visibleSplit
        let sides = split.map { split in
            (state.tab(withID: split.leading, in: state.currentSpace), state.tab(withID: split.trailing, in: state.currentSpace))
        }
        HStack(spacing: max(inset, 6)) {
            SplitPages(
                leading: sides?.0 ?? selected, trailing: sides?.1, selected: selected,
                fraction: split?.fraction ?? 0.5, gap: max(inset, 6)
            )
            if let (id, host) = panel {
                SidePanelCard(id: id, webView: host.webView)
                    .frame(width: CGFloat(settings.general.sidePanelWidth))
                    .overlay(alignment: .leading) {
                        SidePanelResizeHandle().offset(x: -max(inset, 6) / 2 - 4)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(settings.animationsEnabled ? Motion.snappy : nil, value: panels.isShowing)
    }
}

/// One page, or two side by side with a divider between them that sets their widths. The
/// leading card keeps its place either way, so going into or out of a split doesn't rebuild it.
private struct SplitPages: View {
    @Environment(BrowserState.self) private var state
    @Environment(AppSettings.self) private var settings
    @Environment(\.accent) private var accent
    let leading: Tab?
    let trailing: Tab?
    let selected: Tab?
    let fraction: Double
    let gap: CGFloat
    /// The side a tab dragged over the page would go to if dropped now.
    @State private var dropSide: PageDropSide?

    var body: some View {
        GeometryReader { geo in
            let available = geo.size.width - (trailing == nil ? 0 : gap)
            let width = trailing == nil ? geo.size.width : max(0, (available * fraction).rounded())
            // Where each side is, or (one page) would be after the drop: an even split.
            let split = trailing != nil
            let leadingWidth = split ? width : max(0, (geo.size.width - gap) / 2)
            let sideFrame = { (side: PageDropSide) -> CGRect in
                side == .leading
                    ? CGRect(x: 0, y: 0, width: leadingWidth, height: geo.size.height)
                    : CGRect(x: leadingWidth + gap, y: 0, width: max(0, geo.size.width - leadingWidth - gap), height: geo.size.height)
            }
            HStack(spacing: gap) {
                WebCard(tab: leading, focused: trailing == nil || leading === selected, split: trailing != nil)
                    .frame(width: width)
                if let trailing {
                    WebCard(tab: trailing, focused: trailing === selected, split: true)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topLeading) {
                if trailing != nil {
                    SplitDivider(available: available)
                        .frame(height: geo.size.height)
                        .offset(x: width + gap / 2 - SplitDivider.width / 2)
                        .transition(.opacity)
                }
            }
            // A tab dragged over the page: the side it would take is tinted.
            .overlay(alignment: .topLeading) {
                if let dropSide {
                    let frame = sideFrame(dropSide)
                    let shape = RoundedRectangle(cornerRadius: max(8, CGFloat(settings.theme.cardRadius)), style: .continuous)
                    shape.fill(accent.opacity(0.16))
                        .overlay(shape.strokeBorder(accent.opacity(0.85), lineWidth: 2))
                        .overlay {
                            Label(split ? "Replace this side" : "Open in Split View", systemImage: "rectangle.split.2x1")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(.black.opacity(0.6)))
                        }
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .overlay {
                if state.draggingTab != nil {
                    PageDropCatcher(
                        side: { point in
                            point.x < (split ? width + gap / 2 : geo.size.width / 2) ? .leading : .trailing
                        },
                        hovered: $dropSide
                    )
                }
            }
            .animation(Motion.quick, value: dropSide)
        }
    }
}

enum PageDropSide { case leading, trailing }

/// Takes a tab dragged from the sidebar or tab strip over the page, VS Code style: dropped on
/// one half it opens there in a split (in place of that side, if there is a split already).
/// An AppKit view on purpose: the web view under it registers for dragged text itself, and
/// would otherwise take the drag (and type the tab's ID into the page).
private struct PageDropCatcher: NSViewRepresentable {
    @Environment(BrowserState.self) private var state
    let side: (CGPoint) -> PageDropSide
    @Binding var hovered: PageDropSide?

    func makeNSView(context: Context) -> PageDropView { PageDropView() }

    func updateNSView(_ view: PageDropView, context: Context) {
        let state = self.state
        let side = self.side
        let hovered = $hovered
        view.update = { point in
            guard let point, let tab = state.draggingTab, state.canPlace(tab) else {
                if hovered.wrappedValue != nil { hovered.wrappedValue = nil }
                return false
            }
            let new = side(point)
            if hovered.wrappedValue != new { hovered.wrappedValue = new }
            return true
        }
        view.drop = { point in
            hovered.wrappedValue = nil
            defer { endSidebarDrag(state) }
            guard let tab = state.draggingTab, state.canPlace(tab) else { return false }
            state.place(tab, leading: side(point) == .leading)
            return true
        }
        view.staleClick = {
            hovered.wrappedValue = nil
            endSidebarDrag(state)
        }
    }

    static func dismantleNSView(_ view: PageDropView, coordinator: ()) {
        view.update?(nil)
    }
}

final class PageDropView: NSView {
    /// The drag moved to this point (top-left origin), or left (nil). Returns whether it can drop.
    var update: ((CGPoint?) -> Bool)?
    var drop: ((CGPoint) -> Bool)?
    /// A click landed here: the drag that put this view up ended somewhere that didn't say so.
    var staleClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.string])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private func point(_ info: NSDraggingInfo) -> CGPoint { convert(info.draggingLocation, from: nil) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        update?(point(sender)) == true ? .move : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        update?(point(sender)) == true ? .move : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { _ = update?(nil) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { drop?(point(sender)) ?? false }

    override func mouseDown(with event: NSEvent) { staleClick?() }
}

/// The strip between the two sides of a split: drag to share out the width, double-click to
/// even it up again.
private struct SplitDivider: View {
    static let width: CGFloat = 10

    @Environment(BrowserState.self) private var state
    /// The width the two sides share.
    let available: CGFloat
    @State private var start: Double?
    @State private var hovering = false

    var body: some View {
        Capsule()
            .fill(.primary.opacity(hovering || start != nil ? 0.35 : 0))
            .frame(width: 3, height: 36)
            .frame(width: Self.width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        guard available > 0 else { return }
                        let base = start ?? state.visibleSplit?.fraction ?? 0.5
                        if start == nil { start = base }
                        state.setSplitFraction(base + Double(value.translation.width / available))
                    }
                    .onEnded { _ in
                        start = nil
                        state.scheduleSave()
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                withAnimation(Motion.snappy) { state.setSplitFraction(0.5) }
                state.scheduleSave()
            })
            .animation(Motion.quick, value: hovering)
            .help("Drag to resize · Double-click to make both sides the same width")
    }
}

/// Tint + sheen + grain, drawn over whatever blur the window has behind it.
struct WindowBackground: View {
    @Environment(AppSettings.self) private var settings
    let tint: Color
    /// The window's own theme (`BrowserState.theme`); nil for the app-wide one.
    var theme: Theme?

    var body: some View {
        let theme = theme ?? settings.theme
        ZStack {
            if theme.style == .vibrancy {
                VisualEffect(material: .underWindowBackground, blending: .behindWindow)
            }
            tint.opacity(theme.style.isOpaqueFill ? 1 : theme.tintOpacity)
            if theme.sheen > 0, theme.style != .seamless {
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.10 * theme.sheen), location: 0),
                        .init(color: .white.opacity(0.0), location: 0.45),
                        .init(color: .black.opacity(0.10 * theme.sheen), location: 1),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
            if theme.grain > 0, theme.style != .seamless {
                Image(nsImage: Grain.image)
                    .resizable(resizingMode: .tile)
                    .opacity(theme.grain * 0.5)
                    .blendMode(.overlay)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }
}

struct FloatingSidebarBackdrop: View {
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(tint)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 24, x: 6, y: 8)
    }
}

/// Invisible strip on the sidebar's edge that resizes it.
struct SidebarResizeHandle: View {
    @Environment(AppSettings.self) private var settings
    @State private var startWidth: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = startWidth ?? settings.general.sidebarWidth
                        if startWidth == nil { startWidth = base }
                        settings.general.sidebarWidth = max(200, min(420, base + value.translation.width))
                    }
                    .onEnded { _ in startWidth = nil }
            )
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol)
                .font(.system(size: 12, weight: .semibold))
            Text(toast.text)
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(.black.opacity(0.78)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }
}

// MARK: - Web card

struct WebCard: View {
    @Environment(BrowserState.self) private var state
    @Environment(AppSettings.self) private var settings
    @Environment(\.accent) private var accent
    let tab: Tab?
    /// The side with the keyboard: the find bar and screenshots act on it. Always, outside a split.
    var focused = true
    /// One of two pages side by side.
    var split = false

    var body: some View {
        let tab = self.tab
        let seamless = state.theme.style == .seamless
        let radius = seamless ? 0 : CGFloat(settings.theme.cardRadius)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        ZStack(alignment: .top) {
            if tab == nil {
                shape.fill(.primary.opacity(0.05))
                EmptyStateView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            WebStack(
                webView: (tab?.isAwake ?? false) ? tab?.webView : nil,
                radius: radius,
                animated: settings.animationsEnabled,
                focus: { [weak state] in state?.focusWebView() }
            )
            .opacity(tab == nil ? 0 : 1)

            // A PDF: Tuff's own viewer, over the (empty) page WebKit holds for it.
            if let tab, let pdf = tab.pdf {
                PDFViewerView(viewer: pdf)
                    .id(ObjectIdentifier(pdf))
                    .transition(.opacity)
            }

            // Reader mode: the article, over the page.
            if let tab, let reader = tab.reader {
                ReaderOverlay(reader: reader)
                    .id(ObjectIdentifier(reader))
                    .transition(.opacity)
            }

            if let tab {
                LinkPreview(tab: tab)
            }

            if state.findVisible, focused, let tab {
                Group {
                    if let pdf = tab.pdf, pdf.isReady {
                        PDFFindBar(viewer: pdf)
                            .id(ObjectIdentifier(pdf))
                            .padding(.top, PDFViewerView.toolbarHeight)
                    } else {
                        FindBar()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topTrailing)
                .padding(10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if focused, let progress = state.screenshotProgress {
                ScreenshotProgressOverlay(progress: progress)
                    .transition(.opacity)
                    .zIndex(3)
            }

            if focused, state.screenshotSelecting, tab != nil {
                ScreenshotAreaSelector()
                    .transition(.opacity)
                    .zIndex(3)
            }

            if let tab, let request = tab.permissionRequest {
                PermissionCard(tab: tab, request: request)
                    .id(request.id)
                    .padding(.top, 14)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .top)))
                    .zIndex(2)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.primary.opacity(seamless ? 0 : 0.08), lineWidth: 0.5).allowsHitTesting(false))
        // In a split, the side with the keyboard is outlined.
        .overlay(shape.strokeBorder(accent.opacity(split && focused ? 0.85 : 0), lineWidth: 2).allowsHitTesting(false))
        .animation(Motion.quick, value: split && focused)
        // Solid once a page is showing: the empty state is see-through.
        .modifier(CardShadow(cornerRadius: radius, opacity: 0.22, radius: 7, y: 2, solid: tab?.isAwake ?? false, enabled: !seamless))
        .animation(Motion.snappy, value: state.findVisible)
        .animation(Motion.snappy, value: tab?.permissionRequest?.id)
        .animation(Motion.quick, value: state.screenshotSelecting)
        // Switching tabs mid-selection would capture the wrong page.
        .onChange(of: tab?.id) { _, _ in if focused { state.screenshotSelecting = false } }
        .animation(settings.animationsEnabled ? Motion.quick : nil, value: tab?.pdf.map(ObjectIdentifier.init))
        .animation(settings.animationsEnabled ? Motion.quick : nil, value: tab?.reader.map(ObjectIdentifier.init))
    }
}

/// Hosts the selected tab's web view, cross-fading when the selection changes.
struct WebStack: NSViewRepresentable {
    let webView: WKWebView?
    let radius: CGFloat
    let animated: Bool
    /// Hands the keyboard to the page once it is showing (the window's own state does it).
    let focus: () -> Void

    func makeNSView(context: Context) -> WebStackView { WebStackView() }

    func updateNSView(_ view: WebStackView, context: Context) {
        view.layer?.cornerRadius = radius
        view.focus = focus
        view.show(webView, animated: animated)
    }
}

final class WebStackView: NSView {
    private weak var current: WKWebView?
    var focus: () -> Void = {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ webView: WKWebView?, animated: Bool) {
        // Showing already, unless something else has taken the web view into its own hierarchy.
        // Not when that is the other card of a split, though: when a split ends, the card going
        // away can still be asked to show its page while the remaining card has already taken
        // it, and taking it back would carry it out of the window.
        let takenBySibling = (webView?.superview as? WebStackView).map { $0 !== self && $0.window != nil } ?? false
        guard webView !== current || (webView != nil && webView?.superview !== self && !takenBySibling) else { return }
        let old = current
        current = webView

        guard let webView else {
            old?.removeFromSuperview()
            return
        }
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        webView.appearance = NSApp.effectiveAppearance
        let fade = animated && old != nil && window != nil
        webView.alphaValue = fade ? 0 : 1
        addSubview(webView, positioned: .above, relativeTo: nil)

        if fade {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                webView.animator().alphaValue = 1
            } completionHandler: { [weak self] in
                guard let self else { return }
                // Remove everything except what is showing now (the selection may have moved on).
                for sub in self.subviews where sub !== self.current { sub.removeFromSuperview() }
                self.current?.alphaValue = 1
            }
        } else {
            for sub in subviews where sub !== webView { sub.removeFromSuperview() }
        }
        focus()
    }
}

/// The address of the link under the mouse, in a small label at the bottom left of the page.
/// Reads the tab's hovered link itself, so mouse moves over links re-render only this label.
struct LinkPreview: View {
    let tab: Tab
    @State private var shown: URL?

    var body: some View {
        let link = tab.hoveredLink
        VStack {
            Spacer(minLength: 0)
            if let shown {
                Text(Self.display(shown))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                    )
                    .frame(maxWidth: 520, alignment: .leading)
                    .padding(6)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(false)
        .onChange(of: link) { _, new in
            if new != nil {
                // Moving between links swaps the text without fading.
                if shown == nil { withAnimation(.easeOut(duration: 0.12)) { shown = new } } else { shown = new }
            } else {
                // A short grace period, so sliding across the gap between two links doesn't flicker.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    if tab.hoveredLink == nil { withAnimation(.easeOut(duration: 0.18)) { shown = nil } }
                }
            }
        }
        .onChange(of: tab.id) { _, _ in shown = tab.hoveredLink }
    }

    /// The URL as people read it: percent escapes decoded, no trailing slash on a bare host.
    static func display(_ url: URL) -> String {
        var text = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        if url.path == "/" || url.path.isEmpty, url.query == nil, url.fragment == nil, text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

struct EmptyStateView: View {
    @Environment(BrowserState.self) private var state
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: state.currentSpace.icon)
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.16))
                .scaleEffect(appeared ? 1 : 0.86)

            Text(state.currentSpace.name)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.42))

            Button {
                state.openCommandBar(.newTab)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Search or enter address")
                        .font(.system(size: 13, weight: .medium))
                    Text("⌘T")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.primary.opacity(0.1)))
                }
                .foregroundStyle(.primary.opacity(0.6))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(.primary.opacity(0.08)))
                .contentShape(Capsule())
            }
            .buttonStyle(SquishButtonStyle(scale: 0.97))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { appeared = true }
        }
    }
}

// MARK: - Find in page

struct FindBar: View {
    @Environment(BrowserState.self) private var state

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            KeyTextField(
                text: $state.findQuery, placeholder: "Find in page", fontSize: 13,
                selectAllOnFocus: true,
                identifier: BrowserState.findFieldIdentifier,
                onSubmit: { state.find(forward: !NSEvent.modifierFlags.contains(.shift)) },
                onCancel: { state.closeFind() }
            )
            .frame(width: 180, height: 20)
            if !state.findQuery.isEmpty, let status = statusText {
                Text(status)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .transition(.opacity)
            }
            IconButton(symbol: "chevron.up", size: 11, side: 24, help: "Previous  ⇧⌘G") { state.find(forward: false) }
            IconButton(symbol: "chevron.down", size: 11, side: 24, help: "Next  ⌘G") { state.find(forward: true) }
            IconButton(symbol: "xmark", size: 10, side: 24, help: "Done") { state.closeFind() }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .modifier(CardShadow(cornerRadius: 12, opacity: 0.2, radius: 10, y: 3, hollow: true))
        .onChange(of: state.findQuery) { _, _ in
            state.findStatus = .idle
            state.find(forward: true)
        }
        // A query left from before searches the page now showing.
        .onAppear { if !state.findQuery.isEmpty { state.find(forward: true) } }
    }

    private var statusText: String? {
        switch state.findStatus {
        case .idle: nil
        case .notFound: "No matches"
        case .found(let index, let total): total < 0 ? nil : "\(index + 1) of \(total)"
        }
    }
}

// MARK: - Text field with keyboard hooks

/// An `NSTextField` wrapper: SwiftUI's `TextField` gives no reliable access to ↑ / ↓ / Esc,
/// which the command bar and find bar need.
struct KeyTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var fontSize: CGFloat = 15
    var fontWeight: NSFont.Weight = .regular
    var selectAllOnFocus = false
    /// Hides what is typed (passwords).
    var secure = false
    /// Takes keyboard focus when it appears. Only one field in a form should.
    var autoFocus = true
    /// Lets a form find the field to move focus to it.
    var identifier: String?
    var alignment: NSTextAlignment = .natural
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onTab: (() -> Void)?
    /// ⌫ with the caret at the very start and nothing selected (removes the bang chip).
    var onDeleteAtStart: (() -> Void)?
    /// Shown after the typed text, selected, so typing on replaces it and ↩ takes it (the
    /// command bar's inline completion: "git" → "git" + "hub.com"). Not part of `text`.
    var completionSuffix: String?
    /// ⌫ / ⌦ was pressed (before the field deletes anything).
    var onDelete: (() -> Void)?
    /// ⇧⌫; return true if it was handled (the command bar removes a history suggestion).
    var onShiftDelete: (() -> Bool)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = secure ? NSSecureTextField() : NSTextField()
        if let identifier { field.identifier = NSUserInterfaceItemIdentifier(identifier) }
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.stringValue = text
        field.font = .systemFont(ofSize: fontSize, weight: fontWeight)
        field.alignment = alignment
        setPlaceholder(on: field)
        if autoFocus { Self.focus(field, selectAll: selectAllOnFocus, triesLeft: 5) }
        return field
    }

    /// Takes keyboard focus on the next turn of the run loop. The field may not be in its
    /// window yet then (SwiftUI inserts it while animating), so it tries a few more turns
    /// rather than giving up and leaving focus wherever it was.
    private static func focus(_ field: NSTextField, selectAll: Bool, triesLeft: Int) {
        DispatchQueue.main.async { [weak field] in
            guard let field else { return }
            guard let window = field.window, window.makeFirstResponder(field) else {
                if triesLeft > 0 { focus(field, selectAll: selectAll, triesLeft: triesLeft - 1) }
                return
            }
            if let editor = field.currentEditor() {
                editor.selectedRange = selectAll
                    ? NSRange(location: 0, length: field.stringValue.count)
                    : NSRange(location: field.stringValue.count, length: 0)
            }
        }
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        let shown = text + (completionSuffix ?? "")
        if field.stringValue != shown {
            field.stringValue = shown
            // Replacing the text while typing would select all of it; keep the caret after what
            // was typed, with any completion after it selected.
            if let editor = field.currentEditor() {
                let typed = (text as NSString).length
                editor.selectedRange = NSRange(location: typed, length: (shown as NSString).length - typed)
            }
        }
        if field.placeholderAttributedString?.string != placeholder { setPlaceholder(on: field) }
    }

    /// Attributed, so a secure field's placeholder is grey like the others.
    private func setPlaceholder(on field: NSTextField) {
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: field.font ?? .systemFont(ofSize: fontSize),
        ])
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: KeyTextField
        init(_ parent: KeyTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.moveUp(_:)):
                guard let handler = parent.onMoveUp else { return false }
                handler()
                return true
            case #selector(NSResponder.moveDown(_:)):
                guard let handler = parent.onMoveDown else { return false }
                handler()
                return true
            case #selector(NSResponder.insertTab(_:)):
                guard let handler = parent.onTab else { return false }
                handler()
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                if NSEvent.modifierFlags.contains(.shift), let handler = parent.onShiftDelete, handler() { return true }
                parent.onDelete?()
                guard let handler = parent.onDeleteAtStart, textView.selectedRange() == NSRange(location: 0, length: 0) else { return false }
                handler()
                return true
            case #selector(NSResponder.deleteForward(_:)):
                parent.onDelete?()
                return false
            default:
                return false
            }
        }
    }
}
