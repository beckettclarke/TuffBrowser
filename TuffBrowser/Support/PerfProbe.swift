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

/// Times the gap between main-thread display-link callbacks.
private final class HitchMeter: NSObject {
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []

    init(view: NSView?) {
        super.init()
        guard let view else { return }
        stamps.reserveCapacity(4096)
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        stamps.append(CACurrentMediaTime())
    }

    func stop() -> String {
        link?.invalidate()
        link = nil
        guard stamps.count > 2 else { return "no frames" }
        var gaps = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }
        gaps.sort()
        let seconds = stamps[stamps.count - 1] - stamps[0]
        let frame = gaps[gaps.count / 2]
        func percentile(_ p: Double) -> Double { gaps[min(gaps.count - 1, Int(Double(gaps.count) * p))] }
        // A gap of two frame times means one frame never made it to the screen.
        let dropped = gaps.reduce(0) { $0 + max(0, Int(($1 / frame).rounded()) - 1) }
        let late = gaps.filter { $0 > frame * 1.5 }.count
        return String(
            format: "frames=%d seconds=%.2f frame=%.1fms p95=%.1f p99=%.1f max=%.1f late=%d dropped=%d (%.1f%%)",
            gaps.count, seconds, frame, percentile(0.95), percentile(0.99), gaps[gaps.count - 1], late, dropped,
            100 * Double(dropped) / Double(gaps.count + dropped)
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
