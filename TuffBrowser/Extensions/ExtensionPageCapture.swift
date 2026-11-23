import AppKit
import UniformTypeIdentifiers
import WebKit

/// Saving and capturing a tab's page for extensions: Chrome's `pageCapture.saveAsMHTML`, and
/// Firefox's `tabs.captureTab` and `tabs.saveAsPDF`. Routed here by `ExtensionAPIBridge`; tabs
/// arrive as their index in the window (see `ExtensionFind.tab`).
enum ExtensionPageCapture {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // MARK: tabs.captureTab

    /// A picture of the tab's page as a data URL, as `tabs.captureVisibleTab` gives one but for
    /// any tab. `rect` is in CSS pixels of the visible page; `scale` is pixels per CSS pixel (the
    /// screen's by default).
    static func captureTab(_ args: [String: Any], context: WKWebExtensionContext, finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) {
        do {
            let tab = try ExtensionFind.tab(args["tabIndex"])
            guard let url = tab.url, context.hasAccess(to: url, in: tab) else {
                throw Failure("Missing activeTab permission, or permission for the tab’s site.")
            }
            guard let webView = tab.webView else { throw Failure("The tab isn’t loaded.") }
            let options = args["options"] as? [String: Any] ?? [:]
            let configuration = WKSnapshotConfiguration()
            if let rect = options["rect"] as? [String: Any] {
                let number = { (key: String) in (rect[key] as? NSNumber)?.doubleValue ?? 0 }
                configuration.rect = CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
            }
            configuration.afterScreenUpdates = false
            let scale = (options["scale"] as? NSNumber)?.doubleValue ?? webView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let jpeg = (options["format"] as? String) == "jpeg"
            let quality = (options["quality"] as? NSNumber)?.doubleValue ?? 92
            webView.takeSnapshot(with: configuration) { image, error in
                guard let image else { return fail(error ?? Failure("The page couldn’t be captured.")) }
                guard let data = encode(image, scale: scale, jpeg: jpeg, quality: quality) else {
                    return fail(Failure("The picture couldn’t be encoded."))
                }
                finish("data:image/\(jpeg ? "jpeg" : "png");base64," + data.base64EncodedString())
            }
        } catch {
            fail(error)
        }
    }

    /// Draws `image` at `scale` pixels per point and encodes it.
    static func encode(_ image: NSImage, scale: Double, jpeg: Bool, quality: Double) -> Data? {
        let width = max(1, Int((image.size.width * scale).rounded())), height = max(1, Int((image.size.height * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        if jpeg {
            return bitmap.representation(using: .jpeg, properties: [.compressionFactor: min(1, max(0, quality / 100))])
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: tabs.saveAsPDF

    /// Firefox saves the selected tab as a PDF, asking where. Answers as Firefox does: "saved",
    /// "replaced" (an existing file was overwritten), "canceled" or "not_saved".
    static func saveAsPDF(_ settings: [String: Any], finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) {
        let state = BrowserState.shared
        guard let tab = state.selectedTab, let webView = tab.webView, let window = state.window else {
            return fail(Failure("There’s no page to save."))
        }
        let panel = NSSavePanel()
        var name = (settings["toFileName"] as? String)?.trimmed ?? ""
        if name.isEmpty {
            let title = tab.displayTitle.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmed
            name = title.isEmpty ? "Page" : title
        }
        if !name.lowercased().hasSuffix(".pdf") { name += ".pdf" }
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.pdf]
        panel.canSelectHiddenExtension = true
        panel.directoryURL = AppSettings.shared.downloads.folder
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return finish("canceled") }
            let existed = FileManager.default.fileExists(atPath: url.path)
            webView.createPDF { result in
                guard case .success(let data) = result, (try? data.write(to: url, options: .atomic)) != nil else {
                    return finish(existed ? "not_replaced" : "not_saved")
                }
                finish(existed ? "replaced" : "saved")
            }
        }
    }

    // MARK: pageCapture.saveAsMHTML

    /// The tab's page with its pictures, styles and frames as one MHTML document, as Chrome makes
    /// it. WebKit saves pages as Web Archives, which hold the same resources; this repacks one.
    static func saveAsMHTML(_ args: [String: Any], finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) {
        do {
            let tab = try ExtensionFind.tab(args["tabIndex"])
            guard let webView = tab.webView else { throw Failure("The tab isn’t loaded.") }
            let title = tab.title
            webView.createWebArchiveData { result in
                switch result {
                case .failure(let error):
                    fail(error)
                case .success(let data):
                    guard let archive = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                          let mhtml = mhtml(from: archive, title: title) else {
                        return fail(Failure("The page couldn’t be saved."))
                    }
                    finish(mhtml)
                }
            }
        } catch {
            fail(error)
        }
    }

    /// One part per resource: the page first, then what it uses, then its frames (and theirs).
    static func mhtml(from archive: [String: Any], title: String, date: Date = Date()) -> String? {
        guard let main = archive["WebMainResource"] as? [String: Any], let location = main["WebResourceURL"] as? String else { return nil }
        var resources: [[String: Any]] = []
        var seen = Set<String>()
        func collect(_ archive: [String: Any]) {
            let items = [archive["WebMainResource"] as? [String: Any]].compactMap { $0 }
                + (archive["WebSubresources"] as? [[String: Any]] ?? [])
            for item in items {
                guard let url = item["WebResourceURL"] as? String, seen.insert(url).inserted else { continue }
                resources.append(item)
            }
            for frame in archive["WebSubframeArchives"] as? [[String: Any]] ?? [] { collect(frame) }
        }
        collect(archive)

        let boundary = "----MultipartBoundary--" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + "----"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        var lines = [
            "From: <Saved by Tuff>",
            "Snapshot-Content-Location: \(location)",
            "Subject: \(encodedWord(headerSafe(title)))",
            "Date: \(formatter.string(from: date))",
            "MIME-Version: 1.0",
            "Content-Type: multipart/related;",
            "\ttype=\"text/html\";",
            "\tboundary=\"\(boundary)\"",
            "",
        ]
        for resource in resources {
            guard let url = resource["WebResourceURL"] as? String, let data = resource["WebResourceData"] as? Data else { continue }
            var type = resource["WebResourceMIMEType"] as? String ?? "application/octet-stream"
            if let encoding = resource["WebResourceTextEncodingName"] as? String, !encoding.isEmpty, type.hasPrefix("text/") {
                type += "; charset=\(encoding)"
            }
            lines += [
                "--\(boundary)",
                "Content-Type: \(type)",
                "Content-Transfer-Encoding: base64",
                "Content-Location: \(headerSafe(url))",
                "",
            ]
            lines.append(data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]))
            lines.append("")
        }
        lines.append("--\(boundary)--")
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    /// Non-ASCII header text as an RFC 2047 encoded word.
    private static func encodedWord(_ text: String) -> String {
        text.allSatisfy(\.isASCII) ? text : "=?utf-8?B?" + Data(text.utf8).base64EncodedString() + "?="
    }

    private static func headerSafe(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}
