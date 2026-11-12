import AppKit
import Observation
import SwiftUI
import WebKit

final class BrowserWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns the single browser window: transparent chrome, background blur, traffic-light
/// placement, and the event monitors that drive space swiping and sidebar peeking.
final class BrowserWindowController: NSObject {
    let window: BrowserWindow
    private let state: BrowserState
    private let settings = AppSettings.shared
    private var hostingView: NSHostingView<AnyView>!
    private var monitors: [Any] = []
    private var appearanceObservation: NSKeyValueObservation?

    /// Height of the sidebar's top control row; the traffic lights are centred in it.
    static let topBarHeight: CGFloat = 40
    /// Gap between the window edge and the sidebar when it floats over the page (peeking).
    static let floatingSidebarMargin: CGFloat = 6
    /// Leading inset of the close button when the sidebar is docked.
    private static let trafficLightInset: CGFloat = 13

    // Swipe tracking
    private enum Axis { case undecided, horizontal, vertical }
    private var axis: Axis = .undecided
    private var tracking = false
    private var accumulated = CGPoint.zero
    private var lastDeltaX: CGFloat = 0
    private var swallowMomentum = false
    private var layingOutTrafficLights = false

    init(state: BrowserState) {
        self.state = state
        let frame = NSRect(x: 0, y: 0, width: 1320, height: 860)
        window = BrowserWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        super.init()

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.minSize = NSSize(width: 560, height: 420)
        window.tabbingMode = .disallowed
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        window.title = "Tuff"

        let root = RootView()
            .environment(state)
            .environment(settings)
            .environment(ExtensionManager.shared)
            .environment(DownloadManager.shared)
        hostingView = NSHostingView(rootView: AnyView(root))
        hostingView.sizingOptions = []
        hostingView.safeAreaRegions = []
        window.contentView = hostingView

        window.center()
        window.setFrameAutosaveName("TuffBrowserWindow")
        state.window = window

        // AppKit puts the traffic lights back whenever it re-lays out the title bar (title
        // changes, key state, resizes…). Watch for that and re-centre them.
        if let close = window.standardWindowButton(.closeButton) {
            close.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(trafficLightsMoved), name: NSView.frameDidChangeNotification, object: close
            )
        }

        installMonitors()
        observeModel()
        applyTheme()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyWebAppearance() }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        monitors.forEach { NSEvent.removeMonitor($0) }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        layoutTrafficLights()
        state.updateWindowTitle()
        state.focusWebView()
    }

    // MARK: Theme

    /// Re-applies window-level effects whenever something they depend on changes.
    private func observeModel() {
        withObservationTracking {
            _ = settings.theme
            _ = state.sidebarVisible
            _ = state.sidebarPeeking
            _ = state.isFullscreen
            _ = state.currentSpaceIndex
            _ = state.spaces.map(\.colorHex)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.applyTheme()
                self?.layoutTrafficLights()
                self?.observeModel()
            }
        }
    }

    private func applyTheme() {
        let theme = settings.theme
        WindowBlur.setRadius(theme.style == .glass ? theme.blurRadius : 0, for: window)

        let tint = theme.useSpaceColors && !state.spaces.isEmpty ? state.currentSpace.color : NSColor(hex: theme.tintHex)
        let dark = settings.chromeScheme(for: tint) == .dark
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if hostingView.appearance?.name != appearance?.name { hostingView.appearance = appearance }
        applyWebAppearance()
        window.invalidateShadow()
    }

    /// The chrome follows the tint, but web pages should follow the system's light / dark setting.
    private func applyWebAppearance() {
        let system = NSApp.effectiveAppearance
        for tab in state.allTabs {
            tab.webView?.appearance = system
        }
    }

    // MARK: Traffic lights

    /// Centres the close / minimise / zoom buttons in the sidebar's top row, and hides them
    /// along with the sidebar.
    func layoutTrafficLights() {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap {
            window.standardWindowButton($0)
        }
        guard buttons.count == 3, let titlebar = buttons[0].superview, let container = titlebar.superview else { return }

        let visible = state.sidebarVisible || state.sidebarPeeking
        let alpha: CGFloat = visible ? 1 : 0
        if container.alphaValue != alpha {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                container.animator().alphaValue = alpha
            }
        }
        guard !window.styleMask.contains(.fullScreen) else { return }

        // A floating sidebar is inset from the window edges, so its top row (and the buttons
        // centred in it) sits `margin` lower and further right than the docked one.
        let margin = state.sidebarVisible ? 0 : Self.floatingSidebarMargin
        let height = Self.topBarHeight
        var frame = container.frame
        frame.size.height = height + margin
        frame.origin.y = window.frame.height - frame.size.height
        if container.frame != frame { container.frame = frame }

        let spacing = buttons[1].frame.minX - buttons[0].frame.minX
        let buttonHeight = buttons[0].frame.height
        let inset = Self.trafficLightInset + margin
        for (i, button) in buttons.enumerated() {
            let origin = NSPoint(x: inset + CGFloat(i) * spacing, y: ((height - buttonHeight) / 2).rounded())
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }

    @objc private func trafficLightsMoved() {
        guard !layingOutTrafficLights else { return }
        layingOutTrafficLights = true
        layoutTrafficLights()
        layingOutTrafficLights = false
    }

    // MARK: Event monitors

    private func installMonitors() {
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] in self?.handleScroll($0) ?? $0 }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            self?.handleMouseMoved(event)
            return event
        }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] in self?.handleKeyDown($0) ?? $0 }) {
            monitors.append(m)
        }
    }

    private var sidebarWidth: CGFloat { CGFloat(settings.general.sidebarWidth) }

    private func isOverSidebar(_ event: NSEvent) -> Bool {
        guard event.window === window, state.sidebarVisible || state.sidebarPeeking else { return false }
        return event.locationInWindow.x <= sidebarWidth
    }

    /// Two-finger horizontal swipes over the sidebar page between spaces, tracking the fingers.
    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        if swallowMomentum {
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                swallowMomentum = false
                return nil
            }
            if event.momentumPhase != [] { return nil }
            swallowMomentum = false
        }

        if event.phase == .began || event.phase == .mayBegin {
            axis = .undecided
            accumulated = .zero
            lastDeltaX = 0
            tracking = isOverSidebar(event) && state.commandBar == nil && state.spaces.count > 0
        }
        guard tracking else { return event }

        if event.phase == .began || event.phase == .changed {
            if axis == .undecided {
                accumulated.x += event.scrollingDeltaX
                accumulated.y += event.scrollingDeltaY
                if max(abs(accumulated.x), abs(accumulated.y)) > 3 {
                    axis = abs(accumulated.x) > abs(accumulated.y) * 1.2 ? .horizontal : .vertical
                    if axis == .horizontal {
                        state.updateSwipe(deltaX: accumulated.x, width: sidebarWidth)
                        return nil
                    }
                }
                return event
            }
            if axis == .horizontal {
                lastDeltaX = event.scrollingDeltaX
                state.updateSwipe(deltaX: event.scrollingDeltaX, width: sidebarWidth)
                return nil
            }
            return event
        }

        if event.phase == .ended || event.phase == .cancelled {
            tracking = false
            if axis == .horizontal {
                axis = .undecided
                swallowMomentum = true
                state.endSwipe(velocityX: lastDeltaX)
                return nil
            }
        }
        return event
    }

    /// With the sidebar collapsed, touching the window's left edge floats it over the page.
    private func handleMouseMoved(_ event: NSEvent) {
        guard !state.sidebarVisible, event.window === window, state.commandBar == nil else { return }
        let x = event.locationInWindow.x
        if !state.sidebarPeeking, x <= 5, settings.behavior.peekSidebarOnEdge {
            state.setPeeking(true)
        } else if state.sidebarPeeking, x > sidebarWidth + 28, state.editingSpaceID == nil, !state.downloadsVisible {
            state.setPeeking(false)
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else { return event }
        if event.keyCode == 53, state.commandBar == nil, state.findVisible { // Esc
            state.findVisible = false
            state.focusWebView()
            return nil
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !flags.intersection([.command, .control, .option]).isEmpty, ExtensionManager.shared.handleKeyEvent(event) {
            return nil
        }
        return event
    }
}

extension BrowserWindowController: NSWindowDelegate {
    func windowDidResize(_ notification: Notification) { layoutTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { layoutTrafficLights() }
    func windowDidBecomeMain(_ notification: Notification) {
        layoutTrafficLights()
        ExtensionManager.shared.controller.didFocusWindow(ExtensionManager.shared.windowAdapter)
    }

    func windowWillEnterFullScreen(_ notification: Notification) { state.isFullscreen = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        state.isFullscreen = false
        layoutTrafficLights()
    }

    func windowDidEndLiveResize(_ notification: Notification) { layoutTrafficLights() }
}

/// Adjustable blur of whatever is behind the window.
///
/// AppKit only exposes fixed "materials"; the window server has had a per-window blur radius
/// for a long time (terminals use it), so we look it up at runtime and fall back gracefully.
enum WindowBlur {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias SetBlurFn = @convention(c) (Int32, Int32, Int32) -> Int32

    private static let handle = dlopen(nil, RTLD_NOW)
    private static let connection: ConnectionFn? = {
        guard let symbol = dlsym(handle, "CGSMainConnectionID") else { return nil }
        return unsafeBitCast(symbol, to: ConnectionFn.self)
    }()

    private static let setBlur: SetBlurFn? = {
        guard let symbol = dlsym(handle, "CGSSetWindowBackgroundBlurRadius") else { return nil }
        return unsafeBitCast(symbol, to: SetBlurFn.self)
    }()

    static var isAvailable: Bool { connection != nil && setBlur != nil }

    static func setRadius(_ radius: Double, for window: NSWindow) {
        guard let connection, let setBlur, window.windowNumber > 0 else { return }
        _ = setBlur(connection(), Int32(window.windowNumber), Int32(max(0, min(100, radius.rounded()))))
    }
}
