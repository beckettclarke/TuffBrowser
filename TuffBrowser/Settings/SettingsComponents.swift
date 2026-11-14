import SwiftUI

// Tuff's own controls for the Settings window, drawn to match the browser chrome (soft
// primary-tinted plates, the space accent, squishy presses) rather than stock AppKit controls.

// MARK: - Page and groups

/// A scrolling settings page with a large title. When search picks a setting on this page, the
/// page scrolls it into view (the setting lights itself up; see `settingsAnchor`).
struct SettingsPage<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    @State private var position = ScrollPosition()
    /// Content and visible heights, to keep a scroll to a setting inside the page.
    @State private var heights: [CGFloat] = [0, 0]
    /// The search pick last scrolled to, so it happens once per pick.
    @State private var revealed: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.primary.opacity(0.5))
                    }
                }
                .padding(.horizontal, 4)
                content
            }
            .padding(.horizontal, 26)
            .padding(.top, 26)
            .padding(.bottom, 32)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
            .coordinateSpace(.named(SettingsTargetFrame.space))
        }
        .scrollIndicators(.automatic)
        .scrollPosition($position)
        .onScrollGeometryChange(for: [CGFloat].self, of: { [$0.contentSize.height, $0.containerSize.height] }) { _, new in
            heights = new
        }
        .onPreferenceChange(SettingsTargetFrameKey.self) { frame in
            guard let frame, frame.token != revealed else { return }
            revealed = frame.token
            // Put the setting a little below the top, where the eye lands, without scrolling
            // past the end of the page.
            let limit = heights[0] > 0 ? max(0, heights[0] - heights[1]) : .infinity
            let y = min(limit, max(0, frame.y - 90))
            withAnimation(Motion.smooth) { position.scrollTo(y: y) }
        }
    }
}

/// A rounded plate of rows with hairlines between them, an optional heading and footnote.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.5))
                    .padding(.leading, 6)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                        if index > 0 {
                            Rectangle()
                                .fill(.primary.opacity(0.07))
                                .frame(height: 0.5)
                                .padding(.leading, 14)
                        }
                        subview
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.primary.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
            .settingsAnchor("group:" + (title ?? ""), radius: 13, inset: 0)
            if let footer {
                Text(footer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
        }
    }
}

/// One row: a title (and optional detail line) on the left, a control on the right.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String?
    var symbol: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.6))
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.92))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.primary.opacity(0.48))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 44)
        .settingsAnchor(title)
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(title: String, detail: String? = nil, symbol: String? = nil) {
        self.init(title: title, detail: detail, symbol: symbol) { EmptyView() }
    }
}

/// A row whose control is a switch.
struct SwitchRow: View {
    let title: String
    var detail: String?
    var symbol: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, detail: detail, symbol: symbol) {
            TuffSwitch(isOn: $isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Motion.snappy) { isOn.toggle() } }
    }
}

// MARK: - Switch

struct TuffSwitch: View {
    @Environment(\.accent) private var accent
    @Environment(\.isEnabled) private var isEnabled
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(Motion.snappy) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? AnyShapeStyle(accent) : AnyShapeStyle(.primary.opacity(0.16)))
                    .overlay(Capsule().strokeBorder(.primary.opacity(isOn ? 0 : 0.06), lineWidth: 0.5))
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                    .padding(2)
            }
            .frame(width: 34, height: 20)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
        }
        .buttonStyle(SquishButtonStyle(scale: 0.94))
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: - Slider

struct TuffSlider: View {
    @Environment(\.accent) private var accent
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double?
    var width: CGFloat = 190

    @State private var dragging = false

    var body: some View {
        let span = range.upperBound - range.lowerBound
        let fraction = span > 0 ? (value - range.lowerBound) / span : 0
        GeometryReader { geo in
            let knob: CGFloat = 16
            let travel = geo.size.width - knob
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.14)).frame(height: 4)
                Capsule().fill(accent).frame(width: knob / 2 + travel * fraction, height: 4)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.28), radius: dragging ? 3 : 1.5, y: 1)
                    .frame(width: knob, height: knob)
                    .scaleEffect(dragging ? 1.12 : 1)
                    .offset(x: travel * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging { withAnimation(Motion.quick) { dragging = true } }
                        let f = max(0, min(1, (g.location.x - knob / 2) / max(1, travel)))
                        var v = range.lowerBound + f * span
                        if let step { v = (v / step).rounded() * step }
                        value = max(range.lowerBound, min(range.upperBound, v))
                    }
                    .onEnded { _ in withAnimation(Motion.quick) { dragging = false } }
            )
        }
        .frame(width: width, height: 20)
    }
}

/// A slider row with a readout.
struct SliderRow: View {
    let title: String
    var detail: String?
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double?
    /// Formats the readout; defaults to a percentage of the range.
    var format: ((Double) -> String)?

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            HStack(spacing: 10) {
                TuffSlider(value: $value, range: range, step: step)
                Text(readout)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary.opacity(0.5))
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }

    private var readout: String {
        if let format { return format(value) }
        let span = range.upperBound - range.lowerBound
        return "\(Int(((value - range.lowerBound) / span * 100).rounded()))%"
    }
}

// MARK: - Segmented

struct TuffSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(Motion.snappy) { selection = option }
                } label: {
                    Text(label(option))
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(.primary.opacity(selected ? 0.95 : 0.55))
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(.primary.opacity(0.16))
                                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(SquishButtonStyle(scale: 0.95))
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.07)))
    }
}

// MARK: - Menu picker

/// A pop-up menu with a soft plate as its button.
struct TuffMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    @State private var hovering = false

    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(label(selection))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.9))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.45))
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(hovering ? 0.13 : 0.08)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

// MARK: - Buttons and fields

struct TuffButtonStyle: ButtonStyle {
    enum Kind { case plain, prominent, destructive }
    var kind: Kind = .plain

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind)
    }

    private struct StyledButton: View {
        @Environment(\.accent) private var accent
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration
        let kind: Kind
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(configuration.isPressed ? 0.12 : 0)))
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(Motion.quick, value: hovering)
                .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
        }

        private var fill: AnyShapeStyle {
            switch kind {
            case .plain: AnyShapeStyle(.primary.opacity(hovering ? 0.14 : 0.09))
            case .prominent: AnyShapeStyle(accent.opacity(hovering ? 1 : 0.9))
            case .destructive: AnyShapeStyle(Color.red.opacity(hovering ? 0.26 : 0.18))
            }
        }

        private var foreground: AnyShapeStyle {
            switch kind {
            case .plain: AnyShapeStyle(.primary.opacity(0.88))
            case .prominent: AnyShapeStyle(Color.white)
            case .destructive: AnyShapeStyle(Color.red)
            }
        }
    }
}

/// A destructive button that asks for a second click instead of opening a dialog.
struct ConfirmButton: View {
    let title: String
    var confirmTitle = "Click again to confirm"
    let action: () -> Void
    @State private var armed = false
    @State private var done = false

    var body: some View {
        Button(done ? "Done" : (armed ? confirmTitle : title)) {
            if armed {
                action()
                withAnimation(Motion.snappy) { armed = false; done = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation(Motion.snappy) { done = false } }
            } else {
                withAnimation(Motion.snappy) { armed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation(Motion.snappy) { armed = false } }
            }
        }
        .buttonStyle(TuffButtonStyle(kind: armed ? .destructive : .plain))
        .disabled(done)
    }
}

struct TuffTextField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = 240
    var monospaced = false
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool
    @Environment(\.accent) private var accent

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, design: monospaced ? .monospaced : .default))
            .focused($focused)
            .onSubmit(onSubmit)
            .padding(.horizontal, 9)
            .frame(width: width, height: 28)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(focused ? 0.11 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(accent.opacity(focused ? 0.8 : 0), lineWidth: 1.5))
            .animation(Motion.quick, value: focused)
    }
}

/// A row of colour swatches plus a button that opens the full colour picker.
struct SwatchPicker: View {
    let selected: String
    var colors: [String] = Array(Space.palette.prefix(8))
    let pick: (String) -> Void
    @State private var customizing = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(colors, id: \.self) { hex in
                let isSelected = selected.caseInsensitiveCompare(hex) == .orderedSame
                Button { pick(hex) } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1))
                        .overlay(Circle().strokeBorder(.primary.opacity(0.85), lineWidth: 1.5).padding(-3.5).opacity(isSelected ? 1 : 0))
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(SquishButtonStyle())
            }
            let isCustom = !colors.contains { $0.caseInsensitiveCompare(selected) == .orderedSame }
            Button { customizing = true } label: {
                Circle()
                    .strokeBorder(
                        AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center),
                        lineWidth: 3
                    )
                    .overlay(Circle().fill(isCustom ? Color(hex: selected) : .clear).padding(4.5))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.85), lineWidth: 1.5).padding(-3.5).opacity(isCustom ? 1 : 0))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(SquishButtonStyle())
            .help("More colours")
            .popover(isPresented: $customizing, arrowEdge: .bottom) {
                SpaceColorPicker(hex: selected, pick: pick)
                    .padding(16)
                    .frame(width: 260)
            }
        }
    }
}

/// A key-cap for shortcut glyphs.
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary.opacity(0.75))
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
    }
}
