import AppKit
import SwiftUI

/// "example.com is full screen — Press Esc to exit", shown for a few seconds when a page takes
/// the screen (a video's full-screen button, the Fullscreen API), as Chrome and Safari do.
///
/// WebKit moves the web view into a full-screen window of its own, so nothing drawn in the
/// browser window would be seen. The banner is a small click-through panel that floats over
/// that window on the same screen.
/// Main thread only, like the rest of the window code.
final class FullScreenBanner {
    static let shared = FullScreenBanner()

    /// How long the banner stays before fading.
    static let duration: TimeInterval = 3.5

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    /// The tab the banner is about, so a tab leaving full screen only hides its own banner.
    private weak var tab: Tab?

    func show(for tab: Tab, site: String, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        self.tab = tab
        let host = NSHostingView(rootView: FullScreenBannerView(site: site))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height - 28,
            width: size.width, height: size.height
        )
        let panel = self.panel ?? makePanel()
        panel.contentView = host
        panel.setFrame(frame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: work)
    }

    /// Hides the banner (all of them, or only if it is about `tab`).
    func hide(for tab: Tab? = nil) {
        if let tab, tab !== self.tab { return }
        hideWork?.cancel()
        hideWork = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: {
            DispatchQueue.main.async { if panel.alphaValue == 0 { panel.orderOut(nil) } }
        })
    }

    #if DEBUG
    /// For the debug script's `fsbanner`.
    var debugState: String {
        guard let panel else { return "none" }
        let text = (panel.contentView as? NSHostingView<FullScreenBannerView>).map { _ in "banner" } ?? "?"
        return "\(text) visible=\(panel.isVisible) alpha=\(panel.alphaValue) frame=\(panel.frame) screen=\(panel.screen?.frame ?? .zero) onActiveSpace=\(panel.isOnActiveSpace)"
    }
    #endif

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Over the page's full-screen window, in its own Space.
        panel.level = .popUpMenu
        panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .stationary, .ignoresCycle]
        return panel
    }
}

struct FullScreenBannerView: View {
    let site: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .semibold))
            Text("\(site) is full screen")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 5) {
                Text("Press")
                KeyHint("esc", color: .white)
                Text("to exit")
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.75))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(Capsule().fill(.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .fixedSize()
    }
}
