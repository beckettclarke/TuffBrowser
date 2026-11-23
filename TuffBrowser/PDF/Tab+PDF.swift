import AppKit
import SwiftUI
import WebKit

/// How a tab hands PDFs (and office documents, `DocumentFormat`) to `PDFViewer` instead of
/// WebKit's built-in viewer (or a download).
///
/// 1. `decidePolicyFor navigationResponse` sees a main-frame PDF and turns the response into a
///    download (`.download`): the one network fetch streams to a temporary file, and WebKit never
///    loads the PDF into the page. The viewer shows progress meanwhile (`pdfAwaitingCommit`).
/// 2. When the file is in, a tiny placeholder page is committed at the PDF's address
///    (`commitPDFPage`, via `loadSimulatedRequest`), so the address bar, history, Back and session
///    restore treat it as an ordinary page.
/// 3. Coming back to that address (Back, Forward, waking, a restored session) reuses the file
///    in `pdfFiles` rather than fetching again; Reload fetches again.
extension Tab {
    /// Puts up a viewer for `url`. The download (or file) is attached by the caller.
    @discardableResult
    func startPDF(url: URL, filename: String?, format: DocumentFormat = .pdf) -> PDFViewer {
        pdf?.close()
        let viewer = PDFViewer(url: url, filename: filename, format: format, tab: self)
        viewer.onDownloaded = { [weak self, weak viewer] file in
            guard let self, let viewer, self.pdf === viewer, let file else { return }
            self.remember(file, for: viewer.url)
            self.commitPDFPage(viewer)
        }
        pdfAwaitingCommit = true
        withAnimation(Motion.quick) { pdf = viewer }
        if url != self.url {
            self.url = url
            browser?.tabDidChange(self, properties: .URL)
        }
        return viewer
    }

    /// Shows a PDF that is already on disk (a local file, or one downloaded before).
    /// `commit`: also commit its placeholder page (false when that page is already showing).
    /// `format`: what it is (by default, from the file's extension).
    func showPDF(file: URL, url: URL, filename: String?, format: DocumentFormat? = nil, commit: Bool) {
        let viewer = startPDF(url: url, filename: filename, format: format ?? .of(file: file))
        viewer.open(file: file)
        if commit {
            commitPDFPage(viewer)
        } else {
            pdfAwaitingCommit = false
        }
    }

    /// Commits the placeholder page that stands in for the PDF in the web view's history.
    func commitPDFPage(_ viewer: PDFViewer) {
        guard let webView, pdf === viewer else { return }
        let key = PDFViewer.key(viewer.url)
        // A Reload swapping the file in place: its page (or history entry) is already there.
        guard pdfAwaitingCommit else { return }
        // History is already on the PDF's entry (a restored session, or Back / Forward to it once
        // the page cache let it go): committing again would add a second entry for it, and Back
        // would land on the same PDF. Its entry is there; the viewer is all that's needed.
        if let item = webView.backForwardList.currentItem, PDFViewer.key(item.url) == key {
            pdfAwaitingCommit = false
            pdfWithoutPage = true
            favicon = viewer.favicon
            if title != viewer.displayTitle {
                title = viewer.displayTitle
                browser?.tabDidChange(self, properties: .title)
            }
            return
        }
        committingPDF = key
        let title = viewer.displayTitle
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        let html = "<!doctype html><meta charset=\"utf-8\"><meta name=\"color-scheme\" content=\"light dark\"><title>\(title)</title>"
        guard let response = HTTPURLResponse(
            url: viewer.url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        ) else { return }
        webView.loadSimulatedRequest(URLRequest(url: viewer.url), response: response, responseData: Data(html.utf8))
    }

    /// Keeps a downloaded file for the address, replacing (and deleting) an older one.
    func remember(_ file: URL, for url: URL) {
        let key = PDFViewer.key(url)
        if let old = pdfFiles[key], old != file { PDFFiles.remove([old]) }
        pdfFiles[key] = file
    }

    /// The cached file for an address, if it is still there.
    func cachedPDF(for url: URL) -> URL? {
        guard let file = pdfFiles[PDFViewer.key(url)] else { return nil }
        if FileManager.default.fileExists(atPath: file.path) { return file }
        pdfFiles[PDFViewer.key(url)] = nil
        return nil
    }

    /// Takes the viewer down (the tab moved on, slept or closed).
    func closePDF() {
        committingPDF = nil
        pdfAwaitingCommit = false
        pdfWithoutPage = false
        guard let viewer = pdf else { return }
        viewer.close()
        withAnimation(Motion.quick) { pdf = nil }
    }

    /// A PDF that never committed (stopped, or navigated away from mid-download): back to the
    /// page the web view is still on.
    func dropPendingPDF() {
        closePDF()
        if let current = webView?.url, current != url {
            url = current
            browser?.tabDidChange(self, properties: .URL)
        }
    }

    // MARK: Navigation delegate hooks

    /// From `decidePolicyFor navigationAction`, for main-frame navigations.
    func pdfNavigationWillStart(to url: URL, type: WKNavigationType) {
        lastMainNavigationType = type
        // Our own placeholder commit.
        if committingPDF == PDFViewer.key(url) { return }
        guard let pdf, PDFViewer.key(pdf.url) != PDFViewer.key(url) else { return }
        // Going somewhere else while a PDF is still coming in.
        if pdfAwaitingCommit {
            dropPendingPDF()
        } else {
            // The web view tracks the address again (the viewer goes when the new page commits).
            pdfWithoutPage = false
        }
    }

    /// From `decidePolicyFor navigationResponse`. Returns the policy when the response is a PDF
    /// or office document the viewer takes over, nil to carry on as normal.
    func pdfPolicy(for navigationResponse: WKNavigationResponse) -> WKNavigationResponsePolicy? {
        guard navigationResponse.isForMainFrame else { return nil }
        mainResponseSeen = true
        let response = navigationResponse.response
        guard let format = DocumentFormat.of(response), let responseURL = response.url else { return nil }
        let key = PDFViewer.key(responseURL)
        // The address as asked for keeps a `#page=` fragment the response doesn't have.
        let shown = pendingURL.flatMap { PDFViewer.key($0) == key ? $0 : nil } ?? responseURL
        let name = response.suggestedFilename

        if responseURL.isFileURL {
            // A file on this Mac: read it where it is.
            showPDF(file: responseURL, url: shown, filename: responseURL.lastPathComponent, format: format, commit: true)
            return .cancel
        }
        if lastMainNavigationType != .reload, lastMainNavigationType != .formSubmitted,
           lastMainNavigationType != .formResubmitted, let file = cachedPDF(for: responseURL) {
            showPDF(file: file, url: shown, filename: name, format: format, commit: true)
            return .cancel
        }
        startPDF(url: shown, filename: name, format: format)
        return .download
    }

    /// From `navigationResponse:didBecome:`. True when the download is the viewer's.
    func adoptPDFDownload(_ download: WKDownload) -> Bool {
        guard let pdf, pdfAwaitingCommit, pdf.phase == .downloading else { return false }
        pdf.attach(download)
        return true
    }

    /// From `didCommit`: keeps, reopens or drops the viewer for the page now showing.
    func pdfDidCommit(_ url: URL) {
        let key = PDFViewer.key(url)
        defer { mainResponseSeen = false }
        pdfWithoutPage = false
        if let pdf, committingPDF == key || (pdfAwaitingCommit && PDFViewer.key(pdf.url) == key) {
            committingPDF = nil
            pdfAwaitingCommit = false
            favicon = pdf.favicon
            return
        }
        // The placeholder page back from WebKit's back / forward cache.
        if !mainResponseSeen, let file = cachedPDF(for: url) {
            if pdf.map({ PDFViewer.key($0.url) != key }) ?? true {
                showPDF(file: file, url: url, filename: nil, commit: false)
            }
            favicon = pdf?.favicon ?? DocumentFormat.of(file: file).favicon
            return
        }
        closePDF()
    }
}
