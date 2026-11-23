import PDFKit
import SwiftUI

/// Colours for the viewer, worked out from the window's tint so it sits in the theme like the
/// rest of the chrome.
struct PDFPalette {
    let chrome: Color
    let sidebar: Color
    let menu: Color
    let canvas: NSColor

    init(tint: NSColor, dark: Bool) {
        let base = tint.usingColorSpace(.sRGB) ?? tint
        if dark {
            chrome = Color(nsColor: base.mixed(with: .black, fraction: 0.28))
            sidebar = Color(nsColor: base.mixed(with: .black, fraction: 0.38))
            menu = Color(nsColor: base.mixed(with: .black, fraction: 0.18).mixed(with: .white, fraction: 0.05))
            canvas = base.mixed(with: .black, fraction: 0.56)
        } else {
            chrome = Color(nsColor: base.mixed(with: .white, fraction: 0.62))
            sidebar = Color(nsColor: base.mixed(with: .white, fraction: 0.48))
            menu = Color(nsColor: base.mixed(with: .white, fraction: 0.82))
            canvas = base.mixed(with: NSColor(white: 0.72, alpha: 1), fraction: 0.62)
        }
    }
}

// MARK: - Viewer

struct PDFViewerView: View {
    @Environment(BrowserState.self) private var state
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme
    let viewer: PDFViewer

    static let toolbarHeight: CGFloat = 40

    var body: some View {
        let palette = PDFPalette(tint: state.currentTint, dark: scheme == .dark)
        if viewer.format.isPDF {
            pdfBody(palette)
        } else {
            documentBody(palette)
        }
    }

    /// An office document: Quick Look draws it under a smaller toolbar.
    private func documentBody(_ palette: PDFPalette) -> some View {
        let ready = viewer.isReady
        return VStack(spacing: 0) {
            DocumentToolbar(viewer: viewer)
                .frame(height: Self.toolbarHeight)
                .background(palette.chrome)
            Rectangle().fill(.primary.opacity(0.1)).frame(height: 0.5)
            ZStack {
                Color(nsColor: palette.canvas)
                QuickLookCanvas(viewer: viewer)
                    .opacity(ready ? 1 : 0)
                    .allowsHitTesting(ready)
                if !ready {
                    PDFStatusView(viewer: viewer)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .clipped()
        }
    }

    private func pdfBody(_ palette: PDFPalette) -> some View {
        let ready = viewer.isReady
        return VStack(spacing: 0) {
            PDFToolbar(viewer: viewer)
                .frame(height: Self.toolbarHeight)
                .background(palette.chrome)
            Rectangle().fill(.primary.opacity(0.1)).frame(height: 0.5)
            HStack(spacing: 0) {
                if viewer.sidebarVisible, ready {
                    PDFSidebar(viewer: viewer)
                        .frame(width: 176)
                        .background(palette.sidebar)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Rectangle().fill(.primary.opacity(0.1)).frame(width: 0.5)
                }
                ZStack {
                    Color(nsColor: palette.canvas)
                    PDFCanvas(viewer: viewer, background: palette.canvas)
                        .opacity(ready ? 1 : 0)
                        .allowsHitTesting(ready)
                    if !ready {
                        PDFStatusView(viewer: viewer)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                }
                .clipped()
            }
        }
        .overlayPreferenceValue(PDFDropdownAnchorKey.self) { anchors in
            PDFDropdownLayer(viewer: viewer, anchors: anchors, palette: palette)
        }
        .animation(settings.animationsEnabled ? Motion.snappy : nil, value: viewer.sidebarVisible)
        .animation(settings.animationsEnabled ? Motion.snappy : nil, value: viewer.dropdown)
    }
}

// MARK: - Toolbar

private struct PDFToolbar: View {
    @Environment(BrowserState.self) private var state
    let viewer: PDFViewer

    var body: some View {
        let ready = viewer.isReady
        HStack(spacing: 2) {
            IconButton(symbol: "sidebar.left", size: 13, help: "Show or Hide the Page Sidebar", disabled: !ready) {
                viewer.sidebarVisible.toggle()
            }
            ToolbarDivider()
            IconButton(symbol: "chevron.up", size: 12, weight: .semibold, help: "Previous Page", disabled: !ready || viewer.pageIndex == 0) {
                viewer.previousPage()
            }
            IconButton(symbol: "chevron.down", size: 12, weight: .semibold, help: "Next Page",
                       disabled: !ready || viewer.pageIndex >= viewer.pageCount - 1) {
                viewer.nextPage()
            }
            PageNumberField(viewer: viewer)
                .padding(.leading, 4)
                .opacity(ready ? 1 : 0.4)
                .allowsHitTesting(ready)

            Spacer(minLength: 12)
            Text(viewer.displayTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)
                .help(viewer.filename)
            Spacer(minLength: 12)

            IconButton(symbol: "minus.magnifyingglass", size: 13, help: "Zoom Out (⌘−)", disabled: !ready) { viewer.zoomOut() }
            ZoomPill(viewer: viewer)
                .opacity(ready ? 1 : 0.4)
                .allowsHitTesting(ready)
            IconButton(symbol: "plus.magnifyingglass", size: 13, help: "Zoom In (⌘+)", disabled: !ready) { viewer.zoomIn() }
            ToolbarDivider()
            IconButton(symbol: "magnifyingglass", size: 13, help: "Find in PDF (⌘F)", disabled: !ready) {
                if state.findVisible { state.focusFindField() } else { state.findVisible = true }
            }
            IconButton(symbol: "rotate.right", size: 13, help: "Rotate Clockwise", disabled: !ready) { viewer.rotate(clockwise: true) }
            IconButton(symbol: "square.and.arrow.down", size: 13, help: "Download", disabled: !ready) { viewer.saveCopy() }
            IconButton(symbol: "printer", size: 13, help: "Print (⌘P)", disabled: !ready) { viewer.print() }
            DropdownButton(viewer: viewer, kind: .more) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .help("More")
            .opacity(ready ? 1 : 0.4)
            .allowsHitTesting(ready)
        }
        .padding(.horizontal, 8)
    }
}

private struct ToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.12))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 5)
    }
}

/// The page box: type a number and press Return to go there.
private struct PageNumberField: View {
    let viewer: PDFViewer
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            KeyTextField(
                text: $text, placeholder: "", fontSize: 12.5, fontWeight: .medium, selectAllOnFocus: true,
                autoFocus: false, alignment: .center,
                onSubmit: {
                    if let n = Int(text.trimmed) { viewer.go(to: n - 1) }
                    text = "\(viewer.pageIndex + 1)"
                    viewer.focus()
                },
                onCancel: {
                    text = "\(viewer.pageIndex + 1)"
                    viewer.focus()
                }
            )
            .frame(width: digitsWidth, height: 18)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
            Text("of \(max(viewer.pageCount, 1))")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
        .onAppear { text = "\(viewer.pageIndex + 1)" }
        .onChange(of: viewer.pageIndex) { _, new in text = "\(new + 1)" }
    }

    private var digitsWidth: CGFloat { CGFloat(max(2, String(viewer.pageCount).count)) * 8 + 10 }
}

private struct ZoomPill: View {
    let viewer: PDFViewer

    var body: some View {
        DropdownButton(viewer: viewer, kind: .zoom) {
            HStack(spacing: 4) {
                Text(viewer.zoomLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.7)
            }
            .frame(width: 66, height: 24)
            .background(Capsule().fill(.primary.opacity(0.08)))
        }
        .help("Zoom")
    }
}

/// A toolbar button that opens one of the viewer's dropdowns under itself.
private struct DropdownButton<Label: View>: View {
    let viewer: PDFViewer
    let kind: PDFViewer.Dropdown
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        let open = viewer.dropdown == kind
        Button {
            viewer.dropdown = open ? nil : kind
        } label: {
            label()
                .foregroundStyle(.primary.opacity(open || hovering ? 0.95 : 0.65))
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.primary.opacity(open ? 0.12 : (hovering ? 0.08 : 0)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SquishButtonStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .anchorPreference(key: PDFDropdownAnchorKey.self, value: .bounds) { [kind: $0] }
    }
}

// MARK: - Dropdowns

struct PDFDropdownAnchorKey: PreferenceKey {
    static var defaultValue: [PDFViewer.Dropdown: Anchor<CGRect>] = [:]
    static func reduce(value: inout [PDFViewer.Dropdown: Anchor<CGRect>], nextValue: () -> [PDFViewer.Dropdown: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct PDFDropdownLayer: View {
    let viewer: PDFViewer
    let anchors: [PDFViewer.Dropdown: Anchor<CGRect>]
    let palette: PDFPalette

    var body: some View {
        GeometryReader { geo in
            if let open = viewer.dropdown, let anchor = anchors[open] {
                let button = geo[anchor]
                let width: CGFloat = open == .more ? 268 : 196
                let x = open == .more
                    ? min(button.maxX - width, geo.size.width - width - 8)
                    : max(8, min(button.midX - width / 2, geo.size.width - width - 8))
                let top = button.maxY + 6
                ZStack(alignment: .topLeading) {
                    // Clicking anywhere else closes it.
                    Color.black.opacity(0.001)
                        .onTapGesture { viewer.dropdown = nil }
                    menu(open, maxHeight: geo.size.height - top - 10)
                        .frame(width: width)
                        .offset(x: max(8, x), y: top)
                        .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
                        .id(open)
                }
                .onExitCommand { viewer.dropdown = nil }
            }
        }
    }

    @ViewBuilder
    private func menu(_ kind: PDFViewer.Dropdown, maxHeight: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let content = Group {
            switch kind {
            case .more: PDFMoreMenu(viewer: viewer)
            case .zoom: PDFZoomMenu(viewer: viewer)
            }
        }
        .padding(5)
        // Its own height when it fits; scrolls when the window is too short for it. The outer
        // frame only sets the height it is measured against.
        ViewThatFits(in: .vertical) {
            card(content, shape: shape)
            card(ScrollView(.vertical) { content }.scrollIndicators(.never).frame(height: max(120, maxHeight)), shape: shape)
        }
        .frame(height: max(120, maxHeight), alignment: .top)
    }

    private func card(_ content: some View, shape: RoundedRectangle) -> some View {
        content
            .background(shape.fill(palette.menu))
            .overlay(shape.strokeBorder(.primary.opacity(0.14), lineWidth: 0.5))
            .clipShape(shape)
            .modifier(CardShadow(cornerRadius: 12, opacity: 0.32, radius: 16, y: 6))
    }
}

private struct PDFMoreMenu: View {
    let viewer: PDFViewer

    var body: some View {
        VStack(spacing: 1) {
            MenuRow(symbol: "play.rectangle", title: "Presentation Mode") { run { viewer.startPresentation() } }
            MenuRow(symbol: "link", title: "Copy Link to Page \(viewer.pageIndex + 1)") { run { viewer.copyLinkToPage() } }
            MenuRow(symbol: "arrow.up.forward.app", title: "Open in \(viewer.appName ?? "Preview")") { run { viewer.openInApp() } }
            MenuDivider()
            MenuRow(symbol: "arrow.up.to.line", title: "Go to First Page", disabled: viewer.pageIndex == 0) { run { viewer.firstPage() } }
            MenuRow(symbol: "arrow.down.to.line", title: "Go to Last Page", disabled: viewer.pageIndex >= viewer.pageCount - 1) {
                run { viewer.lastPage() }
            }
            MenuDivider()
            SegmentRow(
                title: "Tool",
                options: [
                    .init(id: "select", symbol: "character.cursor.ibeam", help: "Text Selection Tool"),
                    .init(id: "hand", symbol: "hand.raised", help: "Hand Tool"),
                ],
                selected: viewer.tool == .hand ? "hand" : "select"
            ) { viewer.setTool($0 == "hand" ? .hand : .select) }
            SegmentRow(
                title: "Scrolling",
                options: [
                    .init(id: "page", symbol: "rectangle.portrait", help: "Page Scrolling: one page at a time"),
                    .init(id: "vertical", symbol: "rectangle.split.1x2", help: "Vertical Scrolling"),
                    .init(id: "horizontal", symbol: "rectangle.split.2x1", help: "Horizontal Scrolling"),
                ],
                selected: viewer.scrollMode.rawValue
            ) { viewer.setScrollMode(PDFViewer.ScrollMode(rawValue: $0) ?? .vertical) }
            SegmentRow(
                title: "Spreads",
                options: [
                    .init(id: "none", text: "None", help: "No Spreads: one page across"),
                    .init(id: "odd", text: "Odd", help: "Odd Spreads: pages 1–2, 3–4…"),
                    .init(id: "even", text: "Even", help: "Even Spreads: page 1 alone, then 2–3, 4–5… (like a book)"),
                ],
                selected: viewer.spreads.rawValue
            ) { viewer.setSpreads(PDFViewer.Spreads(rawValue: $0) ?? .none) }
            SegmentRow(
                title: "Rotate",
                options: [
                    .init(id: "left", symbol: "rotate.left", help: "Rotate Counterclockwise"),
                    .init(id: "right", symbol: "rotate.right", help: "Rotate Clockwise"),
                ],
                selected: nil
            ) { viewer.rotate(clockwise: $0 == "right") }
            MenuDivider()
            MenuRow(symbol: "doc.on.doc", title: viewer.selectedPages.count > 1 ? "Export \(viewer.selectedPages.count) Pages…" : "Export Pages…") {
                run { viewer.exportPages() }
            }
            MenuRow(symbol: "square.and.arrow.down", title: "Download") { run { viewer.saveCopy() } }
            MenuRow(symbol: "printer", title: "Print…", shortcut: "⌘P") { run { viewer.print() } }
            MenuRow(symbol: "info.circle", title: "Document Properties…") { run { viewer.showProperties() } }
        }
    }

    private func run(_ action: @escaping () -> Void) {
        viewer.dropdown = nil
        // After the menu has gone, so a card or panel opening isn't fighting its animation.
        DispatchQueue.main.async(execute: action)
    }
}

private struct PDFZoomMenu: View {
    let viewer: PDFViewer

    var body: some View {
        let custom = viewer.zoomMode == .custom
        VStack(spacing: 1) {
            MenuRow(symbol: "wand.and.stars", title: "Automatic", checked: viewer.zoomMode == .auto) { set(.auto) }
            MenuRow(symbol: "arrow.up.left.and.arrow.down.right", title: "Page Fit", checked: viewer.zoomMode == .pageFit) { set(.pageFit) }
            MenuRow(symbol: "arrow.left.and.right", title: "Page Width", checked: viewer.zoomMode == .pageWidth) { set(.pageWidth) }
            MenuRow(symbol: "1.magnifyingglass", title: "Actual Size", checked: custom && abs(viewer.scale - 1) < 0.005) {
                set(.custom, 1)
            }
            MenuDivider()
            ForEach([0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4] as [CGFloat], id: \.self) { level in
                MenuRow(symbol: nil, title: "\(Int(level * 100))%", checked: custom && abs(viewer.scale - level) < 0.005) {
                    set(.custom, level)
                }
            }
        }
    }

    private func set(_ mode: PDFViewer.ZoomMode, _ scale: CGFloat? = nil) {
        viewer.dropdown = nil
        viewer.setZoom(mode, scale: scale)
    }
}

private struct MenuRow: View {
    @Environment(\.accent) private var accent
    let symbol: String?
    let title: String
    var shortcut: String?
    var checked = false
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 18)
                        .foregroundStyle(checked ? accent : .primary.opacity(0.75))
                } else {
                    Color.clear.frame(width: 18, height: 1)
                }
                Text(title)
                    .font(.system(size: 13, weight: checked ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(checked ? accent.opacity(0.16) : .primary.opacity(hovering && !disabled ? 0.09 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.38 : 1)
        .onHover { hovering = $0 }
    }
}

private struct MenuDivider: View {
    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.1))
            .frame(height: 0.5)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

/// A labelled row of small segments (tool, scrolling, spreads), the current one picked out in
/// the accent colour. With no `selected`, the segments are plain buttons (rotate).
private struct SegmentRow: View {
    struct Option: Identifiable {
        let id: String
        var symbol: String?
        var text: String?
        var help: String
    }

    @Environment(\.accent) private var accent
    let title: String
    let options: [Option]
    let selected: String?
    let pick: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.8))
            Spacer(minLength: 6)
            HStack(spacing: 2) {
                ForEach(options) { option in
                    Segment(option: option, on: option.id == selected, accent: accent) { pick(option.id) }
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.07)))
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .frame(height: 34)
    }

    private struct Segment: View {
        let option: Option
        let on: Bool
        let accent: Color
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Group {
                    if let symbol = option.symbol {
                        Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                    } else {
                        Text(option.text ?? "").font(.system(size: 11.5, weight: on ? .semibold : .medium))
                    }
                }
                .foregroundStyle(on ? accent : .primary.opacity(hovering ? 0.9 : 0.62))
                .frame(minWidth: 30)
                .padding(.horizontal, option.symbol == nil ? 6 : 0)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(on ? accent.opacity(0.2) : .primary.opacity(hovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(SquishButtonStyle(scale: 0.94))
            .onHover { hovering = $0 }
            .help(option.help)
        }
    }
}

// MARK: - Sidebar

private struct PDFSidebar: View {
    let viewer: PDFViewer

    var body: some View {
        VStack(spacing: 0) {
            if viewer.hasOutline {
                HStack(spacing: 2) {
                    PaneTab(title: "Pages", on: viewer.sidebarPane == .pages) { viewer.sidebarPane = .pages }
                    PaneTab(title: "Contents", on: viewer.sidebarPane == .outline) { viewer.sidebarPane = .outline }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.07)))
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 4)
            }
            if viewer.sidebarPane == .outline, viewer.hasOutline {
                PDFOutlineList(viewer: viewer)
            } else {
                PDFThumbnailList(viewer: viewer)
            }
        }
    }

    private struct PaneTab: View {
        @Environment(\.accent) private var accent
        let title: String
        let on: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 11.5, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Color.primary.opacity(0.1) : Color.clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct PDFThumbnailList: View {
    let viewer: PDFViewer
    @State private var anchor: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                // Lazy: only the rows near the visible area exist (and ask for thumbnails).
                LazyVStack(spacing: 4) {
                    ForEach(0..<viewer.pageCount, id: \.self) { index in
                        PDFThumbnailCell(
                            viewer: viewer, index: index,
                            current: index == viewer.pageIndex,
                            selected: viewer.selectedPages.count > 1 && viewer.selectedPages.contains(index),
                            generation: viewer.rotationGeneration
                        ) { click(index) }
                        .id(index)
                    }
                }
                .padding(.vertical, 10)
            }
            .scrollIndicators(.automatic)
            .onAppear { proxy.scrollTo(viewer.pageIndex, anchor: .center) }
            .onChange(of: viewer.pageIndex) { _, new in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(new) }
            }
        }
    }

    /// Click: go there. ⌘-click: add or remove from the pages to export. ⇧-click: a run of them.
    private func click(_ index: Int) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            var pages = viewer.selectedPages.isEmpty ? [viewer.pageIndex] : viewer.selectedPages
            if pages.contains(index), pages.count > 1 { pages.remove(index) } else { pages.insert(index) }
            viewer.selectedPages = pages
            anchor = index
        } else if flags.contains(.shift) {
            let from = anchor ?? viewer.pageIndex
            viewer.selectedPages = Set(min(from, index)...max(from, index))
        } else {
            viewer.selectedPages = []
            anchor = index
            viewer.go(to: index)
        }
    }
}

private final class WantedFlag: @unchecked Sendable {
    var value = true
}

private struct PDFThumbnailCell: View {
    @Environment(\.accent) private var accent
    let viewer: PDFViewer
    let index: Int
    let current: Bool
    let selected: Bool
    let generation: Int
    let action: () -> Void
    @State private var image: NSImage?
    @State private var wanted = WantedFlag()

    private static let width: CGFloat = 112

    var body: some View {
        let size = thumbnailSize
        VStack(spacing: 6) {
            ZStack {
                Rectangle().fill(.white)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(.black.opacity(0.14), lineWidth: 0.5)
            )
            .padding(4)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(current ? accent : (selected ? accent.opacity(0.55) : .clear), lineWidth: current ? 2.5 : 1.5)
            )
            Text("\(index + 1)")
                .font(.system(size: 11, weight: current ? .bold : .medium))
                .monospacedDigit()
                .foregroundStyle(current ? accent : .secondary)
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? accent.opacity(0.14) : .clear)
                .padding(.horizontal, 10)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .contextMenu {
            Button("Go to Page \(index + 1)") { viewer.go(to: index) }
            Divider()
            if selected {
                Button("Export \(viewer.selectedPages.count) Selected Pages…") { viewer.exportPages() }
            } else {
                Button("Export Page \(index + 1)…") {
                    viewer.selectedPages = []
                    viewer.go(to: index)
                    viewer.exportPages()
                }
            }
            Button("Copy Link to Page \(index + 1)") {
                viewer.go(to: index)
                viewer.copyLinkToPage()
            }
        }
        .onAppear { wanted.value = true }
        .onDisappear { wanted.value = false }
        .task(id: generation) {
            if let cached = viewer.thumbnails.cached(index) { image = cached; return }
            guard let page = viewer.document?.page(at: index) else { return }
            let flag = wanted
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let drawn = await viewer.thumbnails.thumbnail(of: page, index: index, width: Self.width, scale: scale) { flag.value }
            if let drawn { withAnimation(.easeOut(duration: 0.15)) { image = drawn } }
        }
    }

    /// The page's shape at thumbnail width (rotation included), so rows have their final height
    /// before the image is drawn and the list doesn't jump.
    private var thumbnailSize: CGSize {
        guard let page = viewer.document?.page(at: index) else { return CGSize(width: Self.width, height: Self.width * 1.3) }
        var size = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        let aspect = size.width > 0 ? min(3, size.height / size.width) : 1.3
        return CGSize(width: Self.width, height: (Self.width * aspect).rounded())
    }
}

private struct PDFOutlineList: View {
    let viewer: PDFViewer

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 1) {
                if let root = viewer.document?.outlineRoot {
                    ForEach(0..<root.numberOfChildren, id: \.self) { i in
                        if let item = root.child(at: i) { PDFOutlineRow(viewer: viewer, item: item, depth: 0) }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
        }
    }
}

/// One entry of the table of contents. Its children are only built once it is opened.
private struct PDFOutlineRow: View {
    let viewer: PDFViewer
    let item: PDFOutline
    let depth: Int
    @State private var expanded: Bool?
    @State private var hovering = false

    var body: some View {
        let open = expanded ?? (item.isOpen && depth == 0)
        let hasChildren = item.numberOfChildren > 0
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
                    .opacity(hasChildren ? 0.6 : 0)
                    .onTapGesture { if hasChildren { withAnimation(Motion.quick) { expanded = !open } } }
                Text(item.label?.trimmed ?? "Untitled")
                    .font(.system(size: 12, weight: depth == 0 ? .medium : .regular))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let page = pageNumber {
                    Text("\(page)")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, CGFloat(depth) * 12 + 2)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { jump() }

            if open, hasChildren {
                ForEach(0..<item.numberOfChildren, id: \.self) { i in
                    if let child = item.child(at: i) { PDFOutlineRow(viewer: viewer, item: child, depth: depth + 1) }
                }
            }
        }
    }

    private var destination: PDFDestination? {
        item.destination ?? (item.action as? PDFActionGoTo)?.destination
    }

    private var pageNumber: Int? {
        guard let page = destination?.page, let document = viewer.document else { return nil }
        return document.index(for: page) + 1
    }

    private func jump() {
        guard let destination else { return }
        viewer.view.go(to: destination)
    }
}

// MARK: - Loading, failure, locked

private struct PDFStatusView: View {
    @Environment(\.accent) private var accent
    let viewer: PDFViewer

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.primary.opacity(0.08))
                    .frame(width: 54, height: 54)
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(symbolColor)
            }
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
            }
            switch viewer.phase {
            case .downloading:
                ProgressBar(fraction: fraction, accent: accent)
                    .frame(width: 220, height: 5)
            case .failed:
                PillButton(title: "Try Again", accent: accent) { viewer.tab?.reload() }
            case .locked:
                PillButton(title: "Enter Password…", accent: accent) { viewer.unlock() }
            case .ready:
                EmptyView()
            }
        }
        .padding(28)
        .frame(maxWidth: 340)
    }

    private var fraction: Double? {
        guard viewer.expectedBytes > 0 else { return nil }
        return min(1, Double(viewer.receivedBytes) / Double(viewer.expectedBytes))
    }

    private var symbol: String {
        switch viewer.phase {
        case .downloading, .ready: viewer.format.isPDF ? "doc.richtext" : viewer.format.symbol
        case .failed: "exclamationmark.triangle"
        case .locked: "lock.fill"
        }
    }

    private var symbolColor: Color {
        switch viewer.phase {
        case .failed: .orange
        case .locked: accent
        default: .primary.opacity(0.6)
        }
    }

    private var title: String {
        switch viewer.phase {
        case .downloading, .ready: viewer.filename
        case .failed: viewer.format.isPDF ? "Couldn’t open this PDF" : "Couldn’t open this document"
        case .locked: "This PDF is locked"
        }
    }

    private var detail: String {
        switch viewer.phase {
        case .downloading:
            let got = ByteCountFormatter.string(fromByteCount: viewer.receivedBytes, countStyle: .file)
            guard viewer.expectedBytes > 0 else { return viewer.receivedBytes > 0 ? "Loading… \(got)" : "Loading…" }
            let total = ByteCountFormatter.string(fromByteCount: viewer.expectedBytes, countStyle: .file)
            return "\(got) of \(total)"
        case .failed(let message): return message
        case .locked: return "It needs a password to open."
        case .ready: return ""
        }
    }

    private struct ProgressBar: View {
        let fraction: Double?
        let accent: Color
        @State private var sweep = false

        var body: some View {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.1))
                    if let fraction {
                        Capsule()
                            .fill(accent)
                            .frame(width: max(5, geo.size.width * fraction))
                            .animation(.easeOut(duration: 0.25), value: fraction)
                    } else {
                        // Size unknown: a sliding segment.
                        Capsule()
                            .fill(accent)
                            .frame(width: geo.size.width * 0.3)
                            .offset(x: sweep ? geo.size.width * 0.7 : 0)
                            .onAppear {
                                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { sweep = true }
                            }
                    }
                }
            }
        }
    }

    private struct PillButton: View {
        let title: String
        let accent: Color
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 28)
                    .background(Capsule().fill(accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(SquishButtonStyle(scale: 0.96))
        }
    }
}

// MARK: - Find in PDF

struct PDFFindBar: View {
    @Environment(BrowserState.self) private var state
    let viewer: PDFViewer
    @State private var query = ""
    @State private var pending: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            KeyTextField(
                text: $query, placeholder: "Find in PDF", fontSize: 13,
                identifier: BrowserState.findFieldIdentifier,
                onSubmit: { viewer.nextMatch(forward: !NSEvent.modifierFlags.contains(.shift)) },
                onCancel: { close() }
            )
            .frame(width: 170, height: 20)
            status
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
            IconButton(symbol: "chevron.up", size: 11, side: 24, help: "Previous", disabled: viewer.matchCount == 0) {
                viewer.nextMatch(forward: false)
            }
            IconButton(symbol: "chevron.down", size: 11, side: 24, help: "Next", disabled: viewer.matchCount == 0) {
                viewer.nextMatch(forward: true)
            }
            IconButton(symbol: "xmark", size: 10, side: 24, help: "Done") { close() }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .modifier(CardShadow(cornerRadius: 12, opacity: 0.2, radius: 10, y: 3))
        .onAppear { query = viewer.findQuery }
        .onChange(of: query) { _, new in
            // A short pause while typing, so a long document isn't searched for every letter.
            pending?.cancel()
            pending = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(new.count < 3 ? 220 : 90))
                guard !Task.isCancelled else { return }
                viewer.find(new)
            }
        }
        .onDisappear {
            pending?.cancel()
            viewer.endFind()
        }
    }

    @ViewBuilder
    private var status: some View {
        if query.trimmed.isEmpty {
            EmptyView()
        } else if viewer.matchCount > 0 {
            Text("\((viewer.matchIndex ?? 0) + 1) of \(viewer.matchCount)\(viewer.searching ? "+" : "")")
        } else if viewer.searching || pending != nil && viewer.findQuery != query {
            ProgressView().controlSize(.mini)
        } else {
            Text("No matches")
        }
    }

    private func close() {
        state.findVisible = false
        state.focusWebView()
    }
}
