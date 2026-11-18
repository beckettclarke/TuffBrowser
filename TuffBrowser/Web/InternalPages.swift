import AppKit
import WebKit

/// Tuff's own pages, served from `tuff://` (`tuff://history`).
///
/// They are ordinary web pages in an ordinary tab, so they get back / forward, session restore,
/// ⌘-click into a new tab and everything else a tab does for free. What a page needs from the
/// app goes through the `tuff` message handler, which answers only these pages' main frames.
enum InternalPage: String, CaseIterable {
    case history
    /// `tuff://downloads`: web downloads and torrents (see `DownloadsPage`).
    case downloads
    /// `tuff://source?url=…`: a page's HTML as the server sent it (View → View Source).
    case source

    static let scheme = "tuff"

    var url: URL { URL(string: "\(Self.scheme)://\(rawValue)")! }

    var title: String {
        switch self {
        case .history: "History"
        case .downloads: "Downloads"
        case .source: "Page Source"
        }
    }

    var symbol: String {
        switch self {
        case .history: "clock.arrow.circlepath"
        case .downloads: "arrow.down.circle"
        case .source: "chevron.left.forwardslash.chevron.right"
        }
    }

    init?(url: URL?) {
        guard let url, url.scheme?.lowercased() == Self.scheme,
              let page = InternalPage(rawValue: url.host(percentEncoded: false)?.lowercased() ?? "") else { return nil }
        self = page
    }

    static func isInternal(_ url: URL?) -> Bool { url?.scheme?.lowercased() == scheme }

    /// The tab icon for one of these pages.
    static func icon(for url: URL?) -> NSImage? {
        guard let page = InternalPage(url: url) else { return nil }
        if let cached = icons[page] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
            .applying(.init(paletteColors: [NSColor(white: 0.52, alpha: 1)]))
        guard let symbol = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.title)?
            .withSymbolConfiguration(config) else { return nil }
        let size = NSSize(width: 32, height: 32)
        let image = NSImage(size: size, flipped: false) { rect in
            let s = symbol.size
            let scale = min(rect.width / s.width, rect.height / s.height)
            let w = s.width * scale, h = s.height * scale
            symbol.draw(in: NSRect(x: (rect.width - w) / 2, y: (rect.height - h) / 2, width: w, height: h))
            return true
        }
        icons[page] = image
        return image
    }

    private static var icons: [InternalPage: NSImage] = [:]
}

/// Serves `tuff://` pages and answers their requests to the app.
final class InternalPageHandler: NSObject, WKURLSchemeHandler, WKScriptMessageHandlerWithReply {
    static let shared = InternalPageHandler()
    private static let messageName = "tuff"
    /// Scheme tasks still waiting for an answer. WebKit throws if a task it has stopped (the
    /// page went away, an image scrolled off) is answered, so late answers check here first.
    private var active = Set<ObjectIdentifier>()
    private let fileQueue = DispatchQueue(label: "tuff.internal-pages", qos: .userInitiated)

    func install(into configuration: WKWebViewConfiguration) {
        configuration.setURLSchemeHandler(self, forURLScheme: InternalPage.scheme)
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: Self.messageName)
    }

    // MARK: Serving

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        // Only Tuff's own pages load from tuff://. A website embedding tuff://favicon as an image
        // could otherwise tell which sites are in History, and one framing tuff://source could
        // make a signed-in request to another site.
        if let main = urlSchemeTask.request.mainDocumentURL, !InternalPage.isInternal(main) {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        active.insert(ObjectIdentifier(urlSchemeTask))
        let host = url.host(percentEncoded: false)?.lowercased() ?? ""
        if host == "favicon" {
            serveFavicon(for: url, to: urlSchemeTask)
            return
        }
        switch InternalPage(url: url) {
        case .history:
            respond(urlSchemeTask, url: url, mime: "text/html", data: Data(HistoryPage.html().utf8))
        case .downloads:
            respond(urlSchemeTask, url: url, mime: "text/html", data: Data(DownloadsWebPage.html().utf8))
        case .source:
            serveSource(for: url, in: webView, to: urlSchemeTask)
        case nil:
            let page = WebEngine.errorPage(for: URLError(.fileDoesNotExist), url: url)
            respond(urlSchemeTask, url: url, mime: "text/html", data: Data(page.utf8), status: 404)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        active.remove(ObjectIdentifier(urlSchemeTask))
    }

    /// `tuff://favicon?host=www.example.com`: the site's icon from the favicon cache, for the
    /// History page. The cached file is already a PNG, so it is read off the main thread and
    /// sent as is (a page of history asks for a couple of hundred at once). 404 when there
    /// isn't one; the page draws a letter instead.
    private func serveFavicon(for url: URL, to task: WKURLSchemeTask) {
        let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "host" }?.value ?? ""
        // Icons are cached under the host the page was on; the History page knows sites by
        // their name without "www.", so try both.
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let candidates = [host, "www." + bare, bare]
        guard let file = candidates.lazy.compactMap({ FaviconStore.shared.cachedIconFile(forHost: $0) }).first else {
            respond(task, url: url, mime: "image/png", data: Data(), status: 404)
            return
        }
        fileQueue.async { [weak self] in
            let data = try? Data(contentsOf: file)
            DispatchQueue.main.async {
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.respond(task, url: url, mime: "image/png", data: data, cache: true)
                } else {
                    self.respond(task, url: url, mime: "image/png", data: Data(), status: 404)
                }
            }
        }
    }

    /// `tuff://source?url=https://…`: fetches the page again, with the tab's cookies (so a
    /// signed-in page shows what you see), and shows its HTML as text with line numbers.
    private func serveSource(for url: URL, in webView: WKWebView, to task: WKURLSchemeTask) {
        let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "url" }?.value.flatMap(URL.init(string:))
        guard let target, let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            let page = SourcePage.html(for: nil, text: "Open a web page, then choose View → View Source (⌥⌘U).")
            respond(task, url: url, mime: "text/html", data: Data(page.utf8))
            return
        }
        let userAgent = webView.customUserAgent.flatMap { $0.isEmpty ? nil : $0 }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            var request = URLRequest(url: target)
            request.httpShouldHandleCookies = false
            let host = target.host(percentEncoded: false)?.lowercased() ?? ""
            let matching = cookies.filter { cookie in
                let domain = cookie.domain.lowercased()
                let domainMatches = domain.hasPrefix(".") ? (host == domain.dropFirst() || host.hasSuffix(domain)) : host == domain
                return domainMatches && target.path.hasPrefix(cookie.path) && (!cookie.isSecure || scheme == "https")
            }
            HTTPCookie.requestHeaderFields(with: matching).forEach { request.setValue($1, forHTTPHeaderField: $0) }
            if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
            // Trusts a certificate the user let through on the certificate error page, as the tab does.
            let session = URLSession(configuration: .ephemeral, delegate: SourceFetchTrust(), delegateQueue: .main)
            session.dataTask(with: request) { data, response, error in
                var text: String
                if let data {
                    let encoding = (response?.textEncodingName).map {
                        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding($0 as CFString)))
                    } ?? .utf8
                    text = String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
                } else {
                    text = "Couldn’t load the source: \(error?.localizedDescription ?? "no answer")"
                }
                let page = SourcePage.html(for: target, text: text)
                DispatchQueue.main.async { self?.respond(task, url: url, mime: "text/html", data: Data(page.utf8)) }
            }.resume()
            session.finishTasksAndInvalidate()
        }
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, mime: String, data: Data, status: Int = 200, cache: Bool = false) {
        guard active.remove(ObjectIdentifier(task)) != nil else { return }
        var headers = [
            "Content-Type": mime + (mime.hasPrefix("text/") ? "; charset=utf-8" : ""),
            "Content-Length": String(data.count),
            "Cache-Control": cache ? "max-age=3600" : "no-store",
        ]
        if mime == "text/html" {
            // Nothing on these pages comes from the web.
            headers["Content-Security-Policy"] =
                "default-src 'none'; img-src tuff: data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'"
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8")
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    // MARK: Requests from the pages

    private static func date(_ value: Any?) -> Date? {
        (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    }

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        // Every web page can see the handler; only Tuff's own pages, in a tab's main frame, get
        // an answer. (The frame's origin is what counts: the web view's address can lag behind
        // it while a page is being put back.)
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == InternalPage.scheme,
              let body = message.body as? [String: Any], let command = body["cmd"] as? String else {
            replyHandler(nil, "Not available")
            return
        }
        let browser = (message.webView as? TuffWebView)?.tab?.browser
        func confirm(_ prompt: Prompt, then action: @escaping () -> Void) {
            Task { @MainActor in
                var prompt = prompt
                prompt.browser = browser
                let confirmed = await PromptPresenter.present(prompt)
                if confirmed { action() }
                replyHandler(confirmed, nil)
            }
        }

        if command.hasPrefix("dl.") {
            DownloadsWebPage.handle(command, body, browser: browser, reply: replyHandler)
            return
        }

        switch command {
        case "history.list":
            var filter = HistoryStore.Filter()
            filter.query = body["query"] as? String ?? ""
            filter.host = (body["host"] as? String).flatMap { $0.isEmpty ? nil : $0.lowercased() }
            filter.start = Self.date(body["start"])
            filter.end = Self.date(body["end"])
            let offset = (body["offset"] as? NSNumber)?.intValue ?? 0
            let limit = min(500, (body["limit"] as? NSNumber)?.intValue ?? 200)
            let page = HistoryStore.shared.browse(filter, offset: offset, limit: limit)
            replyHandler([
                "items": page.items.map { e -> [String: Any] in
                    [
                        "url": e.url.absoluteString,
                        "title": e.title,
                        "host": e.url.displayHost,
                        "iconHost": e.url.host(percentEncoded: false)?.lowercased() ?? "",
                        "time": e.lastVisit.timeIntervalSince1970 * 1000,
                        "visits": e.visits,
                    ]
                },
                "total": page.total,
                "saving": AppSettings.shared.privacy.saveHistory,
            ], nil)

        case "history.overview":
            var ranges: [String: (start: Date, end: Date)] = [:]
            for (name, value) in body["ranges"] as? [String: [NSNumber]] ?? [:] where value.count == 2 {
                ranges[name] = (Date(timeIntervalSince1970: value[0].doubleValue / 1000), Date(timeIntervalSince1970: value[1].doubleValue / 1000))
            }
            let limit = min(200, (body["sites"] as? NSNumber)?.intValue ?? 12)
            let overview = HistoryStore.shared.overview(ranges: ranges, siteLimit: limit)
            replyHandler([
                "total": overview.total,
                "counts": overview.counts,
                "sites": overview.sites.map { ["host": $0.host, "pages": $0.pages, "visits": $0.visits] },
                "saving": AppSettings.shared.privacy.saveHistory,
            ], nil)

        case "history.delete":
            let urls = (body["urls"] as? [String] ?? []).compactMap(URL.init(string:))
            HistoryStore.shared.delete(urls)
            replyHandler(true, nil)

        case "history.deleteRange":
            guard let start = (body["start"] as? NSNumber)?.doubleValue,
                  let end = (body["end"] as? NSNumber)?.doubleValue else {
                replyHandler(false, nil)
                return
            }
            let label = body["label"] as? String ?? "this day"
            let when = ["today", "yesterday"].contains(label.lowercased()) ? label.lowercased() : "on \(label)"
            confirm(Prompt(
                symbol: "calendar.badge.minus",
                title: "Remove \(label)’s history?",
                message: "Every page you visited \(when) is removed from your history. This can’t be undone.",
                confirmTitle: "Remove",
                destructive: true
            )) {
                HistoryStore.shared.deleteRange(startTime: start, endTime: end)
            }

        case "history.deleteHost":
            guard let host = (body["host"] as? String)?.lowercased(), !host.isEmpty else {
                replyHandler(false, nil)
                return
            }
            let count = HistoryStore.shared.browse(HistoryStore.Filter(host: host), offset: 0, limit: 0).total
            confirm(Prompt(
                symbol: "globe",
                title: "Remove \(host) from history?",
                subtitle: count == 1 ? "1 page" : "\(count.formatted()) pages",
                message: "Every page you visited on \(host) is removed from your history. This can’t be undone.",
                confirmTitle: "Remove",
                destructive: true
            )) {
                HistoryStore.shared.deleteHost(host)
            }

        case "history.clear":
            confirm(Prompt(
                symbol: "clock.badge.xmark",
                title: "Clear all history?",
                message: "Every page in your history is removed, along with recently closed tabs. Your open tabs stay. This can’t be undone.",
                confirmTitle: "Clear History",
                destructive: true
            )) {
                HistoryStore.shared.clear()
                BrowserState.shared.forgetClosedTabs()
            }

        case "import":
            AppDelegate.shared?.showSettings(tab: .importData)
            replyHandler(true, nil)

        case "settings":
            AppDelegate.shared?.showSettings(tab: .privacy)
            replyHandler(true, nil)

        default:
            replyHandler(nil, "Unknown command")
        }
    }
}

// MARK: - History page

/// The page at tuff://history: a sidebar of time ranges and most-visited sites, and everything
/// in `HistoryStore` newest first, grouped by day, with search and delete.
private enum HistoryPage {
    static func html() -> String {
        // The page takes the accent of the space in front, like the rest of the chrome.
        let accent = BrowserState.active.baseTint.derivedAccent.hexString
        return template.replacingOccurrences(of: "__ACCENT__", with: accent)
    }

    private static let template = #"""
    <!doctype html>
    <html lang="en"><head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>History</title>
    <style>
      :root {
        color-scheme: light dark;
        --accent: __ACCENT__;
        --fg: #1d1d1f; --dim: rgba(0,0,0,.52); --faint: rgba(0,0,0,.34);
        --bg: #f6f5f3; --side: #efeeeb; --plate: rgba(0,0,0,.035); --hover: rgba(0,0,0,.055); --line: rgba(0,0,0,.07);
        --field: rgba(0,0,0,.055); --sel: color-mix(in srgb, var(--accent) 20%, transparent);
        --danger: #d93d42;
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --fg: #f2f2f4; --dim: rgba(255,255,255,.55); --faint: rgba(255,255,255,.32);
          --bg: #1b1b1e; --side: #161619; --plate: rgba(255,255,255,.04); --hover: rgba(255,255,255,.065); --line: rgba(255,255,255,.075);
          --field: rgba(255,255,255,.07); --sel: color-mix(in srgb, var(--accent) 30%, transparent);
          --danger: #ff6369;
        }
      }
      * { box-sizing: border-box; }
      html { background: var(--bg); }
      body { margin: 0; font: 13px -apple-system, system-ui, sans-serif; color: var(--fg); -webkit-font-smoothing: antialiased; }
      button { font: inherit; color: inherit; border: 0; background: none; cursor: default; }
      svg { flex: none; }

      .app { display: grid; grid-template-columns: 248px minmax(0, 1fr); min-height: 100vh; }

      /* Sidebar */
      aside { position: sticky; top: 0; height: 100vh; overflow-y: auto; background: var(--side);
              border-right: .5px solid var(--line); padding: 26px 12px 14px; display: flex; flex-direction: column; gap: 2px; }
      aside::-webkit-scrollbar { width: 0; }
      .brand { display: flex; align-items: center; gap: 9px; font: 650 17px ui-rounded, -apple-system, system-ui;
               padding: 0 10px 16px; letter-spacing: -.01em; }
      .brand .mark { width: 28px; height: 28px; border-radius: 8px; display: grid; place-items: center;
                     background: var(--sel); color: var(--accent); }
      aside h3 { font: 600 10.5px -apple-system, system-ui; letter-spacing: .04em; text-transform: uppercase;
                 color: var(--faint); margin: 16px 10px 5px; }
      .item { display: flex; align-items: center; gap: 9px; width: 100%; height: 30px; padding: 0 10px; border-radius: 8px;
              text-align: left; font-weight: 500; color: var(--fg); transition: background .12s; }
      .item:hover { background: var(--hover); }
      .item.sel { background: var(--sel); }
      .item .ic { width: 16px; height: 16px; display: grid; place-items: center; color: var(--dim); }
      .item.sel .ic { color: var(--accent); }
      .item .label { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .item .n { color: var(--faint); font-size: 11.5px; font-variant-numeric: tabular-nums; }
      .item .icon, .item .letter { width: 16px; height: 16px; }
      .item.small { height: 26px; font-size: 12px; color: var(--dim); }
      .item.danger { color: var(--danger); }
      .item.danger .ic { color: var(--danger); }
      .spacer { flex: 1; min-height: 16px; }
      .foot { border-top: .5px solid var(--line); padding-top: 8px; display: flex; flex-direction: column; gap: 2px; }

      /* Main column */
      main { max-width: 860px; width: 100%; margin: 0 auto; padding: 30px 32px 80px; }
      header { display: flex; align-items: center; gap: 12px; min-height: 36px; margin-bottom: 12px; }
      header .titles { flex: 1; min-width: 0; display: flex; align-items: center; gap: 10px; }
      header .site-icon { width: 24px; height: 24px; border-radius: 6px; }
      header .site-icon.letter { font-size: 12px; }
      h1 { font: 650 24px ui-rounded, -apple-system, system-ui; letter-spacing: -.01em; margin: 0;
           overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .count { color: var(--faint); font-size: 12.5px; white-space: nowrap; padding-top: 5px; }
      .pill { font-weight: 600; font-size: 12px; height: 28px; padding: 0 12px; border-radius: 8px; background: var(--field);
              transition: background .12s, transform .12s; white-space: nowrap; }
      .pill:hover { background: var(--hover); }
      .pill:active { transform: scale(.96); }
      .pill.danger { color: var(--danger); }
      .search { position: sticky; top: 0; z-index: 3; background: var(--bg); padding: 6px 0 12px; }
      .search label { display: flex; align-items: center; gap: 8px; height: 36px; padding: 0 12px; border-radius: 11px;
                      background: var(--field); outline: 2px solid transparent; transition: outline-color .12s; }
      .search label:focus-within { outline-color: color-mix(in srgb, var(--accent) 70%, transparent); }
      .search svg { opacity: .5; }
      .search input { flex: 1; border: 0; outline: 0; background: none; font: 500 14px -apple-system, system-ui; color: inherit; }
      .search kbd { font: 600 11px -apple-system, system-ui; color: var(--faint); border: 1px solid var(--line);
                    border-radius: 5px; padding: 1px 6px; }
      section { margin-bottom: 22px; }
      .day { display: flex; align-items: baseline; justify-content: space-between; position: sticky; top: 54px; z-index: 2;
             background: var(--bg); padding: 8px 6px 6px; }
      .day h2 { font: 650 13px -apple-system, system-ui; margin: 0; }
      .day button { height: 22px; font-size: 11.5px; font-weight: 600; padding: 0 9px; border-radius: 6px; color: var(--dim); opacity: 0; }
      .day:hover button { opacity: 1; }
      .day button:hover { background: var(--field); color: var(--danger); }
      .list { background: var(--plate); border: .5px solid var(--line); border-radius: 13px; padding: 4px; }
      a.row { display: grid; grid-template-columns: 62px 18px minmax(0, 1fr) auto 24px; align-items: center; gap: 10px;
              height: 38px; padding: 0 6px 0 10px; border-radius: 9px; color: inherit; text-decoration: none; }
      a.row:hover, a.row.sel { background: var(--hover); }
      a.row.sel { outline: 2px solid color-mix(in srgb, var(--accent) 60%, transparent); outline-offset: -2px; }
      .time { color: var(--faint); font-size: 12px; font-variant-numeric: tabular-nums; white-space: nowrap; }
      .icon { width: 16px; height: 16px; border-radius: 4px; object-fit: contain; }
      .letter { width: 16px; height: 16px; border-radius: 4px; display: grid; place-items: center; font: 700 9.5px -apple-system;
                color: #fff; background: color-mix(in srgb, var(--accent) 80%, #777); text-transform: uppercase; }
      .title { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 500; }
      .host { color: var(--dim); font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 220px;
              border-radius: 5px; padding: 1px 4px; }
      .host:hover { background: var(--field); color: var(--fg); }
      .del { width: 22px; height: 22px; padding: 0; border-radius: 6px; display: grid; place-items: center; color: var(--dim); opacity: 0; }
      a.row:hover .del, a.row.sel .del { opacity: 1; }
      .del:hover { background: var(--field); color: var(--danger); }
      mark { background: color-mix(in srgb, var(--accent) 30%, transparent); color: inherit; border-radius: 3px; }
      .empty { text-align: center; padding: 80px 20px; color: var(--dim); }
      .empty h3 { font: 650 17px -apple-system, system-ui; color: var(--fg); margin: 14px 0 6px; }
      .empty p { margin: 0 auto 16px; max-width: 380px; line-height: 1.5; }
      .empty .pill { background: var(--accent); color: #fff; }
      #more { height: 1px; }

      @media (max-width: 760px) {
        .app { grid-template-columns: minmax(0, 1fr); }
        aside { display: none; }
        main { padding: 24px 18px 60px; }
      }
    </style>
    </head>
    <body>
    <div class="app">
      <aside>
        <div class="brand">
          <span class="mark"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg></span>
          History
        </div>
        <nav id="ranges"></nav>
        <h3 id="sitesHeading">Most Visited</h3>
        <nav id="sites"></nav>
        <button class="item small" id="moreSites" hidden><span class="ic"></span><span class="label">Show More</span></button>
        <div class="spacer"></div>
        <div class="foot">
          <button class="item" id="import"><span class="ic"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12m0 0-4-4m4 4 4-4"/><path d="M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2"/></svg></span><span class="label">Import from Browser…</span></button>
          <button class="item" id="settings"><span class="ic"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3 4 6v6c0 4.5 3.4 8.2 8 9 4.6-.8 8-4.5 8-9V6z"/></svg></span><span class="label">History Settings</span></button>
          <button class="item danger" id="clear"><span class="ic"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M10 11v6M14 11v6M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12M9 7V4h6v3"/></svg></span><span class="label">Clear History…</span></button>
        </div>
      </aside>
      <main>
        <header>
          <div class="titles" id="titles"><h1 id="heading">All History</h1><span class="count" id="count"></span></div>
          <button class="pill danger" id="removeScope" hidden></button>
        </header>
        <div class="search">
          <label>
            <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="7" cy="7" r="5"/><path d="m11 11 3.5 3.5"/></svg>
            <input id="q" type="search" placeholder="Search history" autocomplete="off" spellcheck="false" autofocus>
            <kbd>/</kbd>
          </label>
        </div>
        <div id="days"></div>
        <div id="more"></div>
      </main>
    </div>
    <script>
    (() => {
      const handler = () => window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tuff;
      const wait = (ms) => new Promise((r) => setTimeout(r, ms));
      // Asks the app, retrying a few times: right after launch the app can still be busy.
      async function send(cmd, args = {}, tries = 5) {
        for (let i = 0; ; i++) {
          try {
            const h = handler();
            if (!h) throw new Error('Tuff isn’t answering.');
            return await h.postMessage({ cmd, ...args });
          } catch (e) {
            if (i >= tries) throw e;
            await wait(150 * (i + 1));
          }
        }
      }
      const $ = (id) => document.getElementById(id);
      const days = $('days'), q = $('q'), count = $('count'), heading = $('heading');
      const PAGE = 200, SITES = 12;
      const DAY = 86400000;

      let offset = 0, total = 0, loading = false, generation = 0, saving = true, sel = -1;
      let query = '';
      let scope = { kind: 'range', id: 'all' };   // or { kind: 'site', host }
      let siteLimit = SITES;

      const startOfDay = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
      const dayKey = (d) => d.getFullYear() + '-' + d.getMonth() + '-' + d.getDate();
      const dayLabel = (d) => {
        const diff = Math.round((startOfDay(new Date()) - startOfDay(d)) / DAY);
        if (diff === 0) return 'Today';
        if (diff === 1) return 'Yesterday';
        const opts = { weekday: 'long', month: 'long', day: 'numeric' };
        if (d.getFullYear() !== new Date().getFullYear()) opts.year = 'numeric';
        return d.toLocaleDateString(undefined, opts);
      };
      const timeFmt = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' });

      const icons = {
        all: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
        today: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
        yesterday: '<path d="M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z"/>',
        week: '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/>',
        month: '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4M7.5 14h.01M12 14h.01M16.5 14h.01M7.5 17.5h.01M12 17.5h.01"/>',
        older: '<rect x="3" y="4" width="18" height="5" rx="1.5"/><path d="M5 9v9a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V9M10 13h4"/>',
      };
      const svg = (path) => `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${path}</svg>`;

      // Time ranges, worked out from local midnight each time they are used.
      function ranges() {
        const today = startOfDay(new Date());
        const far = Date.now() + 365 * DAY;
        return {
          all: { label: 'All History', start: null, end: null },
          today: { label: 'Today', start: today, end: far },
          yesterday: { label: 'Yesterday', start: today - DAY, end: today - 1 },
          week: { label: 'Last 7 Days', start: today - 6 * DAY, end: far },
          month: { label: 'Last 30 Days', start: today - 29 * DAY, end: far },
          older: { label: 'Older', start: 0, end: today - 30 * DAY - 1 },
        };
      }

      function el(tag, cls, text) {
        const e = document.createElement(tag);
        if (cls) e.className = cls;
        if (text != null) e.textContent = text;
        return e;
      }

      // The site's icon from Tuff's favicon cache (which also tries the host with and without
      // "www."), else its first letter.
      function favicon(host, cls = 'icon') {
        const letter = (host || '?').replace(/^www\./, '').charAt(0);
        if (!host) return el('span', 'letter ' + (cls === 'icon' ? '' : cls), letter);
        const img = el('img', cls);
        img.alt = '';
        img.loading = 'lazy';
        img.onerror = () => img.replaceWith(el('span', 'letter ' + (cls === 'icon' ? '' : cls), letter));
        img.src = 'tuff://favicon?host=' + encodeURIComponent(host);
        return img;
      }

      // Highlights the words being searched for, without ever putting page text into HTML.
      function highlight(target, text) {
        const words = query.toLowerCase().split(/\s+/).filter(Boolean);
        if (!words.length) { target.textContent = text; return; }
        const lower = text.toLowerCase();
        const marks = new Array(text.length).fill(false);
        for (const w of words) {
          let i = lower.indexOf(w);
          while (i !== -1) { for (let k = i; k < i + w.length; k++) marks[k] = true; i = lower.indexOf(w, i + w.length); }
        }
        let i = 0;
        while (i < text.length) {
          let j = i;
          while (j < text.length && marks[j] === marks[i]) j++;
          const part = text.slice(i, j);
          target.append(marks[i] ? el('mark', null, part) : document.createTextNode(part));
          i = j;
        }
      }

      // MARK: Sidebar

      function sidebarItem(iconHTML, label, n, selected, onclick) {
        const b = el('button', 'item' + (selected ? ' sel' : ''));
        const ic = el('span', 'ic');
        if (typeof iconHTML === 'string') ic.innerHTML = iconHTML; else ic.append(iconHTML);
        b.append(ic, el('span', 'label', label));
        if (n != null) b.append(el('span', 'n', n.toLocaleString()));
        b.onclick = onclick;
        return b;
      }

      async function refreshSidebar() {
        const r = ranges();
        const payload = {};
        for (const [id, v] of Object.entries(r)) if (id !== 'all') payload[id] = [v.start, v.end];
        let o;
        try { o = await send('history.overview', { ranges: payload, sites: siteLimit + 1 }); } catch { return; }
        const nav = $('ranges');
        nav.textContent = '';
        for (const [id, v] of Object.entries(r)) {
          const n = id === 'all' ? o.total : (o.counts[id] || 0);
          if (id !== 'all' && n === 0 && !(scope.kind === 'range' && scope.id === id)) continue;
          nav.append(sidebarItem(svg(icons[id]), v.label, n, scope.kind === 'range' && scope.id === id, () => setScope({ kind: 'range', id })));
        }
        const sites = $('sites');
        sites.textContent = '';
        const shown = o.sites.slice(0, siteLimit);
        $('sitesHeading').hidden = shown.length === 0;
        for (const s of shown) {
          const selected = scope.kind === 'site' && scope.host === s.host;
          sites.append(sidebarItem(favicon(s.host), s.host, s.pages, selected, () => setScope({ kind: 'site', host: s.host })));
        }
        const more = $('moreSites');
        more.hidden = o.sites.length <= siteLimit && siteLimit === SITES;
        more.querySelector('.label').textContent = o.sites.length > siteLimit ? 'Show More' : 'Show Less';
      }

      $('moreSites').onclick = () => {
        siteLimit = $('moreSites').querySelector('.label').textContent === 'Show More' ? siteLimit + 24 : SITES;
        refreshSidebar();
      };

      function setScope(next) {
        scope = next;
        refreshSidebar();
        reload();
        scrollTo({ top: 0 });
      }

      function scopeFilter() {
        if (scope.kind === 'site') return { host: scope.host };
        const r = ranges()[scope.id];
        return r.start == null ? {} : { start: r.start, end: r.end };
      }

      function updateHeader() {
        const titles = $('titles');
        titles.querySelector('.site-icon')?.remove();
        const remove = $('removeScope');
        if (scope.kind === 'site') {
          heading.textContent = scope.host;
          titles.prepend(favicon(scope.host, 'site-icon'));
          remove.textContent = 'Remove Site…';
          remove.hidden = total === 0;
        } else {
          heading.textContent = ranges()[scope.id].label;
          remove.textContent = 'Clear History…';
          remove.hidden = scope.id !== 'all' || total === 0;
        }
        if (!total) { count.textContent = ''; return; }
        const n = total.toLocaleString();
        count.textContent = query ? `${n} ${total === 1 ? 'match' : 'matches'}` : `${n} ${total === 1 ? 'page' : 'pages'}`;
      }

      $('removeScope').onclick = async () => {
        const ok = scope.kind === 'site' ? await send('history.deleteHost', { host: scope.host }, 0) : await send('history.clear', {}, 0);
        if (!ok) return;
        if (scope.kind === 'site') scope = { kind: 'range', id: 'all' };
        refreshSidebar(); reload();
      };

      // MARK: List

      function section(date) {
        const key = dayKey(date);
        let s = days.querySelector(`section[data-day="${key}"]`);
        if (s) return s.querySelector('.list');
        s = el('section'); s.dataset.day = key;
        const head = el('div', 'day');
        head.append(el('h2', null, dayLabel(date)));
        if (scope.kind === 'range') {
          const remove = el('button', null, 'Remove Day');
          const start = startOfDay(date);
          remove.onclick = async () => {
            const ok = await send('history.deleteRange', { start, end: start + DAY - 1, label: dayLabel(date) }, 0);
            if (ok) { refreshSidebar(); reload(); }
          };
          head.append(remove);
        }
        s.append(head, el('div', 'list'));
        days.append(s);
        return s.querySelector('.list');
      }

      function row(item) {
        const date = new Date(item.time);
        const a = el('a', 'row');
        a.href = item.url;
        a.title = item.url;
        a.append(el('span', 'time', timeFmt.format(date)));
        a.append(favicon(item.iconHost || item.host));
        const title = el('span', 'title');
        highlight(title, item.title || item.host || item.url);
        a.append(title);
        const host = el('span', 'host');
        highlight(host, item.host);
        host.title = 'Show everything from ' + item.host;
        host.onclick = (e) => { e.preventDefault(); e.stopPropagation(); setScope({ kind: 'site', host: item.host.toLowerCase() }); };
        a.append(host);
        const del = el('button', 'del');
        del.title = 'Remove from History';
        del.innerHTML = '<svg width="10" height="10" viewBox="0 0 10 10" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M1.5 1.5l7 7M8.5 1.5l-7 7"/></svg>';
        del.onclick = (e) => { e.preventDefault(); e.stopPropagation(); remove(a, item); };
        a.append(del);
        a._item = item;
        section(date).append(a);
      }

      async function remove(a, item) {
        await send('history.delete', { urls: [item.url] }, 0);
        const list = a.parentElement;
        a.remove();
        if (!list.children.length) list.parentElement.remove();
        total = Math.max(0, total - 1); offset = Math.max(0, offset - 1);
        updateHeader();
        refreshSidebar();
        const rows = allRows();
        if (sel >= rows.length) sel = rows.length - 1;
        select(sel);
        if (!total) empty();
      }

      function empty() {
        days.textContent = '';
        const box = el('div', 'empty');
        box.innerHTML = svg('<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>').replace('width="15" height="15"', 'width="44" height="44" opacity=".45"');
        const button = (label, action) => { const b = el('button', 'pill', label); b.onclick = action; box.append(b); };
        if (query) {
          box.append(el('h3', null, 'No matches'), el('p', null, `Nothing here matches “${query}”.`));
        } else if (!saving) {
          box.append(el('h3', null, 'History is off'), el('p', null, 'Tuff isn’t saving the pages you visit. You can turn it on in Settings › Privacy & Security.'));
          button('Open Privacy Settings', () => send('settings'));
        } else if (scope.kind === 'range' && scope.id !== 'all') {
          box.append(el('h3', null, 'Nothing here'), el('p', null, `You didn’t visit any pages ${ranges()[scope.id].label === 'Older' ? 'before the last 30 days' : 'in this time'}.`));
        } else {
          box.append(el('h3', null, 'No history yet'), el('p', null, 'Pages you visit show up here. Coming from another browser? Bring your history with you.'));
          button('Import from Another Browser…', () => send('import'));
        }
        days.append(box);
      }

      function failed(error) {
        days.textContent = '';
        const box = el('div', 'empty');
        box.append(el('h3', null, 'Couldn’t load your history'), el('p', null, String(error && error.message || error)));
        const b = el('button', 'pill', 'Try Again'); b.onclick = () => { refreshSidebar(); reload(); };
        box.append(b);
        days.append(box);
      }

      async function load() {
        if (loading || (offset > 0 && offset >= total)) return;
        loading = true;
        const mine = generation;
        try {
          const res = await send('history.list', { query, offset, limit: PAGE, ...scopeFilter() });
          if (mine !== generation) return;
          total = res.total; saving = res.saving;
          res.items.forEach(row);
          offset += res.items.length;
          updateHeader();
          if (!total) empty();
        } catch (e) {
          if (mine === generation) failed(e);
          return;
        } finally {
          if (mine === generation) loading = false;
        }
        // Keep filling until the page can scroll.
        if (mine === generation && offset < total && document.documentElement.scrollHeight <= innerHeight + 200) load();
      }

      function reload() {
        generation++;
        loading = false; offset = 0; total = 0; sel = -1;
        days.textContent = '';
        load();
      }

      new IntersectionObserver((e) => { if (e[0].isIntersecting) load(); }, { rootMargin: '600px' }).observe($('more'));

      let timer;
      q.addEventListener('input', () => {
        clearTimeout(timer);
        timer = setTimeout(() => { query = q.value.trim(); reload(); }, 120);
      });

      $('clear').onclick = async () => { if (await send('history.clear', {}, 0)) { scope = { kind: 'range', id: 'all' }; refreshSidebar(); reload(); } };
      $('import').onclick = () => send('import');
      $('settings').onclick = () => send('settings');

      // Keyboard: / to search, ↑ ↓ to move, ↩ to open, ⌫ to remove.
      const allRows = () => Array.from(days.querySelectorAll('a.row'));
      function select(i) {
        const rows = allRows();
        rows.forEach((r) => r.classList.remove('sel'));
        sel = Math.max(-1, Math.min(i, rows.length - 1));
        if (sel >= 0) rows[sel].classList.add('sel'), rows[sel].scrollIntoView({ block: 'nearest' });
      }
      document.addEventListener('keydown', (e) => {
        const inField = document.activeElement === q;
        if (e.key === '/' && !inField) { e.preventDefault(); q.focus(); q.select(); return; }
        if (e.key === 'Escape' && inField) { if (q.value) { q.value = ''; query = ''; reload(); } else q.blur(); return; }
        if (e.key === 'ArrowDown') { e.preventDefault(); if (inField) q.blur(); select(sel + 1); if (sel >= allRows().length - 3) load(); return; }
        if (e.key === 'ArrowUp') { e.preventDefault(); if (sel <= 0) { select(-1); q.focus(); } else select(sel - 1); return; }
        const rows = allRows();
        if (sel < 0 || !rows[sel]) return;
        if (e.key === 'Enter') { e.preventDefault(); rows[sel].click(); }
        if ((e.key === 'Backspace' || e.key === 'Delete') && !inField) { e.preventDefault(); remove(rows[sel], rows[sel]._item); }
      });

      // Coming back to the tab (or Back from a page) shows what's new since.
      addEventListener('pageshow', (e) => { if (e.persisted) { refreshSidebar(); reload(); } });
      document.addEventListener('visibilitychange', () => {
        if (document.hidden) return;
        refreshSidebar();
        if (!q.value && scrollY < 200) reload();
      });

      refreshSidebar();
      load();
    })();
    </script>
    </body></html>
    """#
}

/// The View Source page: the HTML as text, with line numbers, wrapping long lines.
enum SourcePage {
    static func html(for url: URL?, text: String) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let lines = text.components(separatedBy: "\n").map { "<span>\(escape($0))</span>" }.joined(separator: "\n")
        let title = url.map { "Source of " + escape($0.displayHost + $0.path) } ?? "Page Source"
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title>
        <style>
          :root { color-scheme: light dark; }
          body { margin: 0; background: Canvas; color: CanvasText; }
          header { position: sticky; top: 0; padding: 10px 16px; font: 600 13px -apple-system, system-ui;
                   background: color-mix(in srgb, Canvas 92%, CanvasText); border-bottom: 1px solid color-mix(in srgb, CanvasText 12%, transparent);
                   white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
          pre { margin: 0; padding: 12px 0; font: 12px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace;
                counter-reset: line; white-space: pre-wrap; word-break: break-all; }
          pre span { display: block; padding: 0 16px 0 64px; position: relative; }
          pre span::before { counter-increment: line; content: counter(line); position: absolute; left: 0; width: 48px;
                             text-align: right; opacity: .38; user-select: none; }
        </style></head>
        <body><header>\(url.map { escape($0.absoluteString) } ?? "Page Source")</header><pre>\(lines)</pre></body></html>
        """
    }
}

/// View Source's fetch accepts the certificates the user chose to trust (`CertificateExceptions`).
private final class SourceFetchTrust: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust,
           CertificateExceptions.shared.allows(trust, host: space.host, port: space.port) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
