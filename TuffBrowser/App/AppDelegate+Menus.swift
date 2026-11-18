import AppKit
import UniformTypeIdentifiers
import WebKit

/// Menu commands beyond tabs and navigation: files, page source, downloads, history, find
/// again, and the keyboard shortcuts card.
extension AppDelegate {
    // MARK: File

    /// ⌘O: opens files from the Mac (web pages, PDFs, pictures, text) in new tabs.
    @objc func openFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.html, .pdf, .image, .plainText, .svg, .webArchive, .xml, .json, .movie, .audio]
        panel.allowsOtherFileTypes = true
        let state = self.state
        let open: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            panel.urls.forEach { state.newTab(url: $0) }
        }
        if let window = state.window {
            panel.beginSheetModal(for: window, completionHandler: open)
        } else {
            open(panel.runModal())
        }
    }

    /// ⇧⌘W: closes the window in front (an Incognito one closes for good; the main one comes back
    /// from the Dock with its tabs).
    @objc func closeWindow(_ sender: Any?) {
        (NSApp.keyWindow ?? state.window)?.performClose(sender)
    }

    /// ⇧⌘S: saves the page as a Web Archive (the whole page, pictures and all), or as HTML (its
    /// source) or PDF when given that ending.
    @objc func savePageAs(_ sender: Any?) {
        guard let tab = state.selectedTab, let webView = tab.webView, let window = state.window else { return }
        let panel = NSSavePanel()
        let base = tab.displayTitle.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmed
        panel.nameFieldStringValue = (base.isEmpty ? "Page" : base) + ".webarchive"
        panel.allowedContentTypes = [.webArchive, .html, .pdf]
        panel.allowsOtherFileTypes = false
        panel.canSelectHiddenExtension = true
        panel.message = "A Web Archive keeps the whole page. Name it .html for the source only, or .pdf for a PDF."
        panel.directoryURL = AppSettings.shared.downloads.folder
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let fail: (Error?) -> Void = { error in
                guard let error else { return }
                self?.state.show(Toast(symbol: "exclamationmark.triangle", text: "Couldn’t save: \(error.localizedDescription)"))
            }
            switch url.pathExtension.lowercased() {
            case "html", "htm":
                webView.evaluateJavaScript("document.documentElement.outerHTML") { result, error in
                    guard let html = result as? String else { fail(error); return }
                    do { try ("<!doctype html>\n" + html).write(to: url, atomically: true, encoding: .utf8) } catch { fail(error) }
                }
            case "pdf":
                webView.createPDF { result in
                    switch result {
                    case .success(let data): do { try data.write(to: url, options: .atomic) } catch { fail(error) }
                    case .failure(let error): fail(error)
                    }
                }
            default:
                webView.createWebArchiveData { result in
                    switch result {
                    case .success(let data): do { try data.write(to: url, options: .atomic) } catch { fail(error) }
                    case .failure(let error): fail(error)
                    }
                }
            }
        }
    }

    // MARK: View

    /// ⌥⌘U: the page's HTML in a new tab beside it.
    @objc func viewSource(_ sender: Any?) {
        guard let tab = state.selectedTab, let url = tab.url,
              var components = URLComponents(string: "\(InternalPage.scheme)://\(InternalPage.source.rawValue)") else { return }
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        guard let source = components.url else { return }
        state.newTab(url: source, after: tab)
    }

    /// ⌥⌘L: opens the downloads page (web downloads and torrents) in a tab.
    @objc func showDownloads(_ sender: Any?) {
        state.downloadsVisible = false
        state.showDownloadsPage()
    }

    /// Edit → Paste and Go: opens what's on the clipboard in the current tab.
    @objc func pasteAndGo(_ sender: Any?) {
        ensureBrowserWindow()
        state.pasteAndGo()
    }

    // MARK: History

    /// History → Clear History…: every page in History and the recently closed tabs. Cookies and
    /// website data stay (Settings → Privacy clears those).
    @objc func clearHistory(_ sender: Any?) {
        let pages = HistoryStore.shared.count
        let prompt = Prompt(
            symbol: "clock.arrow.circlepath",
            title: "Clear all history?",
            subtitle: pages == 1 ? "1 page" : "\(pages) pages",
            message: "Removes every page from History and the list of recently closed tabs. Cookies and website data stay.",
            confirmTitle: "Clear History",
            destructive: true,
            checkbox: "Also clear the downloads list"
        )
        Task { @MainActor in
            let result = await PromptPresenter.ask(prompt)
            guard result.confirmed else { return }
            HistoryStore.shared.clear()
            BrowserState.all.forEach { $0.forgetClosedTabs() }
            if result.checked { DownloadManager.shared.clearFinished() }
            state.show(Toast(symbol: "checkmark", text: "History cleared"))
        }
    }

    // MARK: Edit

    /// ⌘G / ⇧⌘G.
    @objc func findNext(_ sender: Any?) { state.findAgain(forward: true) }
    @objc func findPrevious(_ sender: Any?) { state.findAgain(forward: false) }

    // MARK: Help

    /// Help → Keyboard Shortcuts: the main ones on a card.
    @objc func showKeyboardShortcuts(_ sender: Any?) {
        let shortcuts: [(String, String)] = [
            ("magnifyingglass", "⌘T  New tab · ⌘L  Edit address"),
            ("xmark.square", "⌘W  Close tab · ⇧⌘T  Reopen closed tab"),
            ("sidebar.left", "⌘S  Toggle sidebar · ⌥⌘S  Extension panel"),
            ("rectangle.split.2x1", "⌘\\  Split view · ⌥⌘\\  Switch side"),
            ("rectangle.stack", "⌘1–9  Tabs · ⌃1–9  Spaces · ⌥⌘←/→  Switch space"),
            ("pin", "⌘D  Pin tab · ⇧⌘M  Mute tab"),
            ("text.magnifyingglass", "⌘F  Find · ⌘G / ⇧⌘G  Next / previous match"),
            ("arrow.down.circle", "⌥⌘L  Downloads · ⌘Y  History"),
            ("chevron.left.forwardslash.chevron.right", "⌥⌘U  View source · ⌥⌘I  Web Inspector"),
            ("eyeglasses", "⇧⌘N  New Incognito window"),
        ]
        Task { @MainActor in
            await PromptPresenter.present(Prompt(
                symbol: "keyboard",
                title: "Keyboard Shortcuts",
                items: shortcuts.map { Prompt.Item(symbol: $0.0, text: $0.1) },
                confirmTitle: "Done",
                cancelTitle: nil
            ))
        }
    }

    // MARK: Validation

    /// The commands above, for `validateMenuItem`.
    func validateMoreMenuItems(_ menuItem: NSMenuItem) -> Bool {
        let tab = state.selectedTab
        let isWebPage = tab?.webView != nil && !(tab?.pdf?.isReady ?? false)
        switch menuItem.action {
        case #selector(savePageAs(_:)):
            return isWebPage
        case #selector(viewSource(_:)):
            return isWebPage && ["http", "https"].contains(tab?.url?.scheme?.lowercased() ?? "")
        case #selector(findNext(_:)), #selector(findPrevious(_:)):
            return tab != nil
        case #selector(pasteAndGo(_:)):
            return state.pasteAndGoText != nil
        case #selector(clearHistory(_:)):
            return HistoryStore.shared.count > 0 || state.hasClosedTabs
        default:
            return true
        }
    }
}
