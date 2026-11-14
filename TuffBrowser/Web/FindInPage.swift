import AppKit
import WebKit

/// Where find in page stands: nothing searched yet, "3 of 12", or no matches.
enum FindStatus: Equatable {
    case idle
    case found(index: Int, total: Int)
    case notFound
}

extension Tab {
    /// Finds `query` in the page, highlighting every match and moving to the next (or previous)
    /// one, and reports "n of total" to the window's find bar.
    ///
    /// Uses WebKit's own find (`_findString:options:maxCount:` with a `_WKFindDelegate`), the one
    /// Safari uses, which can say which match is current; the public `find(_:configuration:)`
    /// only says whether there was one. Falls back to that if the private call is missing.
    func find(_ query: String, forward: Bool) {
        // In reader mode it searches the article.
        guard let webView = reader?.view ?? webView else { return }
        guard !query.isEmpty else {
            clearFind()
            return
        }
        let findSelector = NSSelectorFromString("_findString:options:maxCount:")
        let delegateSelector = NSSelectorFromString("_setFindDelegate:")
        guard webView.responds(to: findSelector), webView.responds(to: delegateSelector),
              let findImp = webView.method(for: findSelector) else {
            let configuration = WKFindConfiguration()
            configuration.backwards = !forward
            configuration.wraps = true
            configuration.caseSensitive = false
            webView.find(query, configuration: configuration) { [weak self] result in
                self?.browser?.findDidReport(result.matchFound ? .found(index: -1, total: -1) : .notFound, for: query, in: self)
            }
            return
        }
        let reporter = findReporter ?? FindReporter(tab: self)
        findReporter = reporter
        _ = webView.perform(delegateSelector, with: reporter)
        // _WKFindOptions: case-insensitive, wrap around, find indicator, highlight all, and work
        // out which match is current.
        var options: UInt = (1 << 0) | (1 << 4) | (1 << 6) | (1 << 7) | (1 << 9)
        if !forward { options |= 1 << 3 }
        typealias Fn = @convention(c) (AnyObject, Selector, NSString, UInt, UInt) -> Void
        unsafeBitCast(findImp, to: Fn.self)(webView, findSelector, query as NSString, options, 1000)
    }

    /// Takes away the match highlights (the find bar closed, or its field was emptied).
    func clearFind() {
        guard let webView = reader?.view ?? webView else { return }
        let hide = NSSelectorFromString("_hideFindUI")
        if webView.responds(to: hide) { _ = webView.perform(hide) }
        webView.evaluateJavaScript("window.getSelection().removeAllRanges()", completionHandler: nil)
    }
}

/// Receives WebKit's find results for one tab (`_WKFindDelegate`).
final class FindReporter: NSObject {
    private weak var tab: Tab?

    init(tab: Tab) { self.tab = tab }

    @objc(_webView:didFindMatches:forString:withMatchIndex:)
    func webView(_ webView: WKWebView, didFindMatches matches: UInt, forString string: String, withMatchIndex index: Int) {
        tab?.browser?.findDidReport(.found(index: max(0, index), total: Int(matches)), for: string, in: tab)
    }

    @objc(_webView:didFailToFindString:)
    func webView(_ webView: WKWebView, didFailToFindString string: String) {
        tab?.browser?.findDidReport(.notFound, for: string, in: tab)
    }
}
