#if DEBUG
import AppKit
import QuartzCore

/// Debug-build measurement tools, driven by `DebugHooks` commands (`hitch`, `layers`,
/// `swipeanim`). Nothing here is compiled into release builds.
///
///     hitch start            begin timing main-thread frames
///     hitch stop <label>     log frame statistics since `hitch start`
///     layers <path>          write the window's layer tree, flagging what costs an offscreen pass
///     swipeanim <pages> <s>  drive the space pager like a two-finger swipe, one step per frame
enum PerfProbe {
    private static var meter: HitchMeter?
    private static var swipe: SwipeDriver?

    // MARK: Frame hitches

    /// SwiftUI animations tick on the main thread, so a late display-link callback is a frame
    /// the user saw late (or not at all).
    static func startHitchMeter(in window: NSWindow?) {
        _ = meter?.stop()
        meter = HitchMeter(view: window?.contentView)
    }

    static func stopHitchMeter() -> String {
        defer { meter = nil }
        return meter?.stop() ?? "not started"
    }

    // MARK: Scripted swipe

    /// Moves the pager by `pages` (positive = next space) over `seconds`, then lets go.
    static func animateSwipe(pages: Double, seconds: Double, in window: NSWindow?, completion: @escaping () -> Void) {
        swipe = SwipeDriver(view: window?.contentView, pages: pages, seconds: seconds) {
            swipe = nil
            completion()
        }
    }

    // MARK: Glass

    private static var patternWindow: NSWindow?

    /// A window of stripes, checks and text behind the browser window: fine and coarse detail
    /// that makes the background blur (or the lack of it) obvious in a screenshot.
    static func showPattern(behind window: NSWindow?) {
        guard let window else { return }
        let frame = window.frame.insetBy(dx: -60, dy: -60)
        let pattern = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        pattern.isReleasedWhenClosed = false
        pattern.contentView = PatternView(frame: NSRect(origin: .zero, size: frame.size))
        pattern.order(.below, relativeTo: window.windowNumber)
        patternWindow = pattern
    }

    /// Captures the screen where the window is: the window server's composite, so background
    /// blur and vibrancy are included. Other apps' windows are left out without Screen
    /// Recording permission; the desktop picture and our own windows are not.
    static func captureScreen(under window: NSWindow?, to path: String) -> String {
        guard let window else { return "no window" }
        typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return "no capture API" }
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let f = window.frame
        let rect = CGRect(x: f.minX, y: screenHeight - f.maxY, width: f.width, height: f.height)
        // kCGWindowListOptionOnScreenOnly, every window, nominal resolution.
        guard let image = unsafeBitCast(symbol, to: CaptureFn.self)(rect, 1, 0, 1 << 4)?.takeRetainedValue(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return "capture failed" }
        try? png.write(to: URL(fileURLWithPath: path))
        return "\(image.width)x\(image.height)"
    }

    // MARK: Layer tree

    /// One line per layer. MASK, SHADOW without a path, BLEND and FILTERS each cost the render
    /// server an offscreen pass every frame that part of the window redraws.
    static func layerTree(of window: NSWindow?) -> String {
        guard let root = window?.contentView?.superview?.layer ?? window?.contentView?.layer else { return "no layer tree" }
        var lines: [String] = []
        var counts = (layers: 0, masks: 0, shadows: 0, pathless: 0, blends: 0, filters: 0, clips: 0)

        func walk(_ layer: CALayer, _ depth: Int) {
            counts.layers += 1
            var flags: [String] = []
            if layer.masksToBounds {
                flags.append(layer.cornerRadius > 0 ? "ROUNDCLIP(r=\(layer.cornerRadius))" : "clip")
                if layer.cornerRadius > 0 { counts.clips += 1 }
            } else if layer.cornerRadius > 0 {
                flags.append("r=\(layer.cornerRadius)")
            }
            if layer.mask != nil { flags.append("MASK"); counts.masks += 1 }
            if layer.shadowOpacity > 0 {
                counts.shadows += 1
                if layer.shadowPath == nil { counts.pathless += 1 }
                flags.append("SHADOW(r=\(layer.shadowRadius) a=\(layer.shadowOpacity) \(layer.shadowPath == nil ? "NO PATH" : "path"))")
            }
            if let filter = layer.compositingFilter { flags.append("BLEND(\(filter))"); counts.blends += 1 }
            if let filters = layer.filters, !filters.isEmpty { flags.append("FILTERS(\(filters.count))"); counts.filters += 1 }
            if let filters = layer.backgroundFilters, !filters.isEmpty { flags.append("BACKDROP(\(filters.count))"); counts.filters += 1 }
            if layer.isOpaque { flags.append("opaque") }
            if layer.shouldRasterize { flags.append("rasterized") }
            if layer.opacity < 1 { flags.append("a=\(layer.opacity)") }
            if layer.isHidden { flags.append("hidden") }
            if layer.contents != nil { flags.append("contents") }
            if let animations = layer.animationKeys(), !animations.isEmpty { flags.append("anim[\(animations.joined(separator: ","))]") }
            let f = layer.frame
            let owner = (layer.delegate as? NSView).map { " <\(type(of: $0))>" } ?? ""
            lines.append(
                String(repeating: "  ", count: depth)
                    + "\(type(of: layer)) \(Int(f.width))x\(Int(f.height))@\(Int(f.minX)),\(Int(f.minY))"
                    + (flags.isEmpty ? "" : " " + flags.joined(separator: " ")) + owner
            )
            layer.mask.map { walk($0, depth + 2) }
            layer.sublayers?.forEach { walk($0, depth + 1) }
        }
        walk(root, 0)
        lines.insert(
            "layers=\(counts.layers) masks=\(counts.masks) shadows=\(counts.shadows) (no path: \(counts.pathless)) "
                + "blends=\(counts.blends) filters=\(counts.filters) roundclips=\(counts.clips)", at: 0
        )
        return lines.joined(separator: "\n")
    }
}

private final class PatternView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        var x: CGFloat = 0
        var i = 0
        while x < bounds.width {
            let width = CGFloat(4 + (i % 9) * 6)
            NSColor(hue: CGFloat((i * 37) % 100) / 100, saturation: 0.9, brightness: i % 2 == 0 ? 0.95 : 0.35, alpha: 1).setFill()
            NSRect(x: x, y: 0, width: width, height: bounds.height * 0.45).fill()
            x += width
            i += 1
        }
        let cell: CGFloat = 22
        NSColor.black.setFill()
        for row in 0..<Int(bounds.height * 0.3 / cell) {
            for column in 0..<Int(bounds.width / cell) where (row + column) % 2 == 0 {
                NSRect(x: CGFloat(column) * cell, y: bounds.height * 0.45 + CGFloat(row) * cell, width: cell, height: cell).fill()
            }
        }
        for line in 0..<4 {
            ("TUFF GLASS 0123456789 TUFF GLASS" as NSString).draw(
                at: NSPoint(x: 10, y: bounds.height * 0.76 + CGFloat(line) * 52),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 44, weight: .black),
                    .foregroundColor: NSColor(hue: CGFloat(line) * 0.2, saturation: 1, brightness: 0.8, alpha: 1),
                ]
            )
        }
    }
}

/// Times the gap between main-thread display-link callbacks.
private final class HitchMeter: NSObject {
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    /// A second opinion that doesn't depend on the display: how long a block posted to the main
    /// queue from another thread waits to run. A long frame gap with a short main-queue wait
    /// means the display link paused (screen asleep or locked), not that the app hung.
    private let pinger = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "tuff.hitch.pinger", qos: .userInteractive))
    private let lock = NSLock()
    private var worstMainWait: CFTimeInterval = 0
    private var pingOutstanding = false
    private var pingSent: CFTimeInterval = 0
    private var sampledHang = false

    init(view: NSView?) {
        super.init()
        guard let view else { return }
        stamps.reserveCapacity(4096)
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        pinger.schedule(deadline: .now(), repeating: .milliseconds(4))
        pinger.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let busy = self.pingOutstanding
            self.pingOutstanding = true
            let stuckFor = busy ? CACurrentMediaTime() - self.pingSent : 0
            let shouldSample = stuckFor > 0.7 && !self.sampledHang
            if shouldSample { self.sampledHang = true }
            self.lock.unlock()
            // TUFF_HANG_SAMPLE=<path>: when the main thread has been stuck for a while, record
            // what it is stuck in.
            if shouldSample, let path = ProcessInfo.processInfo.environment["TUFF_HANG_SAMPLE"] {
                let sampler = Process()
                sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                sampler.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "2", "5", "-file", path]
                sampler.standardOutput = FileHandle.nullDevice
                sampler.standardError = FileHandle.nullDevice
                try? sampler.run()
            }
            guard !busy else { return }
            let sent = CACurrentMediaTime()
            self.lock.lock()
            self.pingSent = sent
            self.lock.unlock()
            DispatchQueue.main.async {
                let waited = CACurrentMediaTime() - sent
                self.lock.lock()
                self.worstMainWait = max(self.worstMainWait, waited)
                self.pingOutstanding = false
                self.lock.unlock()
            }
        }
        pinger.resume()
    }

    @objc private func tick(_ link: CADisplayLink) {
        stamps.append(CACurrentMediaTime())
    }

    func stop() -> String {
        link?.invalidate()
        link = nil
        pinger.cancel()
        guard stamps.count > 2 else { return "no frames" }
        var gaps = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }
        gaps.sort()
        let seconds = stamps[stamps.count - 1] - stamps[0]
        let frame = gaps[gaps.count / 2]
        func percentile(_ p: Double) -> Double { gaps[min(gaps.count - 1, Int(Double(gaps.count) * p))] }
        // A gap of two frame times means one frame never made it to the screen.
        let dropped = gaps.reduce(0) { $0 + max(0, Int(($1 / frame).rounded()) - 1) }
        let late = gaps.filter { $0 > frame * 1.5 }.count
        lock.lock()
        let mainWait = worstMainWait * 1000
        lock.unlock()
        return String(
            format: "frames=%d seconds=%.2f frame=%.1fms p95=%.1f p99=%.1f max=%.1f late=%d dropped=%d (%.1f%%) mainwait=%.0f",
            gaps.count, seconds, frame, percentile(0.95), percentile(0.99), gaps[gaps.count - 1], late, dropped,
            100 * Double(dropped) / Double(gaps.count + dropped), mainWait
        )
    }
}

/// Feeds the pager one swipe step per frame, the way trackpad scroll events would.
private final class SwipeDriver: NSObject {
    private var link: CADisplayLink?
    private let pages: Double
    private let seconds: Double
    private let completion: () -> Void
    private var start: CFTimeInterval = 0
    private var travelled = 0.0

    init(view: NSView?, pages: Double, seconds: Double, completion: @escaping () -> Void) {
        self.pages = pages
        self.seconds = max(0.05, seconds)
        self.completion = completion
        super.init()
        guard let view else { completion(); return }
        start = CACurrentMediaTime()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let state = BrowserState.shared
        let width = CGFloat(AppSettings.shared.general.sidebarWidth)
        let progress = min(1, (CACurrentMediaTime() - start) / seconds)
        let target = pages * progress
        let step = target - travelled
        travelled = target
        // `updateSwipe` takes scroll deltas: fingers moving left (negative) go to the next space.
        state.updateSwipe(deltaX: -CGFloat(step) * width, width: width)
        if progress >= 1 {
            self.link?.invalidate()
            self.link = nil
            state.endSwipe(velocityX: pages > 0 ? -12 : 12)
            completion()
        }
    }
}
#endif
