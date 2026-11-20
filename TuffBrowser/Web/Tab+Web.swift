import AppKit
import SwiftUI
import WebKit

// MARK: - Navigation

extension Tab: WKNavigationDelegate {
    private static let webSchemes: Set<String> = [
        "http", "https", "about", "file", "data", "blob", "javascript", InternalPage.scheme,
        "webkit-extension", "chrome-extension", "moz-extension", "safari-web-extension",
    ]

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        // JavaScript, pop-ups and autoplay, as Settings and the site's own choices say. A
        // subframe's load follows the page it is in.
        let pageURL = (navigationAction.targetFrame?.isMainFrame ?? true) ? navigationAction.request.url : webView.url
        SiteSettings.apply(to: preferences, for: pageURL, incognito: browser?.isPrivate ?? false)
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow, preferences)
            return
        }

        // The end of signing in to sync (Settings → Sync): Tuff takes the code; the page never loads.
        if navigationAction.targetFrame?.isMainFrame ?? true,
           MainActor.assumeIsolated({ SyncManager.shared.handleRedirect(url, from: self) }) {
            decisionHandler(.cancel, preferences)
            return
        }

        // Magnet links open Tuff's own torrent client (its add sheet asks before anything starts).
        if url.scheme?.lowercased() == "magnet" {
            decisionHandler(.cancel, preferences)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                TorrentBridge.offer(magnet: url, isPrivate: self.browser?.isPrivate ?? false)
            }
            return
        }

        // Hand non-web schemes (mailto:, facetime:, zoommtg:, …) to the system, asking first
        // when a page rather than the user is behind it (`openInOtherApp`).
        if let scheme = url.scheme?.lowercased(), !Self.webSchemes.contains(scheme) {
            if navigationAction.targetFrame?.isMainFrame ?? true {
                openInOtherApp(url, action: navigationAction)
            }
            decisionHandler(.cancel, preferences)
            return
        }

        // Tuff's own pages open only from Tuff (menus, the command bar, Back / Forward). A
        // website can't send a tab, a pop-up or a frame to one: `tuff://source` fetches with the
        // tab's cookies, which a page must not be able to trigger.
        if InternalPage.isInternal(url), !mayOpenInternalPage(url, action: navigationAction) {
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

        let isLink = navigationAction.navigationType == .linkActivated
        if isLink, navigationAction.modifierFlags.contains(.option), url.scheme == "http" || url.scheme == "https" {
            decisionHandler(.download, preferences)
            return
        }

        // ⌘-click or middle-click opens a background tab.
        let wantsNewTab = navigationAction.modifierFlags.contains(.command) || navigationAction.buttonNumber == 4
        if isLink, wantsNewTab, let browser {
            let foreground = navigationAction.modifierFlags.contains(.shift) != AppSettings.shared.tabs.foregroundLinks
            browser.newTab(url: url, select: foreground, after: self)
            decisionHandler(.cancel, preferences)
            return
        }

        // A main-frame navigation is now in flight; extensions read it as `pendingUrl` until it commits.
        if navigationAction.targetFrame?.isMainFrame ?? false {
            pendingURL = url
            // HTTPS for every site. Tuff's own error pages load at the address that failed, as is.
            let policy = url == errorPageURL ? .keepAsRequested : HTTPSUpgrade.policy(for: url, incognito: browser?.isPrivate ?? false)
            preferences.preferredHTTPSNavigationPolicy = policy
            if url.scheme?.lowercased() == "http" {
                httpsUpgradeURL = policy == .errorOnFailure ? url : nil
            } else if url.host(percentEncoded: false) != httpsUpgradeURL?.host(percentEncoded: false) {
                httpsUpgradeURL = nil
            }
            pdfNavigationWillStart(to: url, type: navigationAction.navigationType)
            ContentBlocker.shared.prepare(webView.configuration.userContentController, for: url)
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
        // PDFs open in Tuff's own viewer (see Tab+PDF).
        if let policy = pdfPolicy(for: navigationResponse) {
            decisionHandler(policy)
            return
        }
        if navigationResponse.canShowMIMEType || Self.isRenderable(navigationResponse.response.mimeType) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.download)
    }

    /// Whether a navigation to a `tuff://` page comes from Tuff rather than from a website:
    /// a load Tuff started (`Tab.start`), Back / Forward through the tab's own history, or one
    /// of Tuff's pages moving to another.
    private func mayOpenInternalPage(_ url: URL, action: WKNavigationAction) -> Bool {
        guard action.targetFrame?.isMainFrame ?? false else { return false }
        if let expected = internalPageLoad, expected == url {
            internalPageLoad = nil
            return true
        }
        if action.navigationType == .backForward { return true }
        let source: WKFrameInfo? = action.sourceFrame
        return source?.securityOrigin.protocol.lowercased() == InternalPage.scheme
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
        DownloadManager.shared.track(download, isPrivate: browser?.isPrivate ?? false)
        if navigationAction.targetFrame?.isMainFrame ?? true { mainFrameBecameDownload(in: webView) }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        if adoptPDFDownload(download) { return }
        DownloadManager.shared.track(download, isPrivate: browser?.isPrivate ?? false)
        if navigationResponse.isForMainFrame { mainFrameBecameDownload(in: webView) }
    }

    /// The address the tab was going to turned out to be a file to download. The tab goes
    /// back to saying the page it is still on; one that was opened just for the download (a
    /// link to a file in a new tab) closes, as in Chrome. Before, the tab kept the file's
    /// address, so waking it or relaunching Tuff downloaded the file again.
    private func mainFrameBecameDownload(in webView: WKWebView) {
        pendingURL = nil
        // After WebKit has finished with the navigation that turned into the download.
        DispatchQueue.main.async { [weak self, weak webView] in
            guard let self, let webView, self.webView === webView, !self.pdfHoldsAddress else { return }
            if let page = webView.backForwardList.currentItem?.url {
                guard page != self.url else { return }
                self.url = page
                self.browser?.tabDidChange(self, properties: .URL)
            } else if let browser = self.browser, browser.section(of: self) == .tabs {
                // Without an address it isn't kept for Reopen Closed Tab, which would download again.
                self.url = nil
                browser.close(self, force: true)
            }
        }
    }

    /// WebKit's (private) callback for a download started from the page's context menu
    /// (Download Image, Download Linked File). Without it the download has no delegate, never
    /// gets a destination, and nothing happens. These go straight to the downloads folder; the
    /// menu's "Save … As…" items mark theirs to ask where (`TuffWebView.saveContextDownloadAs`).
    @objc(_webView:contextMenuDidCreateDownload:)
    func webView(_ webView: WKWebView, contextMenuDidCreateDownload download: WKDownload) {
        let asks = contextSaveAsRequested.map { Date().timeIntervalSince($0) < 10 } ?? false
        contextSaveAsRequested = nil
        DownloadManager.shared.track(download, saveLocation: asks ? .ask : .downloadsFolder, isPrivate: browser?.isPrivate ?? false)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        pendingURL = nil
        lastSameDocumentURL = webView.url
        mediaFrame = nil
        // The certificate error page commits at the address that failed; anything else ends it.
        if let failure = certificateFailure, webView.url != failure.url { certificateFailure = nil }
        if let warning = httpsWarningURL, webView.url != warning { httpsWarningURL = nil }
        httpsUpgradeURL = nil
        // A new page gets to show dialogs again, and starts with no blocked pop-ups.
        if !blockedPopups.isEmpty { blockedPopups.removeAll() }
        pageDialogCount = 0
        pageDialogsBlocked = false
        if hoveredLink != nil { hoveredLink = nil }
        if passwordSuggestions != nil { passwordSuggestions = nil }
        translationPageDidCommit()
        // A new page: reader mode was for the one before.
        closeReader()
        if isInPictureInPicture {
            isInPictureInPicture = false
            enteredPictureInPictureAutomatically = false
            pictureInPictureFrame = nil
        }
        if let request = permissionRequest, webView.url?.host(percentEncoded: false) != request.host {
            withAnimation(Motion.snappy) { resolvePermission(granted: nil) }
        }
        showingErrorPage = errorPageURL != nil && webView.url == errorPageURL
        errorPageURL = nil
        if let u = webView.url {
            // Moving within a site keeps the icon on show until the page's own is found: the
            // site's cached one can belong to another of its pages (Docs vs Sheets on
            // docs.google.com).
            // (`url` has already moved on when the navigation started, so the icon's own host says.)
            let host = u.host(percentEncoded: false)?.lowercased()
            let sameSite = favicon != nil && host != nil && faviconHost == host
            url = u
            applySiteZoom()
            favicon = InternalPage.icon(for: u) ?? ExtensionManager.shared.icon(forPage: u)
                ?? (sameSite ? favicon : nil) ?? FaviconStore.shared.cachedIcon(for: u) ?? favicon
            faviconHost = host
            faviconRequest += 1
            pdfDidCommit(u)
        }
        browser?.tabDidNavigate(self)
        ExtensionDeclarativeContent.shared.evaluate(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let u = webView.url else { return }
        if loadingHome {
            loadingHome = false
            if let homeURL, !Self.samePage(u, homeURL) { homeLandingURL = u }
        }
        // Incognito leaves no history and no favicons on disk.
        let incognito = browser?.isPrivate ?? false
        // An error page isn't a visit: recording it put typos in History (and in the command
        // bar's completions) and gave pages titles like "You’re offline".
        if showingErrorPage {
            refreshHeaderColor()
            return
        }
        if !incognito { HistoryStore.shared.record(url: u, title: webView.title ?? "", profileID: browser?.profile(containing: self)?.id) }
        // A PDF's placeholder page has no header or icon of its own to find.
        if let pdf {
            // WebKit hands the keyboard to a page it brings back from the back / forward
            // cache; it belongs to the viewer.
            pdf.focus()
            browser?.scheduleSave()
            return
        }
        refreshHeaderColor()
        // A sign-in sent from the page before this one.
        if pendingLogin != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.offerPendingLogin() } }
        translationPageDidFinish()
        if readerModeRequested {
            readerModeRequested = false
            openReader()
        }
        // Late styles (a header painted by script, a banner slid in) can change it again.
        refreshHeaderColor(after: 0.8)
        refreshHeaderColor(after: 2.5)
        faviconRequest += 1
        let request = faviconRequest
        FaviconStore.shared.fetchIcon(from: webView, persist: !incognito) { [weak self] image in
            guard let self, let image, request == self.faviconRequest else { return }
            self.favicon = image
            self.faviconHost = u.host(percentEncoded: false)?.lowercased()
        }
        browser?.scheduleSave()
    }

    /// WebKit's (private) same-document callback: a single-page app (YouTube, GitHub) moving to
    /// another page with `history.pushState`, or Back / Forward between such pages. These never
    /// reach `didFinish`, so they're recorded here. `replaceState` and #fragment jumps aren't new
    /// pages. The page's new title usually comes a moment later (`HistoryStore.updateTitle`).
    @objc(_webView:navigation:didSameDocumentNavigation:)
    func webView(_ webView: WKWebView, navigation: WKNavigation?, didSameDocumentNavigation type: Int) {
        // _WKSameDocumentNavigationType: 0 anchor, 1 push, 2 replace, 3 pop.
        // A single-page app moving to another page leaves the article reader mode showed.
        if type != 0, let reader, let u = webView.url, !Self.samePage(u, reader.url) { closeReader() }
        if let u = webView.url, !ExtensionManager.isExtensionPage(u) {
            reportSameDocumentNavigation(to: u, type: type)
        }
        guard type == 1 || type == 3, !(browser?.isPrivate ?? false), pdf == nil, let u = webView.url else { return }
        HistoryStore.shared.record(url: u, title: webView.title ?? "", profileID: browser?.profile(containing: self)?.id)
    }

    /// webNavigation has these in Chrome and Firefox but not in WebKit: a single-page app
    /// changing its address (pushState / replaceState / back between them) is
    /// `onHistoryStateUpdated`; only the #fragment changing is `onReferenceFragmentUpdated`.
    /// WebKit reports a fragment change twice (as an anchor navigation, then a history pop),
    /// so an address already reported is skipped.
    private func reportSameDocumentNavigation(to url: URL, type: Int) {
        let previous = lastSameDocumentURL ?? self.url
        lastSameDocumentURL = url
        if url == previous, type != 2 { return }
        func withoutFragment(_ u: URL?) -> String? {
            guard let u, var parts = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return nil }
            parts.fragment = nil
            return parts.string
        }
        let fragmentOnly = type == 0 || (previous != nil && withoutFragment(previous) == withoutFragment(url))
        let details: [String: Any] = [
            "url": url.absoluteString, "frameId": 0, "parentFrameId": -1, "processId": -1,
            "timeStamp": Date().timeIntervalSince1970 * 1000,
            "transitionType": "link", "transitionQualifiers": type == 3 ? ["forward_back"] : [],
        ]
        ExtensionEventPush.shared.emit(
            fragmentOnly ? "webNavigation.onReferenceFragmentUpdated" : "webNavigation.onHistoryStateUpdated",
            details: details, tabs: ["tabId": self], allowed: { $0.hasPermission(.webNavigation) }
        )
        ExtensionDeclarativeContent.shared.evaluate(self)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadingHome = false
        handleLoadFailure(webView, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleLoadFailure(webView, error: error)
    }

    private func handleLoadFailure(_ webView: WKWebView, error: Error) {
        pendingURL = nil
        let ns = error as NSError
        // Cancelled loads, and loads that turned into downloads / plug-in handled content.
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain", [102, 204].contains(ns.code) { return }
        let failingURL = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url
        guard let failingURL else { return }
        // An extension's own page that fails to load (a missing file, a page the extension
        // removed) can't be covered by a simulated page: WebKit's extension scheme handler owns
        // that address, so the simulated load would fail too. Leave whatever is there.
        if ExtensionManager.isExtensionPage(failingURL) || ExtensionManager.isExtensionPage(webView.url) {
            NSLog("Tuff: extension page failed to load: \(failingURL) — \(ns.localizedDescription)")
            return
        }
        // "Always use secure connections" and the site has no working https: a warning page
        // that can let it through on http, unless the site can't be reached at all.
        if let upgraded = httpsUpgradeURL, failingURL.scheme?.lowercased() == "https",
           failingURL.host(percentEncoded: false)?.lowercased() == upgraded.host(percentEncoded: false)?.lowercased() {
            httpsUpgradeURL = nil
            if HTTPSUpgrade.isUnreachable(ns) {
                showErrorPage(WebEngine.errorPage(for: error, url: upgraded), at: upgraded, in: webView)
            } else {
                httpsWarningURL = upgraded
                showErrorPage(HTTPSUpgrade.warningPage(for: upgraded), at: upgraded, in: webView)
            }
            return
        }
        // An untrusted certificate gets its own page, which can show it and let you through.
        if let failure = CertificateFailure(error: ns, url: failingURL) {
            certificateFailure = failure
            showErrorPage(WebEngine.certificateErrorPage(for: failure), at: failingURL, in: webView)
            return
        }
        showErrorPage(WebEngine.errorPage(for: error, url: failingURL), at: failingURL, in: webView)
    }

    /// Puts one of Tuff's error pages up at the address that failed (`showingErrorPage`).
    func showErrorPage(_ html: String, at url: URL, in webView: WKWebView) {
        errorPageURL = url
        webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
    }

    /// The content process went away (memory pressure, or the page crashed it). A tab on screen
    /// reloads now and one in the background when it is next shown; a page that keeps crashing
    /// gets an error page instead of reloading forever.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        recentCrashes = recentCrashes.filter { now.timeIntervalSince($0) < 60 } + [now]
        if recentCrashes.count >= 3 {
            recentCrashes.removeAll()
            crashedWhileHidden = false
            let error = NSError(domain: "Tuff", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "This page stopped working several times in a row, so Tuff stopped reloading it.",
            ])
            if let url = url ?? webView.url {
                showErrorPage(WebEngine.errorPage(for: error, url: url), at: url, in: webView)
            }
            return
        }
        if browser?.isOnScreen(self) == true {
            webView.reload()
        } else {
            crashedWhileHidden = true
        }
    }

    func webView(
        _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        // A certificate the user chose to trust on the certificate error page; anything else is
        // checked by the system as usual (and an untrusted one fails into that page).
        if method == NSURLAuthenticationMethodServerTrust {
            let space = challenge.protectionSpace
            if let trust = space.serverTrust, CertificateExceptions.shared.allows(trust, host: space.host, port: space.port) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }
        let passwordMethods = [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM]
        // A tab in the background asks when it is next shown (see `askForPage`).
        guard passwordMethods.contains(method), browser != nil else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let space = challenge.protectionSpace
        // Saved passwords: the site's login filled in, and a box to save a new one.
        let scheme = space.protocol?.lowercased() ?? "https"
        let defaultPort = scheme == "https" ? 443 : 80
        let origin = "\(scheme)://\(space.host.lowercased())\(space.port != 0 && space.port != defaultPort ? ":\(space.port)" : "")"
        let profile = PasswordAutofill.enabled ? passwordProfileID : nil
        let saved = profile.flatMap { PasswordStore.shared.logins(for: origin, profile: $0).first { $0.origin == origin } }
        let proposed = challenge.previousFailureCount == 0 ? saved : nil
        let prompt = Prompt(
            icon: favicon,
            symbol: "lock.fill",
            title: "Sign in to \(space.host)",
            subtitle: space.realm,
            message: challenge.previousFailureCount > 0 ? "That username or password didn’t work. Try again." : nil,
            note: space.receivesCredentialSecurely ? nil : "This connection isn’t secure, so your password could be seen by others on the network.",
            confirmTitle: "Sign In",
            fields: [
                Prompt.Field(placeholder: "Username", text: proposed?.username ?? challenge.proposedCredential?.user ?? ""),
                Prompt.Field(placeholder: "Password", text: proposed?.password ?? "", secure: true),
            ],
            checkbox: profile == nil ? nil : "Save password in Tuff",
            checked: profile != nil
        )
        Task { @MainActor in
            if let result = await askForPage(prompt), result.confirmed, result.fields.count == 2 {
                let credential = URLCredential(user: result.fields[0], password: result.fields[1], persistence: .forSession)
                if let profile, result.checked, !result.fields[1].isEmpty {
                    PasswordStore.shared.save(origin: origin, username: result.fields[0].trimmed, password: result.fields[1], profile: profile)
                }
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}

// MARK: - UI

extension Tab: WKUIDelegate {
    /// WebKit's (private) hover callback, the one Safari's status bar uses: it reports the link
    /// under the mouse, in any frame, without running script in the page.
    @objc(_webView:mouseDidMoveOverElement:withFlags:userInfo:)
    func webView(_ webView: WKWebView, mouseDidMoveOverElement hitTestResult: NSObject?, withFlags flags: UInt, userInfo: Any?) {
        var link: URL?
        if let hitTestResult, hitTestResult.responds(to: NSSelectorFromString("absoluteLinkURL")) {
            link = hitTestResult.value(forKey: "absoluteLinkURL") as? URL
        }
        // Called on every mouse move; only touch the observed property when the link changes.
        if link != hoveredLink { hoveredLink = link }
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let browser else { return nil }
        let commandClick = navigationAction.modifierFlags.contains(.command)
        let shift = navigationAction.modifierFlags.contains(.shift)
        let background = commandClick && (shift == AppSettings.shared.tabs.foregroundLinks)
        let tab = browser.newTab(url: nil, select: !background, configuration: configuration, after: self)
        // webNavigation.onCreatedNavigationTarget, which WebKit doesn't send: a link with a
        // target or window.open made a new tab.
        if let target = navigationAction.request.url {
            ExtensionEventPush.shared.emit("webNavigation.onCreatedNavigationTarget", details: [
                "url": target.absoluteString, "sourceFrameId": navigationAction.sourceFrame.isMainFrame ? 0 : -1,
                "sourceProcessId": -1, "timeStamp": Date().timeIntervalSince1970 * 1000,
            ], tabs: ["sourceTabId": self, "tabId": tab], allowed: { $0.hasPermission(.webNavigation) })
        }
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        // Either the page agreed to a close we asked for (`requestClose`), or it called
        // `window.close()` itself.
        if pendingClose != nil {
            finishClose()
        } else {
            browser?.close(self, force: true)
        }
    }

    /// The page has unsaved changes and asks before it is left (`beforeunload`): closing the
    /// tab, reloading or going elsewhere. The tab comes to the front, since the user is acting
    /// on it.
    @objc(_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:)
    func webView(
        _ webView: WKWebView, runBeforeUnloadConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
    ) {
        guard !pageDialogsBlocked, let browser else { completionHandler(true); return }
        if browser.selectedTab !== self { browser.select(self) }
        beforeUnloadShowing = true
        let prompt = Prompt(
            icon: favicon,
            symbol: "exclamationmark.triangle.fill",
            title: "Leave this page?",
            subtitle: hostLabel(frame),
            message: "Changes you made may not be saved.",
            confirmTitle: "Leave",
            cancelTitle: "Stay",
            destructive: true
        )
        Task { @MainActor in
            let leave = await askForPage(prompt)?.confirmed ?? true
            beforeUnloadShowing = false
            if !leave { pendingClose = nil }
            completionHandler(leave)
        }
    }

    /// The page called `window.print()` (a "Print" button on a receipt or boarding pass).
    /// Without this WebKit does nothing. Prints the frame that asked, with the print panel.
    @objc(_webView:printFrame:pdfFirstPageSize:completionHandler:)
    func webView(_ webView: WKWebView, printFrame frame: AnyObject, pdfFirstPageSize size: CGSize, completionHandler: @escaping () -> Void) {
        printFrame(frame, in: webView, then: completionHandler)
    }

    @objc(_webView:printFrame:)
    func webView(_ webView: WKWebView, printFrame frame: AnyObject) {
        printFrame(frame, in: webView, then: {})
    }

    private func printFrame(_ frame: AnyObject, in webView: WKWebView, then done: @escaping () -> Void) {
        guard let browser, browser.selectedTab === self, let window = webView.window else { done(); return }
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        var operation: NSPrintOperation?
        let selector = NSSelectorFromString("_printOperationWithPrintInfo:forFrame:")
        if webView.responds(to: selector), let imp = webView.method(for: selector) {
            typealias Fn = @convention(c) (AnyObject, Selector, NSPrintInfo, AnyObject) -> NSPrintOperation?
            operation = unsafeBitCast(imp, to: Fn.self)(webView, selector, info, frame)
        }
        let print = operation ?? webView.printOperation(with: info)
        if operation == nil { print.view?.frame = webView.bounds }
        PrintCompletion.run(print, in: window, then: done)
    }

    private func hostLabel(_ frame: WKFrameInfo) -> String {
        let host = frame.securityOrigin.host
        return host.isEmpty ? "This page" : host
    }

    /// The card for a page's alert() / confirm() / prompt(). From the page's second dialog on,
    /// it offers to stop the page showing any more (a page can loop on `alert`).
    private func pagePrompt(_ frame: WKFrameInfo, _ message: String, cancel: String? = nil, fields: [Prompt.Field] = []) -> Prompt {
        Prompt(
            icon: favicon,
            symbol: "globe",
            title: "\(hostLabel(frame)) says",
            message: message.trimmed.isEmpty ? nil : message,
            confirmTitle: "OK",
            cancelTitle: cancel,
            fields: fields,
            checkbox: pageDialogCount > 0 ? "Don’t let this page show more dialogs" : nil
        )
    }

    /// Shows a card on behalf of this page. A tab in the background doesn't interrupt what is on
    /// screen: its card waits until the tab is shown, as in Chrome and Safari. Nil when the page
    /// went away first (tab closed or unloaded), which counts as Cancel.
    @MainActor
    func askForPage(_ prompt: Prompt) async -> PromptResult? {
        guard let browser else { return nil }
        if !browser.isOnScreen(self) {
            let shown = await withCheckedContinuation { dialogWaiters.append($0) }
            guard shown else { return nil }
        }
        // The other side of a split: it takes the keyboard, so the card is plainly its own.
        if browser.selectedTab !== self, browser.isOnScreen(self) { browser.select(self) }
        var prompt = prompt
        prompt.browser = self.browser ?? browser
        return await PromptPresenter.ask(prompt)
    }

    /// Shows a page's alert() / confirm() / prompt() card, unless the user has blocked the page's
    /// dialogs. Nil when it wasn't shown or the page went away.
    @MainActor
    private func askForPageDialog(_ prompt: Prompt) async -> PromptResult? {
        guard !pageDialogsBlocked, let result = await askForPage(prompt) else { return nil }
        pageDialogCount += 1
        if result.checked { pageDialogsBlocked = true }
        return result
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void
    ) {
        guard !pageDialogsBlocked else { completionHandler(); return }
        let prompt = pagePrompt(frame, message)
        Task { @MainActor in
            _ = await askForPageDialog(prompt)
            completionHandler()
        }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
    ) {
        guard !pageDialogsBlocked else { completionHandler(false); return }
        let prompt = pagePrompt(frame, message, cancel: "Cancel")
        Task { @MainActor in completionHandler(await askForPageDialog(prompt)?.confirmed ?? false) }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void
    ) {
        // The notifications script reading `Notification.permission`; nothing to show.
        if prompt == WebNotifications.permissionQuery {
            completionHandler(WebNotifications.permission(for: frame, in: self))
            return
        }
        guard !pageDialogsBlocked else { completionHandler(nil); return }
        let card = pagePrompt(frame, prompt, cancel: "Cancel", fields: [Prompt.Field(placeholder: "", text: defaultText ?? "")])
        Task { @MainActor in
            let result = await askForPageDialog(card)
            completionHandler(result?.confirmed == true ? result?.fields.first ?? "" : nil)
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
        askPermission(origin: origin, kind: SitePermissionKind(type)) { decisionHandler($0 == true ? .grant : .deny) }
    }

    /// `getDisplayMedia`: "Present" in Meet, Zoom and Teams. WebKit's private question for it;
    /// unanswered, every request is refused. After Allow, macOS's own picker chooses the
    /// screen or window. The answer is a `WKDisplayCapturePermissionDecision`: 0 deny,
    /// 1 pick a screen, 2 pick a window.
    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func webView(
        _ webView: WKWebView, requestDisplayCapturePermissionFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo, withSystemAudio: Bool, decisionHandler: @escaping (Int) -> Void
    ) {
        askPermission(origin: origin, kind: .screen) { decisionHandler($0 == true ? 1 : 0) }
    }

    /// `navigator.geolocation`. Public from macOS 27; WebKit asks the private method below on
    /// older versions. Unanswered, WebKit refuses every location request.
    @available(macOS 27.0, *)
    @MainActor
    func webView(
        _ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo
    ) async -> WKPermissionDecision {
        await withCheckedContinuation { continuation in
            askPermission(origin: origin, kind: .location) { continuation.resume(returning: $0 == true ? .grant : .deny) }
        }
    }

    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func webView(
        _ webView: WKWebView, legacyGeolocationPermissionFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        askPermission(origin: origin, kind: .location) { decisionHandler($0 == true ? .grant : .deny) }
    }

    /// Answers from a remembered choice, else shows the permission card over this tab.
    /// `decide` gets nil when the request goes unanswered (tab closed, page navigated).
    /// Answers are kept per origin (scheme, host and port), and Incognito's stay in memory.
    func askPermission(origin: WKSecurityOrigin, kind: SitePermissionKind, then decide: @escaping (Bool?) -> Void) {
        let host = origin.host
        let key = SitePermissions.origin(of: origin)
        let incognito = browser?.isPrivate ?? false
        if kind.isRemembered, let remembered = SitePermissions.shared.decision(origin: key, kind: kind, incognito: incognito) {
            decide(remembered)
            return
        }
        // A newer request replaces one that is still waiting.
        resolvePermission(granted: nil)
        let request = PermissionRequest(host: host, kind: kind) { granted, remember in
            guard let granted else { decide(nil); return }
            if kind.isRemembered {
                SitePermissions.shared.record(origin: key, kind: kind, granted: granted, remember: remember, incognito: incognito)
            }
            decide(granted)
        }
        withAnimation(Motion.snappy) { permissionRequest = request }
    }
}

// MARK: - Header colour (Seamless background)

extension Tab {
    /// Works out `headerColor`: the background of what is painted along the page's top edge,
    /// else its `theme-color`, else the colour WebKit shows past the page's ends.
    /// Does nothing unless the Seamless background is on.
    func refreshHeaderColor(after delay: TimeInterval = 0) {
        let style = browser?.theme.style ?? AppSettings.shared.theme.style
        guard style == .seamless, let view = webView else { return }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak view] in
                guard let self, let view, self.webView === view else { return }
                self.refreshHeaderColor()
            }
            return
        }
        // What is actually painted comes first: a `theme-color` can disagree with the header
        // (GitHub's is dark over a white bar), and the point is for the two to run together.
        view.evaluateJavaScript(Self.headerColorScript) { [weak self, weak view] result, _ in
            guard let self, let view, self.webView === view else { return }
            if let css = result as? String, let color = NSColor(cssRGB: css) {
                self.setHeaderColor(color)
            } else if let theme = view.themeColor, theme.alphaComponent > 0.5 {
                self.setHeaderColor(theme)
            } else {
                self.setHeaderColor(view.underPageBackgroundColor)
            }
        }
    }

    private func setHeaderColor(_ color: NSColor?) {
        let color = color?.usingColorSpace(.sRGB)
        guard let color else { return }
        if let current = headerColor, current.isClose(to: color) { return }
        withAnimation(.easeOut(duration: 0.22)) { headerColor = color }
    }

    /// The background colour of the topmost painted element across the top of the page, or "".
    /// An element with a background image there (a photo header) gives "" too: no flat colour
    /// would match it.
    static let headerColorScript = """
    (() => {
      const solid = (c) => {
        const m = /^rgba?\\(([^)]+)\\)$/.exec(c || '');
        if (!m) return false;
        const p = m[1].split(/[\\s,\\/]+/).filter(Boolean).map(Number);
        return p.length < 4 || p[3] >= 0.6;
      };
      const paint = (el) => {
        for (; el && el.nodeType === 1; el = el.parentElement) {
          const cs = getComputedStyle(el);
          if (solid(cs.backgroundColor)) return cs.backgroundColor;
          if (cs.backgroundImage && cs.backgroundImage !== 'none' && el !== document.body && el !== document.documentElement) return '';
        }
        return null;
      };
      const w = innerWidth;
      const seen = [];
      for (const x of [w * 0.5, w * 0.2, w * 0.8]) {
        const c = paint(document.elementFromPoint(x, 1));
        if (c === '') return '';
        if (c) seen.push(c);
      }
      if (seen.length) {
        const counts = {};
        for (const c of seen) counts[c] = (counts[c] || 0) + 1;
        return Object.keys(counts).sort((a, b) => counts[b] - counts[a])[0];
      }
      for (const el of [document.body, document.documentElement]) {
        if (el && solid(getComputedStyle(el).backgroundColor)) return getComputedStyle(el).backgroundColor;
      }
      return '';
    })()
    """
}

extension NSColor {
    /// Reads CSS `rgb(r, g, b)` / `rgba(r, g, b, a)` (the form `getComputedStyle` gives).
    convenience init?(cssRGB css: String) {
        guard let open = css.firstIndex(of: "("), let close = css.lastIndex(of: ")"), open < close else { return nil }
        let parts = css[css.index(after: open)..<close]
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .compactMap { Double($0) }
        guard parts.count >= 3 else { return nil }
        self.init(srgbRed: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: 1)
    }

    /// Near enough that swapping one for the other wouldn't show.
    func isClose(to other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
    }
}

/// Runs a print operation as a sheet and calls back when it is done (AppKit reports that
/// through a delegate selector).
final class PrintCompletion: NSObject {
    private let done: () -> Void
    private static var running: Set<PrintCompletion> = []

    private init(_ done: @escaping () -> Void) { self.done = done }

    static func run(_ operation: NSPrintOperation, in window: NSWindow, then done: @escaping () -> Void) {
        let completion = PrintCompletion(done)
        running.insert(completion)
        operation.runModal(
            for: window, delegate: completion,
            didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil
        )
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        done()
        Self.running.remove(self)
    }
}
