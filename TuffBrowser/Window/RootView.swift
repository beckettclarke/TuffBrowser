import SwiftUI
import WebKit

/// The whole window: tinted glass background, sidebar, the rounded web "card", and overlays.
struct RootView: View {
    @Environment(BrowserState.self) private var state
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let theme = settings.theme
        let width = CGFloat(settings.general.sidebarWidth)
        let inset = CGFloat(theme.cardInset)
        let docked = state.sidebarVisible
        let shown = docked || state.sidebarPeeking
        let panels = SidePanelManager.shared

        ZStack(alignment: .topLeading) {
            WindowBackground(tint: Color(nsColor: state.currentTint))

            HStack(spacing: max(inset, 6)) {
                WebCard()
                if let id = panels.openID, let host = panels.host {
                    SidePanelCard(id: id, webView: host.webView)
                        .frame(width: CGFloat(settings.general.sidePanelWidth))
                        .overlay(alignment: .leading) {
                            SidePanelResizeHandle().offset(x: -max(inset, 6) / 2 - 4)
                        }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.leading, docked ? width : inset)
            .padding([.top, .bottom, .trailing], inset)
            .animation(settings.animationsEnabled ? Motion.snappy : nil, value: panels.isShowing)

            SidebarView()
                .frame(width: width)
                .background {
                    if !docked { FloatingSidebarBackdrop(tint: Color(nsColor: state.currentTint)) }
                }
                .padding(docked ? 0 : BrowserWindowController.floatingSidebarMargin)
                .offset(x: shown ? 0 : -(width + 40))
                .opacity(shown ? 1 : 0)

            if docked {
                SidebarResizeHandle()
                    .offset(x: width - 4)
            }

            if let mode = state.commandBar {
                CommandBarOverlay(mode: mode)
                    .transition(.opacity)
                    .zIndex(10)
            }

            if let toast = state.toast {
                ToastView(toast: toast)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, inset + 14)
                    .padding(.leading, docked ? width : 0)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(11)
                    .allowsHitTesting(false)
            }

            if let prompt = state.prompt, prompt.host == .browser {
                PromptOverlay(prompt: prompt)
                    .id(prompt.id)
                    .transition(.opacity)
                    .zIndex(12)
            }
        }
        .environment(\.accent, Color(nsColor: state.currentTint.derivedAccent))
        .ignoresSafeArea()
    }
}

/// Tint + sheen + grain, drawn over whatever blur the window has behind it.
struct WindowBackground: View {
    @Environment(AppSettings.self) private var settings
    let tint: Color

    var body: some View {
        let theme = settings.theme
        ZStack {
            if theme.style == .vibrancy {
                VisualEffect(material: .underWindowBackground, blending: .behindWindow)
            }
            tint.opacity(theme.style == .solid ? 1 : theme.tintOpacity)
            if theme.sheen > 0 {
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.10 * theme.sheen), location: 0),
                        .init(color: .white.opacity(0.0), location: 0.45),
                        .init(color: .black.opacity(0.10 * theme.sheen), location: 1),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
            if theme.grain > 0 {
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
    #if DEBUG
    private var benchNoBar: Bool { DebugHooks.bench("nobar") }
    #else
    private var benchNoBar: Bool { false }
    #endif

    var body: some View {
        let tab = state.selectedTab
        let radius = CGFloat(settings.theme.cardRadius)
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
                animated: settings.animationsEnabled
            )
            .opacity(tab == nil ? 0 : 1)

            if let tab, !benchNoBar {
                LoadingBar(progress: tab.progress, loading: tab.isLoading)
            }

            if state.findVisible, tab != nil {
                FindBar()
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .padding(10)
                    .transition(.move(edge: .top).combined(with: .opacity))
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
        .overlay(shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.22), radius: 7, y: 2)
        .animation(Motion.snappy, value: state.findVisible)
        .animation(Motion.snappy, value: tab?.permissionRequest?.id)
    }
}

/// Hosts the selected tab's web view, cross-fading when the selection changes.
struct WebStack: NSViewRepresentable {
    let webView: WKWebView?
    let radius: CGFloat
    let animated: Bool

    func makeNSView(context: Context) -> WebStackView { WebStackView() }

    func updateNSView(_ view: WebStackView, context: Context) {
        view.layer?.cornerRadius = radius
        view.show(webView, animated: animated)
    }
}

final class WebStackView: NSView {
    private weak var current: WKWebView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ webView: WKWebView?, animated: Bool) {
        guard webView !== current else { return }
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
        BrowserState.shared.focusWebView()
    }
}

struct LoadingBar: View {
    @Environment(\.accent) private var accent
    let progress: Double
    let loading: Bool

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [accent.opacity(0.55), accent],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(width: max(0, geo.size.width * (loading ? max(0.08, progress) : 1)), height: 2.5)
                .opacity(loading ? 1 : 0)
                .animation(.easeOut(duration: loading ? 0.25 : 0.45), value: progress)
                .animation(.easeOut(duration: 0.35).delay(loading ? 0 : 0.15), value: loading)
        }
        .frame(height: 2.5)
        .allowsHitTesting(false)
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
    @State private var query = ""
    @State private var notFound = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            KeyTextField(
                text: $query, placeholder: "Find in page", fontSize: 13,
                onSubmit: { find(forward: !NSEvent.modifierFlags.contains(.shift)) },
                onCancel: { close() }
            )
            .frame(width: 180, height: 20)
            if notFound, !query.isEmpty {
                Text("No matches")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            IconButton(symbol: "chevron.up", size: 11, side: 24, help: "Previous") { find(forward: false) }
            IconButton(symbol: "chevron.down", size: 11, side: 24, help: "Next") { find(forward: true) }
            IconButton(symbol: "xmark", size: 10, side: 24, help: "Done") { close() }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
        .onChange(of: query) { _, _ in find(forward: true) }
    }

    private func find(forward: Bool) {
        guard let webView = state.selectedTab?.webView, !query.isEmpty else {
            notFound = false
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.wraps = true
        configuration.caseSensitive = false
        webView.find(query, configuration: configuration) { result in
            withAnimation(Motion.quick) { notFound = !result.matchFound }
        }
    }

    private func close() {
        state.selectedTab?.webView?.evaluateJavaScript("window.getSelection().removeAllRanges()", completionHandler: nil)
        state.findVisible = false
        state.focusWebView()
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
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onTab: (() -> Void)?

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
        setPlaceholder(on: field)
        let selectAll = selectAllOnFocus
        if autoFocus { DispatchQueue.main.async {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
            if let editor = field.currentEditor() {
                editor.selectedRange = selectAll
                    ? NSRange(location: 0, length: field.stringValue.count)
                    : NSRange(location: field.stringValue.count, length: 0)
            }
        } }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
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
            default:
                return false
            }
        }
    }
}
