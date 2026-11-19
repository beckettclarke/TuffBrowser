import AppKit
import Observation
import SwiftUI

/// The welcome screen on a new profile: the logo, then the few choices worth making before the
/// first page (tab layout, window style, search engine, ad blocking, default browser). Every
/// choice is the real setting, applied as it is picked, so the window behind changes with it.
@Observable
final class Onboarding {
    static let shared = Onboarding()

    enum Step: Int, CaseIterable {
        case welcome, tabs, appearance, search, adBlocking, finish

        var title: String {
            switch self {
            case .welcome: "Welcome to Tuff"
            case .tabs: "Tabs"
            case .appearance: "Appearance"
            case .search: "Search Engine"
            case .adBlocking: "Ad Blocking"
            case .finish: "Finish Setup"
            }
        }
    }

    private(set) var isShowing = false
    private(set) var step: Step = .welcome
    /// The last step change went forward: the new page comes in from the right.
    private(set) var forward = true

    private static let doneKey = "tuff.onboarded"

    /// Shows the welcome screen on the first launch of a new profile.
    func showIfNeeded() {
        guard Paths.testDataDirectory == nil, BrowserState.shared.startedFresh,
              !UserDefaults.standard.bool(forKey: Self.doneKey) else { return }
        show()
    }

    func show() {
        let state = BrowserState.shared
        step = .welcome
        forward = true
        animate(.easeOut(duration: 0.3)) { isShowing = true }
        state.closeCommandBar()
        // Return goes to the card's buttons, not the page.
        state.window?.makeFirstResponder(nil)
    }

    func next() {
        if let following = Step(rawValue: step.rawValue + 1) { go(to: following) } else { finish() }
    }

    func back() {
        if let previous = Step(rawValue: step.rawValue - 1) { go(to: previous) }
    }

    func go(to target: Step) {
        guard target != step else { return }
        let ahead = target.rawValue > step.rawValue
        if ahead == forward {
            animate(Motion.smooth) { step = target }
        } else {
            // The page going out takes its transition from the last update it was in, so the
            // direction has to change in an update of its own first.
            forward = ahead
            DispatchQueue.main.async { self.animate(Motion.smooth) { self.step = target } }
        }
    }

    func finish() {
        if Paths.testDataDirectory == nil { UserDefaults.standard.set(true, forKey: Self.doneKey) }
        animate(.easeOut(duration: 0.25)) { isShowing = false }
        let state = BrowserState.shared
        // Straight on to the first page.
        if state.selectedTab == nil { state.openCommandBar(.newTab) } else { state.focusWebView() }
    }

    private func animate(_ animation: Animation, _ body: () -> Void) {
        if AppSettings.shared.animationsEnabled { withAnimation(animation, body) } else { body() }
    }
}

// MARK: - Overlay and card

/// Dims the window and holds the welcome card in the middle of it.
struct OnboardingOverlay: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.opacity(appeared ? 0.3 : 0)
                .contentShape(Rectangle())
                .onTapGesture {}
            OnboardingCard()
                .scaleEffect(appeared ? 1 : 0.96)
                .opacity(appeared ? 1 : 0)
        }
        // The scrim covers the title bar area; keep the window draggable there.
        .overlay(alignment: .top) { WindowDragArea().frame(height: 36) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if AppSettings.shared.animationsEnabled {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { appeared = true }
            } else {
                appeared = true
            }
        }
    }
}

private struct OnboardingCard: View {
    @Environment(BrowserState.self) private var state

    static let width: CGFloat = 600
    static let height: CGFloat = 436

    var body: some View {
        let onboarding = Onboarding.shared
        let step = onboarding.step
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(spacing: 0) {
            ZStack {
                page(step)
                    .id(step)
                    .transition(slide(forward: onboarding.forward))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if step != .welcome {
                OnboardingFooter(step: step)
                    .transition(.opacity)
            }
        }
        .frame(width: Self.width, height: Self.height)
        .background(
            ZStack {
                VisualEffect(material: .hudWindow, blending: .withinWindow)
                Color(nsColor: state.baseTint).opacity(0.55)
            }
        )
        .clipShape(shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.14), lineWidth: 1))
        .modifier(CardShadow(cornerRadius: 22, opacity: 0.4, radius: 44, y: 20, hollow: true))
    }

    @ViewBuilder private func page(_ step: Onboarding.Step) -> some View {
        switch step {
        case .welcome: WelcomePage()
        case .tabs: OnboardingPage(step: step) { TabsChoice() }
        case .appearance: OnboardingPage(step: step) { AppearanceChoice() }
        case .search: OnboardingPage(step: step) { SearchChoice() }
        case .adBlocking: OnboardingPage(step: step) { AdBlockingChoice() }
        case .finish: OnboardingPage(step: step) { FinishChoice() }
        }
    }

    private func slide(forward: Bool) -> AnyTransition {
        let distance: CGFloat = 44
        return .asymmetric(
            insertion: .modifier(active: SlideFade(x: forward ? distance : -distance), identity: SlideFade(x: 0)),
            removal: .modifier(active: SlideFade(x: forward ? -distance : distance), identity: SlideFade(x: 0))
        )
    }
}

private struct SlideFade: ViewModifier {
    let x: CGFloat
    func body(content: Content) -> some View {
        content.offset(x: x).opacity(x == 0 ? 1 : 0)
    }
}

/// A step's title over its choices.
private struct OnboardingPage<Content: View>: View {
    let step: Onboarding.Step
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(step.title)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            content
        }
        .padding(.horizontal, 32)
        .padding(.top, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Back, where you are, and Continue (↩).
private struct OnboardingFooter: View {
    @Environment(BrowserState.self) private var state
    let step: Onboarding.Step

    var body: some View {
        let accent = state.baseTint.derivedAccent
        let text: Color = accent.luminance > 0.45 ? Color.black.opacity(0.85) : .white
        let last = step == Onboarding.Step.allCases.last
        HStack {
            if step.rawValue > 1 {
                Button("Back") { Onboarding.shared.back() }
                    .buttonStyle(PromptButtonStyle(fill: .primary.opacity(0.1), text: .primary))
                    .transition(.opacity)
            }
            Spacer()
            Button { Onboarding.shared.next() } label: {
                HStack(spacing: 8) {
                    Text(last ? "Start Browsing" : "Continue")
                        .contentTransition(.opacity)
                    KeyHint("↩", color: text)
                }
            }
            .buttonStyle(PromptButtonStyle(fill: Color(nsColor: accent), text: text, trailingPadding: 6))
            .keyboardShortcut(.defaultAction)
        }
        .overlay { StepDots(current: step) }
        .padding(.horizontal, 24)
        .frame(height: 66)
    }
}

/// One dot per step after the welcome; the current one is drawn long.
private struct StepDots: View {
    let current: Onboarding.Step

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Onboarding.Step.allCases.dropFirst(), id: \.self) { step in
                let on = step == current
                Capsule()
                    .fill(.primary.opacity(on ? 0.75 : (step.rawValue < current.rawValue ? 0.35 : 0.16)))
                    .frame(width: on ? 18 : 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current.rawValue) of \(Onboarding.Step.allCases.count - 1)")
    }
}

// MARK: - Welcome

private struct WelcomePage: View {
    @Environment(BrowserState.self) private var state
    @State private var titleShown = false
    @State private var buttonShown = false

    var body: some View {
        let accent = state.baseTint.derivedAccent
        let text: Color = accent.luminance > 0.45 ? Color.black.opacity(0.85) : .white
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            AnimatedLogoTile(size: 112)
            Text("Welcome to Tuff")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .padding(.top, 30)
                .opacity(titleShown ? 1 : 0)
                .offset(y: titleShown ? 0 : 10)
            Spacer(minLength: 0)
            Button { Onboarding.shared.next() } label: {
                HStack(spacing: 8) {
                    Text("Get Started")
                    KeyHint("↩", color: text)
                }
            }
            .buttonStyle(PromptButtonStyle(fill: Color(nsColor: accent), text: text, trailingPadding: 6))
            .keyboardShortcut(.defaultAction)
            .opacity(buttonShown ? 1 : 0)
            .offset(y: buttonShown ? 0 : 8)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            guard AppSettings.shared.animationsEnabled else {
                titleShown = true
                buttonShown = true
                return
            }
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { titleShown = true }
            try? await Task.sleep(for: .milliseconds(200))
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { buttonShown = true }
        }
    }
}

/// The app icon, built up: the tile springs in, the mark's outline is traced, then it fills and
/// a light passes over it.
private struct AnimatedLogoTile: View {
    let size: CGFloat
    @State private var tileIn = false
    @State private var traced: CGFloat = 0
    @State private var filled = false
    @State private var sheen: CGFloat = -1

    var body: some View {
        let radius = size * 0.225
        let tile = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let markWidth = size * 0.56
        ZStack {
            tile.fill(Color(white: 0.098))
            ZStack {
                TuffLogoShape()
                    .trim(from: 0, to: traced)
                    .stroke(.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .opacity(filled ? 0 : 1)
                TuffLogoShape()
                    .fill(.white)
                    .opacity(filled ? 1 : 0)
            }
            .frame(width: markWidth, height: markWidth * TuffLogoShape.aspect)
            .scaleEffect(filled ? 1 : 0.97)
            // A soft band of light crossing the tile once the mark is in.
            LinearGradient(
                colors: [.white.opacity(0), .white.opacity(0.13), .white.opacity(0)],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: size * 0.5)
            .rotationEffect(.degrees(18))
            .offset(x: sheen * size * 1.1)
            .blendMode(.plusLighter)
        }
        .frame(width: size, height: size)
        .clipShape(tile)
        .overlay(tile.strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .modifier(CardShadow(cornerRadius: radius, opacity: 0.35, radius: 22, y: 10))
        .scaleEffect(tileIn ? 1 : 0.82)
        .opacity(tileIn ? 1 : 0)
        .accessibilityHidden(true)
        .task {
            guard AppSettings.shared.animationsEnabled else {
                tileIn = true
                traced = 1
                filled = true
                return
            }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) { tileIn = true }
            try? await Task.sleep(for: .milliseconds(160))
            withAnimation(.easeInOut(duration: 0.95)) { traced = 1 }
            try? await Task.sleep(for: .milliseconds(820))
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { filled = true }
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(.easeInOut(duration: 0.9)) { sheen = 1 }
        }
    }
}

/// Tuff's mark (assets/TuffBrowser Logo.svg), scaled to fit.
struct TuffLogoShape: Shape {
    /// Height over width of the artwork.
    static let aspect: CGFloat = 158 / 175

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 175, rect.height / 158)
        let ox = rect.midX - 175 * scale / 2
        let oy = rect.midY - 158 * scale / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * scale, y: oy + y * scale) }
        var path = Path()
        path.move(to: p(174.69, 41.6091))
        path.addCurve(to: p(172.774, 44.1818), control1: p(175.073, 42.8919), control2: p(174.113, 44.1818))
        path.addLine(to: p(113.122, 44.1818))
        path.addCurve(to: p(111.372, 45.2128), control1: p(112.394, 44.1818), control2: p(111.725, 44.5766))
        path.addLine(to: p(49.4915, 156.938))
        path.addCurve(to: p(45.8275, 156.548), control1: p(48.6347, 158.485), control2: p(46.3393, 158.24))
        path.addLine(to: p(29.4942, 102.522))
        path.addCurve(to: p(29.6617, 100.969), control1: p(29.3373, 102.003), control2: p(29.3978, 101.443))
        path.addLine(to: p(59.6587, 47.1556))
        path.addCurve(to: p(57.9118, 44.1818), control1: p(60.4018, 45.8225), control2: p(59.438, 44.1818))
        path.addLine(to: p(13.7204, 44.1818))
        path.addCurve(to: p(11.8003, 42.7418), control1: p(12.8315, 44.1818), control2: p(12.0492, 43.5952))
        path.addLine(to: p(0.0806519, 2.56))
        path.addCurve(to: p(2.00065, 0), control1: p(-0.292681, 1.28), control2: p(0.667318, 0))
        path.addLine(to: p(160.765, 0))
        path.addCurve(to: p(162.681, 1.42729), control1: p(161.649, 0), control2: p(162.428, 0.580327))
        path.closeSubpath()
        return path
    }
}

// MARK: - Shared pieces

/// A choice drawn as a picture with its name under it, ringed in the accent when picked.
private struct ChoiceTile<Preview: View>: View {
    @Environment(\.accent) private var accent
    let title: String
    var symbol: String?
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var preview: Preview
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button(action: action) {
            VStack(spacing: 10) {
                preview
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                HStack(spacing: 6) {
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold))
                    }
                    Text(title).font(.system(size: 13, weight: selected ? .semibold : .medium))
                }
                .foregroundStyle(.primary.opacity(selected ? 0.95 : 0.65))
                .padding(.bottom, 2)
            }
            .padding(8)
            .background(shape.fill(.primary.opacity(selected ? 0.08 : (hovering ? 0.06 : 0.035))))
            .overlay(shape.strokeBorder(selected ? accent : .primary.opacity(0.08), lineWidth: selected ? 2 : 0.5))
            .contentShape(shape)
        }
        .buttonStyle(SquishButtonStyle(scale: 0.98))
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.snappy, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Colours for the miniature browser drawings.
private struct MiniPalette {
    let tint: Color
    /// Chrome marks: light on a dark tint, dark on a light one.
    let ink: Color

    init(_ tint: NSColor) {
        self.tint = Color(nsColor: tint)
        ink = tint.luminance < 0.55 ? .white : .black
    }

    static let lights: [Color] = [
        Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25),
    ]
    /// A different page per tab, so changing tab shows.
    static let pages: [Color] = [
        Color(red: 0.33, green: 0.52, blue: 0.95), Color(red: 0.96, green: 0.55, blue: 0.29),
        Color(red: 0.27, green: 0.72, blue: 0.52), Color(red: 0.62, green: 0.44, blue: 0.90),
    ]

    static func trafficLights(_ side: CGFloat) -> some View {
        HStack(spacing: side * 0.6) {
            ForEach(0..<3, id: \.self) { Circle().fill(lights[$0]).frame(width: side, height: side) }
        }
    }
}

/// A web page in miniature: a coloured header and lines of text.
private struct MiniPage: View {
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(accent.gradient)
                .frame(height: 34)
            Capsule().fill(Color(white: 0.55)).frame(width: 70, height: 5)
            ForEach(0..<4, id: \.self) { i in
                Capsule().fill(Color(white: 0.82)).frame(width: i == 3 ? 60 : nil, height: 3.5)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(white: 0.98))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

// MARK: - Tabs

private struct TabsChoice: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(spacing: 14) {
            ForEach(TabLayout.allCases) { layout in
                let selected = settings.tabs.layout == layout
                ChoiceTile(title: layout.label, symbol: layout.symbol, selected: selected) {
                    withAnimation(Motion.snappy) { settings.tabs.layout = layout }
                } preview: {
                    LayoutPreview(layout: layout, running: selected)
                        .frame(height: 212)
                }
            }
        }
    }
}

/// The browser with its tabs down the side or across the top. On the picked layout the
/// selection moves from tab to tab, and the page changes with it.
private struct LayoutPreview: View {
    @Environment(BrowserState.self) private var state
    let layout: TabLayout
    let running: Bool
    @State private var active = 0

    private static let tabCount = 4

    var body: some View {
        let palette = MiniPalette(state.baseTint)
        ZStack {
            palette.tint
            LinearGradient(colors: [.white.opacity(0.07), .clear], startPoint: .top, endPoint: .bottom)
            if layout == .vertical { vertical(palette) } else { horizontal(palette) }
        }
        .task(id: running) {
            guard running, AppSettings.shared.animationsEnabled else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                if Task.isCancelled { break }
                withAnimation(Motion.smooth) { active = (active + 1) % Self.tabCount }
            }
        }
    }

    private func vertical(_ palette: MiniPalette) -> some View {
        let rowHeight: CGFloat = 17, rowGap: CGFloat = 5
        let widths: [CGFloat] = [34, 26, 38, 22]
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                MiniPalette.trafficLights(6)
                    .padding(.top, 2)
                Capsule().fill(palette.ink.opacity(0.13)).frame(height: 13)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(palette.ink.opacity(0.16))
                        .frame(height: rowHeight)
                        .offset(y: CGFloat(active) * (rowHeight + rowGap))
                    VStack(alignment: .leading, spacing: rowGap) {
                        ForEach(0..<Self.tabCount, id: \.self) { i in
                            HStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(MiniPalette.pages[i])
                                    .frame(width: 8, height: 8)
                                Capsule()
                                    .fill(palette.ink.opacity(i == active ? 0.6 : 0.32))
                                    .frame(width: widths[i], height: 3.5)
                            }
                            .padding(.horizontal, 5)
                            .frame(height: rowHeight)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 9)
            .padding(.trailing, 5)
            .padding(.top, 8)
            .frame(width: 78)
            MiniPage(accent: MiniPalette.pages[active])
                .padding([.top, .trailing, .bottom], 6)
        }
    }

    private func horizontal(_ palette: MiniPalette) -> some View {
        let tabWidth: CGFloat = 36, tabGap: CGFloat = 4
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                MiniPalette.trafficLights(6)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(palette.ink.opacity(0.16))
                        .frame(width: tabWidth, height: 15)
                        .offset(x: CGFloat(active) * (tabWidth + tabGap))
                    HStack(spacing: tabGap) {
                        ForEach(0..<Self.tabCount, id: \.self) { i in
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(MiniPalette.pages[i])
                                    .frame(width: 6, height: 6)
                                Capsule()
                                    .fill(palette.ink.opacity(i == active ? 0.6 : 0.32))
                                    .frame(height: 3)
                            }
                            .padding(.horizontal, 5)
                            .frame(width: tabWidth, height: 15)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            HStack(spacing: 5) {
                ForEach(["chevron.left", "chevron.right"], id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(palette.ink.opacity(0.4))
                }
                Capsule().fill(palette.ink.opacity(0.13)).frame(height: 12)
            }
            .padding(.horizontal, 10)
            .frame(height: 18)
            MiniPage(accent: MiniPalette.pages[active])
                .padding(6)
        }
    }
}

// MARK: - Appearance

private struct AppearanceChoice: View {
    @Environment(AppSettings.self) private var settings
    @Environment(BrowserState.self) private var state

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "Background", footer: settings.theme.style.summary) {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(BackgroundStyle.allCases) { StyleTile(style: $0) }
                }
                .padding(8)
            }
            SettingsGroup {
                if settings.theme.useSpaceColors {
                    SettingsRow(title: "Colour") {
                        SwatchPicker(selected: state.currentSpace.colorHex) { hex in
                            withAnimation(Motion.smooth) { state.currentSpace.colorHex = hex }
                            state.scheduleSave()
                        }
                    }
                } else {
                    SettingsRow(title: "Colour") {
                        SwatchPicker(selected: settings.theme.tintHex) { hex in
                            withAnimation(Motion.smooth) { settings.theme.tintHex = hex }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Search

private struct SearchChoice: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accent) private var accent

    private let engines = SearchEngine.allCases.filter { $0 != .custom }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        let current = settings.general.searchEngine
        VStack(alignment: .leading, spacing: 18) {
            // What typing in the address bar will do.
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.5))
                Text("Search with \(current == .custom ? SearchEngine.google.label : current.label)")
                    .font(.system(size: 15))
                    .foregroundStyle(.primary.opacity(0.55))
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(engines) { engine in
                    EngineTile(engine: engine, selected: engine == current) {
                        withAnimation(Motion.snappy) { settings.general.searchEngine = engine }
                    }
                }
            }
        }
    }
}

private struct EngineTile: View {
    @Environment(\.accent) private var accent
    let engine: SearchEngine
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: action) {
            VStack(spacing: 8) {
                EngineLogo(engine: engine, size: 30)
                Text(engine.label)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.primary.opacity(selected ? 0.95 : 0.7))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .background(shape.fill(selected ? AnyShapeStyle(accent.opacity(0.18)) : AnyShapeStyle(.primary.opacity(hovering ? 0.07 : 0.04))))
            .overlay(shape.strokeBorder(selected ? accent : .primary.opacity(0.08), lineWidth: selected ? 2 : 0.5))
            .contentShape(shape)
        }
        .buttonStyle(SquishButtonStyle(scale: 0.97))
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// An engine's logo on a rounded tile; bare marks (Google's G) get a white one.
private struct EngineLogo: View {
    let engine: SearchEngine
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        Group {
            if let logo = engine.logo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(engine.logoIsBareMark ? size * 0.16 : 0)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.6))
            }
        }
        .frame(width: size, height: size)
        .background(engine.logo == nil || engine.logoIsBareMark ? Color.white : .clear)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

// MARK: - Ad blocking

private struct AdBlockingChoice: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 18) {
            AdBlockPreview(blocking: settings.privacy.blockAds)
                .frame(height: 214)
            SettingsGroup {
                SwitchRow(title: "Block ads and trackers", symbol: "shield.lefthalf.filled", isOn: $settings.privacy.blockAds)
            }
        }
    }
}

/// A news page in miniature, with its ads folding away while blocking is on.
private struct AdBlockPreview: View {
    let blocking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Capsule().fill(Color(white: 0.2)).frame(width: 46, height: 7)
                Spacer()
                ForEach(0..<3, id: \.self) { _ in Capsule().fill(Color(white: 0.75)).frame(width: 22, height: 4) }
            }
            .frame(height: 12)

            Advert(kind: .banner)
                .frame(height: blocking ? 0 : 38)
                .opacity(blocking ? 0 : 1)
                .padding(.bottom, blocking ? -10 : 0)

            HStack(alignment: .top, spacing: blocking ? 0 : 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Capsule().fill(Color(white: 0.25)).frame(width: 190, height: 7)
                    Capsule().fill(Color(white: 0.25)).frame(width: 130, height: 7)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(white: 0.88))
                        .frame(height: 56)
                        .padding(.vertical, 3)
                    ForEach(0..<3, id: \.self) { i in
                        Capsule().fill(Color(white: 0.8)).frame(width: i == 2 ? 150 : nil, height: 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Advert(kind: .box)
                    .frame(width: blocking ? 0 : 118)
                    .opacity(blocking ? 0 : 1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(white: 0.98))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: blocking ? "checkmark.shield.fill" : "shield.slash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(blocking ? Color(red: 0.2, green: 0.68, blue: 0.4) : Color(white: 0.55))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 32)
                .background(Circle().fill(.white))
                .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                .padding(10)
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .animation(AppSettings.shared.animationsEnabled ? .spring(response: 0.5, dampingFraction: 0.82) : nil, value: blocking)
    }
}

private struct Advert: View {
    enum Kind { case banner, box }
    let kind: Kind

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: kind == .banner
                    ? [Color(red: 1, green: 0.62, blue: 0.25), Color(red: 0.96, green: 0.33, blue: 0.47)]
                    : [Color(red: 0.36, green: 0.42, blue: 0.98), Color(red: 0.7, green: 0.36, blue: 0.95)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Text("Ad")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.black.opacity(0.6))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.85)))
                .padding(5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

// MARK: - Finish

private struct FinishChoice: View {
    @Environment(\.accent) private var accent
    @State private var isDefault = GeneralPage.checkDefault()
    @State private var browsers: [BrowserSource] = []

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup {
                SettingsRow(title: "Default browser", symbol: isDefault ? "checkmark.seal.fill" : "globe") {
                    if isDefault {
                        Text("Tuff")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.5))
                    } else {
                        Button("Make Default") {
                            GeneralPage.makeDefaultBrowser { isDefault = GeneralPage.checkDefault() }
                        }
                        .buttonStyle(TuffButtonStyle(kind: .prominent))
                    }
                }
            }

            if !browsers.isEmpty {
                SettingsGroup(title: "Import from") {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(browsers.prefix(10)) { source in
                            ImportSourceTile(source: source) {
                                ImportPage.preselectedSourceID = source.id
                                AppDelegate.shared?.showSettings(tab: .importData)
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .onAppear { browsers = BrowserImporter.detect() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isDefault = GeneralPage.checkDefault()
        }
    }
}

private struct ImportSourceTile: View {
    let source: BrowserSource
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(nsImage: source.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
                Text(source.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.primary.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(SquishButtonStyle(scale: 0.96))
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help("Import from \(source.name)")
    }
}
