import AppKit
import SwiftUI
import WebKit

enum ScreenshotMode: String, CaseIterable, Identifiable {
    case area, visible, fullPage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .area: "Area"
        case .visible: "Visible"
        case .fullPage: "Full Page"
        }
    }

    var subtitle: String {
        switch self {
        case .area: "Drag to select part of the page"
        case .visible: "What’s on screen right now"
        case .fullPage: "The whole page, top to bottom"
        }
    }
}

/// Captures the selected tab's page and opens the result in the screenshot editor.
enum Screenshotter {
    /// Tallest full-page capture, in page points. Past this the image gets unwieldy (a 2× bitmap
    /// of it is already ~200 MB) and the capture takes a long time.
    static let maxFullPageHeight: CGFloat = 12_000

    /// Begins a capture: an area capture first asks for the area, the others snap straight away.
    static func start(_ mode: ScreenshotMode, in state: BrowserState) {
        guard let tab = state.selectedTab, tab.isAwake, tab.pdf == nil, let webView = tab.webView else {
            state.show(Toast(symbol: "camera", text: "Nothing to capture on this page"))
            return
        }
        switch mode {
        case .area:
            withAnimation(Motion.quick) { state.screenshotSelecting = true }
        case .visible:
            snap(webView, rect: nil, mode: mode, tab: tab, state: state)
        case .fullPage:
            fullPage(webView, tab: tab, state: state)
        }
    }

    /// The whole page. `takeSnapshot` only paints what's in the viewport, so the page is scrolled
    /// a screen at a time and the pieces stitched together (as browsers' own full-page captures
    /// do). Fixed and sticky bits (headers, cookie bars) are hidden after the first screen so
    /// they don't repeat down the image; everything is put back afterwards.
    static func fullPage(_ webView: WKWebView, tab: Tab, state: BrowserState) {
        guard state.screenshotProgress == nil else { return }
        withAnimation(Motion.quick) { state.screenshotProgress = 0 }
        Task { @MainActor in
            let result = await stitch(webView, tab: tab, state: state)
            _ = await js(webView, restoreJS)
            withAnimation(Motion.quick) { state.screenshotProgress = nil }
            guard let (image, size) = result else {
                state.show(Toast(symbol: "exclamationmark.triangle", text: "Couldn’t capture the page"))
                return
            }
            let session = ScreenshotSession(
                image: image, pointSize: size, mode: .fullPage,
                title: tab.displayTitle, accent: state.currentTint.derivedAccent
            )
            withAnimation(Motion.snappy) { state.screenshot = session }
        }
    }

    /// Remembers the scroll position, turns off smooth scrolling, and reports
    /// [page height, viewport height] in CSS pixels.
    private static let setupJS = """
    (() => { const d = document.documentElement, b = document.body;
      window.__tuffShot = { x: scrollX, y: scrollY, behavior: d.style.scrollBehavior, hidden: [] };
      d.style.scrollBehavior = 'auto';
      return [Math.max(d.scrollHeight, b ? b.scrollHeight : 0, innerHeight), innerHeight]; })()
    """

    private static let hideFixedJS = """
    (() => { const s = window.__tuffShot; if (!s || s.hid) return 0; s.hid = true;
      for (const el of document.querySelectorAll('body *')) {
        const p = getComputedStyle(el).position;
        if (p === 'fixed' || p === 'sticky') {
          s.hidden.push([el, el.style.getPropertyValue('visibility'), el.style.getPropertyPriority('visibility')]);
          el.style.setProperty('visibility', 'hidden', 'important');
        }
      }
      return s.hidden.length; })()
    """

    private static let restoreJS = """
    (() => { const s = window.__tuffShot; if (!s) return 0;
      for (const [el, v, p] of s.hidden) { if (v) el.style.setProperty('visibility', v, p); else el.style.removeProperty('visibility'); }
      document.documentElement.style.scrollBehavior = s.behavior;
      window.scrollTo(s.x, s.y);
      delete window.__tuffShot; return 1; })()
    """

    @MainActor
    private static func stitch(_ webView: WKWebView, tab: Tab, state: BrowserState) async -> (CGImage, CGSize)? {
        guard let setup = await js(webView, setupJS) as? [NSNumber], setup.count == 2 else { return nil }
        // View points per CSS pixel.
        let zoom = webView.pageZoom * webView.magnification
        let pageHeight = CGFloat(truncating: setup[0]), viewport = CGFloat(truncating: setup[1])
        let width = webView.bounds.width, viewHeight = webView.bounds.height
        let total = min(max(pageHeight * zoom, viewHeight), maxFullPageHeight)
        var context: CGContext?
        var contextScale: CGFloat = 1
        var offset: CGFloat = 0
        var first = true

        while true {
            // Switching tabs or closing the editor's page mid-capture: give up.
            guard state.selectedTab === tab, tab.webView === webView else { return nil }
            let scrolled = (await js(webView, "window.scrollTo(0, \(offset)); window.scrollY") as? NSNumber).map { CGFloat(truncating: $0) } ?? offset
            if !first { _ = await js(webView, hideFixedJS) }
            // A moment for lazy images and scroll-triggered layout to settle.
            try? await Task.sleep(nanoseconds: first ? 40_000_000 : 110_000_000)
            guard let shot = await snapshot(webView) else { return nil }

            if context == nil {
                // Retina like the screen, unless that would make an enormous bitmap.
                let screenScale = CGFloat(shot.width) / max(width, 1)
                contextScale = min(screenScale, (60_000_000 / max(width * total, 1)).squareRoot())
                context = CGContext(
                    data: nil, width: Int(width * contextScale), height: Int(total * contextScale),
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
                context?.interpolationQuality = .high
            }
            guard let context else { return nil }
            // Bitmap space runs bottom-up.
            let top = scrolled * zoom
            context.draw(shot, in: CGRect(
                x: 0, y: (total - top - viewHeight) * contextScale,
                width: width * contextScale, height: viewHeight * contextScale
            ))
            state.screenshotProgress = min(1, (top + viewHeight) / total)
            first = false

            let reachedEnd = top + viewHeight >= total - 0.5
            // The page wouldn't scroll as far as asked: that was the bottom.
            let clamped = scrolled + 0.5 < offset
            if reachedEnd || clamped { break }
            offset = scrolled + viewport
        }
        guard let image = context?.makeImage() else { return nil }
        return (image, CGSize(width: width, height: total))
    }

    @MainActor
    private static func js(_ webView: WKWebView, _ source: String) async -> Any? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(source) { result, _ in continuation.resume(returning: result) }
        }
    }

    @MainActor
    private static func snapshot(_ webView: WKWebView) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            webView.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
    }

    /// Captures `rect` (view coordinates; the whole view when nil) of the page.
    static func snap(_ webView: WKWebView, rect: CGRect?, mode: ScreenshotMode, tab: Tab, state: BrowserState) {
        let configuration = WKSnapshotConfiguration()
        if let rect { configuration.rect = rect }
        configuration.afterScreenUpdates = true
        webView.takeSnapshot(with: configuration) { image, error in
            guard let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                state.show(Toast(symbol: "exclamationmark.triangle", text: "Couldn’t capture the page"))
                return
            }
            let session = ScreenshotSession(
                image: cgImage, pointSize: image.size, mode: mode,
                title: tab.displayTitle, accent: state.currentTint.derivedAccent
            )
            withAnimation(Motion.snappy) { state.screenshot = session }
        }
    }
}

// MARK: - Area selection

/// Covers the page while an area is dragged out for a screenshot. Esc or a click without a drag
/// cancels.
struct ScreenshotAreaSelector: View {
    @Environment(BrowserState.self) private var state
    @Environment(\.accent) private var accent
    @State private var start: CGPoint?
    @State private var current: CGPoint?
    @State private var hoveringBar = false

    private var selection: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(
            x: min(start.x, current.x), y: min(start.y, current.y),
            width: abs(current.x - start.x), height: abs(current.y - start.y)
        )
    }

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            let rect = selection?.intersection(bounds)
            ZStack(alignment: .topLeading) {
                // Dim everything but the selection.
                Path { path in
                    path.addRect(bounds)
                    if let rect, !rect.isEmpty { path.addRect(rect) }
                }
                .fill(Color.black.opacity(0.42), style: FillStyle(eoFill: true))

                if let rect, !rect.isEmpty {
                    Rectangle()
                        .strokeBorder(.white.opacity(0.95), lineWidth: 1.5)
                        .overlay(Rectangle().strokeBorder(accent.opacity(0.9), lineWidth: 0.5).padding(1.5))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)

                    Text("\(Int(rect.width)) × \(Int(rect.height))")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(Capsule().fill(.black.opacity(0.7)))
                        .fixedSize()
                        .offset(x: rect.minX, y: rect.maxY + 26 > geo.size.height ? rect.minY - 26 : rect.maxY + 6)
                }

                Color.clear
                    .contentShape(Rectangle())
                    .pointerStyle(.rectSelection)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if start == nil { start = value.startLocation }
                                current = value.location
                            }
                            .onEnded { _ in finish(in: bounds) }
                    )
            }
            .overlay(alignment: .top) {
                if start == nil { hint.padding(.top, 16).transition(.opacity.combined(with: .move(edge: .top))) }
            }
            .animation(Motion.quick, value: start == nil)
        }
        .background {
            // Esc cancels.
            Button("") { cancel() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var hint: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 12, weight: .semibold))
            Text("Drag to select an area")
                .font(.system(size: 12.5, weight: .semibold))
            Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 14)
            ForEach([ScreenshotMode.visible, .fullPage]) { mode in
                Button(mode.title) {
                    state.screenshotSelecting = false
                    Screenshotter.start(mode, in: state)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            }
            Button { cancel() } label: {
                HStack(spacing: 6) {
                    Text("Cancel")
                    KeyHint("esc", color: .white)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.75))
        }
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 34)
        .background(Capsule().fill(.black.opacity(0.86)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
    }

    private func finish(in bounds: CGRect) {
        defer { start = nil; current = nil }
        guard let rect = selection?.intersection(bounds), rect.width >= 4, rect.height >= 4 else {
            cancel()
            return
        }
        state.screenshotSelecting = false
        guard let tab = state.selectedTab, let webView = tab.webView else { return }
        Screenshotter.snap(webView, rect: rect.integral, mode: .area, tab: tab, state: state)
    }

    private func cancel() {
        withAnimation(Motion.quick) { state.screenshotSelecting = false }
    }
}

/// Shown over the page while a full-page capture scrolls through it. It also keeps clicks and
/// scrolls off the page until it's done.
struct ScreenshotProgressOverlay: View {
    let progress: Double

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .contentShape(Rectangle())
                .onTapGesture {}
            HStack(spacing: 10) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("Capturing full page")
                    .font(.system(size: 12.5, weight: .semibold))
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule().fill(.white).frame(width: 70 * max(0.04, progress))
                }
                .frame(width: 70, height: 4)
                .animation(.easeOut(duration: 0.2), value: progress)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Capsule().fill(.black.opacity(0.86)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .padding(.top, 16)
        }
    }
}
