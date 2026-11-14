import AppKit
import Observation
import SwiftUI

// MARK: - Model

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select, pen, highlighter, arrow, box, text

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .arrow: "arrow.up.right"
        case .box: "rectangle"
        case .text: "textformat"
        }
    }

    var title: String {
        switch self {
        case .select: "Select"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .arrow: "Arrow"
        case .box: "Box"
        case .text: "Text"
        }
    }

    /// Single-key shortcut, shown in the tooltip.
    var key: Character {
        switch self {
        case .select: "v"
        case .pen: "p"
        case .highlighter: "h"
        case .arrow: "a"
        case .box: "r"
        case .text: "t"
        }
    }
}

struct Annotation: Identifiable, Equatable {
    let id = UUID()
    var tool: AnnotationTool
    var color: NSColor
    /// Stroke width in image points (text uses it to pick its size).
    var width: CGFloat
    /// In image points, top-left origin. Two points (start, end) for arrows and boxes, one for
    /// text, every sample for the pen and highlighter.
    var points: [CGPoint]
    var text = ""
}

enum AnnotationThickness: CaseIterable, Identifiable {
    case thin, medium, thick
    var id: Self { self }
    var points: CGFloat {
        switch self {
        case .thin: 2.5
        case .medium: 4.5
        case .thick: 8
        }
    }
}

/// A screenshot open in the editor, with its annotations.
@Observable
final class ScreenshotSession: Identifiable {
    let id = UUID()
    let image: CGImage
    /// The image's size in points (it's usually 2× that in pixels).
    let pointSize: CGSize
    let mode: ScreenshotMode
    let title: String
    let createdAt = Date()

    var annotations: [Annotation] = []
    /// Earlier states of `annotations`, for undo, and the ones undone, for redo.
    private(set) var history: [[Annotation]] = []
    private(set) var future: [[Annotation]] = []
    /// The state before an edit in progress (a drag, a recolour, retyping a text box).
    @ObservationIgnored private var pending: [Annotation]?
    /// The stroke being drawn right now.
    var draft: Annotation?
    /// The text box being typed into.
    var editingTextID: UUID?
    /// The annotation picked with the Select tool.
    var selectedID: UUID?

    var selected: Annotation? { selectedID.flatMap { id in annotations.first { $0.id == id } } }

    var tool: AnnotationTool = .arrow
    var color: NSColor
    var thickness: AnnotationThickness = .medium

    static let palette: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.27, blue: 0.23, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.84, blue: 0.40, alpha: 1),
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1),
        .white,
        NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1),
    ]

    init(image: CGImage, pointSize: CGSize, mode: ScreenshotMode, title: String, accent: NSColor) {
        self.image = image
        self.pointSize = pointSize
        self.mode = mode
        self.title = title
        color = Self.palette[0]
    }

    var pixelScale: CGFloat { pointSize.width > 0 ? CGFloat(image.width) / pointSize.width : 1 }

    // MARK: Editing and undo

    private func checkpoint() {
        history.append(annotations)
        if history.count > 200 { history.removeFirst() }
        future.removeAll()
    }

    func commit(_ annotation: Annotation) {
        checkpoint()
        annotations.append(annotation)
    }

    /// Starts an edit that may span many changes (a drag); `endEdit` makes it one undo step, or
    /// none if nothing actually changed.
    func beginEdit() {
        if pending == nil { pending = annotations }
    }

    func endEdit() {
        guard let before = pending else { return }
        pending = nil
        guard before != annotations else { return }
        history.append(before)
        future.removeAll()
    }

    /// Changes one annotation as a single undo step.
    func update(_ id: UUID, _ change: (inout Annotation) -> Void) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        beginEdit()
        change(&annotations[i])
        endEdit()
    }

    func undo() {
        endTextEditing()
        guard let previous = history.popLast() else { return }
        future.append(annotations)
        annotations = previous
        dropStaleSelection()
    }

    func redo() {
        endTextEditing()
        guard let next = future.popLast() else { return }
        history.append(annotations)
        annotations = next
        dropStaleSelection()
    }

    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    func clear() {
        guard !annotations.isEmpty else { return }
        editingTextID = nil
        checkpoint()
        annotations.removeAll()
        selectedID = nil
    }

    func delete(_ id: UUID) {
        guard annotations.contains(where: { $0.id == id }) else { return }
        if editingTextID == id { editingTextID = nil }
        checkpoint()
        annotations.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }

    /// Picks an annotation with the Select tool, and shows its colour and width in the toolbar.
    func select(_ id: UUID?) {
        selectedID = id
        guard let a = selected else { return }
        color = a.color
        thickness = AnnotationThickness.allCases.min { abs($0.points - a.width) < abs($1.points - a.width) } ?? thickness
    }

    /// Starts retyping a text annotation.
    func editText(_ id: UUID) {
        beginEdit()
        selectedID = nil
        editingTextID = id
    }

    private func dropStaleSelection() {
        if let id = selectedID, !annotations.contains(where: { $0.id == id }) { selectedID = nil }
    }

    /// Ends typing into a text box, dropping it if it was left empty.
    func endTextEditing() {
        guard let id = editingTextID else { return }
        editingTextID = nil
        annotations.removeAll { $0.id == id && $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        if pending != nil {
            endEdit()
        } else if history.last == annotations {
            // A new text box left empty: nothing happened.
            history.removeLast()
        }
    }

    // MARK: Output

    /// The screenshot with its annotations drawn in, at full resolution.
    func render() -> NSBitmapImageRep? {
        let width = image.width, height = image.height
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = context.cgContext
        cg.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let drawn = annotations.filter { $0.tool != .text || !$0.text.isEmpty }
        if !drawn.isEmpty {
            // Annotations are in image points, top-left origin.
            cg.translateBy(x: 0, y: CGFloat(height))
            cg.scaleBy(x: pixelScale, y: -pixelScale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            AnnotationRenderer.draw(drawn, in: cg)
            NSGraphicsContext.restoreGraphicsState()
        }
        context.flushGraphics()
        return rep
    }

    var pngData: Data? { render()?.representation(using: .png, properties: [:]) }

    /// "Screenshot – Page Title – 2026-11-12 at 10.42.13.png"
    var filename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let name = cleaned.isEmpty ? "Screenshot" : "Screenshot – \(cleaned.prefix(60))"
        return "\(name) – \(formatter.string(from: createdAt)).png"
    }
}

// MARK: - Drawing

enum AnnotationRenderer {
    /// Draws annotations into a context set up in image points with a top-left origin. Text goes
    /// through AppKit, so the current `NSGraphicsContext` must wrap `cg` (flipped).
    static func draw(_ annotations: [Annotation], in cg: CGContext) {
        for annotation in annotations { draw(annotation, in: cg) }
    }

    static func draw(_ a: Annotation, in cg: CGContext) {
        cg.saveGState()
        defer { cg.restoreGState() }
        let color = a.color.usingColorSpace(.sRGB) ?? a.color
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        switch a.tool {
        case .select:
            return
        case .pen, .highlighter:
            guard let first = a.points.first else { return }
            let path = CGMutablePath()
            path.move(to: first)
            if a.points.count == 1 {
                path.addLine(to: first)
            } else {
                // Smooth through the midpoints so fast strokes don't look jagged.
                for i in 1..<a.points.count {
                    let mid = CGPoint(x: (a.points[i - 1].x + a.points[i].x) / 2, y: (a.points[i - 1].y + a.points[i].y) / 2)
                    path.addQuadCurve(to: mid, control: a.points[i - 1])
                }
                path.addLine(to: a.points[a.points.count - 1])
            }
            if a.tool == .highlighter {
                cg.setBlendMode(.multiply)
                cg.setStrokeColor(color.withAlphaComponent(0.42).cgColor)
                cg.setLineWidth(a.width * 3.6)
                cg.setLineCap(.butt)
            } else {
                cg.setStrokeColor(color.cgColor)
                cg.setLineWidth(a.width)
            }
            cg.addPath(path)
            cg.strokePath()

        case .arrow:
            guard a.points.count >= 2 else { return }
            let start = a.points[0], end = a.points[1]
            let dx = end.x - start.x, dy = end.y - start.y
            let length = hypot(dx, dy)
            guard length > 0.5 else { return }
            let angle = atan2(dy, dx)
            let head = min(max(a.width * 4.2, 12), length * 0.6)
            let spread: CGFloat = .pi / 7
            let left = CGPoint(x: end.x - head * cos(angle - spread), y: end.y - head * sin(angle - spread))
            let right = CGPoint(x: end.x - head * cos(angle + spread), y: end.y - head * sin(angle + spread))
            // The shaft stops inside the head so its round cap doesn't poke out of the tip.
            let shaftEnd = CGPoint(x: end.x - head * 0.7 * cos(angle), y: end.y - head * 0.7 * sin(angle))
            withOutline(cg) {
                cg.setStrokeColor(color.cgColor)
                cg.setFillColor(color.cgColor)
                cg.setLineWidth(a.width)
                cg.move(to: start)
                cg.addLine(to: shaftEnd)
                cg.strokePath()
                cg.move(to: end)
                cg.addLine(to: left)
                cg.addLine(to: right)
                cg.closePath()
                cg.setLineWidth(a.width * 0.6)
                cg.drawPath(using: .fillStroke)
            }

        case .box:
            guard a.points.count >= 2 else { return }
            let rect = CGRect(
                x: min(a.points[0].x, a.points[1].x), y: min(a.points[0].y, a.points[1].y),
                width: abs(a.points[1].x - a.points[0].x), height: abs(a.points[1].y - a.points[0].y)
            )
            let radius = min(a.width * 1.6, rect.width / 2, rect.height / 2)
            withOutline(cg) {
                cg.setStrokeColor(color.cgColor)
                cg.setLineWidth(a.width)
                cg.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                cg.strokePath()
            }

        case .text:
            guard let origin = a.points.first, !a.text.isEmpty else { return }
            // A contrasting outline first (only its outer half shows once the fill goes on top),
            // so white text reads on a white page and black on a black one.
            var outline = textAttributes(a)
            outline[.strokeColor] = color.luminance > 0.55 ? NSColor.black.withAlphaComponent(0.7) : NSColor.white.withAlphaComponent(0.9)
            outline[.strokeWidth] = 16
            NSAttributedString(string: a.text, attributes: outline).draw(at: origin)
            NSAttributedString(string: a.text, attributes: textAttributes(a)).draw(at: origin)
        }
    }

    static func fontSize(_ a: Annotation) -> CGFloat { 10 + a.width * 3 }

    static func textAttributes(_ a: Annotation) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize(a), weight: .bold), .foregroundColor: a.color]
    }

    /// A soft dark halo under a shape so it reads on light and dark pages alike.
    private static func withOutline(_ cg: CGContext, _ draw: () -> Void) {
        cg.setShadow(offset: .zero, blur: 3, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        draw()
        cg.endTransparencyLayer()
    }
}

// MARK: - Editor

/// Full-window card showing a fresh screenshot, with tools to mark it up and buttons to copy it
/// or save it to the downloads folder.
struct ScreenshotEditor: View {
    @Environment(BrowserState.self) private var state
    @Environment(\.accent) private var accent
    @Bindable var session: ScreenshotSession
    @State private var appeared = false

    var body: some View {
        let typing = session.editingTextID != nil
        ZStack {
            Color.black.opacity(appeared ? 0.45 : 0)
                .contentShape(Rectangle())
                .onTapGesture { close() }

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 14)
                    .frame(height: 52)

                AnnotationCanvas(session: session)
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                footer(typing: typing)
                    .padding(.horizontal, 16)
                    .frame(height: 58)
            }
            .background(
                ZStack {
                    VisualEffect(material: .hudWindow, blending: .withinWindow)
                    Color(nsColor: state.currentTint).opacity(0.6)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.primary.opacity(0.14), lineWidth: 1))
            .modifier(CardShadow(cornerRadius: 20, opacity: 0.45, radius: 36, y: 16))
            .padding(.horizontal, 48)
            .padding(.vertical, 36)
            .frame(maxWidth: 1240, maxHeight: 980)
            .scaleEffect(appeared ? 1 : 0.97)
            .opacity(appeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { shortcuts(typing: typing) }
        .onAppear { withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) { appeared = true } }
    }

    // MARK: Header: tools

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.6))
                Text(session.mode == .area ? "Area Screenshot" : session.mode == .visible ? "Visible Screenshot" : "Full Page Screenshot")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            // Tools
            HStack(spacing: 2) {
                ForEach(AnnotationTool.allCases) { tool in
                    EditorToolButton(
                        symbol: tool.symbol, help: "\(tool.title)  \(tool.key.uppercased())",
                        selected: session.tool == tool, accent: accent
                    ) {
                        session.endTextEditing()
                        session.tool = tool
                        if tool != .select { session.selectedID = nil }
                    }
                }
                EditorDivider()
                ForEach(Array(ScreenshotSession.palette.enumerated()), id: \.offset) { _, color in
                    ColorSwatch(color: color, selected: session.color.hexString == color.hexString) {
                        session.color = color
                        recolourEditingText(color)
                        if let id = session.selectedID { session.update(id) { $0.color = color } }
                    }
                }
                EditorDivider()
                ForEach(AnnotationThickness.allCases) { thickness in
                    EditorToolButton(selected: session.thickness == thickness, accent: accent, help: "Stroke Width") {
                        session.thickness = thickness
                        if let id = session.selectedID { session.update(id) { $0.width = thickness.points } }
                    } label: {
                        Circle()
                            .fill(.primary.opacity(0.85))
                            .frame(width: thickness.points + 1.5, height: thickness.points + 1.5)
                    }
                }
                EditorDivider()
                EditorToolButton(symbol: "arrow.uturn.backward", help: "Undo  ⌘Z", disabled: !session.canUndo) {
                    withAnimation(Motion.quick) { session.undo() }
                }
                EditorToolButton(symbol: "arrow.uturn.forward", help: "Redo  ⇧⌘Z", disabled: !session.canRedo) {
                    withAnimation(Motion.quick) { session.redo() }
                }
                EditorToolButton(symbol: "trash", help: "Clear Markup", disabled: session.annotations.isEmpty) {
                    withAnimation(Motion.quick) { session.clear() }
                }
            }
            .padding(4)
            .background(Capsule().fill(.primary.opacity(0.07)))
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
            .fixedSize()

            HStack {
                Spacer(minLength: 0)
                IconButton(symbol: "xmark", size: 11, weight: .bold, side: 26, help: "Close  esc") { close() }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
        }
    }

    private func recolourEditingText(_ color: NSColor) {
        guard let id = session.editingTextID, let i = session.annotations.firstIndex(where: { $0.id == id }) else { return }
        session.annotations[i].color = color
    }

    // MARK: Footer: output

    private func footer(typing: Bool) -> some View {
        HStack(spacing: 10) {
            Text("\(session.image.width) × \(session.image.height) px")
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.5))
            if session.mode == .fullPage, session.pointSize.height >= Screenshotter.maxFullPageHeight - 1 {
                Text("· Trimmed to the first \(Int(Screenshotter.maxFullPageHeight)) points")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.4))
            }
            Spacer()
            Button { save() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 11, weight: .bold))
                    Text("Save to Downloads")
                    KeyHint("⌘S")
                }
            }
            .buttonStyle(PromptButtonStyle(fill: .primary.opacity(0.1), text: .primary, trailingPadding: 6))

            let fill = state.currentTint.derivedAccent
            let text: Color = fill.luminance > 0.45 ? Color.black.opacity(0.85) : .white
            Button { copy() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .bold))
                    Text("Copy")
                    KeyHint("↩", color: text)
                }
            }
            .buttonStyle(PromptButtonStyle(fill: Color(nsColor: fill), text: text, trailingPadding: 6))
        }
    }

    /// Keyboard shortcuts. Off while a text box has focus, so typing reaches it.
    @ViewBuilder
    private func shortcuts(typing: Bool) -> some View {
        let selected = session.selectedID
        ZStack {
            // Esc lets go of the selection first, then closes.
            Button("") {
                if session.selectedID != nil { session.selectedID = nil } else { close() }
            }
            .keyboardShortcut(typing ? nil : .cancelAction)
            Button("") { if let selected { withAnimation(Motion.quick) { session.delete(selected) } } }
                .keyboardShortcut(typing || selected == nil ? nil : KeyboardShortcut(.delete, modifiers: []))
            Button("") { if let selected { withAnimation(Motion.quick) { session.delete(selected) } } }
                .keyboardShortcut(typing || selected == nil ? nil : KeyboardShortcut(.deleteForward, modifiers: []))
            // Arrow keys nudge the selection a point (ten with Shift).
            ForEach(Self.nudges, id: \.key.character) { nudge in
                Button("") { nudgeSelection(nudge.dx, nudge.dy) }
                    .keyboardShortcut(typing || selected == nil ? nil : KeyboardShortcut(nudge.key, modifiers: []))
                Button("") { nudgeSelection(nudge.dx * 10, nudge.dy * 10) }
                    .keyboardShortcut(typing || selected == nil ? nil : KeyboardShortcut(nudge.key, modifiers: .shift))
            }
            Button("") { copy() }.keyboardShortcut(typing ? nil : .defaultAction)
            Button("") { copy() }.keyboardShortcut(typing ? nil : KeyboardShortcut("c", modifiers: .command))
            Button("") { save() }.keyboardShortcut(KeyboardShortcut("s", modifiers: .command))
            Button("") { withAnimation(Motion.quick) { session.undo() } }.keyboardShortcut(typing ? nil : KeyboardShortcut("z", modifiers: .command))
            Button("") { withAnimation(Motion.quick) { session.redo() } }.keyboardShortcut(typing ? nil : KeyboardShortcut("z", modifiers: [.command, .shift]))
            ForEach(AnnotationTool.allCases) { tool in
                Button("") {
                    session.tool = tool
                    if tool != .select { session.selectedID = nil }
                }
                    .keyboardShortcut(typing ? nil : KeyboardShortcut(KeyEquivalent(tool.key), modifiers: []))
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private struct Nudge {
        let key: KeyEquivalent
        let dx: CGFloat
        let dy: CGFloat
    }

    private static let nudges = [
        Nudge(key: .leftArrow, dx: -1, dy: 0), Nudge(key: .rightArrow, dx: 1, dy: 0),
        Nudge(key: .upArrow, dx: 0, dy: -1), Nudge(key: .downArrow, dx: 0, dy: 1),
    ]

    private func nudgeSelection(_ dx: CGFloat, _ dy: CGFloat) {
        guard let id = session.selectedID else { return }
        session.update(id) { $0 = AnnotationGeometry.moved($0, by: CGSize(width: dx, height: dy)) }
    }

    // MARK: Actions

    private func copy() {
        session.endTextEditing()
        session.selectedID = nil
        guard let png = session.pngData else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let image = NSImage(data: png), let tiff = image.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
        close()
        state.show(Toast(symbol: "doc.on.doc", text: "Copied screenshot"))
    }

    private func save() {
        session.endTextEditing()
        guard let png = session.pngData else { return }
        let folder = AppSettings.shared.downloads.folder
        var url = folder.appendingPathComponent(session.filename)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(session.filename.replacingOccurrences(of: ".png", with: " \(n).png"))
            n += 1
        }
        do {
            try png.write(to: url, options: .atomic)
            close()
            state.show(Toast(symbol: "arrow.down.circle", text: "Saved to \(folder.lastPathComponent)"))
        } catch {
            state.show(Toast(symbol: "exclamationmark.triangle", text: "Couldn’t save the screenshot"))
        }
    }

    private func close() {
        withAnimation(Motion.snappy) { state.screenshot = nil }
    }
}

// MARK: - Canvas

/// The screenshot, fitted to the space, with its annotations over it. Very tall captures (a
/// full page) fit the width and scroll.
private struct AnnotationCanvas: View {
    @Bindable var session: ScreenshotSession

    /// What the Select tool's drag in progress is doing.
    private enum Interaction {
        case move(Annotation)
        case reshape(Annotation, AnnotationHandle)
        case none
    }
    @State private var interaction: Interaction?
    @State private var hoveredID: UUID?
    @State private var hoveredHandle: AnnotationHandle?

    var body: some View {
        GeometryReader { geo in
            let size = session.pointSize
            let avail = geo.size
            let fitWidth = min(avail.width, size.width)
            let scrolls = size.height * (fitWidth / max(size.width, 1)) > avail.height * 1.35
            let scale = scrolls ? fitWidth / size.width : min(avail.width / size.width, avail.height / size.height, 1)
            let display = CGSize(width: size.width * scale, height: size.height * scale)
            Group {
                if scrolls {
                    ScrollView(.vertical) {
                        surface(scale: scale, display: display)
                            .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.visible)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    surface(scale: scale, display: display)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func surface(scale: CGFloat, display: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return ZStack(alignment: .topLeading) {
            Image(decorative: session.image, scale: session.pixelScale)
                .resizable()
                .interpolation(.high)
                .frame(width: display.width, height: display.height)

            Canvas { context, _ in
                context.scaleBy(x: scale, y: scale)
                var shown = session.annotations.filter { $0.id != session.editingTextID }
                if let draft = session.draft { shown.append(draft) }
                context.withCGContext { cg in
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
                    AnnotationRenderer.draw(shown, in: cg)
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            .frame(width: display.width, height: display.height)
            .allowsHitTesting(false)

            Color.clear
                .frame(width: display.width, height: display.height)
                .contentShape(Rectangle())
                .pointerStyle(pointer)
                .onContinuousHover { phase in
                    guard session.tool == .select, interaction == nil else { return }
                    switch phase {
                    case .active(let location):
                        let point = CGPoint(x: location.x / scale, y: location.y / scale)
                        hoveredHandle = handle(at: location, scale: scale)
                        hoveredID = hoveredHandle == nil ? AnnotationGeometry.hit(session.annotations, at: point, tolerance: 5 / scale)?.id : nil
                    case .ended:
                        hoveredID = nil
                        hoveredHandle = nil
                    }
                }
                .gesture(session.tool == .select ? AnyGesture(selecting(scale: scale).map { _ in }) : AnyGesture(drawing(scale: scale).map { _ in }))

            if session.tool == .select || session.selectedID != nil {
                AnnotationSelectionOverlay(session: session, scale: scale, hoveredID: session.tool == .select ? hoveredID : nil)
                    .frame(width: display.width, height: display.height)
            }

            if let id = session.editingTextID, let index = session.annotations.firstIndex(where: { $0.id == id }) {
                AnnotationTextField(session: session, index: index, scale: scale)
            }
        }
        .frame(width: display.width, height: display.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.16), lineWidth: 1))
    }

    private var pointer: PointerStyle {
        switch session.tool {
        case .text: return .horizontalText
        case .select:
            if case .move = interaction { return .grabActive }
            if case .reshape(_, let handle) = interaction { return handle.pointer }
            if let hoveredHandle { return hoveredHandle.pointer }
            return hoveredID != nil ? .grabIdle : .default
        default: return .rectSelection
        }
    }

    /// The selected annotation's handle under a point in display coordinates.
    private func handle(at location: CGPoint, scale: CGFloat) -> AnnotationHandle? {
        guard let a = session.selected else { return nil }
        let reach = AnnotationSelectionOverlay.handleSize / 2 + 4
        return AnnotationGeometry.handles(a).first { hypot($0.1.x * scale - location.x, $0.1.y * scale - location.y) <= reach }?.0
    }

    /// The Select tool: press on an annotation to pick it and drag to move it, drag a handle to
    /// resize (or reshape an arrow), double-click text to retype it, press on nothing to let go.
    private func selecting(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if interaction == nil {
                    session.endTextEditing()
                    let start = CGPoint(x: value.startLocation.x / scale, y: value.startLocation.y / scale)
                    if let selected = session.selected, let handle = handle(at: value.startLocation, scale: scale) {
                        interaction = .reshape(selected, handle)
                    } else if let hit = AnnotationGeometry.hit(session.annotations, at: start, tolerance: 5 / scale) {
                        session.select(hit.id)
                        interaction = .move(hit)
                    } else {
                        session.selectedID = nil
                        interaction = Interaction.none
                    }
                    hoveredID = nil
                    session.beginEdit()
                }
                let point = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
                let delta = CGSize(width: value.translation.width / scale, height: value.translation.height / scale)
                switch interaction {
                case .move(let original):
                    replace(AnnotationGeometry.moved(original, by: delta))
                case .reshape(let original, let handle):
                    replace(AnnotationGeometry.resized(original, handle: handle, to: point))
                default:
                    break
                }
            }
            .onEnded { value in
                let ended = interaction
                interaction = nil
                session.endEdit()
                // Double-clicking text without dragging it: retype it.
                if case .move(let original) = ended, original.tool == .text,
                   hypot(value.translation.width, value.translation.height) < 2,
                   (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                    session.editText(original.id)
                }
            }
    }

    private func replace(_ annotation: Annotation) {
        guard let i = session.annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        session.annotations[i] = annotation
    }

    private func drawing(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let point = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
                let start = CGPoint(x: value.startLocation.x / scale, y: value.startLocation.y / scale)
                if session.draft == nil {
                    session.endTextEditing()
                    guard session.tool != .text else { return }
                    session.draft = Annotation(
                        tool: session.tool, color: session.color,
                        width: session.thickness.points, points: [start]
                    )
                }
                switch session.tool {
                case .pen, .highlighter:
                    session.draft?.points.append(point)
                case .arrow, .box:
                    session.draft?.points = [start, point]
                case .text, .select:
                    break
                }
            }
            .onEnded { value in
                if session.tool == .text {
                    let point = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
                    let size = AnnotationRenderer.fontSize(Annotation(tool: .text, color: .white, width: session.thickness.points, points: []))
                    var text = Annotation(tool: .text, color: session.color, width: session.thickness.points, points: [
                        CGPoint(x: point.x, y: point.y - size * 0.6),
                    ])
                    text.text = ""
                    session.commit(text)
                    session.editingTextID = text.id
                    return
                }
                guard var draft = session.draft else { return }
                session.draft = nil
                // A click without a drag: a dot for the pen, nothing for shapes.
                if draft.tool == .arrow || draft.tool == .box {
                    guard draft.points.count == 2, hypot(draft.points[1].x - draft.points[0].x, draft.points[1].y - draft.points[0].y) > 3 else { return }
                }
                if draft.points.count == 1 { draft.points.append(draft.points[0]) }
                session.commit(draft)
            }
    }
}

/// Typing into a text annotation, in place.
private struct AnnotationTextField: View {
    @Bindable var session: ScreenshotSession
    let index: Int
    let scale: CGFloat
    @FocusState private var focused: Bool

    var body: some View {
        let a = session.annotations[index]
        let size = AnnotationRenderer.fontSize(a) * scale
        let text = Binding(
            get: { session.annotations.indices.contains(index) ? session.annotations[index].text : "" },
            set: { if session.annotations.indices.contains(index) { session.annotations[index].text = $0 } }
        )
        TextField("Type…", text: text)
            .textFieldStyle(.plain)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(Color(nsColor: a.color))
            .shadow(color: .black.opacity(0.4), radius: 2)
            .fixedSize()
            .frame(minWidth: 60 * scale, alignment: .leading)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color(nsColor: a.color).opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            )
            .offset(x: (a.points.first?.x ?? 0) * scale - 4, y: (a.points.first?.y ?? 0) * scale)
            .focused($focused)
            .onSubmit { session.endTextEditing() }
            .onExitCommand { session.endTextEditing() }
            .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

// MARK: - Bits

private struct EditorToolButton<Label: View>: View {
    var selected = false
    var accent: Color = .accentColor
    var help = ""
    var disabled = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(.primary.opacity(disabled ? 0.25 : (selected || hovering ? 0.95 : 0.65)))
                .frame(width: 30, height: 28)
                .background(
                    Capsule().fill(selected ? AnyShapeStyle(accent.opacity(0.35)) : AnyShapeStyle(.primary.opacity(hovering && !disabled ? 0.1 : 0)))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(SquishButtonStyle())
        .disabled(disabled)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: selected)
        .help(help)
    }
}

extension EditorToolButton where Label == AnyView {
    init(symbol: String, help: String, selected: Bool = false, accent: Color = .accentColor, disabled: Bool = false, action: @escaping () -> Void) {
        self.init(selected: selected, accent: accent, help: help, disabled: disabled, action: action) {
            AnyView(Image(systemName: symbol).font(.system(size: 12.5, weight: .semibold)))
        }
    }
}

private struct ColorSwatch: View {
    let color: NSColor
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(nsColor: color))
                .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
                .frame(width: 15, height: 15)
                .padding(3)
                .overlay(Circle().strokeBorder(.primary.opacity(selected ? 0.9 : 0), lineWidth: 1.5))
                .scaleEffect(hovering && !selected ? 1.1 : 1)
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(SquishButtonStyle())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: selected)
    }
}

private struct EditorDivider: View {
    var body: some View {
        Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: 16).padding(.horizontal, 4)
    }
}
