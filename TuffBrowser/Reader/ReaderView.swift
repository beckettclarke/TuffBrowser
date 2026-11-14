import AppKit
import SwiftUI
import WebKit

/// Reader mode over the page: the reader's web view, with its type controls floating top right.
struct ReaderOverlay: View {
    @Environment(BrowserState.self) private var state
    let reader: Reader
    private let settings = ReaderSettings.shared

    var body: some View {
        let prefs = settings.prefs
        let systemDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ZStack(alignment: .topTrailing) {
            prefs.theme.background(systemDark: systemDark)
            ReaderHost(view: reader.view)
            ReaderToolbar(reader: reader)
                .environment(\.colorScheme, prefs.theme.isDark(systemDark: systemDark) ? .dark : .light)
                .padding(.top, state.findVisible ? 58 : 10)
                .padding(.trailing, 10)
        }
        .animation(Motion.snappy, value: state.findVisible)
        .onAppear { reader.apply(prefs) }
        .onChange(of: prefs) { _, new in reader.apply(new) }
    }
}

/// Hosts the reader's own web view (kept by the `Reader`, so scrolling survives tab switches).
private struct ReaderHost: NSViewRepresentable {
    let view: ReaderWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard view.superview !== container else { return }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        view.appearance = NSApp.effectiveAppearance
        container.addSubview(view)
        DispatchQueue.main.async {
            if let window = view.window, view.reader?.tab?.browser?.selectedTab === view.reader?.tab {
                window.makeFirstResponder(view)
            }
        }
    }
}

private struct ReaderToolbar: View {
    let reader: Reader
    private let settings = ReaderSettings.shared

    var body: some View {
        let prefs = settings.prefs
        HStack(spacing: 2) {
            IconButton(symbol: "textformat.size.smaller", size: 12, side: 26, help: "Smaller Text  ⌘−", disabled: !prefs.canShrink) {
                withAnimation(Motion.quick) { settings.shrink() }
            }
            IconButton(symbol: "textformat.size.larger", size: 13, side: 26, help: "Bigger Text  ⌘+", disabled: !prefs.canGrow) {
                withAnimation(Motion.quick) { settings.grow() }
            }
            divider
            ForEach(ReaderFont.allCases) { font in
                FontChoice(font: font, selected: prefs.font == font) {
                    withAnimation(Motion.quick) { settings.prefs.font = font }
                }
            }
            divider
            HStack(spacing: 5) {
                ForEach(ReaderTheme.allCases) { theme in
                    ThemeSwatch(theme: theme, selected: prefs.theme == theme) {
                        withAnimation(Motion.quick) { settings.prefs.theme = theme }
                    }
                }
            }
            .padding(.horizontal, 5)
            divider
            IconButton(symbol: "xmark", size: 10, weight: .bold, side: 26, help: "Exit Reader Mode  ⌥⌘R") {
                reader.tab?.closeReader()
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .modifier(CardShadow(cornerRadius: 12, opacity: 0.16, radius: 10, y: 3, hollow: true))
    }

    private var divider: some View {
        Rectangle()
            .fill(.primary.opacity(0.12))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 4)
    }
}

/// "Aa" set in the font it picks.
private struct FontChoice: View {
    let font: ReaderFont
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("Aa")
                .font(.system(size: 13, weight: .semibold, design: font == .serif ? .serif : .default))
                .foregroundStyle(.primary.opacity(selected || hovering ? 0.92 : 0.55))
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.primary.opacity(selected ? 0.13 : (hovering ? 0.08 : 0)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SquishButtonStyle())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help(font.label)
    }
}

/// A dot in the theme's page colour; "Match System" is half light, half dark.
private struct ThemeSwatch: View {
    let theme: ReaderTheme
    let selected: Bool
    let action: () -> Void
    @Environment(\.accent) private var accent
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if theme == .auto {
                    Circle().fill(ReaderTheme.light.background(systemDark: false))
                    Circle().fill(ReaderTheme.dark.background(systemDark: true))
                        .mask(Rectangle().offset(x: 9))
                } else {
                    Circle().fill(theme.background(systemDark: false))
                }
                Circle().strokeBorder(.primary.opacity(0.22), lineWidth: 0.5)
            }
            .frame(width: 18, height: 18)
            .padding(2.5)
            .overlay(Circle().strokeBorder(selected ? accent : .primary.opacity(hovering ? 0.25 : 0), lineWidth: 1.5))
            .contentShape(Circle())
        }
        .buttonStyle(SquishButtonStyle())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help(theme.label)
    }
}
