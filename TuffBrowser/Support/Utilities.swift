import WebKit
import CryptoKit
import AppKit
import SwiftUI

// MARK: - Colour helpers

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(
            format: "#%02X%02X%02X",
            Int(round(c.redComponent * 255)),
            Int(round(c.greenComponent * 255)),
            Int(round(c.blueComponent * 255))
        )
    }

    /// Perceived luminance, 0 (black) … 1 (white).
    var luminance: CGFloat {
        let c = usingColorSpace(.sRGB) ?? self
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }

    func mixed(with other: NSColor, fraction: CGFloat) -> NSColor {
        let a = usingColorSpace(.sRGB) ?? self
        let b = other.usingColorSpace(.sRGB) ?? other
        let f = max(0, min(1, fraction))
        return NSColor(
            srgbRed: a.redComponent + (b.redComponent - a.redComponent) * f,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * f,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * f,
            alpha: 1
        )
    }

    /// A lively accent derived from a (usually dark, muted) tint.
    var derivedAccent: NSColor {
        let c = usingColorSpace(.sRGB) ?? self
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.06 { return NSColor(srgbRed: 0.56, green: 0.62, blue: 0.70, alpha: 1) }
        let dark = luminance < 0.5
        return NSColor(hue: h, saturation: dark ? 0.42 : 0.62, brightness: dark ? 0.78 : 0.52, alpha: 1)
    }
}

extension Color {
    init(hex: String) { self.init(nsColor: NSColor(hex: hex)) }
}

// MARK: - Images

extension NSImage {
    func resized(to side: CGFloat) -> NSImage {
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        image.unlockFocus()
        return image
    }

    var pngData: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

enum Grain {
    /// A tileable film-grain texture, generated once.
    static let image: NSImage = {
        let side = 192
        var rng = SystemRandomNumberGenerator()
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for i in 0..<(side * side) {
            let white = Bool.random(using: &rng)
            let alpha = UInt8.random(in: 0...150, using: &rng)
            let v: UInt8 = white ? alpha : 0 // premultiplied
            pixels[i * 4] = v
            pixels[i * 4 + 1] = v
            pixels[i * 4 + 2] = v
            pixels[i * 4 + 3] = alpha
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cg = CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        return NSImage(cgImage: cg, size: NSSize(width: side / 2, height: side / 2))
    }()
}

// MARK: - Strings / URLs

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension URL {
    /// Host without a leading "www.".
    var displayHost: String {
        guard let host = host(percentEncoded: false) else { return absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// This Mac itself (localhost, 127.x.x.x, ::1), which browsers trust over plain http.
    var isLoopback: Bool {
        guard let host = host(percentEncoded: false)?.lowercased() else { return false }
        return host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "[::1]"
            || host.hasPrefix("127.") && host.split(separator: ".").count == 4
    }

    /// Splits the host into a dim prefix (subdomains) and the emphasised registrable part.
    var hostParts: (prefix: String, domain: String) {
        let host = displayHost
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2, !labels.allSatisfy({ Int($0) != nil }) else { return ("", host) }
        var keep = 2
        let last = labels[labels.count - 1], second = labels[labels.count - 2]
        if last.count == 2, second.count <= 3, labels.count > 3 || ["co", "com", "org", "net", "ac", "gov"].contains(second) {
            keep = min(3, labels.count)
        }
        if labels.count <= keep { return ("", host) }
        let prefix = labels.dropLast(keep).joined(separator: ".") + "."
        let domain = labels.suffix(keep).joined(separator: ".")
        return (prefix, domain)
    }
}

enum Paths {
    /// Debug builds keep a profile of their own, apart from the Release one.
    #if DEBUG
    private static let folderName = "TuffBrowser Debug"
    #else
    private static let folderName = "TuffBrowser"
    #endif

    /// Set for automated test runs (debug builds only): everything goes in this folder.
    static let testDataDirectory: URL? = {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["TUFF_DATA_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        return nil
    }()

    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = testDataDirectory ?? base.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let caches: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

/// Where WebKit keeps cookies, site storage and extension storage. Normally WebKit's default
/// store for this app; a test run (TUFF_DATA_DIR) gets its own, so it can't touch the real one.
enum DataStores {
    private static let testIdentifier: UUID? = Paths.testDataDirectory.map { dir in
        let digest = Array(SHA256.hash(data: Data(dir.standardizedFileURL.path.utf8)))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }

    static let website: WKWebsiteDataStore = testIdentifier.map { WKWebsiteDataStore(forIdentifier: $0) } ?? .default()

    private static var profileStores: [UUID: WKWebsiteDataStore] = [:]

    /// A profile's own store: cookies, logins and site storage kept apart from every other
    /// profile's. In a test run the identifier is mixed with the test's, so it stays separate.
    static func store(forProfile id: UUID) -> WKWebsiteDataStore {
        if let store = profileStores[id] { return store }
        let store = WKWebsiteDataStore(forIdentifier: identifier(forProfile: id))
        profileStores[id] = store
        return store
    }

    private static func identifier(forProfile id: UUID) -> UUID {
        guard let testIdentifier else { return id }
        let digest = Array(SHA256.hash(data: Data((testIdentifier.uuidString + id.uuidString).utf8)))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }

    /// Deletes a profile's store from disk. WebKit refuses while a web view still uses it, so
    /// this waits until the profile's tabs have gone.
    static func removeStore(forProfile id: UUID, attempts: Int = 5) {
        profileStores[id] = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            WKWebsiteDataStore.remove(forIdentifier: identifier(forProfile: id)) { error in
                guard error != nil, attempts > 1 else { return }
                DispatchQueue.main.async { removeStore(forProfile: id, attempts: attempts - 1) }
            }
        }
    }

    /// Every store in use: the shared one and each profile's own.
    static var all: [WKWebsiteDataStore] {
        var stores = [website]
        for profile in BrowserState.shared.profiles where !stores.contains(where: { $0 === profile.dataStore }) {
            stores.append(profile.dataStore)
        }
        return stores
    }

    static func extensionControllerConfiguration() -> WKWebExtensionController.Configuration {
        testIdentifier.map { WKWebExtensionController.Configuration(identifier: $0) } ?? .default()
    }
}

/// Coalesces bursts of calls into one, on the main queue.
final class Debouncer {
    private var work: DispatchWorkItem?
    private let delay: TimeInterval
    init(delay: TimeInterval) { self.delay = delay }

    func schedule(_ block: @escaping () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem(block: block)
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() { work?.cancel() }
}

// MARK: - SwiftUI building blocks

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

/// The drop shadow of a rounded rectangle, drawn from its outline.
///
/// SwiftUI's `.shadow` is derived from whatever the view contains. Around a card that holds a
/// web view (or a blurred backdrop) that means the render server re-derives the shadow from
/// live pixels on every frame the card redraws or moves. A solid card's shadow is simply the
/// shadow of its outline, so this draws that, once, from a path — the same shadow for none of
/// the per-frame work. Put it behind the card with `.background`; see `CardShadow`.
struct OutlineShadow: NSViewRepresentable {
    var cornerRadius: CGFloat
    var opacity: Double
    var radius: CGFloat
    var x: CGFloat = 0
    var y: CGFloat = 0
    /// Only outside the outline: for a see-through card (a blurred material), which would
    /// otherwise show — and blur — its own shadow through itself.
    var hollow = false

    func makeNSView(context: Context) -> ShadowView { ShadowView() }

    func updateNSView(_ view: ShadowView, context: Context) {
        view.cornerRadius = cornerRadius
        view.hollowReach = hollow ? radius * 3 + abs(x) + abs(y) : nil
        guard let layer = view.layer else { return }
        layer.shadowColor = NSColor.black.withAlphaComponent(opacity).cgColor
        layer.shadowOpacity = 1
        layer.shadowRadius = radius
        // SwiftUI's y grows downwards; a layer's grows upwards.
        layer.shadowOffset = CGSize(width: x, height: -y)
    }

    final class ShadowView: NSView {
        var cornerRadius: CGFloat = 0 { didSet { if cornerRadius != oldValue { updatePath() } } }
        /// How far the shadow can reach past the outline, when its inside is cut away; nil for
        /// a solid shadow.
        var hollowReach: CGFloat? { didSet { if hollowReach != oldValue { updatePath() } } }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            updatePath()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            updatePath()
        }

        /// Follows the view's size without animating on its own, so it stays in step with
        /// whatever is animating the card.
        private func updatePath() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let outline = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: bounds).cgPath
            layer?.shadowPath = outline
            if let reach = hollowReach {
                // Everything around the card, and nothing inside it.
                let mask = (layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
                let path = CGMutablePath()
                path.addRect(bounds.insetBy(dx: -reach, dy: -reach))
                path.addPath(outline)
                mask.path = path
                mask.fillRule = .evenOdd
                mask.frame = bounds
                layer?.mask = mask
            } else {
                layer?.mask = nil
            }
            CATransaction.commit()
        }
    }
}

/// The shadow under a card. While the card is `solid` (nothing shows through it) the shadow is
/// drawn from its outline; while it is see-through its shadow depends on what is inside, and
/// SwiftUI's own is used.
struct CardShadow: ViewModifier {
    var cornerRadius: CGFloat
    var opacity: Double
    var radius: CGFloat
    var x: CGFloat = 0
    var y: CGFloat = 0
    var solid = true
    /// No shadow at all (the Seamless background's flat page).
    var enabled = true
    /// Drawn only outside the outline, for a card with a see-through material (see
    /// `OutlineShadow.hollow`). Keeps the shadow off the live backdrop, which `.shadow` isn't.
    var hollow = false

    func body(content: Content) -> some View {
        // Two branches rather than one `.shadow` with its colour switched to clear: SwiftUI
        // keeps a clear shadow on the layer, and the render server still has to derive it.
        if !enabled {
            content
        } else if solid {
            content.background { OutlineShadow(cornerRadius: cornerRadius, opacity: opacity, radius: radius, x: x, y: y, hollow: hollow) }
        } else {
            content.shadow(color: .black.opacity(opacity), radius: radius, x: x, y: y)
        }
    }
}

/// Empty area that drags the window, and zooms on double-click, like a title bar.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// Small icon button with a soft hover plate and a press squish.
struct IconButton: View {
    let symbol: String
    var size: CGFloat = 14
    var weight: Font.Weight = .medium
    var side: CGFloat = 28
    var help: String = ""
    var disabled = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(.primary.opacity(disabled ? 0.25 : (hovering ? 0.95 : 0.62)))
                .frame(width: side, height: side)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.primary.opacity(hovering && !disabled ? 0.1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SquishButtonStyle())
        .disabled(disabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(help)
    }
}

struct SquishButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.92
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

extension View {
    /// Runs `action` when the middle mouse button is pressed and released over this view.
    /// SwiftUI has no gesture for it, so one app-wide event monitor (`MiddleClickRouter`) finds
    /// the view under the pointer by its real frame in the window.
    func onMiddleClick(perform action: @escaping () -> Void) -> some View {
        modifier(MiddleClickModifier(action: action))
    }
}

private struct MiddleClickModifier: ViewModifier {
    let action: () -> Void
    @State private var target = MiddleClickTarget()

    func body(content: Content) -> some View {
        content
            .background(MiddleClickAnchor(target: target, action: action))
            .onHover { target.hovered = $0 }
            .onAppear { MiddleClickRouter.shared.add(target) }
            .onDisappear {
                target.hovered = false
                MiddleClickRouter.shared.remove(target)
            }
    }
}

/// One view that takes middle clicks: what it does, and an AppKit view filling it, which says
/// where it is in its window (clipped by any scroll view it is in).
private final class MiddleClickTarget {
    var action: (() -> Void)?
    var hovered = false
    weak var anchor: NSView?

    /// Whether a mouse event's point is on the visible part of the view.
    func contains(_ event: NSEvent) -> Bool {
        guard let anchor, let inWindow = point(of: event) else { return false }
        // `visibleRect` can reach past the bounds (views don't clip to them by default), so
        // it only trims the bounds to what an enclosing scroll view shows.
        return anchor.bounds.intersection(anchor.visibleRect).contains(anchor.convert(inWindow, from: nil))
    }

    /// Whether nothing of the window's covers the view at the event's point (the command bar's
    /// dimmed backdrop, a card): the window's own hit test there lands in the scroll view the
    /// view is in. A view outside any scroll view can't be checked this way.
    func isUncovered(at event: NSEvent) -> Bool {
        guard let anchor, let scrollView = anchor.enclosingScrollView, let window = anchor.window,
              let inWindow = point(of: event), let root = window.contentView?.superview ?? window.contentView,
              let hit = root.hitTest(root.convert(inWindow, from: nil)) else { return false }
        return hit === scrollView || hit.isDescendant(of: scrollView)
    }

    /// The event's point in the view's window, or nil when it happened in another window.
    private func point(of event: NSEvent) -> NSPoint? {
        guard let window = anchor?.window else { return nil }
        if let eventWindow = event.window { return eventWindow === window ? event.locationInWindow : nil }
        // An event with no window (posted from a CGEvent) is in screen coordinates.
        return window.convertPoint(fromScreen: event.locationInWindow)
    }
}

private struct MiddleClickAnchor: NSViewRepresentable {
    let target: MiddleClickTarget
    let action: () -> Void

    /// Takes no clicks of its own; it is only there to be measured.
    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        target.anchor = view
        target.action = action
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        target.anchor = view
        target.action = action
    }
}

/// Routes middle clicks to the `onMiddleClick` view under the pointer.
///
/// SwiftUI's hover alone isn't enough to say which that is: it only changes when the mouse
/// moves. After a middle click closes a tab, the row below slides up under a still pointer
/// without being told, so the next middle click (closing tabs one after another, as in Chrome)
/// went nowhere; and a row that slid away from the pointer still thought it was hovered. So a
/// view counts only when the pointer is on its visible frame, and either SwiftUI says it is
/// hovered or nothing else of the window's is drawn over it there.
private final class MiddleClickRouter {
    static let shared = MiddleClickRouter()
    private struct Entry { weak var target: MiddleClickTarget? }
    private var targets: [ObjectIdentifier: Entry] = [:]
    private var monitor: Any?
    /// The view the button went down on; a release over the same view is a click.
    private weak var pressed: MiddleClickTarget?

    func add(_ target: MiddleClickTarget) {
        targets[ObjectIdentifier(target)] = Entry(target: target)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func remove(_ target: MiddleClickTarget) {
        targets[ObjectIdentifier(target)] = nil
        targets = targets.filter { $0.value.target != nil }
    }

    /// Returns nil to swallow the event.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.buttonNumber == 2 else { return event }
        if event.type == .otherMouseDown {
            pressed = target(at: event)
            return pressed == nil ? event : nil
        }
        guard let down = pressed else { return event }
        pressed = nil
        guard target(at: event) === down else { return nil }
        down.action?()
        return nil
    }

    private func target(at event: NSEvent) -> MiddleClickTarget? {
        let live = targets.values.compactMap(\.target).filter { $0.contains(event) }
        return live.first(where: \.hovered) ?? live.first { $0.isUncovered(at: event) }
    }
}

enum Motion {
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.82)
    static let smooth = Animation.spring(response: 0.42, dampingFraction: 0.88)
    static let quick = Animation.easeOut(duration: 0.16)
    /// Docking / undocking the sidebar: fast and decisive, with just enough give to feel physical.
    static let sidebar = Animation.spring(response: 0.27, dampingFraction: 0.86)
}
