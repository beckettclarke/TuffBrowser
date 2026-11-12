import AppKit
import SwiftUI
import WebKit

// MARK: - Navigation

extension Tab: WKNavigationDelegate {
    private static let webSchemes: Set<String> = [
        "http", "https", "about", "file", "data", "blob", "javascript",
        "webkit-extension", "chrome-extension", "moz-extension", "safari-web-extension",
    ]

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        preferences.allowsContentJavaScript = AppSettings.shared.privacy.javaScript
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow, preferences)
            return
        }

        // Hand non-web schemes (mailto:, facetime:, zoommtg:, …) to the system.
        if let scheme = url.scheme?.lowercased(), !Self.webSchemes.contains(scheme) {
            if navigationAction.targetFrame?.isMainFrame ?? true {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel, preferences)
            return
        }

        // Leaving (or entering) an extension's pages takes a web view of the other kind.
        if navigationAction.targetFrame?.isMainFrame ?? false, needsNewWebView(for: url) {
            decisionHandler(.cancel, preferences)
            let request = navigationAction.request
            DispatchQueue.main.async { [weak self] in
                guard let self, self.needsNewWebView(for: url) else { return }
                ExtensionManager.shared.trace("moving tab to a new web view for \(url.absoluteString)")
                self.moveToNewWebView(loading: request)
            }
            return
        }

        // ⌘-click or middle-click opens a background tab.
        let isLink = navigationAction.navigationType == .linkActivated
        let wantsNewTab = navigationAction.modifierFlags.contains(.command) || navigationAction.buttonNumber == 4
        if isLink, wantsNewTab, let browser {
            let foreground = navigationAction.modifierFlags.contains(.shift) != AppSettings.shared.tabs.foregroundLinks
            browser.newTab(url: url, select: foreground, after: self)
            decisionHandler(.cancel, preferences)
            return
        }

        decisionHandler(.allow, preferences)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        if navigationResponse.canShowMIMEType || Self.isRenderable(navigationResponse.response.mimeType) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.download)
    }

    /// WebKit occasionally reports `canShowMIMEType == false` for ordinary pages (seen on a
    /// first visit to youtube.com, whose redirect and service worker hit an edge case), which
    /// turned the page into a downloaded `.html` file and left the tab blank. Never download
    /// content a browser obviously renders unless the server asked for it (Content-Disposition).
    private static func isRenderable(_ mimeType: String?) -> Bool {
        guard let type = mimeType?.lowercased(), !type.isEmpty else { return true }
        if type.hasPrefix("text/") { return true }
        return [
            "application/xhtml+xml", "application/xml", "application/json",
            "application/javascript", "image/svg+xml",
        ].contains(type)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.track(download)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        mediaFrame = nil
        if isInPictureInPicture {
            isInPictureInPicture = false
            enteredPictureInPictureAutomatically = false
            pictureInPictureFrame = nil
        }
        if let request = permissionRequest, webView.url?.host(percentEncoded: false) != request.host {
            withAnimation(Motion.snappy) { resolvePermission(granted: nil) }
        }
        if let u = webView.url {
            url = u
            favicon = ExtensionManager.shared.icon(forPage: u) ?? FaviconStore.shared.cachedIcon(for: u) ?? favicon
        }
        browser?.tabDidNavigate(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let u = webView.url else { return }
        HistoryStore.shared.record(url: u, title: webView.title ?? "")
        FaviconStore.shared.fetchIcon(from: webView) { [weak self] image in
            guard let self, let image else { return }
            self.favicon = image
        }
        browser?.scheduleSave()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadFailure(webView, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleLoadFailure(webView, error: error)
    }

    private func handleLoadFailure(_ webView: WKWebView, error: Error) {
        let ns = error as NSError
        // Cancelled loads, and loads that turned into downloads / plug-in handled content.
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain", [102, 204].contains(ns.code) { return }
        let failingURL = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url
        guard let failingURL else { return }
        webView.loadSimulatedRequest(URLRequest(url: failingURL), responseHTML: WebEngine.errorPage(for: error, url: failingURL))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The content process was killed (usually memory pressure). Reload if the tab is on screen.
        if browser?.selectedTab === self { webView.reload() }
    }

    func webView(
        _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        let passwordMethods = [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM]
        guard passwordMethods.contains(method), webView.window != nil else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let space = challenge.protectionSpace
        let prompt = Prompt(
            icon: favicon,
            symbol: "lock.fill",
            title: "Sign in to \(space.host)",
            subtitle: space.realm,
            message: challenge.previousFailureCount > 0 ? "That username or password didn’t work. Try again." : nil,
            note: space.receivesCredentialSecurely ? nil : "This connection isn’t secure, so your password could be seen by others on the network.",
            confirmTitle: "Sign In",
            fields: [
                Prompt.Field(placeholder: "Username", text: challenge.proposedCredential?.user ?? ""),
                Prompt.Field(placeholder: "Password", secure: true),
            ]
        )
        Task { @MainActor in
            let result = await askForPage(prompt)
            if result.confirmed, result.fields.count == 2 {
                let credential = URLCredential(user: result.fields[0], password: result.fields[1], persistence: .forSession)
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}

// MARK: - UI

extension Tab: WKUIDelegate {
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let browser else { return nil }
        let commandClick = navigationAction.modifierFlags.contains(.command)
        let shift = navigationAction.modifierFlags.contains(.shift)
        let background = commandClick && (shift == AppSettings.shared.tabs.foregroundLinks)
        let tab = browser.newTab(url: nil, select: !background, configuration: configuration, after: self)
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        browser?.close(self)
    }

    private func hostLabel(_ frame: WKFrameInfo) -> String {
        let host = frame.securityOrigin.host
        return host.isEmpty ? "This page" : host
    }

    /// The card for a page's alert() / confirm() / prompt().
    private func pagePrompt(_ frame: WKFrameInfo, _ message: String, cancel: String? = nil, fields: [Prompt.Field] = []) -> Prompt {
        Prompt(
            icon: favicon,
            symbol: "globe",
            title: "\(hostLabel(frame)) says",
            message: message.trimmed.isEmpty ? nil : message,
            confirmTitle: "OK",
            cancelTitle: cancel,
            fields: fields
        )
    }

    /// Shows a card on behalf of this page, bringing its tab to the front first so it's clear
    /// which page is asking.
    @MainActor
    func askForPage(_ prompt: Prompt) async -> PromptResult {
        if let browser, browser.selectedTab !== self { browser.select(self) }
        return await PromptPresenter.ask(prompt)
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void
    ) {
        guard webView.window != nil else { completionHandler(); return }
        let prompt = pagePrompt(frame, message)
        Task { @MainActor in
            _ = await askForPage(prompt)
            completionHandler()
        }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
    ) {
        guard webView.window != nil else { completionHandler(false); return }
        let prompt = pagePrompt(frame, message, cancel: "Cancel")
        Task { @MainActor in completionHandler(await askForPage(prompt).confirmed) }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void
    ) {
        guard webView.window != nil else { completionHandler(nil); return }
        let card = pagePrompt(frame, prompt, cancel: "Cancel", fields: [Prompt.Field(placeholder: "", text: defaultText ?? "")])
        Task { @MainActor in
            let result = await askForPage(card)
            completionHandler(result.confirmed ? result.fields.first ?? "" : nil)
        }
    }

    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        let finish: (NSApplication.ModalResponse) -> Void = { completionHandler($0 == .OK ? panel.urls : nil) }
        if let window = webView.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let host = origin.host
        let kind = SitePermissionKind(type)
        if let remembered = SitePermissions.shared.decision(host: host, kind: kind) {
            decisionHandler(remembered ? .grant : .deny)
            return
        }
        // A newer request replaces one that is still waiting.
        resolvePermission(granted: nil)
        let request = PermissionRequest(host: host, kind: kind) { granted, remember in
            guard let granted else { decisionHandler(.deny); return }
            SitePermissions.shared.record(host: host, kind: kind, granted: granted, remember: remember)
            decisionHandler(granted ? .grant : .deny)
        }
        withAnimation(Motion.snappy) { permissionRequest = request }
    }
}
