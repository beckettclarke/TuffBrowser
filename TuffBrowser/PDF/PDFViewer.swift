import AppKit
import Observation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Tuff's own PDF viewer for one tab, used in place of WebKit's.
///
/// Built to stay cheap on very large documents (800+ pages):
/// - The page's network response is turned into a `WKDownload` that streams straight to a
///   temporary file, so the bytes are fetched once and never held in memory. WebKit never builds
///   its own PDF viewer for the page (which would keep a second full copy in the web process).
/// - `PDFDocument(url:)` reads that file lazily; PDFKit only decodes and draws the pages that
///   are on screen.
/// - Thumbnails are drawn off the main thread, only for rows that scroll into view, into a
///   size-capped cache (`PDFThumbnailCache`).
/// - Search runs incrementally (`beginFindString`), and the outline only expands what is opened.
/// - Download / export copy from the file already on disk; nothing is fetched again.
///
/// The tab still navigates normally: once the file is in, a tiny placeholder page is committed at
/// the PDF's address (`Tab.commitPDFPage`), so history, the address bar and Back all behave.
@Observable
final class PDFViewer: NSObject {
    enum Phase: Equatable { case downloading, ready, locked, failed(String) }
    enum ZoomMode: Equatable { case auto, pageFit, pageWidth, custom }
    enum ScrollMode: String, CaseIterable { case page, vertical, horizontal }
    enum Spreads: String, CaseIterable { case none, odd, even }
    enum Tool { case select, hand }
    enum SidebarPane { case pages, outline }
    enum Dropdown: Hashable { case zoom, more }

    /// The PDF's address as the tab shows it (a `#page=` fragment included).
    let url: URL
    var filename: String
    var phase: Phase = .downloading
    var receivedBytes: Int64 = 0
    var expectedBytes: Int64 = -1
    private(set) var document: PDFDocument?
    /// The document's own title, when it has one.
    private(set) var documentTitle: String?
    var pageIndex = 0
    var pageCount = 0
    var scale: CGFloat = 1
    var zoomMode: ZoomMode = .auto
    var scrollMode: ScrollMode = .vertical
    var spreads: Spreads = .none
    var tool: Tool = .select
    var sidebarVisible: Bool {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: Self.sidebarKey) }
    }
    var sidebarPane: SidebarPane = .pages
    var dropdown: Dropdown?
    /// Pages picked in the sidebar (⌘ / ⇧-click) for exporting.
    var selectedPages: Set<Int> = []
    /// Bumped when pages are rotated, so thumbnails redraw.
    var rotationGeneration = 0
    var hasOutline = false

    // Find
    private(set) var findQuery = ""
    private(set) var matchCount = 0
    private(set) var matchIndex: Int?
    private(set) var searching = false

    @ObservationIgnored let view = TuffPDFView()
    @ObservationIgnored weak var tab: Tab?
    /// The file the document is read from (a temporary download, or a local file).
    @ObservationIgnored private(set) var fileURL: URL?
    @ObservationIgnored let thumbnails = PDFThumbnailCache()
    @ObservationIgnored private var download: WKDownload?
    @ObservationIgnored private var destination: URL?
    @ObservationIgnored private var progressObservation: NSKeyValueObservation?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var matches: [PDFSelection] = []
    @ObservationIgnored private var highlightWork: DispatchWorkItem?
    @ObservationIgnored private var applyingZoom = false
    @ObservationIgnored private var presentation: PDFPresentation?
    /// Where to go once the document is open (`#page=N`, or the page a reload was on).
    @ObservationIgnored private var initialPage: Int?
    /// Called with the downloaded file, or nil when the download failed.
    @ObservationIgnored var onDownloaded: ((URL?) -> Void)?

    private static let sidebarKey = "pdf.sidebarVisible"
    static let favicon: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(.init(paletteColors: [.systemRed]))
        return NSImage(systemSymbolName: "doc.richtext.fill", accessibilityDescription: "PDF")?
            .withSymbolConfiguration(config) ?? NSImage()
    }()

    init(url: URL, filename: String?, tab: Tab?) {
        self.url = url
        self.filename = Self.cleanFilename(filename, url: url)
        self.tab = tab
        let defaults = UserDefaults.standard
        sidebarVisible = defaults.object(forKey: Self.sidebarKey) as? Bool ?? false
        initialPage = Self.pageFragment(url)
        super.init()
        view.viewer = self
        view.delegate = self
    }

    var isReady: Bool { phase == .ready }

    /// What the tab and window title show.
    var displayTitle: String { documentTitle ?? filename }

    // MARK: Telling PDFs apart

    /// The address without its fragment: the key for a PDF's cached file.
    static func key(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.fragment = nil
        return parts.string ?? url.absoluteString
    }

    /// A response the viewer should take over: a PDF by its type, or a generic binary type
    /// served from an address ending in `.pdf` (common on file hosts).
    static func isPDF(_ response: URLResponse) -> Bool {
        let type = response.mimeType?.lowercased() ?? ""
        if ["application/pdf", "application/x-pdf", "application/acrobat", "text/pdf", "text/x-pdf"].contains(type) { return true }
        let generic = type.isEmpty || type == "application/octet-stream" || type == "binary/octet-stream"
        return generic && response.url?.pathExtension.lowercased() == "pdf"
    }

    private static func cleanFilename(_ suggested: String?, url: URL) -> String {
        var name = suggested?.trimmed ?? ""
        if name.isEmpty || name == "Unknown" {
            name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        }
        if name.isEmpty || name == "/" { name = url.host ?? "document" }
        if !name.lowercased().hasSuffix(".pdf") { name += ".pdf" }
        return name
    }

    /// `#page=12` (as Firefox and Chrome understand it), zero-based.
    private static func pageFragment(_ url: URL) -> Int? {
        guard let fragment = url.fragment else { return nil }
        for part in fragment.split(separator: "&") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2, pair[0].lowercased() == "page", let n = Int(pair[1]), n > 0 { return n - 1 }
        }
        return nil
    }

    // MARK: Loading

    /// Takes over the download WebKit made of the page's response.
    func attach(_ download: WKDownload) {
        self.download = download
        download.delegate = self
        phase = .downloading
        progressObservation = download.progress.observe(\.completedUnitCount, options: [.new]) { [weak self] progress, _ in
            let received = progress.completedUnitCount
            let total = progress.totalUnitCount
            DispatchQueue.main.async {
                guard let self else { return }
                self.receivedBytes = received
                self.expectedBytes = total
            }
        }
    }

    /// Stops a download still in flight.
    func cancelDownload() {
        progressObservation = nil
        download?.cancel { _ in }
        download = nil
    }

    /// Fetches the PDF again (Reload) without touching the tab's history, then swaps it in on
    /// the same page.
    func reload(using webView: WKWebView) {
        guard phase != .downloading else { return }
        initialPage = pageIndex
        if url.isFileURL, let fileURL {
            open(file: fileURL)
            return
        }
        receivedBytes = 0
        expectedBytes = -1
        withAnimation(Motion.quick) { phase = .downloading }
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            self?.attach(download)
        }
    }

    /// Opens the document from a file. PDFKit reads it lazily: only what is drawn is decoded.
    func open(file: URL) {
        progressObservation = nil
        download = nil
        endFind()
        fileURL = file
        guard let document = PDFDocument(url: file) else {
            withAnimation(Motion.quick) { phase = .failed("This file isn’t a PDF Tuff can read.") }
            return
        }
        if document.isLocked {
            self.document = document
            withAnimation(Motion.quick) { phase = .locked }
            unlock()
            return
        }
        present(document)
    }

    private func present(_ document: PDFDocument) {
        let keepPage = initialPage
        self.document = document
        thumbnails.reset()
        pageCount = document.pageCount
        if let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?.trimmed, !title.isEmpty {
            documentTitle = title
        }
        hasOutline = (document.outlineRoot?.numberOfChildren ?? 0) > 0
        if !hasOutline, sidebarPane == .outline { sidebarPane = .pages }
        selectedPages = []

        view.document = document
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 6, left: 8, bottom: 10, right: 8)
        view.handTool = tool == .hand
        applyLayout()
        observe(document)
        if let page = keepPage.flatMap({ document.page(at: min($0, max(0, document.pageCount - 1))) }) {
            view.go(to: page)
        }
        initialPage = nil
        pageIndex = view.currentPage.map { document.index(for: $0) } ?? 0
        withAnimation(Motion.quick) { phase = .ready }
        focus()
    }

    /// Asks for the password of a locked PDF, as many times as it takes or until cancelled.
    func unlock() {
        guard let document, document.isLocked else { return }
        Task { @MainActor [weak self] in
            var failed = false
            while let self, document.isLocked {
                let prompt = Prompt(
                    symbol: "lock.fill",
                    title: "“\(self.filename)” is locked",
                    message: failed ? "That password didn’t work. Try again." : "Enter the password to open this PDF.",
                    confirmTitle: "Unlock",
                    fields: [Prompt.Field(placeholder: "Password", secure: true)]
                )
                let result = await self.ask(prompt)
                guard result.confirmed else { return }
                if document.unlock(withPassword: result.fields.first ?? "") {
                    self.present(document)
                    return
                }
                failed = true
            }
        }
    }

    /// Lets go of everything: called when the tab moves on, sleeps or closes.
    func close() {
        cancelDownload()
        endFind()
        presentation?.close()
        presentation = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        view.delegate = nil
        view.document = nil
        view.removeFromSuperview()
        document = nil
        thumbnails.reset()
    }

    private func observe(_ document: PDFDocument) {
        observers.forEach(NotificationCenter.default.removeObserver)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
                guard let self, let document = self.document, let page = self.view.currentPage else { return }
                let index = document.index(for: page)
                if index != self.pageIndex { self.pageIndex = index }
            },
            center.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.scale = self.view.scaleFactor
                // A pinch takes the zoom out of whichever fitting mode it was in.
                if !self.applyingZoom, !self.view.autoScales, self.zoomMode != .custom { self.zoomMode = .custom }
            },
            center.addObserver(forName: .PDFDocumentDidFindMatch, object: document, queue: .main) { [weak self] note in
                guard let self, let selection = note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection else { return }
                self.addMatch(selection)
            },
            center.addObserver(forName: .PDFDocumentDidEndFind, object: document, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.searching = false
                self.refreshHighlights(now: true)
            },
        ]
    }

    func focus() {
        guard let browser = tab?.browser, browser.selectedTab === tab else { return }
        browser.focusWebView()
    }

    // MARK: Pages

    func go(to index: Int) {
        guard let document, let page = document.page(at: max(0, min(index, document.pageCount - 1))) else { return }
        view.go(to: page)
        pageIndex = document.index(for: page)
    }

    func nextPage() { view.canGoToNextPage ? view.goToNextPage(nil) : () }
    func previousPage() { view.canGoToPreviousPage ? view.goToPreviousPage(nil) : () }
    func firstPage() { go(to: 0) }
    func lastPage() { go(to: pageCount - 1) }

    // MARK: Layout

    func setScrollMode(_ mode: ScrollMode) {
        scrollMode = mode
        applyLayout()
    }

    func setSpreads(_ value: Spreads) {
        spreads = value
        applyLayout()
    }

    func setTool(_ value: Tool) {
        tool = value
        view.handTool = value == .hand
        view.window?.invalidateCursorRects(for: view)
    }

    private func applyLayout() {
        let page = view.currentPage
        let paired = spreads != .none
        switch scrollMode {
        case .page: view.displayMode = paired ? .twoUp : .singlePage
        case .vertical, .horizontal: view.displayMode = paired ? .twoUpContinuous : .singlePageContinuous
        }
        view.displayDirection = scrollMode == .horizontal ? .horizontal : .vertical
        view.displaysAsBook = spreads == .even
        view.layoutDocumentView()
        if let page { view.go(to: page) }
        applyZoom()
    }

    // MARK: Zoom

    static let zoomSteps: [CGFloat] = [0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5, 6.4]

    func setZoom(_ mode: ZoomMode, scale value: CGFloat? = nil) {
        zoomMode = mode
        if let value { view.autoScales = false; setScale(value) } else { applyZoom() }
    }

    func zoomIn() {
        let next = Self.zoomSteps.first { $0 > view.scaleFactor * 1.01 } ?? Self.zoomSteps.last!
        setZoom(.custom, scale: next)
    }

    func zoomOut() {
        let next = Self.zoomSteps.last { $0 < view.scaleFactor * 0.99 } ?? Self.zoomSteps.first!
        setZoom(.custom, scale: next)
    }

    /// Re-fits the page after the view or the layout changed size.
    func applyZoom() {
        switch zoomMode {
        case .auto:
            applyingZoom = true
            view.autoScales = true
            applyingZoom = false
            scale = view.scaleFactor
        case .pageFit, .pageWidth:
            view.autoScales = false
            setScale(fitScale(width: zoomMode == .pageWidth))
        case .custom:
            break
        }
    }

    private func setScale(_ value: CGFloat) {
        let clamped = max(0.1, min(value, 6.4))
        guard abs(view.scaleFactor - clamped) > 0.0005 else { scale = view.scaleFactor; return }
        applyingZoom = true
        view.scaleFactor = clamped
        applyingZoom = false
        scale = view.scaleFactor
    }

    private func fitScale(width: Bool) -> CGFloat {
        guard let page = view.currentPage ?? document?.page(at: 0) else { return 1 }
        var size = page.bounds(for: view.displayBox).size
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        guard size.width > 0, size.height > 0 else { return 1 }
        let across: CGFloat = spreads == .none ? 1 : 2
        let margins = view.pageBreakMargins
        let available = view.bounds.size
        let horizontal = (available.width - (margins.left + margins.right) * across - 18) / (size.width * across)
        let vertical = (available.height - margins.top - margins.bottom - 4) / size.height
        return width ? horizontal : min(horizontal, vertical)
    }

    /// The zoom as the toolbar shows it.
    var zoomLabel: String { "\(Int((scale * 100).rounded()))%" }

    // MARK: Rotation

    func rotate(clockwise: Bool) {
        guard let document else { return }
        let current = view.currentPage
        let delta = clockwise ? 90 : -90
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            page.rotation = ((page.rotation + delta) % 360 + 360) % 360
        }
        view.layoutDocumentView()
        if let current { view.go(to: current) }
        thumbnails.reset()
        rotationGeneration += 1
        applyZoom()
    }

    // MARK: Find

    func find(_ query: String) {
        guard let document else { return }
        if document.isFinding { document.cancelFindString() }
        matches = []
        matchCount = 0
        matchIndex = nil
        highlightWork?.cancel()
        view.highlightedSelections = nil
        findQuery = query
        guard !query.trimmed.isEmpty else {
            searching = false
            view.clearSelection()
            return
        }
        searching = true
        // Incremental: matches arrive page by page (`addMatch`) without blocking the window.
        document.beginFindString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
    }

    private func addMatch(_ selection: PDFSelection) {
        selection.color = Self.matchColor
        matches.append(selection)
        matchCount = matches.count
        // Jumps to the first match on or after the page being read; if there is none, the
        // search's end settles on the first match overall (`refreshHighlights`).
        if matchIndex == nil, let page = selection.pages.first, let document, document.index(for: page) >= pageIndex {
            show(match: matches.count - 1)
        }
        refreshHighlights(now: false)
    }

    /// Highlights every match. Batched: a common word in a long document can match thousands of
    /// times, and redrawing the page for each one would stall.
    private func refreshHighlights(now: Bool) {
        highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.matchIndex == nil, !self.searching, !self.matches.isEmpty { self.show(match: 0) }
            // Past a few thousand highlights PDFKit spends more time than they are worth.
            self.view.highlightedSelections = Array(self.matches.prefix(4000))
        }
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0 : 0.25), execute: work)
    }

    func nextMatch(forward: Bool) {
        guard !matches.isEmpty else { return }
        let count = matches.count
        let next = matchIndex.map { (($0 + (forward ? 1 : -1)) % count + count) % count } ?? 0
        show(match: next)
    }

    private static let matchColor = NSColor.systemYellow.withAlphaComponent(0.55)
    private static let currentMatchColor = NSColor.systemOrange.withAlphaComponent(0.8)

    private func show(match index: Int) {
        guard matches.indices.contains(index) else { return }
        if let old = matchIndex, matches.indices.contains(old) { matches[old].color = Self.matchColor }
        matchIndex = index
        let selection = matches[index]
        selection.color = Self.currentMatchColor
        if !searching { view.highlightedSelections = Array(matches.prefix(4000)) }
        // Scrolled to with room above it, so the find bar over the top of the page doesn't
        // cover it.
        if let page = selection.pages.first {
            let bounds = selection.bounds(for: page)
            view.go(to: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height + 110), on: page)
        } else {
            view.go(to: selection)
        }
    }

    func endFind() {
        if let document, document.isFinding { document.cancelFindString() }
        highlightWork?.cancel()
        matches = []
        matchCount = 0
        matchIndex = nil
        searching = false
        findQuery = ""
        view.highlightedSelections = nil
        view.clearSelection()
    }

    // MARK: Actions

    func print() {
        guard let document, let window = view.window else { return }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        info.jobDisposition = .spool
        guard let operation = document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) else { return }
        operation.jobTitle = displayTitle
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// Saves the PDF to the downloads folder, copied from the file already on disk.
    func saveCopy() {
        guard let fileURL else { return }
        DownloadManager.shared.addLocalCopy(of: fileURL, filename: filename, sourceURL: url, isPrivate: tab?.browser?.isPrivate ?? false)
    }

    func copyLinkToPage() {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        parts.fragment = "page=\(pageIndex + 1)"
        guard let link = parts.string else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        tab?.browser?.show(Toast(symbol: "link", text: "Copied link to page \(pageIndex + 1)"))
    }

    func openInPreview() {
        guard let fileURL else { return }
        var target = fileURL
        if !url.isFileURL {
            // A readable name in Preview's title bar, rather than the download's.
            let named = PDFFiles.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent(filename)
            try? FileManager.default.createDirectory(at: named.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? FileManager.default.copyItem(at: fileURL, to: named)) != nil {
                PDFFiles.secure(named, source: url)
                target = named
            }
        }
        let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview")
        if let preview {
            NSWorkspace.shared.open([target], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(target)
        }
    }

    func startPresentation() {
        guard let document else { return }
        presentation?.close()
        let show = PDFPresentation(document: document, page: pageIndex) { [weak self] last in
            self?.presentation = nil
            self?.go(to: last)
            self?.focus()
        }
        presentation = show
        show.begin()
    }

    /// Saves some pages as a new PDF: the ones picked in the sidebar, or the current one, with a
    /// card to change the range first.
    func exportPages() {
        guard let document else { return }
        let picked = selectedPages.count > 1 ? selectedPages : [pageIndex]
        Task { @MainActor [weak self] in
            guard let self else { return }
            var text = PageRanges.format(picked)
            var problem: String?
            while true {
                let prompt = Prompt(
                    symbol: "doc.on.doc.fill",
                    title: "Export Pages",
                    subtitle: self.filename,
                    message: problem ?? "Save these pages as a new PDF. Use commas and ranges, like 1–3, 7, 10–.",
                    confirmTitle: "Export…",
                    fields: [Prompt.Field(placeholder: "Pages, e.g. 1-3, 7", text: text)]
                )
                let result = await self.ask(prompt)
                guard result.confirmed else { return }
                text = result.fields.first ?? ""
                if let pages = PageRanges.parse(text, count: document.pageCount), !pages.isEmpty {
                    self.writePages(pages)
                    return
                }
                problem = "“\(text)” isn’t a page range in this \(document.pageCount)-page PDF. Try something like 1–3, 7."
            }
        }
    }

    private func writePages(_ pages: [Int]) {
        guard let document, let window = view.window else { return }
        let base = (filename as NSString).deletingPathExtension
        let label = pages.count == 1 ? "page \(pages[0] + 1)" : "pages \(PageRanges.format(Set(pages)))"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(base) (\(label.replacingOccurrences(of: "–", with: "-"))).pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            // Copies of the pages make a document of their own, so writing it can happen off the
            // main thread without touching the one on screen.
            let output = PDFDocument()
            for (i, index) in pages.enumerated() {
                if let copy = document.page(at: index)?.copy() as? PDFPage { output.insert(copy, at: i) }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = output.write(to: destination)
                DispatchQueue.main.async {
                    let text = ok ? "Exported \(pages.count == 1 ? "1 page" : "\(pages.count) pages")" : "Couldn’t save the pages"
                    self?.tab?.browser?.show(Toast(symbol: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", text: text))
                }
            }
        }
    }

    func showProperties() {
        guard let document else { return }
        let attributes = document.documentAttributes ?? [:]
        func text(_ key: PDFDocumentAttribute) -> String? {
            (attributes[key] as? String)?.trimmed.nilIfEmpty
        }
        let dates = DateFormatter()
        dates.dateStyle = .medium
        dates.timeStyle = .short
        var items: [Prompt.Item] = []
        if let v = text(.authorAttribute) { items.append(.init(symbol: "person", text: "Author: \(v)")) }
        if let v = text(.subjectAttribute) { items.append(.init(symbol: "text.alignleft", text: "Subject: \(v)")) }
        if let v = attributes[PDFDocumentAttribute.creationDateAttribute] as? Date {
            items.append(.init(symbol: "calendar", text: "Created \(dates.string(from: v))"))
        }
        if let v = attributes[PDFDocumentAttribute.modificationDateAttribute] as? Date {
            items.append(.init(symbol: "pencil", text: "Modified \(dates.string(from: v))"))
        }
        items.append(.init(symbol: "doc.on.doc", text: "\(document.pageCount) \(document.pageCount == 1 ? "page" : "pages")"))
        if let page = document.page(at: pageIndex) {
            items.append(.init(symbol: "ruler", text: "Page size: " + Self.describeSize(page.bounds(for: .mediaBox).size)))
        }
        if let fileURL, let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            items.append(.init(symbol: "internaldrive", text: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
        }
        let maker = [text(.creatorAttribute), text(.producerAttribute)].compactMap { $0 }
        if !maker.isEmpty { items.append(.init(symbol: "hammer", text: "Made with " + maker.joined(separator: ", "))) }
        items.append(.init(symbol: "number", text: "PDF \(document.majorVersion).\(document.minorVersion)"
            + (document.isEncrypted ? " · encrypted" : "")))

        let prompt = Prompt(
            symbol: "doc.richtext.fill",
            symbolColor: .systemRed,
            title: documentTitle ?? filename,
            subtitle: documentTitle == nil ? nil : filename,
            itemsHeading: "Document",
            items: items,
            confirmTitle: "Done",
            cancelTitle: nil
        )
        Task { @MainActor [weak self] in _ = await self?.ask(prompt) }
    }

    private static func describeSize(_ size: CGSize) -> String {
        let w = size.width / 72, h = size.height / 72
        let named: [(String, CGFloat, CGFloat)] = [
            ("Letter", 8.5, 11), ("Legal", 8.5, 14), ("Tabloid", 11, 17),
            ("A3", 11.69, 16.54), ("A4", 8.27, 11.69), ("A5", 5.83, 8.27),
        ]
        let name = named.first { abs($0.1 - min(w, h)) < 0.05 && abs($0.2 - max(w, h)) < 0.05 }?.0
        let inches = String(format: "%g × %g in", (w * 100).rounded() / 100, (h * 100).rounded() / 100)
        let mm = String(format: "%.0f × %.0f mm", w * 25.4, h * 25.4)
        return "\(inches) (\(mm))" + (name.map { " · \($0)" } ?? "")
    }

    @MainActor
    private func ask(_ prompt: Prompt) async -> PromptResult {
        var prompt = prompt
        prompt.browser = tab?.browser
        let result = await PromptPresenter.ask(prompt)
        focus()
        return result
    }

    /// A link in the PDF was clicked: opens it in the tab, or a new one with ⌘.
    fileprivate func open(link: URL) {
        // Only web and mail addresses: a PDF must not reach `javascript:` in the page behind it,
        // local files, or other apps' URL schemes.
        let scheme = link.scheme?.lowercased() ?? ""
        if scheme == "mailto" || scheme == "tel" {
            NSWorkspace.shared.open(link)
            return
        }
        guard scheme == "http" || scheme == "https" else { return }
        guard let tab, let browser = tab.browser else { return }
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) {
            let foreground = flags.contains(.shift) != AppSettings.shared.tabs.foregroundLinks
            browser.newTab(url: link, select: foreground, after: tab)
        } else {
            tab.load(link)
        }
    }

    fileprivate func hover(link: URL?) {
        guard let tab, tab.hoveredLink != link else { return }
        tab.hoveredLink = link
    }
}

// MARK: - Download

extension PDFViewer: WKDownloadDelegate {
    func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        if let name = response.suggestedFilename, filename.hasPrefix("document") { filename = Self.cleanFilename(name, url: url) }
        if response.expectedContentLength > 0 { expectedBytes = response.expectedContentLength }
        let file = PDFFiles.newFile()
        destination = file
        completionHandler(file)
    }

    func downloadDidFinish(_ download: WKDownload) {
        progressObservation = nil
        guard self.download === download else { return }
        self.download = nil
        guard let file = destination, FileManager.default.fileExists(atPath: file.path) else {
            fail("The PDF couldn’t be saved for viewing.")
            return
        }
        PDFFiles.secure(file, source: url)
        open(file: file)
        onDownloaded?(file)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        progressObservation = nil
        guard self.download === download else { return }
        self.download = nil
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        fail(error.localizedDescription)
    }

    private func fail(_ message: String) {
        onDownloaded?(nil)
        withAnimation(Motion.quick) { phase = .failed(message) }
    }
}

// MARK: - PDF view delegate

extension PDFViewer: PDFViewDelegate {
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        open(link: url)
    }

    func pdfViewParentViewController(for sender: PDFView) -> NSViewController? { nil }
}

// MARK: - Temporary files

/// Where downloaded PDFs are kept while their tabs might show them again.
///
/// The same thing every browser's HTTP disk cache does with a PDF, kept tight: the folder is the
/// user's alone (0700) inside their per-user temporary directory, files get random names and
/// 0600, carry the quarantine flag of a web download, and are never executed. Cleared at launch
/// (whatever a previous run left) and as tabs close.
enum PDFFiles {
    static let directory: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TuffPDF", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }()

    /// Owner-only, and marked as downloaded from `source` (Gatekeeper's quarantine), so if it is
    /// opened elsewhere (Open in Preview) macOS treats it like any other web download.
    static func secure(_ file: URL, source: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        guard !source.isFileURL else { return }
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: "Tuff",
            kLSQuarantineDataURLKey as String: source,
        ]
        var target = file
        try? target.setResourceValues(values)
    }

    static func newFile() -> URL {
        directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
    }

    static func remove(_ urls: some Sequence<URL>) {
        let dir = directory.standardizedFileURL.path
        DispatchQueue.global(qos: .utility).async {
            for url in urls where url.standardizedFileURL.path.hasPrefix(dir) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

// MARK: - Page ranges

enum PageRanges {
    /// "1-3, 7, 10-" → zero-based page indices, in order and without repeats. Nil if any part
    /// isn't a page in a document of `count` pages.
    static func parse(_ text: String, count: Int) -> [Int]? {
        let normalized = text.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-").lowercased()
        if normalized.trimmed == "all" { return Array(0..<count) }
        var result: [Int] = []
        var seen = Set<Int>()
        for part in normalized.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let piece = part.trimmingCharacters(in: .whitespaces)
            if piece.isEmpty { continue }
            let bounds = piece.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let lower: Int, upper: Int
            switch bounds.count {
            case 1:
                guard let n = Int(bounds[0]) else { return nil }
                lower = n; upper = n
            case 2:
                guard let a = bounds[0].isEmpty ? 1 : Int(bounds[0]),
                      let b = bounds[1].isEmpty ? count : Int(bounds[1]) else { return nil }
                lower = a; upper = b
            default:
                return nil
            }
            guard lower >= 1, upper <= count, lower <= upper else { return nil }
            for n in lower...upper where seen.insert(n - 1).inserted { result.append(n - 1) }
        }
        return result.isEmpty ? nil : result
    }

    /// Zero-based indices → "1–3, 7".
    static func format(_ pages: Set<Int>) -> String {
        let sorted = pages.sorted()
        var parts: [String] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count, sorted[j + 1] == sorted[j] + 1 { j += 1 }
            parts.append(i == j ? "\(sorted[i] + 1)" : "\(sorted[i] + 1)–\(sorted[j] + 1)")
            i = j + 1
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Thumbnails

/// Page thumbnails, drawn on a background queue only when asked for (rows scrolled into view)
/// and kept in a cache with a memory ceiling, so an 800-page document costs no more than the
/// handful of rows on screen.
final class PDFThumbnailCache: @unchecked Sendable {
    private let cache: NSCache<NSNumber, NSImage> = {
        let cache = NSCache<NSNumber, NSImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 160
        return cache
    }()
    private let queue = DispatchQueue(label: "tuff.pdf.thumbnails", qos: .userInitiated)
    private var generation = 0

    func reset() {
        generation += 1
        cache.removeAllObjects()
    }

    func cached(_ index: Int) -> NSImage? { cache.object(forKey: NSNumber(value: index)) }

    /// Draws page `index` `width` points wide. `isWanted` is checked before drawing, so rows
    /// that scrolled past while queued are skipped.
    func thumbnail(of page: PDFPage, index: Int, width: CGFloat, scale: CGFloat, isWanted: @escaping () -> Bool) async -> NSImage? {
        if let image = cached(index) { return image }
        let generation = self.generation
        nonisolated(unsafe) let page = page
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, isWanted() else { continuation.resume(returning: nil); return }
                var size = page.bounds(for: .cropBox).size
                if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
                let aspect = size.width > 0 ? size.height / size.width : 1.3
                let pixels = CGSize(width: width * scale, height: (width * aspect * scale).rounded())
                let image = page.thumbnail(of: pixels, for: .cropBox)
                image.size = CGSize(width: width, height: width * aspect)
                if generation == self.generation {
                    self.cache.setObject(image, forKey: NSNumber(value: index), cost: Int(pixels.width * pixels.height * 4))
                }
                continuation.resume(returning: image)
            }
        }
    }
}

// MARK: - The PDFKit view

/// `PDFView` with a hand tool, link hover reporting, and re-fitting when it is resized.
final class TuffPDFView: PDFView {
    weak var viewer: PDFViewer?
    var handTool = false {
        didSet { if handTool != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    private var dragStart: (point: NSPoint, origin: NSPoint)?
    private var lastSize: CGSize = .zero

    private var scrollView: NSScrollView? { documentView?.enclosingScrollView }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Shown (a tab switch, a PDF opening): the keyboard comes here, if its tab is on screen.
        if window != nil, viewer?.isReady == true { viewer?.focus() }
    }

    override func layout() {
        super.layout()
        if bounds.size != lastSize {
            lastSize = bounds.size
            DispatchQueue.main.async { [weak self] in self?.viewer?.applyZoom() }
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let tab = viewer?.tab { tab.browser?.pageWasClicked(tab) }
        guard handTool, let clip = scrollView?.contentView else { return super.mouseDown(with: event) }
        dragStart = (event.locationInWindow, clip.bounds.origin)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard handTool, let start = dragStart, let scroll = scrollView else { return super.mouseDragged(with: event) }
        let clip = scroll.contentView
        let dx = event.locationInWindow.x - start.point.x
        let dy = event.locationInWindow.y - start.point.y
        var origin = NSPoint(x: start.origin.x - dx, y: clip.isFlipped ? start.origin.y + dy : start.origin.y - dy)
        if let doc = scroll.documentView {
            origin.x = max(0, min(origin.x, doc.frame.width - clip.bounds.width))
            origin.y = max(0, min(origin.y, doc.frame.height - clip.bounds.height))
        }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard handTool, dragStart != nil else { return super.mouseUp(with: event) }
        dragStart = nil
        NSCursor.openHand.set()
        // A click without a drag still follows links.
        if let link = link(at: event) { viewer?.open(link: link) }
    }

    override func mouseMoved(with event: NSEvent) {
        viewer?.hover(link: link(at: event))
        if handTool {
            NSCursor.openHand.set()
        } else {
            super.mouseMoved(with: event)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        viewer?.hover(link: nil)
    }

    override func cursorUpdate(with event: NSEvent) {
        if handTool { NSCursor.openHand.set() } else { super.cursorUpdate(with: event) }
    }

    /// The web address of the link under the mouse, if there is one.
    private func link(at event: NSEvent) -> URL? {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false) else { return nil }
        let onPage = convert(point, to: page)
        guard let annotation = page.annotation(at: onPage) else { return nil }
        if let action = annotation.action as? PDFActionURL { return action.url }
        return annotation.url
    }
}

/// Hosts a viewer's `PDFView`. The view belongs to the viewer, so switching tabs and back keeps
/// its scroll position.
struct PDFCanvas: NSViewRepresentable {
    let viewer: PDFViewer
    let background: NSColor

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.wantsLayer = true
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        let view = viewer.view
        if view.backgroundColor != background { view.backgroundColor = background }
        guard view.superview !== host else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
        viewer.focus()
    }
}

extension DownloadManager {
    /// Adds a copy of a file that is already on disk (a PDF the viewer downloaded) to the
    /// downloads folder and the downloads list.
    func addLocalCopy(of file: URL, filename: String, sourceURL: URL?, isPrivate: Bool = false) {
        let destination = Self.uniqueDestination(for: filename)
        let item = DownloadItem(filename: destination.lastPathComponent)
        item.url = sourceURL
        item.isPrivate = isPrivate
        // Extensions (`chrome.downloads`) never see an Incognito window's downloads.
        item.chromeID = isPrivate ? nil : reserveChromeID()
        do {
            try FileManager.default.copyItem(at: file, to: destination)
        } catch {
            item.state = .failed(error.localizedDescription)
            items.insert(item, at: 0)
            return
        }
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        item.destination = destination
        item.fraction = 1
        item.bytesReceived = size
        item.totalBytes = size
        item.finishedAt = Date()
        item.state = .finished
        items.insert(item, at: 0)
        bumpPulse(isPrivate: isPrivate)
        DistributedNotificationCenter.default().post(name: Notification.Name("com.apple.DownloadFileFinished"), object: destination.path)
        let state = Self.window(isPrivate: isPrivate)
        if AppSettings.shared.downloads.showPanelOnStart, state.downloadsButtonShowing {
            state.downloadsVisible = true
        } else {
            state.show(Toast(symbol: "arrow.down.circle.fill", text: "Saved to \(destination.deletingLastPathComponent().lastPathComponent)"))
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
