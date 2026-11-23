import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// The kinds of file the viewer opens in a tab: PDFs (PDFKit, the full viewer) and office
/// documents (Word, Excel, PowerPoint, Pages, Numbers, Keynote, RTF), drawn by Quick Look as
/// Finder's space-bar preview draws them. They come in the same way (`Tab+PDF`): the response
/// streams to a temporary file, a placeholder page holds the address, Back and Forward reuse it.
struct DocumentFormat: Equatable {
    /// The usual extension, and the one a downloaded file gets when its name has none.
    let ext: String
    /// What the format is called ("Word document").
    let name: String
    let symbol: String
    let color: NSColor
    /// Types a server names it by.
    let mimeTypes: Set<String>
    /// Extensions that mark it when the server only says "some bytes" (`application/octet-stream`).
    let extensions: Set<String>
    /// The tab's icon while it shows one.
    let favicon: NSImage

    var isPDF: Bool { ext == "pdf" }

    init(ext: String, name: String, symbol: String, color: NSColor, mimeTypes: Set<String>, extensions: Set<String>) {
        self.ext = ext
        self.name = name
        self.symbol = symbol
        self.color = color
        self.mimeTypes = mimeTypes
        self.extensions = extensions
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [color]))
        favicon = NSImage(systemSymbolName: symbol, accessibilityDescription: name)?.withSymbolConfiguration(config) ?? NSImage()
    }

    static func == (a: DocumentFormat, b: DocumentFormat) -> Bool { a.ext == b.ext }

    static let pdf = DocumentFormat(
        ext: "pdf", name: "PDF", symbol: "doc.richtext.fill", color: .systemRed,
        mimeTypes: ["application/pdf", "application/x-pdf", "application/acrobat", "text/pdf", "text/x-pdf"],
        extensions: ["pdf"]
    )

    static let word = DocumentFormat(
        ext: "docx", name: "Word document", symbol: "doc.text.fill", color: .systemBlue,
        mimeTypes: [
            "application/msword",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.template",
            "application/vnd.ms-word.document.macroenabled.12",
            "application/vnd.ms-word.template.macroenabled.12",
        ],
        extensions: ["docx", "doc", "docm", "dotx", "dot", "dotm"]
    )

    static let excel = DocumentFormat(
        ext: "xlsx", name: "Excel spreadsheet", symbol: "tablecells.fill", color: .systemGreen,
        mimeTypes: [
            "application/vnd.ms-excel",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.template",
            "application/vnd.ms-excel.sheet.macroenabled.12",
            "application/vnd.ms-excel.sheet.binary.macroenabled.12",
        ],
        extensions: ["xlsx", "xls", "xlsm", "xlsb", "xltx", "xlt"]
    )

    static let powerPoint = DocumentFormat(
        ext: "pptx", name: "PowerPoint presentation", symbol: "play.rectangle.fill", color: .systemOrange,
        mimeTypes: [
            "application/vnd.ms-powerpoint",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "application/vnd.openxmlformats-officedocument.presentationml.slideshow",
            "application/vnd.openxmlformats-officedocument.presentationml.template",
            "application/vnd.ms-powerpoint.presentation.macroenabled.12",
            "application/vnd.ms-powerpoint.slideshow.macroenabled.12",
        ],
        extensions: ["pptx", "ppt", "pptm", "ppsx", "pps", "ppsm", "potx", "pot"]
    )

    static let pages = DocumentFormat(
        ext: "pages", name: "Pages document", symbol: "doc.text.fill", color: .systemOrange,
        mimeTypes: ["application/vnd.apple.pages", "application/x-iwork-pages-sffpages"],
        extensions: ["pages"]
    )

    static let numbers = DocumentFormat(
        ext: "numbers", name: "Numbers spreadsheet", symbol: "tablecells.fill", color: .systemGreen,
        mimeTypes: ["application/vnd.apple.numbers", "application/x-iwork-numbers-sffnumbers"],
        extensions: ["numbers"]
    )

    /// By its type only: an address ending in `.key` is as likely a private key as a Keynote file.
    static let keynote = DocumentFormat(
        ext: "key", name: "Keynote presentation", symbol: "play.rectangle.fill", color: .systemBlue,
        mimeTypes: ["application/vnd.apple.keynote", "application/x-iwork-keynote-sffkey"],
        extensions: []
    )

    static let richText = DocumentFormat(
        ext: "rtf", name: "Rich text document", symbol: "doc.richtext.fill", color: .systemGray,
        mimeTypes: ["application/rtf", "text/rtf", "application/x-rtf", "text/richtext"],
        extensions: ["rtf"]
    )

    static let all: [DocumentFormat] = [.pdf, .word, .excel, .powerPoint, .pages, .numbers, .keynote, .richText]

    /// Types that say nothing about what the file is, where the address's extension decides.
    /// Office files are zips, and some servers say so.
    private static let genericTypes: Set<String> = [
        "", "application/octet-stream", "binary/octet-stream", "application/unknown", "application/download",
        "application/force-download", "application/x-download", "application/zip", "application/x-zip-compressed",
    ]

    /// The format a main-frame response should open in the viewer as, if any.
    static func of(_ response: URLResponse) -> DocumentFormat? {
        let type = response.mimeType?.lowercased() ?? ""
        if let format = all.first(where: { $0.mimeTypes.contains(type) }) { return format }
        guard genericTypes.contains(type) else { return nil }
        // Zips are only office files when the address says so plainly; a PDF never is one.
        let zipped = type.contains("zip")
        let names = [response.url?.pathExtension, response.suggestedFilename.map { ($0 as NSString).pathExtension }]
        for ext in names.compactMap({ $0?.lowercased() }) where !ext.isEmpty {
            if let format = all.first(where: { $0.extensions.contains(ext) }), !(zipped && format.isPDF) { return format }
        }
        return nil
    }

    /// The format of a file the viewer saved (or one on this Mac), from its extension.
    static func of(file: URL) -> DocumentFormat {
        let ext = file.pathExtension.lowercased()
        return all.first { $0.ext == ext || $0.extensions.contains(ext) } ?? .pdf
    }

    /// Whether `name` already ends in one of this format's extensions.
    func names(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == self.ext || extensions.contains(ext)
    }

    /// File types the Open panel offers for documents the viewer shows.
    static var contentTypes: [UTType] {
        all.flatMap { [$0.ext] + $0.extensions }.compactMap { UTType(filenameExtension: $0) }
    }
}

// MARK: - Quick Look

/// Hosts a viewer's Quick Look view. Like `PDFCanvas`, the view belongs to the viewer, so
/// switching tabs and back keeps its place.
struct QuickLookCanvas: NSViewRepresentable {
    let viewer: PDFViewer

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.wantsLayer = true
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        guard let view = viewer.quickLook, view.superview !== host else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
        viewer.focus()
    }
}

/// `QLPreviewView` that makes its tab the selected one when clicked (in a split).
final class TuffQuickLookView: QLPreviewView {
    weak var viewer: PDFViewer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, viewer?.isReady == true { viewer?.focus() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Quick Look's own views take the click; this only notes it.
        let hit = super.hitTest(point)
        if hit != nil, NSApp.currentEvent?.type == .leftMouseDown, let tab = viewer?.tab {
            tab.browser?.pageWasClicked(tab)
        }
        return hit
    }
}

/// The toolbar over an office document: what it is, and ways to take it elsewhere.
struct DocumentToolbar: View {
    let viewer: PDFViewer

    var body: some View {
        let ready = viewer.isReady
        let format = viewer.format
        HStack(spacing: 8) {
            Image(systemName: format.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(nsColor: format.color))
                .frame(width: 22)
            Text(format.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()

            Spacer(minLength: 12)
            Text(viewer.displayTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)
                .help(viewer.filename)
            Spacer(minLength: 12)

            if let app = viewer.appName {
                OpenInAppButton(title: "Open in \(app)", disabled: !ready) { viewer.openInApp() }
            }
            IconButton(symbol: "square.and.arrow.down", size: 13, help: "Download", disabled: !ready) { viewer.saveCopy() }
        }
        .padding(.horizontal, 10)
    }
}

private struct OpenInAppButton: View {
    let title: String
    let disabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.primary.opacity(disabled ? 0.3 : 0.8))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(.primary.opacity(hovering && !disabled ? 0.13 : 0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(SquishButtonStyle(scale: 0.96))
        .disabled(disabled)
        .onHover { hovering = $0 }
        .fixedSize()
    }
}
