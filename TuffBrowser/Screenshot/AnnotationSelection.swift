import AppKit
import SwiftUI

/// What a drag on a selected annotation grabs.
enum AnnotationHandle: Equatable {
    /// An arrow's tail (`start`) or tip (`end`): dragging reshapes it.
    case start, end
    /// A corner of the frame: dragging resizes, keeping the opposite corner put.
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var pointer: PointerStyle {
        switch self {
        case .start, .end: .grabIdle
        case .topLeading: .frameResize(position: .topLeading)
        case .topTrailing: .frameResize(position: .topTrailing)
        case .bottomLeading: .frameResize(position: .bottomLeading)
        case .bottomTrailing: .frameResize(position: .bottomTrailing)
        }
    }
}

/// Hit-testing, framing, moving and resizing annotations. Everything is in image points.
enum AnnotationGeometry {
    /// The box the selection frame and its corner handles sit on.
    static func frame(_ a: Annotation) -> CGRect {
        switch a.tool {
        case .box:
            guard a.points.count >= 2 else { return .null }
            return rect(a.points[0], a.points[1])
        case .text:
            guard let origin = a.points.first else { return .null }
            let size = NSAttributedString(string: a.text.isEmpty ? " " : a.text, attributes: AnnotationRenderer.textAttributes(a)).size()
            return CGRect(origin: origin, size: size)
        case .pen, .highlighter, .arrow, .select:
            guard let first = a.points.first else { return .null }
            var r = CGRect(origin: first, size: .zero)
            for p in a.points.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
            let pad = a.tool == .highlighter ? a.width * 1.8 : a.width / 2
            return r.insetBy(dx: -pad, dy: -pad)
        }
    }

    static func handles(_ a: Annotation) -> [(AnnotationHandle, CGPoint)] {
        if a.tool == .arrow, a.points.count >= 2 {
            return [(.start, a.points[0]), (.end, a.points[1])]
        }
        let r = frame(a)
        guard !r.isNull else { return [] }
        return [
            (.topLeading, CGPoint(x: r.minX, y: r.minY)), (.topTrailing, CGPoint(x: r.maxX, y: r.minY)),
            (.bottomLeading, CGPoint(x: r.minX, y: r.maxY)), (.bottomTrailing, CGPoint(x: r.maxX, y: r.maxY)),
        ]
    }

    /// The topmost annotation under `point`. Strokes win over the insides of boxes and text, so
    /// an arrow drawn inside a box can still be picked.
    static func hit(_ annotations: [Annotation], at point: CGPoint, tolerance: CGFloat) -> Annotation? {
        if let a = annotations.last(where: { hitsStroke($0, point, tolerance) }) { return a }
        return annotations.last { a in
            (a.tool == .box || a.tool == .text) && frame(a).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    private static func hitsStroke(_ a: Annotation, _ p: CGPoint, _ tolerance: CGFloat) -> Bool {
        let reach = tolerance + (a.tool == .highlighter ? a.width * 1.8 : a.width / 2)
        switch a.tool {
        case .pen, .highlighter:
            if a.points.count == 1 { return distance(p, a.points[0]) <= reach }
            return zip(a.points, a.points.dropFirst()).contains { segmentDistance(p, $0, $1) <= reach }
        case .arrow:
            guard a.points.count >= 2 else { return false }
            // The head is wider than the shaft.
            return segmentDistance(p, a.points[0], a.points[1]) <= reach + a.width
        case .box:
            guard a.points.count >= 2 else { return false }
            let r = rect(a.points[0], a.points[1])
            let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            return (0..<4).contains { segmentDistance(p, corners[$0], corners[($0 + 1) % 4]) <= reach }
        case .text:
            return frame(a).contains(p)
        case .select:
            return false
        }
    }

    static func moved(_ a: Annotation, by delta: CGSize) -> Annotation {
        var a = a
        a.points = a.points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
        return a
    }

    /// `original` with `handle` dragged to `point`.
    static func resized(_ original: Annotation, handle: AnnotationHandle, to point: CGPoint) -> Annotation {
        var a = original
        switch handle {
        case .start:
            if a.points.count >= 2 { a.points[0] = point }
            return a
        case .end:
            if a.points.count >= 2 { a.points[1] = point }
            return a
        default:
            break
        }
        let r = frame(original)
        guard !r.isNull else { return a }
        // The corner that stays put.
        let anchor: CGPoint
        let moving: CGPoint
        switch handle {
        case .topLeading: anchor = CGPoint(x: r.maxX, y: r.maxY); moving = CGPoint(x: r.minX, y: r.minY)
        case .topTrailing: anchor = CGPoint(x: r.minX, y: r.maxY); moving = CGPoint(x: r.maxX, y: r.minY)
        case .bottomLeading: anchor = CGPoint(x: r.maxX, y: r.minY); moving = CGPoint(x: r.minX, y: r.maxY)
        default: anchor = CGPoint(x: r.minX, y: r.minY); moving = CGPoint(x: r.maxX, y: r.maxY)
        }

        switch original.tool {
        case .box:
            a.points = [anchor, point]
        case .text:
            // Text scales evenly, by however far the corner was pulled along the diagonal.
            let before = distance(moving, anchor)
            let after = max(0, projection(of: point, onto: anchor, toward: moving))
            let factor = min(max(before > 0 ? after / before : 1, 0.25), 8)
            let size = max(AnnotationRenderer.fontSize(original) * factor, 8)
            a.width = (size - 10) / 3
            let scaledFrame = frame(a)
            // Keep the anchor corner where it was.
            let x = anchor.x == r.minX ? r.minX : anchor.x - scaledFrame.width
            let y = anchor.y == r.minY ? r.minY : anchor.y - scaledFrame.height
            a.points = [CGPoint(x: x, y: y)]
        case .pen, .highlighter:
            let sx = scale(point.x - anchor.x, moving.x - anchor.x)
            let sy = scale(point.y - anchor.y, moving.y - anchor.y)
            a.points = original.points.map { CGPoint(x: anchor.x + ($0.x - anchor.x) * sx, y: anchor.y + ($0.y - anchor.y) * sy) }
        case .arrow, .select:
            break
        }
        return a
    }

    // MARK: Maths

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    /// How far `point` lies from `origin` along the direction to `toward`.
    private static func projection(of point: CGPoint, onto origin: CGPoint, toward: CGPoint) -> CGFloat {
        let dx = toward.x - origin.x, dy = toward.y - origin.y
        let length = hypot(dx, dy)
        guard length > 0 else { return 0 }
        return ((point.x - origin.x) * dx + (point.y - origin.y) * dy) / length
    }

    /// A stretch factor that never collapses a stroke to nothing (it may flip it, though).
    private static func scale(_ now: CGFloat, _ before: CGFloat) -> CGFloat {
        guard abs(before) > 0.5 else { return 1 }
        let s = now / before
        return abs(s) < 0.05 ? (s < 0 ? -0.05 : 0.05) : s
    }
}

// MARK: - Overlay

/// The frame, handles and delete button around the selected annotation, and a faint outline
/// around the one under the pointer. Drawn over the canvas only: none of it is in the export.
struct AnnotationSelectionOverlay: View {
    @Environment(\.accent) private var accent
    @Bindable var session: ScreenshotSession
    let scale: CGFloat
    let hoveredID: UUID?

    static let handleSize: CGFloat = 10

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let id = hoveredID, id != session.selectedID, let a = session.annotations.first(where: { $0.id == id }) {
                outline(a)
                    .stroke(accent.opacity(0.55), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            if let a = session.selected, a.id != session.editingTextID {
                if a.tool == .arrow, a.points.count >= 2 {
                    Path { path in
                        path.move(to: display(a.points[0]))
                        path.addLine(to: display(a.points[1]))
                    }
                    .stroke(accent.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .allowsHitTesting(false)
                } else {
                    outline(a)
                        .stroke(accent, style: StrokeStyle(lineWidth: 1.25, dash: [5, 3]))
                        .allowsHitTesting(false)
                }
                ForEach(Array(AnnotationGeometry.handles(a).enumerated()), id: \.offset) { _, handle in
                    Circle()
                        .fill(.white)
                        .overlay(Circle().strokeBorder(accent, lineWidth: 2))
                        .frame(width: Self.handleSize, height: Self.handleSize)
                        .position(display(handle.1))
                        .allowsHitTesting(false)
                }
                deleteButton(a)
            }
        }
    }

    private func display(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale, y: p.y * scale) }

    private func displayFrame(_ a: Annotation) -> CGRect {
        let r = AnnotationGeometry.frame(a)
        return CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
    }

    private func outline(_ a: Annotation) -> Path {
        Path(roundedRect: displayFrame(a).insetBy(dx: -3, dy: -3), cornerRadius: 4)
    }

    /// A small trash button just above the selection's top-right corner (or below it at the top
    /// of the image).
    private func deleteButton(_ a: Annotation) -> some View {
        let r = displayFrame(a)
        let y = r.minY - 20 < 4 ? r.maxY + 20 : r.minY - 20
        return Button {
            withAnimation(Motion.quick) { session.delete(a.id) }
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 22)
                .background(Capsule().fill(Color.black.opacity(0.78)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(SquishButtonStyle())
        .help("Delete  ⌫")
        .position(x: r.maxX, y: y)
    }
}
