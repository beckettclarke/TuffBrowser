import AppKit
import PDFKit

/// Presentation mode: the PDF one page at a time, filling the screen on black.
///
/// Shares the viewer's `PDFDocument` (nothing is loaded twice). → ↓ Space and clicks go forward,
/// ← ↑ ⇧Space back, Home / End jump to the ends, Esc leaves. The cursor hides while still.
final class PDFPresentation: NSObject, NSWindowDelegate {
    private let window: PresentationWindow
    private let pdfView = PresentationPDFView()
    private let onClose: (Int) -> Void
    private var savedOptions: NSApplication.PresentationOptions = []
    private var closed = false

    init(document: PDFDocument, page: Int, onClose: @escaping (Int) -> Void) {
        self.onClose = onClose
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        window = PresentationWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        window.delegate = self
        window.presentation = self
        window.setFrame(screen.frame, display: false)

        pdfView.presentation = self
        pdfView.document = document
        pdfView.displayMode = .singlePage
        pdfView.displaysPageBreaks = false
        pdfView.backgroundColor = .black
        pdfView.autoScales = true
        pdfView.pageShadowsEnabled = false
        pdfView.frame = window.contentView?.bounds ?? screen.frame
        pdfView.autoresizingMask = [.width, .height]
        window.contentView = pdfView
        if let target = document.page(at: page) { pdfView.go(to: target) }
    }

    func begin() {
        savedOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(pdfView)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().alphaValue = 1
        }
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func close() {
        guard !closed else { return }
        closed = true
        NSApp.presentationOptions = savedOptions
        let page = pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) } ?? 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            window.animator().alphaValue = 0
        } completionHandler: { [window, pdfView] in
            pdfView.document = nil
            window.orderOut(nil)
        }
        onClose(page)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Switching apps (⌘Tab) ends the show rather than leaving a black screen behind.
        close()
    }

    fileprivate func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: close()                                       // Esc
        case 49: // Space, ⇧Space
            if event.modifierFlags.contains(.shift) { pdfView.goToPreviousPage(nil) } else { pdfView.goToNextPage(nil) }
        case 124, 125, 121: pdfView.goToNextPage(nil)          // → ↓ PgDn
        case 123, 126, 116: pdfView.goToPreviousPage(nil)      // ← ↑ PgUp
        case 115: pdfView.goToFirstPage(nil)                    // Home
        case 119: pdfView.goToLastPage(nil)                     // End
        default: return false
        }
        NSCursor.setHiddenUntilMouseMoves(true)
        return true
    }
}

private final class PresentationWindow: NSWindow {
    weak var presentation: PDFPresentation?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { presentation?.close() }
}

private final class PresentationPDFView: PDFView {
    weak var presentation: PDFPresentation?

    override func keyDown(with event: NSEvent) {
        if presentation?.handle(event) != true { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        // Links still work; anywhere else moves on a page (⇧-click goes back).
        let point = convert(event.locationInWindow, from: nil)
        if let page = page(for: point, nearest: false), page.annotation(at: convert(point, to: page))?.action != nil {
            return super.mouseDown(with: event)
        }
        if event.modifierFlags.contains(.shift) { goToPreviousPage(nil) } else { goToNextPage(nil) }
    }

    override func rightMouseDown(with event: NSEvent) { goToPreviousPage(nil) }
}
