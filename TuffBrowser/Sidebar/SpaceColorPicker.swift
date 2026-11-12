import AppKit
import SwiftUI

/// Picks a space's tint: a hue × lightness pad you drag around, a pageable row of presets,
/// and an editable hex readout for exact values.
struct SpaceColorPicker: View {
    let hex: String
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Colour").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                HexField(hex: hex, pick: pick)
            }
            ColorPad(hex: hex, pick: pick)
            PresetSwatches(selected: hex) { preset in
                withAnimation(Motion.smooth) { pick(preset) }
            }
        }
    }
}

// MARK: - Pad

/// Hue runs left to right, lightness top (pale) to bottom (deep). Saturation is held at a muted
/// level so everything on the pad makes a pleasant window tint.
private struct ColorPad: View {
    let hex: String
    let pick: (String) -> Void

    /// The pad point we last picked and the hex it became. Hex is only 8 bits per channel, so a
    /// dark colour read back from hex can sit a little off the point the user dropped it on;
    /// remembering the point keeps the handle exactly under their finger.
    @State private var anchor: (hex: String, point: CGPoint)?
    @State private var dragging = false
    @State private var hovering = false

    static let saturation = 0.42
    static let lightest = 0.9
    static let darkest = 0.085
    /// Gives the deep end more room: most good window tints are dark.
    static let curve = 1.25
    private let inset: CGFloat = 14
    private let height: CGFloat = 132

    static func lightness(at y: Double) -> Double {
        darkest + (lightest - darkest) * pow(1 - y, curve)
    }

    static func y(forLightness l: Double) -> Double {
        let t = max(0, min(1, (l - darkest) / (lightest - darkest)))
        return 1 - pow(t, 1 / curve)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let unit = currentPoint
            let handle = CGPoint(
                x: inset + unit.x * (size.width - inset * 2),
                y: inset + unit.y * (size.height - inset * 2)
            )
            ZStack(alignment: .topLeading) {
                field(size: size)
                Circle()
                    .fill(Color(hex: hex))
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3.5))
                    .frame(width: 24, height: 24)
                    .shadow(color: .black.opacity(0.35), radius: dragging ? 8 : 4, y: dragging ? 3 : 1.5)
                    .scaleEffect(dragging ? 1.18 : hovering ? 1.06 : 1)
                    .position(handle)
                    .animation(Motion.snappy, value: dragging)
                    .animation(Motion.quick, value: hovering)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        let p = CGPoint(
                            x: max(0, min(1, (value.location.x - inset) / (size.width - inset * 2))),
                            y: max(0, min(1, (value.location.y - inset) / (size.height - inset * 2)))
                        )
                        let picked = HSL(h: p.x, s: Self.saturation, l: Self.lightness(at: p.y)).nsColor.hexString
                        anchor = (picked, p)
                        if picked != hex { pick(picked) }
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: height)
    }

    private var currentPoint: CGPoint {
        if let anchor, anchor.hex.caseInsensitiveCompare(hex) == .orderedSame { return anchor.point }
        let hsl = HSL(NSColor(hex: hex))
        return CGPoint(x: hsl.h, y: Self.y(forLightness: hsl.l))
    }

    private func field(size: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let start = inset / max(size.width, 1)
        let hues = stride(from: 0.0, through: 1.0, by: 1.0 / 12).map {
            Gradient.Stop(color: Color(nsColor: HSL(h: $0, s: Self.saturation, l: 0.5).nsColor), location: start + $0 * (1 - start * 2))
        }
        // HSL lightness is a straight mix toward white (above 0.5) or black (below), so two
        // overlays reproduce the pad's colours exactly.
        let rows = stride(from: 0.0, through: 1.0, by: 0.05).map { y -> (Double, Double) in
            let location = (inset + y * (size.height - inset * 2)) / max(size.height, 1)
            return (location, Self.lightness(at: y))
        }
        let whites = rows.map { Gradient.Stop(color: .white.opacity(max(0, ($0.1 - 0.5) / 0.5)), location: $0.0) }
        let blacks = rows.map { Gradient.Stop(color: .black.opacity(max(0, (0.5 - $0.1) / 0.5)), location: $0.0) }

        return shape
            .fill(LinearGradient(stops: hues, startPoint: .leading, endPoint: .trailing))
            .overlay(shape.fill(LinearGradient(stops: whites, startPoint: .top, endPoint: .bottom)))
            .overlay(shape.fill(LinearGradient(stops: blacks, startPoint: .top, endPoint: .bottom)))
            .overlay(
                Canvas { context, size in
                    let step: CGFloat = 9
                    var dots = Path()
                    for x in stride(from: step / 2, to: size.width, by: step) {
                        for y in stride(from: step / 2, to: size.height, by: step) {
                            dots.addEllipse(in: CGRect(x: x - 0.7, y: y - 0.7, width: 1.4, height: 1.4))
                        }
                    }
                    context.fill(dots, with: .color(.white.opacity(0.16)))
                }
                .clipShape(shape)
                .blendMode(.overlay)
            )
            .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1).blendMode(.plusLighter))
            .overlay(shape.strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
    }
}

// MARK: - Presets

private struct PresetSwatches: View {
    let selected: String
    let pick: (String) -> Void
    @State private var page: Int
    @State private var forward = true

    init(selected: String, pick: @escaping (String) -> Void) {
        self.selected = selected
        self.pick = pick
        let start = Space.presetPages.firstIndex { $0.contains { $0.caseInsensitiveCompare(selected) == .orderedSame } }
        _page = State(initialValue: start ?? 0)
    }

    var body: some View {
        HStack(spacing: 0) {
            PagerButton(symbol: "chevron.left") { turn(by: -1) }
            ZStack {
                HStack(spacing: 0) {
                    ForEach(Space.presetPages[page], id: \.self) { hex in
                        Swatch(hex: hex, isSelected: hex.caseInsensitiveCompare(selected) == .orderedSame) { pick(hex) }
                            .frame(maxWidth: .infinity)
                    }
                }
                .id(page)
                .transition(.asymmetric(
                    insertion: .offset(x: forward ? 40 : -40).combined(with: .opacity),
                    removal: .offset(x: forward ? -40 : 40).combined(with: .opacity)
                ))
            }
            .frame(maxWidth: .infinity)
            .clipped()
            PagerButton(symbol: "chevron.right") { turn(by: 1) }
        }
        .frame(height: 34)
    }

    private func turn(by offset: Int) {
        forward = offset > 0
        let count = Space.presetPages.count
        withAnimation(Motion.snappy) { page = (page + offset + count) % count }
    }
}

private struct Swatch: View {
    let hex: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(hex: hex))
                .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center)))
                .overlay(Circle().strokeBorder(.primary.opacity(0.3), lineWidth: 1))
                .frame(width: 24, height: 24)
                .padding(3)
                .overlay(Circle().strokeBorder(.primary.opacity(isSelected ? 0.85 : 0), lineWidth: 2))
                .scaleEffect(hovering && !isSelected ? 1.08 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(SquishButtonStyle())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.snappy, value: isSelected)
        .help(hex)
    }
}

private struct PagerButton: View {
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(hovering ? 0.85 : 0.45))
                .frame(width: 18, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(SquishButtonStyle())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

// MARK: - Hex

private struct HexField: View {
    let hex: String
    let pick: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.primary.opacity(focused ? 0.9 : 0.5))
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .frame(width: 62)
            .onAppear { text = hex.uppercased() }
            .onChange(of: hex) { _, new in if !focused { text = new.uppercased() } }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onSubmit(commit)
    }

    private func commit() {
        var s = text.trimmed.uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, s.allSatisfy(\.isHexDigit) else {
            text = hex.uppercased()
            return
        }
        withAnimation(Motion.smooth) { pick("#" + s) }
        text = "#" + s
    }
}

// MARK: - HSL

private struct HSL {
    var h: Double, s: Double, l: Double

    init(h: Double, s: Double, l: Double) {
        self.h = h
        self.s = s
        self.l = l
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Double(c.redComponent), g = Double(c.greenComponent), b = Double(c.blueComponent)
        let hi = max(r, g, b), lo = min(r, g, b), d = hi - lo
        l = (hi + lo) / 2
        s = d == 0 ? 0 : d / (1 - abs(2 * l - 1))
        if d == 0 {
            h = 0
        } else if hi == r {
            h = ((g - b) / d).truncatingRemainder(dividingBy: 6) / 6
        } else if hi == g {
            h = ((b - r) / d + 2) / 6
        } else {
            h = ((r - g) / d + 4) / 6
        }
        if h < 0 { h += 1 }
    }

    var nsColor: NSColor {
        let c = (1 - abs(2 * l - 1)) * s
        let sector = (h.truncatingRemainder(dividingBy: 1)) * 6
        let x = c * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double) = switch Int(sector) % 6 {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        return NSColor(srgbRed: r + m, green: g + m, blue: b + m, alpha: 1)
    }
}
