import XCTest
@testable import Tuff

/// Address handling: what typing into the command bar opens.
final class ResolveTests: XCTestCase {
    private func resolve(_ text: String) -> String {
        BrowserState.resolve(text, engine: .duckduckgo).absoluteString
    }

    func testFullURLsOpenAsTyped() {
        XCTAssertEqual(resolve("https://example.com/a?b=c"), "https://example.com/a?b=c")
        XCTAssertEqual(resolve("about:blank"), "about:blank")
    }

    func testBareDomainsGetHTTPS() {
        XCTAssertEqual(resolve("example.com"), "https://example.com")
        XCTAssertEqual(resolve("news.ycombinator.com/item?id=1"), "https://news.ycombinator.com/item?id=1")
    }

    func testLocalAddressesGetHTTP() {
        XCTAssertEqual(resolve("localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(resolve("192.168.1.1"), "http://192.168.1.1")
        XCTAssertEqual(resolve("[::1]:8080"), "http://[::1]:8080")
    }

    func testFileNamesAndSentencesAreSearched() {
        for text in ["index.html", "node.js", "how to cook rice", "swift"] {
            XCTAssertFalse(resolve(text).hasPrefix("https://\(text)"), "\(text) should be a search")
            XCTAssertFalse(resolve(text).hasPrefix("http://\(text)"), "\(text) should be a search")
        }
    }
}

final class TabTests: XCTestCase {
    func testSamePageIgnoresFragmentSlashWWWAndScheme() {
        let a = URL(string: "http://www.example.com/page/#top")!
        let b = URL(string: "https://example.com/page")!
        XCTAssertTrue(Tab.samePage(a, b))
        XCTAssertFalse(Tab.samePage(b, URL(string: "https://example.com/other")!))
        XCTAssertFalse(Tab.samePage(b, URL(string: "https://example.com/page?x=1")!))
    }

    func testZoomStepsUpAndDown() {
        XCTAssertEqual(Tab.zoomStep(from: 1, up: true), 1.1)
        XCTAssertEqual(Tab.zoomStep(from: 1, up: false), 0.9)
        // Between steps (an old ×1.1 level): to the nearest step that way.
        XCTAssertEqual(Tab.zoomStep(from: 1.21, up: true), 1.25)
        XCTAssertEqual(Tab.zoomStep(from: 1.21, up: false), 1.1)
        // Clamped at the ends.
        XCTAssertEqual(Tab.zoomStep(from: 4, up: true), 4)
        XCTAssertEqual(Tab.zoomStep(from: 0.3, up: false), 0.3)
    }
}

final class VersionTests: XCTestCase {
    func testBrowserMajorVersionCountsFourWeeklyReleases() {
        let calendar = Calendar(identifier: .gregorian)
        let date = { (y: Int, m: Int, d: Int) in calendar.date(from: DateComponents(year: y, month: m, day: d))! }
        XCTAssertEqual(AdvancedSettings.currentMajorVersion(known: 142, releasedOn: (2025, 10, 28), now: date(2025, 10, 1)), 142)
        XCTAssertEqual(AdvancedSettings.currentMajorVersion(known: 142, releasedOn: (2025, 10, 28), now: date(2025, 11, 24)), 142)
        XCTAssertEqual(AdvancedSettings.currentMajorVersion(known: 142, releasedOn: (2025, 10, 28), now: date(2025, 11, 25)), 143)
        XCTAssertEqual(AdvancedSettings.currentMajorVersion(known: 142, releasedOn: (2025, 10, 28), now: date(2026, 10, 27)), 155)
    }

    func testExtensionVersionComparison() {
        XCTAssertTrue(ExtensionManager.isVersion("1.10", newerThan: "1.9"))
        XCTAssertTrue(ExtensionManager.isVersion("2.0", newerThan: "1.99.99"))
        XCTAssertTrue(ExtensionManager.isVersion("1.0.1", newerThan: "1.0"))
        XCTAssertFalse(ExtensionManager.isVersion("1.0", newerThan: "1.0.0"))
        XCTAssertFalse(ExtensionManager.isVersion("1.2.3", newerThan: "1.2.3"))
        XCTAssertFalse(ExtensionManager.isVersion("1.2", newerThan: "1.10"))
        XCTAssertTrue(ExtensionManager.isVersion("2.1b1", newerThan: "2.0"))
    }
}

final class ExtensionInstallTests: XCTestCase {
    func testGeckoManifestDetection() {
        XCTAssertTrue(ExtensionManager.isGeckoManifest(["browser_specific_settings": ["gecko": ["id": "a@b"]]]))
        XCTAssertTrue(ExtensionManager.isGeckoManifest(["applications": ["gecko": ["id": "a@b"]]]))
        XCTAssertFalse(ExtensionManager.isGeckoManifest(["manifest_version": 3, "name": "x"]))
        XCTAssertFalse(ExtensionManager.isGeckoManifest(["browser_specific_settings": ["safari": [:]]]))
    }

    func testChromeDownloadURLUsesCurrentVersionAndArch() {
        let url = ExtensionManager.chromeDownloadURL(id: String(repeating: "a", count: 32)).absoluteString
        XCTAssertTrue(url.contains("prodversion=\(ExtensionManager.chromeProdVersion)"))
        XCTAssertTrue(url.contains("arch=\(ExtensionManager.chromeArch)"))
        XCTAssertFalse(url.contains("prodversion=140.0.0.0"))
    }

    func testShimGoesBeforeFirstScriptOrIntoHead() {
        func at(_ html: String) -> String {
            String(html[ExtensionCompat.shimInsertionPoint(in: html)...])
        }
        XCTAssertTrue(at("<html><head><title>x</title><script src=a.js></script>").hasPrefix("<script src=a.js>"))
        XCTAssertTrue(at("<html><head><title>x</title></head><body>hi</body>").hasPrefix("</head>"))
        XCTAssertTrue(at("<body>hi</body>").hasPrefix("<body>"))
        XCTAssertTrue(at("<!DOCTYPE html>hi").hasPrefix("hi"))
        XCTAssertEqual(at("hi"), "hi")
    }
}

final class ExtensionUpdateTests: XCTestCase {
    func testReadsVersionFromChromeUpdateCheck() {
        let tag = #"<updatecheck _esbAllowlist="true" prodversion="1.2" status="ok" version="2026.1116.1650"/>"#
        XCTAssertEqual(ExtensionManager.updateCheckVersion(in: tag, installed: "1.0"), "2026.1116.1650")
        XCTAssertEqual(ExtensionManager.updateCheckVersion(in: #"<updatecheck status="noupdate"/>"#, installed: "1.0"), "1.0")
    }
}
