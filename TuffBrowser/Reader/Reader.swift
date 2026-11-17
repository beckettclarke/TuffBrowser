import AppKit
import Observation
import SwiftUI
import WebKit

/// Reader mode: the page's article, pulled out of the clutter and shown in Tuff's own type.
///
/// 1. `ReaderScript.extract` runs in the page (in an isolated content world, so the page's own
///    scripts can't interfere) and finds the main article by scoring its paragraphs, much as
///    Safari's and Firefox's readers do. It hands back cleaned-up HTML plus the title, byline,
///    site name and date.
/// 2. A `Reader` shows that in a second web view of its own, laid over the page the way the PDF
///    viewer is. That web view runs no JavaScript and its content-security policy lets in
///    nothing but images, video and inline styles. The page underneath is left exactly as it
///    was, so leaving reader mode is instant and loses nothing.
/// 3. Any navigation in the page (a link, Back, a reload, a single-page app moving on) ends it.
@Observable
final class Reader: NSObject {
    let article: ReaderArticle
    /// The page the article came from (the reader web view's base URL).
    let url: URL
    @ObservationIgnored weak var tab: Tab?
    @ObservationIgnored let view: ReaderWebView

    init(article: ReaderArticle, url: URL, tab: Tab, dataStore: WKWebsiteDataStore) {
        self.article = article
        self.url = url
        self.tab = tab

        let config = WKWebViewConfiguration()
        // Same store as the page: images load with its cookies, and Incognito stays off disk.
        config.websiteDataStore = dataStore
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.isElementFullscreenEnabled = false
        if config.preferences.responds(to: NSSelectorFromString("_setShouldAllowUserInstalledFonts:")) {
            config.preferences.setValue(false, forKey: "shouldAllowUserInstalledFonts")
        }
        if config.preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) {
            config.preferences.setValue(AppSettings.shared.advanced.webInspector, forKey: "developerExtrasEnabled")
        }
        view = ReaderWebView(frame: .zero, configuration: config)
        super.init()
        view.reader = self
        view.navigationDelegate = self
        view.allowsMagnification = false
        view.allowsBackForwardNavigationGestures = false
        view.loadHTMLString(ReaderPage.html(for: article, prefs: ReaderSettings.shared.prefs), baseURL: url)
    }

    /// Puts a change of theme, font or size into the page without reloading it.
    func apply(_ prefs: ReaderPreferences) {
        let js = """
        (() => { const r = document.documentElement;
          r.dataset.theme = '\(prefs.theme.rawValue)'; r.dataset.font = '\(prefs.font.rawValue)';
          r.style.setProperty('--size', '\(prefs.size)px'); })()
        """
        view.evaluateJavaScript(js, completionHandler: nil)
    }

    func close() {
        view.navigationDelegate = nil
        view.reader = nil
        view.stopLoading()
        view.removeFromSuperview()
    }
}

extension Reader: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard action.navigationType == .linkActivated, let target = action.request.url else {
            // The article itself (`loadHTMLString`); with scripts off nothing else navigates.
            decisionHandler(action.targetFrame?.isMainFrame == true ? .allow : .cancel)
            return
        }
        // A footnote or a heading further down the article.
        if target.fragment != nil, Self.withoutFragment(target) == Self.withoutFragment(url) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        guard let tab, let browser = tab.browser else { return }
        if action.modifierFlags.contains(.command) || action.buttonNumber == 4 {
            let foreground = AppSettings.shared.tabs.foregroundLinks != action.modifierFlags.contains(.shift)
            browser.newTab(url: target, select: foreground, after: tab)
        } else {
            tab.closeReader()
            tab.load(target)
        }
    }

    private static func withoutFragment(_ url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        return parts?.string ?? url.absoluteString
    }
}

/// The reader's web view. Esc leaves reader mode.
final class ReaderWebView: WKWebView {
    weak var reader: Reader?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
           let tab = reader?.tab {
            tab.closeReader()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Tab

extension Tab {
    /// The page is something reader mode can try (a web page or file, not a PDF or a Tuff page).
    var canUseReader: Bool {
        guard isAwake, webView != nil, pdf == nil, !isExtensionPage, let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "file"
    }

    func toggleReader() {
        if reader != nil { closeReader() } else { openReader() }
    }

    func openReader() {
        guard reader == nil, canUseReader, let webView, let url = webView.url ?? url else { return }
        webView.callAsyncJavaScript(ReaderScript.extract, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            // Still on that page (a script tidying its address with replaceState doesn't count).
            guard let self, self.webView === webView, self.reader == nil,
                  let now = webView.url, Self.samePage(now, url) else { return }
            guard case .success(let value) = result, let article = ReaderArticle(value) else {
                self.browser?.show(Toast(symbol: "doc.plaintext", text: "Reader mode isn’t available for this page"))
                return
            }
            let reader = Reader(article: article, url: now, tab: self, dataStore: webView.configuration.websiteDataStore)
            withAnimation(Motion.quick) { self.reader = reader }
            self.browser?.tabDidChange(self, properties: .readerMode)
            self.browser?.focusWebView()
        }
    }

    /// Back to the page. `focus`: hand the keyboard back to it (not when the tab is going to sleep).
    func closeReader(focus: Bool = true) {
        guard let reader else { return }
        reader.close()
        withAnimation(Motion.quick) { self.reader = nil }
        browser?.tabDidChange(self, properties: .readerMode)
        if focus, browser?.selectedTab === self { browser?.focusWebView() }
    }
}

// MARK: - Article

struct ReaderArticle {
    var title: String
    var byline: String
    var siteName: String
    var published: String
    var html: String
    var lang: String
    var dir: String
    var minutes: Int

    init?(_ value: Any?) {
        guard let dict = value as? [String: Any], let html = dict["html"] as? String, !html.isEmpty else { return nil }
        self.html = html
        title = dict["title"] as? String ?? ""
        byline = dict["byline"] as? String ?? ""
        siteName = dict["siteName"] as? String ?? ""
        published = dict["published"] as? String ?? ""
        lang = dict["lang"] as? String ?? ""
        dir = dict["dir"] as? String ?? ""
        minutes = (dict["minutes"] as? NSNumber)?.intValue ?? 1
    }
}

// MARK: - Preferences

enum ReaderTheme: String, Codable, CaseIterable, Identifiable {
    case auto, light, sepia, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Match System"
        case .light: "Light"
        case .sepia: "Sepia"
        case .dark: "Dark"
        }
    }

    /// Whether the page is dark, given the system's appearance (for `auto`).
    func isDark(systemDark: Bool) -> Bool {
        switch self {
        case .auto: systemDark
        case .light, .sepia: false
        case .dark: true
        }
    }

    /// The page colour (kept in step with `ReaderPage.css`).
    func background(systemDark: Bool) -> Color {
        switch self {
        case .auto: systemDark ? ReaderTheme.dark.background(systemDark: true) : ReaderTheme.light.background(systemDark: false)
        case .light: Color(red: 0.984, green: 0.980, blue: 0.973)
        case .sepia: Color(red: 0.957, green: 0.925, blue: 0.863)
        case .dark: Color(red: 0.110, green: 0.110, blue: 0.118)
        }
    }
}

enum ReaderFont: String, Codable, CaseIterable, Identifiable {
    case serif, sans
    var id: String { rawValue }
    var label: String { self == .serif ? "Serif" : "Sans Serif" }
}

struct ReaderPreferences: Codable, Equatable {
    static let sizes = [13, 14, 15, 16, 17, 18, 20, 22, 24, 27, 30, 34]
    static let defaultSizeIndex = 6

    var theme: ReaderTheme = .auto
    var font: ReaderFont = .serif
    var sizeIndex = ReaderPreferences.defaultSizeIndex

    var size: Int { Self.sizes[min(max(sizeIndex, 0), Self.sizes.count - 1)] }
    var canGrow: Bool { sizeIndex < Self.sizes.count - 1 }
    var canShrink: Bool { sizeIndex > 0 }
}

/// How the reader looks, shared by every tab and kept between launches.
@Observable
final class ReaderSettings {
    static let shared = ReaderSettings()
    private static let key = "readerPreferences"

    var prefs: ReaderPreferences {
        didSet {
            guard prefs != oldValue, let data = try? JSONEncoder().encode(prefs) else { return }
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private init() {
        prefs = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(ReaderPreferences.self, from: $0) } ?? ReaderPreferences()
    }

    func grow() { if prefs.canGrow { prefs.sizeIndex += 1 } }
    func shrink() { if prefs.canShrink { prefs.sizeIndex -= 1 } }
    func resetSize() { prefs.sizeIndex = ReaderPreferences.defaultSizeIndex }
}

// MARK: - Page

enum ReaderPage {
    static func html(for article: ReaderArticle, prefs: ReaderPreferences) -> String {
        var meta: [String] = []
        if !article.byline.isEmpty { meta.append(escape(article.byline)) }
        if !article.published.isEmpty { meta.append(escape(article.published)) }
        meta.append("\(article.minutes) min read")
        let lang = article.lang.isEmpty ? "" : " lang=\"\(escape(article.lang))\""
        let dir = article.dir.lowercased() == "rtl" ? " dir=\"rtl\"" : ""
        let site = article.siteName.isEmpty ? "" : "<p class=\"tuff-site\">\(escape(article.siteName))</p>"
        let title = article.title.isEmpty ? "" : "<h1 class=\"tuff-title\">\(escape(article.title))</h1>"
        return """
        <!doctype html>
        <html\(lang)\(dir) data-theme="\(prefs.theme.rawValue)" data-font="\(prefs.font.rawValue)" style="--size:\(prefs.size)px">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src * data: blob:; media-src *; style-src 'unsafe-inline'">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <title>\(escape(article.title))</title>
        <style>\(css)</style>
        </head>
        <body>
        <article>
        <header class="tuff-header">\(site)\(title)<p class="tuff-meta">\(meta.joined(separator: "<span class=\"tuff-dot\">·</span>"))</p></header>
        <div class="tuff-content">\(article.html)</div>
        </article>
        </body>
        </html>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let css = """
    :root {
      --bg: #fbfaf8; --fg: #1d1d1f; --muted: #6e6e73; --link: #0b63ce; --rule: rgba(0,0,0,.11); --tint: rgba(0,0,0,.045);
      --serif: ui-serif, "New York", "Iowan Old Style", Georgia, serif;
      --sans: system-ui, -apple-system, "Helvetica Neue", sans-serif;
      --size: 20px; color-scheme: light;
    }
    @media (prefers-color-scheme: dark) {
      :root[data-theme="auto"] { --bg: #1c1c1e; --fg: #e5e5e7; --muted: #98989f; --link: #6cb0ff; --rule: rgba(255,255,255,.14); --tint: rgba(255,255,255,.06); color-scheme: dark; }
    }
    :root[data-theme="sepia"] { --bg: #f4ecdc; --fg: #3b2f22; --muted: #85725c; --link: #9a4f12; --rule: rgba(80,50,20,.16); --tint: rgba(80,50,20,.06); }
    :root[data-theme="dark"] { --bg: #1c1c1e; --fg: #e5e5e7; --muted: #98989f; --link: #6cb0ff; --rule: rgba(255,255,255,.14); --tint: rgba(255,255,255,.06); color-scheme: dark; }
    html { background: var(--bg); color: var(--fg); font-size: var(--size); -webkit-text-size-adjust: none;
      transition: background-color .2s ease, color .2s ease; }
    body { margin: 0; padding: 64px 32px 140px; }
    article { max-width: 34em; margin: 0 auto; font-family: var(--serif); line-height: 1.62;
      text-rendering: optimizeLegibility; overflow-wrap: break-word; hyphens: auto; }
    :root[data-font="sans"] article { font-family: var(--sans); line-height: 1.58; }
    .tuff-header { margin-bottom: 2.2em; padding-bottom: 1.5em; border-bottom: 1px solid var(--rule); }
    .tuff-site { margin: 0 0 .7em; font: 600 .74em/1.3 var(--sans); color: var(--muted); }
    .tuff-title { margin: 0 0 .45em; font-size: 2em; line-height: 1.16; font-weight: 700; letter-spacing: -.012em; }
    .tuff-meta { margin: 0; font: 500 .78em/1.4 var(--sans); color: var(--muted); }
    .tuff-dot { margin: 0 .5em; opacity: .7; }
    .tuff-content > :first-child { margin-top: 0; }
    p, ul, ol, dl, blockquote, pre, figure, table { margin: 0 0 1.15em; }
    h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.7em 0 .55em; font-weight: 700; }
    h1 { font-size: 1.6em; } h2 { font-size: 1.36em; } h3 { font-size: 1.16em; } h4, h5, h6 { font-size: 1em; }
    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; text-underline-offset: .15em; }
    h1 a, h2 a, h3 a, h4 a, h5 a, h6 a { color: inherit; }
    summary { cursor: default; font-weight: 600; }
    img, video, svg, picture { max-width: 100%; height: auto; }
    img, video { display: block; margin: 1.5em auto; border-radius: 6px; }
    img[data-inline] { display: inline; height: 1.15em; width: auto; margin: 0; vertical-align: -.2em; border-radius: 0; }
    figure { margin: 1.6em 0; }
    figure img, figure video { margin-bottom: .6em; }
    figcaption, caption { font: .76em/1.45 var(--sans); color: var(--muted); text-align: center; }
    blockquote { margin-left: 0; padding: .1em 0 .1em 1.1em; border-left: 3px solid var(--rule); color: var(--muted); font-style: italic; }
    ul, ol { padding-left: 1.4em; } li { margin: .3em 0; }
    hr { border: 0; border-top: 1px solid var(--rule); margin: 2.2em 0; }
    code, kbd, samp { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: .84em; }
    :not(pre) > code { background: var(--tint); padding: .1em .32em; border-radius: 4px; }
    pre { background: var(--tint); padding: .9em 1.1em; border-radius: 8px; overflow-x: auto; line-height: 1.45; hyphens: none; }
    pre code { font-size: .8em; }
    table { border-collapse: collapse; display: block; overflow-x: auto; font: .8em/1.45 var(--sans); }
    th, td { border: 1px solid var(--rule); padding: .45em .7em; text-align: left; vertical-align: top; }
    th { background: var(--tint); }
    sup, sub { line-height: 0; }
    ::selection { background: color-mix(in srgb, var(--link) 28%, transparent); }
    @media print {
      :root, :root[data-theme] { --bg: #fff; --fg: #000; --muted: #555; --link: #000; }
      body { padding: 0; }
    }
    """
}

// MARK: - Extraction

enum ReaderScript {
    /// Finds the page's article. Runs as an async function body (`callAsyncJavaScript`) and
    /// returns `{title, byline, siteName, published, html, lang, dir, minutes}`, or null when the
    /// page doesn't have enough of an article to be worth showing.
    static let extract = #"""
    const doc = document, body = doc.body;
    // `debug` (a debug-build probe) says why nothing was found instead of returning null.
    const fail = (reason, extra) => (typeof debug !== 'undefined' && debug) ? { failed: reason, ...extra } : null;
    if (!body) return fail('no body');
    const UNLIKELY = /-ad-|ad-break|agegate|banner|breadcrumb|combx|comment|community|consent|cookie|cover-wrap|disqus|extra|footer|gdpr|header|legends|menu|newsletter|outbrain|pager|pagination|popup|promo|recirc|related|remark|replies|rss|share|shoutbox|sidebar|skyscraper|social|sponsor|subscribe|supplemental|taboola|trending|yom-remote/i;
    const MAYBE = /and|article|body|column|content|main|shadow|story|entry|post/i;
    const POSITIVE = /article|body|content|entry|hentry|h-entry|main|page|post|text|blog|story/i;
    const NEGATIVE = /-ad-|hidden|^hid$| hid$| hid |^hid |banner|combx|comment|com-|contact|foot|footer|footnote|gdpr|masthead|media|meta|outbrain|promo|related|scroll|share|shoutbox|sidebar|skyscraper|sponsor|shopping|tags|tool|widget/i;
    const CLEAN = /(^|[\s_-])ads?([\s_-]|$)|advert|banner|breadcrumb|byline|comment|consent|cookie|disqus|gdpr|newsletter|outbrain|paywall|popup|promo|recirc|related|share|sharing|signup|social|sponsor|subscribe|taboola|toolbar|trending|widget|more-stories|most-popular|read-?more/i;
    const BAD_ROLES = new Set(['menu', 'menubar', 'complementary', 'navigation', 'alert', 'alertdialog', 'dialog', 'banner', 'contentinfo']);
    const DIV_BLOCKS = 'blockquote,dl,div,img,ol,p,pre,table,ul,section,article,figure,h1,h2,h3,h4,h5,h6';

    const norm = s => (s || '').replace(/\s+/g, ' ').trim();
    const text = el => norm(el.textContent);
    const meta = sel => norm(doc.querySelector(sel)?.getAttribute('content'));
    const classOf = el => (el.getAttribute('class') || '') + ' ' + (el.id || '');
    const hidden = el => el.getClientRects().length === 0 && getComputedStyle(el).display !== 'contents';

    // First pass leaves out anything whose class looks like page furniture; if that leaves too
    // little (a whole page wrapped in "layout-with-sidebars"), a second pass goes by tags and roles only.
    let strict = true;
    const unlikelyCache = new Map();
    /// The element itself looks like page furniture (not counting its ancestors).
    const furniture = el => {
      const tag = el.localName, cls = classOf(el), role = el.getAttribute('role');
      if (['nav', 'aside', 'footer', 'form', 'dialog'].includes(tag)) return true;
      if (role && BAD_ROLES.has(role)) return true;
      return strict && tag !== 'article' && tag !== 'main' && role !== 'main' && UNLIKELY.test(cls) && !MAYBE.test(cls);
    };
    const unlikely = el => {
      if (!el || el === body || el === doc.documentElement) return false;
      if (unlikelyCache.has(el)) return unlikelyCache.get(el);
      const result = furniture(el) || unlikely(el.parentElement);
      unlikelyCache.set(el, result);
      return result;
    };

    const classWeight = el => {
      let w = 0;
      for (const s of [el.getAttribute('class'), el.id]) {
        if (!s) continue;
        if (NEGATIVE.test(s)) w -= 25;
        if (POSITIVE.test(s)) w += 25;
      }
      return w;
    };

    const linkDensity = el => {
      const len = text(el).length;
      if (!len) return 0;
      let links = 0;
      for (const a of el.querySelectorAll('a')) {
        const href = a.getAttribute('href') || '';
        links += text(a).length * (href.startsWith('#') ? 0.3 : 1);
      }
      return links / len;
    };

    const attempt = () => {
    // Score paragraphs into their ancestors.
    const scores = new Map();
    // How much paragraph text each element holds.
    const paragraphText = new Map();
    const pt = el => paragraphText.get(el) || 0;
    const initScore = el => {
      if (scores.has(el)) return;
      let s = classWeight(el);
      switch (el.localName) {
        case 'div': s += 5; break;
        case 'pre': case 'td': case 'blockquote': s += 3; break;
        case 'address': case 'ol': case 'ul': case 'dl': case 'dd': case 'dt': case 'li': case 'form': s -= 3; break;
        case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6': case 'th': s -= 5; break;
        case 'article': s += 15; break;
      }
      if ((el.getAttribute('itemprop') || '').includes('articleBody')) s += 15;
      scores.set(el, s);
    };

    const paragraphs = [...body.querySelectorAll('p, pre, td, blockquote')];
    for (const div of body.querySelectorAll('div')) if (!div.querySelector(DIV_BLOCKS)) paragraphs.push(div);

    for (const el of paragraphs) {
      if (unlikely(el) || hidden(el)) continue;
      const t = text(el);
      if (t.length < 25) continue;
      for (let a = el.parentElement; a && a !== doc.documentElement; a = a.parentElement) paragraphText.set(a, pt(a) + t.length);
      const score = 1 + t.split(/[,，、]/).length - 1 + Math.min(Math.floor(t.length / 100), 3);
      let a = el.parentElement, level = 0;
      while (a && level < 5 && a !== doc.documentElement) {
        initScore(a);
        scores.set(a, scores.get(a) + score / (level === 0 ? 1 : level === 1 ? 2 : level * 3));
        a = a.parentElement; level++;
      }
    }
    if (!scores.size) return fail('no paragraphs');

    const final = new Map();
    for (const [el, s] of scores) final.set(el, s * (1 - linkDensity(el)));
    const ranked = [...final].sort((a, b) => b[1] - a[1]);
    let [top, topScore] = ranked[0];

    // Several near-equal candidates under one ancestor: the article is that ancestor.
    const alternatives = ranked.slice(1, 6).filter(([, s]) => s / topScore >= 0.75).map(([el]) => el);
    if (alternatives.length >= 3) {
      for (let p = top.parentElement; p && p !== body; p = p.parentElement) {
        if (alternatives.filter(a => p.contains(a)).length >= 3) { top = p; break; }
      }
    }
    // The best-scoring block may be one piece of an article the page splits up (a block per
    // paragraph, or text broken up by ads): climb to the ancestor holding the rest of it, as
    // long as most of what that ancestor says is still paragraphs.
    const climb = [];
    for (let a = top.parentElement; a && a !== body; a = a.parentElement) {
      if (typeof debug !== 'undefined' && debug) climb.push(a.localName + '.' + classOf(a).slice(0, 40) + ' pt=' + pt(a) + ' text=' + text(a).length + ' ld=' + linkDensity(a).toFixed(2));
      if (pt(a) < pt(top) * 1.2) continue;
      if (pt(a) / Math.max(text(a).length, 1) >= 0.6 && linkDensity(a) < 0.3) top = a;
    }
    while (top.parentElement && top.parentElement !== body && top.parentElement.children.length === 1) top = top.parentElement;
    topScore = final.get(top) ?? topScore;

    // Siblings that belong with it (an article split across a few containers).
    const parts = [];
    const parent = top.parentElement;
    if (!parent || top === body) parts.push(top);
    else {
      const threshold = Math.max(10, topScore * 0.2);
      const topClass = top.getAttribute('class');
      for (const sib of parent.children) {
        if (sib === top) { parts.push(sib); continue; }
        if (unlikely(sib) || hidden(sib)) continue;
        let s = final.get(sib) ?? 0;
        if (topClass && sib.getAttribute('class') === topClass) s += topScore * 0.2;
        if (s >= threshold) { parts.push(sib); continue; }
        if (sib.localName === 'p') {
          const t = text(sib), ld = linkDensity(sib);
          if ((t.length > 80 && ld < 0.25) || (t.length > 0 && ld === 0 && /\.( |$)/.test(t))) parts.push(sib);
        }
      }
    }

    // Copy it, leaving out what the page doesn't show and fixing up images as we go (the copy
    // has no layout, so this reads the original element by element alongside it).
    const KEEP_UNRENDERED = new Set(['source', 'track', 'br', 'wbr', 'col', 'colgroup']);
    const lazyAttrs = ['data-src', 'data-lazy-src', 'data-original', 'data-url', 'data-hi-res-src', 'data-full-src', 'data-lazy'];
    const absolute = u => { try { return new URL(u, doc.baseURI).href; } catch { return null; } };

    const copy = original => {
      const clone = original.cloneNode(true);
      const from = [original, ...original.querySelectorAll('*')];
      const to = [clone, ...clone.querySelectorAll('*')];
      const drop = [];
      for (let i = 0; i < from.length; i++) {
        const o = from[i], c = to[i], tag = o.localName;
        if (o.closest('svg') && tag !== 'svg') continue;
        if (!KEEP_UNRENDERED.has(tag) && !o.closest('details:not([open])') && hidden(o)) { drop.push(c); continue; }
        if (o !== original && furniture(o)) { drop.push(c); continue; }
        if (tag === 'img') {
          let src = o.currentSrc || o.src || '';
          const placeholder = !src || src.startsWith('data:') || (o.complete && o.naturalWidth > 0 && o.naturalWidth < 4);
          if (placeholder) {
            const lazy = lazyAttrs.map(a => o.getAttribute(a)).find(Boolean)
              || (o.getAttribute('data-srcset') || o.getAttribute('data-lazy-srcset') || '').trim().split(/\s+/)[0];
            // Nothing behind the placeholder: a spacer.
            if (!lazy) { drop.push(c); continue; }
            src = lazy;
          }
          src = src && absolute(src);
          if (!src) { drop.push(c); continue; }
          const r = o.getBoundingClientRect();
          if (r.width < 4 || r.height < 4) { drop.push(c); continue; }
          if (r.width > 0 && r.width <= 40 && r.height <= 40) {
            if (o.closest('p, li, h1, h2, h3, h4, h5, h6, td')) c.setAttribute('data-inline', '');
            else { drop.push(c); continue; }
          }
          c.setAttribute('src', src);
        } else if (tag === 'video') {
          const src = o.currentSrc && !o.currentSrc.startsWith('blob:') ? o.currentSrc : null;
          if (!src) { drop.push(c); continue; }
          c.setAttribute('src', src);
          c.setAttribute('controls', '');
          const poster = o.getAttribute('poster');
          if (poster) c.setAttribute('poster', absolute(poster) || '');
        } else if (tag === 'svg') {
          const r = o.getBoundingClientRect();
          if ((r.width < 64 && r.height < 64) || o.querySelector('use')) drop.push(c);
        }
      }
      drop.forEach(e => e.remove());
      return clone;
    };

    const root = doc.createElement('div');
    for (const part of parts) root.appendChild(copy(part));

    root.querySelectorAll('script, style, link, meta, noscript, iframe, frame, object, embed, form, input, button, select, textarea, nav, aside, footer, dialog, template, canvas, audio, picture > source, video > source, [role="navigation"], [role="complementary"], [aria-hidden="true"]:not(svg *)').forEach(e => e.remove());

    // Image-map navigation, and logos that link to the site's home page.
    for (const img of root.querySelectorAll('img[usemap], a[href] img')) {
      if (img.hasAttribute('usemap')) { img.remove(); continue; }
      try {
        const link = new URL(img.closest('a').getAttribute('href'), doc.baseURI);
        if (link.host === location.host && /^\/(index\.html?)?$/.test(link.pathname)) img.remove();
      } catch {}
    }

    // Tables used for layout (old sites, newsletters) become plain blocks; data tables stay.
    const isDataTable = t => {
      if (t.getAttribute('role') === 'presentation') return false;
      if (t.querySelector('caption, th, thead, tfoot, colgroup') || t.getAttribute('summary')) return true;
      if (t.querySelector('table')) return false;
      const rows = t.rows.length, cols = rows ? Math.max(...[...t.rows].map(r => r.cells.length)) : 0;
      if (rows < 2 || cols < 2) return false;
      return ![...t.querySelectorAll('td')].some(td => text(td).length > 300 || td.querySelector('p, div, h1, h2, h3'));
    };
    for (const t of [...root.querySelectorAll('table')].reverse()) {
      if (isDataTable(t)) continue;
      const block = doc.createElement('div');
      for (const cell of t.querySelectorAll(':scope > * > tr > td, :scope > tr > td, :scope > * > tr > th')) {
        const div = doc.createElement('div');
        div.append(...cell.childNodes);
        block.appendChild(div);
      }
      t.replaceWith(block);
    }

    // Leftover clutter inside the article: share bars, related links, ad slots, empty boxes.
    for (const el of [...root.querySelectorAll('div, section, header, ul, ol, table, figure, span')].reverse()) {
      if (!root.contains(el) || el.closest('pre, code')) continue;
      const tag = el.localName, cls = classOf(el), len = text(el).length;
      if (CLEAN.test(cls) && !POSITIVE.test(cls) && len < 1000) { el.remove(); continue; }
      if (tag === 'span') continue;
      const ld = linkDensity(el);
      if (tag === 'ul' || tag === 'ol') {
        const items = el.querySelectorAll('li').length || 1;
        if (ld > 0.5 && len / items < 80) el.remove();
        continue;
      }
      if (tag === 'figure') continue;
      if (tag === 'table') { if (ld > 0.5) el.remove(); continue; }
      if (ld > 0.5 && len < 2000) { el.remove(); continue; }
      if (len === 0 && !el.querySelector('img, video, svg, hr, math, table')) el.remove();
    }

    // No run of line breaks before the first words (left over from layout tables and spacer images).
    const trimLeading = node => {
      while (node.firstChild) {
        const c = node.firstChild;
        if (c.nodeType === Node.TEXT_NODE && !c.textContent.trim()) { c.remove(); continue; }
        if (c.nodeType !== Node.ELEMENT_NODE) return;
        if (c.localName === 'br') { c.remove(); continue; }
        if (!text(c) && !c.querySelector('img, video, svg, table, hr')) { c.remove(); continue; }
        trimLeading(c);
        return;
      }
    };
    trimLeading(root);

    // Title: a heading in the article that the page title starts with, else the page title
    // without the site's name tacked on.
    const siteName = meta('meta[property="og:site_name"]') || location.hostname.replace(/^www\./, '');
    let title = meta('meta[property="og:title"]') || meta('meta[name="twitter:title"]') || norm(doc.title);
    const pageTitle = norm(doc.title);
    const matchesTitle = h => {
      const t = text(h);
      if (t.length < 2 || t.length > 300) return false;
      if (pageTitle.startsWith(t) || title.startsWith(t)) return true;
      return t.length >= 10 && (pageTitle.includes(t) || title.includes(t));
    };
    const heading = [...root.querySelectorAll('h1, h2')].find(matchesTitle)
      || [...body.querySelectorAll('h1')].find(h => !hidden(h) && matchesTitle(h));
    if (heading) title = text(heading);
    else {
      const m = title.match(/^(.{10,}?)\s+[|\-–—:»]\s+[^|\-–—:»]{2,60}$/);
      if (m) title = m[1];
    }
    for (const h of root.querySelectorAll('h1, h2')) {
      if (text(h) === title) { h.remove(); break; }
    }
    // A picture of the title (sites that set their headline as an image).
    for (const img of root.querySelectorAll('img')) {
      if (norm(img.getAttribute('alt')).toLowerCase() === title.toLowerCase()) img.remove();
    }

    let byline = meta('meta[name="author"]') || meta('meta[property="article:author"]') || meta('meta[name="parsely-author"]') || meta('meta[name="sailthru.author"]');
    if (/^https?:/i.test(byline)) byline = '';
    if (!byline) {
      const el = [...doc.querySelectorAll('[rel="author"], [itemprop~="author"] [itemprop~="name"], [itemprop~="author"], .byline, .author, [class*="byline"]')]
        .find(e => { const t = text(e); return t.length > 1 && t.length < 100; });
      if (el) byline = text(el);
    }
    if (byline.length >= 120) byline = '';
    else if (byline && !/^by\s/i.test(byline)) byline = 'By ' + byline;

    let published = '';
    const when = meta('meta[property="article:published_time"]') || meta('meta[name="date"]') || meta('meta[itemprop="datePublished"]')
      || doc.querySelector('[itemprop="datePublished"]')?.getAttribute('datetime') || doc.querySelector('article time[datetime], time[datetime]')?.getAttribute('datetime');
    if (when) {
      const d = new Date(when);
      if (!isNaN(d)) published = d.toLocaleDateString(undefined, { year: 'numeric', month: 'long', day: 'numeric' });
    }

    // Only what's needed survives: no classes, styles or handlers from the page.
    const ALLOWED = {
      a: ['href', 'title'], img: ['src', 'alt', 'title', 'width', 'height', 'data-inline'],
      video: ['src', 'poster', 'controls', 'width', 'height'], td: ['colspan', 'rowspan'], th: ['colspan', 'rowspan', 'scope'],
      ol: ['start', 'type', 'reversed'], li: ['value'], time: ['datetime'], blockquote: ['cite'], q: ['cite'], abbr: ['title'],
    };
    for (const el of [...root.querySelectorAll('*')]) {
      const tag = el.localName, inSvg = el.closest('svg');
      for (const attr of [...el.attributes]) {
        const name = attr.name;
        if (inSvg) { if (name.startsWith('on') || name === 'href' || name === 'xlink:href') el.removeAttribute(name); continue; }
        if (name === 'id' || name === 'lang' || name === 'dir') continue;
        if (!(ALLOWED[tag] || []).includes(name)) el.removeAttribute(name);
      }
      if (tag === 'a') {
        const href = el.getAttribute('href');
        const abs = href && absolute(href);
        if (!abs || /^javascript:/i.test(abs)) el.replaceWith(...el.childNodes);
        else el.setAttribute('href', abs);
      }
    }

    const content = text(root);
    if (content.length < 500 || root.querySelectorAll('p').length + root.querySelectorAll('pre, li').length < 2 && content.length < 1200) {
      return fail('too short', { content: content.length, top: top.localName + '.' + classOf(top), parts: parts.length, ranked: ranked.slice(0, 5).map(([e, s]) => e.localName + '.' + classOf(e) + '=' + Math.round(s)) });
    }

    const words = content.split(' ').length;
    return {
      title, byline, siteName, published,
      html: root.innerHTML,
      lang: doc.documentElement.lang || '',
      dir: doc.documentElement.dir || getComputedStyle(body).direction || '',
      minutes: Math.max(1, Math.round(words / 230)),
      ...((typeof debug !== 'undefined' && debug) ? { top: top.localName + '.' + classOf(top) + ' pt=' + pt(top), parts: parts.length, climb: climb.join(' | ') } : {}),
    };
    };

    let result = attempt();
    if (!result || result.failed) {
      strict = false;
      unlikelyCache.clear();
      result = attempt();
    }
    return result;
    """#
}
