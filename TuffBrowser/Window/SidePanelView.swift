import SwiftUI
import WebKit

/// An extension's side panel, docked to the right of the web card (see `SidePanelManager`).
struct SidePanelCard: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ExtensionManager.self) private var extensions
    let id: String
    let webView: WKWebView

    var body: some View {
        let panels = SidePanelManager.shared
        let _ = panels.revision
        let radius = CGFloat(settings.theme.cardRadius)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Group {
                    if let icon = panels.icon(for: id) {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 15, height: 15)

                Text(panels.title(for: id))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Menu {
                    let others = panels.panelExtensionIDs.filter { $0 != id }
                    if !others.isEmpty {
                        Section("Switch To") {
                            ForEach(others, id: \.self) { other in
                                Button(panels.title(for: other)) { panels.open(other) }
                            }
                        }
                    }
                    Button("Reload Panel") { panels.reload() }
                    if extensions.hasOptions(id: id) {
                        Button("Extension Options…") { extensions.openOptions(id: id) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.6))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")

                IconButton(symbol: "xmark", size: 10, weight: .bold, side: 24, help: "Close Panel  ⌥⌘S") { panels.close() }
            }
            .padding(.leading, 11)
            .padding(.trailing, 5)
            .frame(height: 34)
            .background(.background)

            Divider().opacity(0.6)

            PanelWebView(webView: webView)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5).allowsHitTesting(false))
        .modifier(CardShadow(cornerRadius: radius, opacity: 0.22, radius: 7, y: 2))
    }
}

/// Hosts the panel's web view.
private struct PanelWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        webView.appearance = NSApp.effectiveAppearance
        container.addSubview(webView)
    }
}

/// Invisible strip on the panel's leading edge that resizes it.
struct SidePanelResizeHandle: View {
    @Environment(AppSettings.self) private var settings
    @State private var startWidth: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = startWidth ?? settings.general.sidePanelWidth
                        if startWidth == nil { startWidth = base }
                        settings.general.sidePanelWidth = max(260, min(640, base - value.translation.width))
                    }
                    .onEnded { _ in startWidth = nil }
            )
    }
}
