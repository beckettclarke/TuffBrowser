import AppKit
import SwiftUI

/// A question or notice shown as a card over a window: the app's own dialog, used instead of
/// `NSAlert` for anything users see (extension installs and permissions, deleting a space, …).
struct Prompt: Identifiable {
    struct Item: Hashable {
        var symbol: String
        var text: String
    }

    /// A text box on the card (a page's `prompt()`, a sign-in form).
    struct Field {
        var placeholder: String
        var text = ""
        var secure = false
    }

    /// The window the card covers.
    enum Host { case browser, settings }

    let id = UUID()
    var host: Host = .browser
    /// The browser window's state for `.browser` cards (an Incognito window's page asks in
    /// that window). Nil: the browser window in front.
    var browser: BrowserState?
    var icon: NSImage?
    /// SF Symbol drawn in a tile when there is no `icon`.
    var symbol = "puzzlepiece.extension.fill"
    /// Tints the symbol tile; nil for a neutral one.
    var symbolColor: NSColor?
    var title: String
    var subtitle: String?
    var message: String?
    var itemsHeading: String?
    var items: [Item] = []
    /// A caveat shown in a highlighted box (e.g. a feature WebKit doesn't support).
    var note: String?
    var confirmTitle: String
    /// nil for a notice with a single button.
    var cancelTitle: String? = "Cancel"
    /// A second way to say yes, beside the main button (e.g. "Use Transmission" next to "Use
    /// Tuff"); `PromptResult.alternate` says it was picked.
    var alternateTitle: String?
    var destructive = false
    /// Edited in place while the card is up; `PromptResult.fields` has what was typed.
    var fields: [Field] = []
    /// A checkbox beside the buttons (e.g. "Don’t ask again"); nil for none.
    var checkbox: String?
    var checked = false
    /// Replaces the usual confirm key, e.g. ⌘Q for Quit.
    var confirmKey: (shortcut: KeyboardShortcut, label: String)?

    /// Destructive actions need ⌘↩ so a stray Return can't confirm them; others take plain ↩.
    var confirmShortcut: KeyboardShortcut {
        confirmKey?.shortcut ?? (destructive ? KeyboardShortcut(.return, modifiers: .command) : .defaultAction)
    }
    var confirmShortcutLabel: String { confirmKey?.label ?? (destructive ? "⌘↩" : "↩") }
}

struct PromptResult {
    var confirmed: Bool
    /// The prompt's `alternateTitle` button was picked (then `confirmed` is false).
    var alternate = false
    /// The text of each of the prompt's `fields`, in order.
    var fields: [String]
    var checked: Bool
}

/// Shows prompts one at a time and reports the answer.
@MainActor
enum PromptPresenter {
    private static var queue: [(Prompt, CheckedContinuation<PromptResult, Never>)] = []
    private static var current: (id: UUID, continuation: CheckedContinuation<PromptResult, Never>)?
    /// The state whose window shows the card on screen.
    private static var currentState: BrowserState = .shared

    /// The prompt on screen now, if any.
    static var currentID: UUID? { current?.id }

    /// True when the user confirms; false when they cancel (or dismiss a notice).
    @discardableResult
    static func present(_ prompt: Prompt) async -> Bool {
        await ask(prompt).confirmed
    }

    /// Like `present`, but also returns what was typed in the fields and the checkbox state.
    static func ask(_ prompt: Prompt) async -> PromptResult {
        await withCheckedContinuation { continuation in
            queue.append((prompt, continuation))
            showNext()
        }
    }

    static func resolve(_ confirmed: Bool, alternate: Bool = false) {
        guard let (_, continuation) = current else { return }
        current = nil
        let state = currentState
        let live = state.prompt
        let result = PromptResult(
            confirmed: confirmed,
            alternate: alternate,
            fields: live?.fields.map(\.text) ?? [],
            checked: live?.checked ?? false
        )
        withAnimation(Motion.quick) { state.prompt = nil }
        continuation.resume(returning: result)
        state.focusWebView()
        // Let the outgoing card fade before the next one comes in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { showNext() }
    }

    private static func showNext() {
        guard current == nil, !queue.isEmpty else { return }
        let (prompt, continuation) = queue.removeFirst()
        // Settings belongs to the main window's state, so its cards are drawn from there.
        let state = prompt.host == .settings ? BrowserState.shared : (prompt.browser ?? BrowserState.active)
        currentState = state
        let host: NSWindow? = switch prompt.host {
        case .browser: state.window
        case .settings: AppDelegate.shared?.visibleSettingsWindow ?? state.window
        }
        // The browser window was closed (it comes back from the Dock): bring it back to hold
        // the card, rather than falling back to a native alert. An Incognito window that has
        // gone away can't come back, so its question is answered "no" — the safe answer.
        var window = host
        if window == nil, !state.isPrivate {
            AppDelegate.shared?.showMainWindow()
            window = state.window
        }
        guard let window else {
            NSLog("Tuff: no window to show “\(prompt.title)” in; answered no")
            continuation.resume(returning: PromptResult(
                confirmed: false, fields: prompt.fields.map(\.text), checked: prompt.checked
            ))
            showNext()
            return
        }
        current = (prompt.id, continuation)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Keep Return / Esc away from the page so they reach the card's buttons.
        window.makeFirstResponder(nil)
        withAnimation(Motion.snappy) { state.prompt = prompt }
    }
}

// MARK: - Views

/// Dimmed scrim that blocks the window, with the prompt card dropping in from the top.
struct PromptOverlay: View {
    let prompt: Prompt
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(appeared ? 0.22 : 0)
                .contentShape(Rectangle())
                .onTapGesture {}

            PromptCard(prompt: prompt)
                .scaleEffect(appeared ? 1 : 0.96, anchor: .top)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : -10)
                .padding(.top, 96)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { appeared = true }
        }
    }
}

struct PromptCard: View {
    @Environment(BrowserState.self) private var state
    let prompt: Prompt

    /// The tint of the window the card covers (Settings doesn't take on a page's colour).
    private var tint: NSColor { prompt.host == .settings ? state.baseTint : state.currentTint }

    private var confirmColor: NSColor {
        prompt.destructive ? .systemRed : tint.derivedAccent
    }
    private var confirmFill: Color { Color(nsColor: confirmColor) }
    /// Dark text on a light accent, white on a deep one.
    private var confirmText: Color {
        confirmColor.luminance > 0.45 ? Color.black.opacity(0.85) : .white
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                PromptIcon(image: prompt.icon, symbol: prompt.symbol, color: prompt.symbolColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(prompt.title)
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle = prompt.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            if let message = prompt.message {
                let text = Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                // Pages can put anything in alert(); keep a long one from running off the window.
                if message.count > 500 {
                    ScrollView { text.frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 240)
                } else {
                    text
                }
            }

            if !prompt.fields.isEmpty {
                VStack(spacing: 8) {
                    ForEach(prompt.fields.indices, id: \.self) { index in
                        PromptField(prompt: prompt, index: index)
                    }
                }
            }

            if !prompt.items.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    if let heading = prompt.itemsHeading {
                        Text(heading)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(prompt.items, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(item.text)
                                .font(.system(size: 13))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.primary.opacity(0.06)))
            }

            if let note = prompt.note {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.yellow)
                        .frame(width: 16)
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.yellow.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.yellow.opacity(0.28), lineWidth: 0.5))
            }

            // Three buttons leave no room beside them: the checkbox gets its own line.
            if let checkbox = prompt.checkbox, prompt.alternateTitle != nil {
                PromptCheckbox(title: checkbox, fill: confirmFill, mark: confirmText)
            }

            HStack(spacing: 8) {
                if let checkbox = prompt.checkbox, prompt.alternateTitle == nil {
                    PromptCheckbox(title: checkbox, fill: confirmFill, mark: confirmText)
                }
                Spacer()
                if let cancel = prompt.cancelTitle {
                    Button(cancel) { PromptPresenter.resolve(false) }
                        .buttonStyle(PromptButtonStyle(fill: .primary.opacity(0.1), text: .primary))
                        .keyboardShortcut(.cancelAction)
                } else {
                    // A notice still closes with Esc.
                    Button("") { PromptPresenter.resolve(false) }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
                if let alternate = prompt.alternateTitle {
                    Button(alternate) { PromptPresenter.resolve(false, alternate: true) }
                        .buttonStyle(PromptButtonStyle(fill: .primary.opacity(0.1), text: .primary))
                }
                Button { PromptPresenter.resolve(true) } label: {
                    HStack(spacing: 8) {
                        Text(prompt.confirmTitle)
                        KeyHint(prompt.confirmShortcutLabel, color: confirmText)
                    }
                }
                .buttonStyle(PromptButtonStyle(fill: confirmFill, text: confirmText, trailingPadding: 6))
                .keyboardShortcut(prompt.confirmShortcut)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(
            ZStack {
                VisualEffect(material: .hudWindow, blending: .withinWindow)
                Color(nsColor: tint).opacity(0.55)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.14), lineWidth: 1))
        .modifier(CardShadow(cornerRadius: 18, opacity: 0.4, radius: 40, y: 18, hollow: true))
    }
}

/// One of a prompt's text boxes. Its text lives in `state.prompt`, so whoever resolves the card
/// (a button, a second ⌘Q, a debug script) reads what was typed.
private struct PromptField: View {
    @Environment(BrowserState.self) private var state
    let prompt: Prompt
    let index: Int

    var body: some View {
        let field = prompt.fields[index]
        let text = Binding(
            get: { state.prompt.flatMap { $0.fields.indices.contains(index) ? $0.fields[index].text : nil } ?? field.text },
            set: { value in if state.prompt?.fields.indices.contains(index) == true { state.prompt?.fields[index].text = value } }
        )
        KeyTextField(
            // The placeholder is drawn below instead: a secure field draws its own too bright.
            text: text, placeholder: "", fontSize: 13,
            selectAllOnFocus: true, secure: field.secure, autoFocus: index == 0,
            identifier: Self.identifier(index),
            onSubmit: {
                // Return moves down the form, then confirms from the last box.
                if index < prompt.fields.count - 1 { Self.focus(index + 1) } else { PromptPresenter.resolve(true) }
            },
            onCancel: { PromptPresenter.resolve(false) },
            onTab: { Self.focus((index + 1) % prompt.fields.count) }
        )
        .frame(height: 20)
        .background(alignment: .leading) {
            if text.wrappedValue.isEmpty {
                Text(field.placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
    }

    private static func identifier(_ index: Int) -> String { "prompt-field-\(index)" }

    private static func focus(_ index: Int) {
        func find(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == identifier(index) { return view }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        for window in NSApp.windows where window.isVisible {
            if let root = window.contentView, let field = find(root) {
                window.makeFirstResponder(field)
                return
            }
        }
    }
}

private struct PromptCheckbox: View {
    @Environment(BrowserState.self) private var state
    let title: String
    let fill: Color
    let mark: Color

    var body: some View {
        let on = state.prompt?.checked ?? false
        Button {
            withAnimation(Motion.quick) { state.prompt?.checked.toggle() }
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(on ? AnyShapeStyle(fill) : AnyShapeStyle(.primary.opacity(0.1)))
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.primary.opacity(on ? 0 : 0.18), lineWidth: 0.5)
                    if on {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(mark)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                .frame(width: 16, height: 16)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PromptIcon: View {
    let image: NSImage?
    let symbol: String
    let color: NSColor?

    /// On a coloured tile: white on a deep colour, dark on a light one (like the Settings rows).
    private var symbolStyle: AnyShapeStyle {
        guard let color else { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(color.luminance > 0.6 ? Color.black.opacity(0.8) : .white)
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(symbolStyle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(shape.fill(color.map { AnyShapeStyle(Color(nsColor: $0)) } ?? AnyShapeStyle(.primary.opacity(0.08))))
                    .overlay(shape.strokeBorder(.primary.opacity(color == nil ? 0 : 0.14), lineWidth: 0.5))
            }
        }
        .frame(width: 42, height: 42)
    }
}

struct PromptButtonStyle: ButtonStyle {
    var fill: AnyShapeStyle
    var text: Color
    /// Smaller when the label ends in a `KeyHint`, so the chip sits snug in the capsule's curve.
    var trailingPadding: CGFloat

    init(fill: some ShapeStyle, text: Color, trailingPadding: CGFloat = 16) {
        self.fill = AnyShapeStyle(fill)
        self.text = text
        self.trailingPadding = trailingPadding
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(text)
            .padding(.leading, 16)
            .padding(.trailing, trailingPadding)
            .frame(height: 30)
            .background(Capsule().fill(fill))
            .overlay(Capsule().fill(.black.opacity(configuration.isPressed ? 0.15 : 0)))
            .contentShape(Capsule())
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

/// A keyboard-shortcut chip (e.g. "⌘↩") shown inside or beside the control it triggers.
struct KeyHint: View {
    let keys: String
    var color: Color = .primary

    init(_ keys: String, color: Color = .primary) {
        self.keys = keys
        self.color = color
    }

    var body: some View {
        Text(keys)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(color.opacity(0.75))
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(Capsule().fill(color.opacity(0.16)))
    }
}
