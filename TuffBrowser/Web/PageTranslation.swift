import NaturalLanguage
import SwiftUI
import Translation
import WebKit

/// A tab's page being shown in another language.
///
/// Translation happens on this Mac (Apple's Translation framework: private, and offline once a
/// language is downloaded) or, when a language isn't on this Mac and the user chooses it, with
/// Google Translate (`GoogleTranslate`), which sends the page's text to Google. Which one is
/// asked on a card, unless Settings → Privacy says (`TranslationFallback`).
///
/// A script in Tuff's content world collects the page's text (each text node on its own,
/// skipping code, form fields and anything marked `translate="no"`), Tuff translates it in
/// batches and puts it back, keeping the originals for Show Original. Text the page adds later
/// (infinite scroll, a single-page app moving on) is translated as it appears, and further
/// pages in the same language that the tab goes to are translated too, as in Chrome.
struct PageTranslation: Equatable {
    enum Phase: Equatable { case translating, translated, failed(String) }
    enum Engine: Equatable { case device, google }

    let id = UUID()
    var source: Locale.Language
    var target: Locale.Language
    var engine: Engine
    var phase: Phase = .translating
    /// Says so when it is done (not for the pages a tab follows a translation onto).
    var announce = true
    /// On this Mac: what `.translationTask` runs for. Nil for Google.
    var configuration: TranslationSession.Configuration?

    init(source: Locale.Language, target: Locale.Language, engine: Engine, announce: Bool) {
        self.source = source
        self.target = target
        self.engine = engine
        self.announce = announce
        if engine == .device { configuration = TranslationSession.Configuration(source: source, target: target) }
    }

    var sourceName: String { PageTranslation.name(of: source) }
    var targetName: String { PageTranslation.name(of: target) }

    /// "French", "English": the language without its region.
    static func name(of language: Locale.Language) -> String {
        let code = language.languageCode?.identifier ?? language.minimalIdentifier
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    /// The language pages are translated into: the first of the user's preferred languages.
    static var preferredTarget: Locale.Language {
        Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
    }

    static func sameLanguage(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        a.languageCode == b.languageCode
    }
}

/// What to do when a page's language isn't on this Mac.
enum TranslationFallback: String, Codable, CaseIterable {
    case ask, download, google

    var label: String {
        switch self {
        case .ask: "Ask"
        case .download: "Download it"
        case .google: "Use Google Translate"
        }
    }
}

enum PageTranslator {
    static let world = WebEngine.scriptWorld
    static let handlerName = "tuffTranslate"
    private static let handler = MessageHandler()
    /// Text nodes put back into the page at a time: small on this Mac, so the top of the page
    /// changes quickly; larger for Google, which splits them into requests of its own.
    static func batchSize(for engine: PageTranslation.Engine) -> Int { engine == .device ? 60 : 400 }

    static func install(into controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        controller.add(handler, contentWorld: world, name: handlerName)
    }

    /// The page's language: what its text reads as, else what its `lang` attribute says.
    static func detectLanguage(in webView: WKWebView) async -> Locale.Language? {
        let result = try? await webView.callAsyncJavaScript(
            "return window.__tuffTranslate ? window.__tuffTranslate.sample() : null", contentWorld: world
        )
        guard let sample = result as? [String: Any] else { return nil }
        let text = sample["text"] as? String ?? ""
        let declared = (sample["lang"] as? String).flatMap { $0.isEmpty ? nil : Locale.Language(identifier: $0) }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence > 0.6 || declared == nil {
            return Locale.Language(identifier: language.rawValue)
        }
        return declared
    }

    private final class MessageHandler: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let tab = (message.webView as? TuffWebView)?.tab,
                  message.body as? String == "more" else { return }
            tab.translationMore?.yield()
        }
    }

    // MARK: Script

    private static let script = #"""
    (function () {
      if (window.__tuffTranslate) return;
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tuffTranslate;
      var skip = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEXTAREA: 1, INPUT: 1, SELECT: 1, CODE: 1, PRE: 1, KBD: 1, SAMP: 1, VAR: 1, SVG: 1, MATH: 1, TEMPLATE: 1 };
      var letters = /[A-Za-zÀ-ɏͰ-ϿЀ-ӿ֐-ۿऀ-෿฀-࿿ᄀ-ᇿ぀-ヿ㐀-鿿가-힯]/;
      var nodes = [], originals = new Map(), applied = new WeakMap(), observer = null, timer = null, originalTitle = null;

      function translatable(node) {
        var text = node.nodeValue;
        if (!text || !letters.test(text)) return false;
        for (var el = node.parentElement; el; el = el.parentElement) {
          if (skip[el.tagName.toUpperCase()] || el.isContentEditable) return false;
          if (el.getAttribute('translate') === 'no' || (el.classList && el.classList.contains('notranslate'))) return false;
        }
        return true;
      }

      function collect() {
        var out = [];
        var root = document.body || document.documentElement;
        if (!root) return out;
        if (originalTitle === null && document.title && letters.test(document.title)) {
          originalTitle = document.title;
          out.push([-1, document.title]);
        }
        var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        var node;
        while ((node = walker.nextNode())) {
          // Already translated and unchanged since.
          if (applied.has(node) && applied.get(node) === node.nodeValue) continue;
          if (!translatable(node)) continue;
          originals.set(node, node.nodeValue);
          applied.set(node, node.nodeValue);
          out.push([nodes.length, node.nodeValue.trim()]);
          nodes.push(node);
        }
        return out;
      }

      function apply(results) {
        for (var i = 0; i < results.length; i++) {
          var id = results[i][0], text = results[i][1];
          if (id === -1) { document.title = text; continue; }
          var node = nodes[id];
          if (!node) continue;
          var original = originals.get(node) || '';
          var value = original.match(/^\s*/)[0] + text + original.match(/\s*$/)[0];
          // An elision ("d'" before a link) comes back as a word ("of"): keep it apart from the next one.
          if (/['\u2019]$/.test(original) && /[^\s'\u2019]$/.test(value)) value += ' ';
          node.nodeValue = value;
          applied.set(node, value);
        }
        // Our own changes aren't new text.
        if (observer) observer.takeRecords();
      }

      function watch() {
        if (observer || !document.body || !bridge) return;
        observer = new MutationObserver(function () {
          clearTimeout(timer);
          timer = setTimeout(function () { try { bridge.postMessage('more'); } catch (e) {} }, 500);
        });
        observer.observe(document.body, { childList: true, subtree: true, characterData: true });
      }

      function restore() {
        if (observer) { observer.disconnect(); observer = null; }
        clearTimeout(timer);
        originals.forEach(function (value, node) { node.nodeValue = value; });
        if (originalTitle !== null) document.title = originalTitle;
        nodes = []; originals = new Map(); applied = new WeakMap(); originalTitle = null;
      }

      function sample() {
        var body = document.body;
        return { lang: document.documentElement.lang || '', text: ((body && body.innerText) || document.title || '').slice(0, 4000) };
      }

      window.__tuffTranslate = { collect: collect, apply: apply, watch: watch, restore: restore, sample: sample };
    })();
    """#
}

/// Google Translate without an API key: the endpoint Google's own Translate extension uses. It
/// costs nothing, but it is unofficial, so Google could limit or change it; the page's text goes
/// to Google. Requests carry no cookies (an ephemeral session), Incognito included.
enum GoogleTranslate {
    private static let session = URLSession(configuration: .ephemeral)
    /// Characters per request, kept well under what the endpoint accepts.
    private static let requestLimit = 4500

    /// Google's code for a language: Chinese by script, Hebrew under its old code.
    static func code(_ language: Locale.Language) -> String {
        guard let code = language.languageCode?.identifier else { return "auto" }
        if code == "zh" {
            let traditional = language.script?.identifier == "Hant" || ["TW", "HK", "MO"].contains(language.region?.identifier ?? "")
            return traditional ? "zh-TW" : "zh-CN"
        }
        return code == "he" ? "iw" : code
    }

    /// Requests in flight at once.
    private static let parallel = 4

    /// Translates each text, in order.
    static func translate(_ texts: [String], from source: Locale.Language, to target: Locale.Language) async throws -> [String] {
        var chunks: [[String]] = []
        var batch: [String] = []
        var size = 0
        for text in texts {
            if size + text.utf8.count > requestLimit, !batch.isEmpty {
                chunks.append(batch)
                batch = []
                size = 0
            }
            batch.append(text)
            size += text.utf8.count
        }
        if !batch.isEmpty { chunks.append(batch) }
        var results = [[String]](repeating: [], count: chunks.count)
        try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
            var next = 0
            func add() {
                guard next < chunks.count else { return }
                let index = next, chunk = chunks[index]
                next += 1
                group.addTask { (index, try await request(chunk, from: source, to: target)) }
            }
            for _ in 0..<parallel { add() }
            while let (index, translated) = try await group.next() {
                results[index] = translated
                add()
            }
        }
        return results.flatMap { $0 }
    }

    private static func request(_ texts: [String], from source: Locale.Language, to target: Locale.Language) async throws -> [String] {
        try Task.checkCancellation()
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/t")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"), URLQueryItem(name: "sl", value: code(source)),
            URLQueryItem(name: "tl", value: code(target)), URLQueryItem(name: "format", value: "text"),
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = texts.map { "q=" + ($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Google Translate didn’t answer (\((response as? HTTPURLResponse)?.statusCode ?? 0))."])
        }
        // One entry per text: the translation, or [translation, detected language].
        guard let list = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? [Any], list.count == texts.count else {
            throw URLError(.cannotParseResponse)
        }
        return list.enumerated().map { index, entry in
            (entry as? String) ?? ((entry as? [Any])?.first as? String) ?? texts[index]
        }
    }
}

// MARK: - Tab

extension Tab {
    /// Translate Page: works out the page's language and starts translating it into the
    /// user's language, on this Mac or with Google as the user chooses.
    @MainActor
    func translatePage(automatically: Bool = false) async {
        guard let webView, pdf == nil else { return }
        let target = PageTranslation.preferredTarget
        guard let source = await PageTranslator.detectLanguage(in: webView) else {
            if !automatically { browser?.show(Toast(symbol: "character.bubble", text: "Couldn’t tell what language this page is in")) }
            return
        }
        if PageTranslation.sameLanguage(source, target) {
            if !automatically { browser?.show(Toast(symbol: "character.bubble", text: "This page is already in \(PageTranslation.name(of: target))")) }
            return
        }
        // A later page in the same tab only follows along if it is in the language that was translated.
        if automatically, let keep = keepTranslating, !PageTranslation.sameLanguage(keep.source, source) { return }
        let status = await LanguageAvailability().status(from: source, to: target)
        let engine: PageTranslation.Engine
        if status == .installed {
            engine = .device
        } else if automatically, let keep = keepTranslating {
            engine = keep.engine
        } else {
            guard let chosen = await chooseEngine(source: source, target: target, canDownload: status == .supported) else { return }
            engine = chosen
        }
        startTranslation(PageTranslation(source: source, target: target, engine: engine, announce: !automatically))
    }

    /// The language isn't on this Mac: download it, or use Google? Settings can answer for
    /// the user; Incognito always asks before a page goes to Google.
    @MainActor
    private func chooseEngine(source: Locale.Language, target: Locale.Language, canDownload: Bool) async -> PageTranslation.Engine? {
        let incognito = browser?.isPrivate ?? false
        let setting = AppSettings.shared.privacy.translationFallback
        if setting == .download, canDownload { return .device }
        if setting == .google, !incognito { return .google }
        let from = PageTranslation.name(of: source), into = PageTranslation.name(of: target)
        let prompt = canDownload
            ? Prompt(
                icon: favicon, symbol: "character.bubble",
                title: "Translate this page from \(from)?",
                message: "\(from) isn’t on this Mac yet. Download it to translate here, privately (it works offline after), or use Google Translate now, which sends the page’s text to Google.",
                confirmTitle: "Download",
                alternateTitle: "Use Google",
                checkbox: incognito ? nil : "Remember my choice"
            )
            : Prompt(
                icon: favicon, symbol: "character.bubble",
                title: "Translate with Google?",
                message: "This Mac can’t translate \(from) into \(into). Google Translate can, but it sends the page’s text to Google.",
                confirmTitle: "Use Google Translate",
                checkbox: incognito ? nil : "Remember my choice"
            )
        guard let result = await askForPage(prompt), result.confirmed || result.alternate else { return nil }
        let engine: PageTranslation.Engine = result.confirmed && canDownload ? .device : .google
        if result.checked { AppSettings.shared.privacy.translationFallback = engine == .device ? .download : .google }
        return engine
    }

    private func startTranslation(_ run: PageTranslation) {
        translationRun?.cancel()
        translation = run
        // On this Mac, `TranslationHost`'s `.translationTask` hands over a session and runs it.
        guard run.engine == .google else { return }
        translationRun = Task { @MainActor [weak self] in
            await self?.runTranslation(run.id) { texts in
                try await GoogleTranslate.translate(texts, from: run.source, to: run.target)
            }
        }
    }

    /// Show Original: puts the page's own text back and stops following it to other pages.
    func showOriginal() {
        keepTranslating = nil
        stopTranslation()
        webView?.callAsyncJavaScript("if (window.__tuffTranslate) window.__tuffTranslate.restore()", arguments: [:], in: nil, in: PageTranslator.world)
    }

    func toggleTranslation() {
        if translation != nil {
            showOriginal()
        } else {
            Task { @MainActor in await translatePage() }
        }
    }

    private func stopTranslation() {
        translation = nil
        translationRun?.cancel()
        translationRun = nil
        translationMore?.finish()
        translationMore = nil
    }

    /// The page moved on: a translation was for the one before.
    func translationPageDidCommit() {
        guard translation != nil else { return }
        stopTranslation()
    }

    /// The page finished loading: translate it too if the tab is following a translation.
    func translationPageDidFinish() {
        guard keepTranslating != nil, translation == nil else { return }
        Task { @MainActor in await translatePage(automatically: true) }
    }

    /// On this Mac, with the session `.translationTask` hands over.
    @MainActor
    func runTranslation(_ session: TranslationSession) async {
        guard let run = translation, run.engine == .device else { return }
        do {
            // Shows the system's download sheet when the language isn't on this Mac yet.
            try await session.prepareTranslation()
        } catch {
            // Download declined, or it couldn't be done.
            if translation?.id == run.id { stopTranslation() }
            return
        }
        await runTranslation(run.id) { texts in
            let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
            var results = texts
            for response in try await session.translations(from: requests) {
                if let index = response.clientIdentifier.flatMap(Int.init), results.indices.contains(index) {
                    results[index] = response.targetText
                }
            }
            return results
        }
    }

    /// Translates the page's text in batches, then whatever the page adds, until the tab moves
    /// on or Show Original.
    @MainActor
    private func runTranslation(_ id: UUID, translate: @escaping ([String]) async throws -> [String]) async {
        guard let run = translation, run.id == id, let webView else { return }
        let stream = AsyncStream<Void> { translationMore = $0 }
        do {
            // Pages the tab goes to next follow along, even before this one is done.
            keepTranslating = (run.source, run.target, run.engine)
            try await translateNewText(in: webView, engine: run.engine, with: translate)
            guard translation?.id == id else { return }
            translation?.phase = .translated
            if run.announce {
                browser?.show(Toast(symbol: "character.bubble", text: run.engine == .google
                    ? "Translated from \(run.sourceName) with Google" : "Translated from \(run.sourceName)"))
            }
            _ = try? await webView.callAsyncJavaScript("window.__tuffTranslate.watch()", contentWorld: PageTranslator.world)
            for await _ in stream {
                guard translation?.id == id else { break }
                try await translateNewText(in: webView, engine: run.engine, with: translate)
            }
        } catch is CancellationError {
            return
        } catch {
            guard translation?.id == id else { return }
            translation?.phase = .failed(error.localizedDescription)
            browser?.show(Toast(symbol: "exclamationmark.triangle", text: "Couldn’t translate this page"))
        }
    }

    @MainActor
    private func translateNewText(
        in webView: WKWebView, engine: PageTranslation.Engine, with translate: ([String]) async throws -> [String]
    ) async throws {
        let collected = try await webView.callAsyncJavaScript("return window.__tuffTranslate.collect()", contentWorld: PageTranslator.world)
        guard let pairs = collected as? [[Any]], !pairs.isEmpty else { return }
        let segments: [(id: Int, text: String)] = pairs.compactMap { pair in
            guard pair.count == 2, let id = (pair[0] as? NSNumber)?.intValue, let text = pair[1] as? String else { return nil }
            return (id, text)
        }
        let size = PageTranslator.batchSize(for: engine)
        for start in stride(from: 0, to: segments.count, by: size) {
            try Task.checkCancellation()
            let batch = Array(segments[start..<min(start + size, segments.count)])
            let translated = try await translate(batch.map(\.text))
            guard self.webView === webView else { return }
            let results: [[Any]] = zip(batch, translated).map { [$0.id, $1] }
            _ = try await webView.callAsyncJavaScript(
                "window.__tuffTranslate.apply(results)", arguments: ["results": results], contentWorld: PageTranslator.world
            )
        }
    }
}

/// Hosts the Translation framework's session for a tab's page (it only hands one out through
/// a SwiftUI view, which also holds the language download sheet). Draws nothing.
struct TranslationHost: View {
    let tab: Tab

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .translationTask(tab.translation?.configuration) { session in
                await tab.runTranslation(session)
            }
    }
}

private extension WKWebView {
    func callAsyncJavaScript(_ body: String, arguments: [String: Any] = [:], contentWorld: WKContentWorld) async throws -> Any? {
        try await callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: contentWorld)
    }
}
