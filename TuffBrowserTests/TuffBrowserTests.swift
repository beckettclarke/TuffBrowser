import AppKit
import Network
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

/// Favicon downloads carry the page profile's cookies for the icon's address, and no others.
final class FaviconCookieTests: XCTestCase {
    private func cookie(_ name: String, domain: String, path: String = "/", secure: Bool = false, expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "1", .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    func testMatchesDomainPathSecureAndExpiry() {
        let cookies = [
            cookie("host", domain: "cdn.example.com"),
            cookie("domain", domain: ".example.com"),
            cookie("other", domain: "example.org"),
            cookie("path", domain: ".example.com", path: "/icons"),
            cookie("deep", domain: ".example.com", path: "/static"),
            cookie("secure", domain: ".example.com", secure: true),
            cookie("old", domain: ".example.com", expires: Date(timeIntervalSince1970: 1)),
        ]
        let names = { (url: String) in Set(FaviconStore.cookies(cookies, for: URL(string: url)!).map(\.name)) }
        XCTAssertEqual(names("https://cdn.example.com/icons/a.png"), ["host", "domain", "path", "secure"])
        XCTAssertEqual(names("http://example.com/favicon.ico"), ["domain"])
        XCTAssertEqual(names("https://example.com/iconsx/a.png"), ["domain", "secure"])
        XCTAssertEqual(names("https://notexample.com/"), [])
    }
}

/// Parsing for the extension APIs Tuff implements itself.
final class ExtensionAPITests: XCTestCase {
    func testContentSettingsPatterns() throws {
        XCTAssertNil(try ExtensionContentSettings.parse("<all_urls>"))
        XCTAssertNil(try ExtensionContentSettings.parse("*://*/*"))
        let site = try XCTUnwrap(try ExtensionContentSettings.parse("https://*.Example.com/*"))
        XCTAssertEqual(site.scheme, "https")
        XCTAssertEqual(site.host, "example.com")
        XCTAssertEqual(try ExtensionContentSettings.parse("*://example.org:8080/")?.scheme, "https")
        XCTAssertThrowsError(try ExtensionContentSettings.parse("file:///x"))
    }

    func testThemeColours() {
        XCTAssertEqual(ExtensionTheme.color("#f00")?.hexString.uppercased(), "#FF0000")
        XCTAssertEqual(ExtensionTheme.color("#00ff0080")?.hexString.uppercased(), "#00FF00")
        XCTAssertEqual(ExtensionTheme.color("rgb(0, 0, 255)")?.hexString.uppercased(), "#0000FF")
        XCTAssertEqual(ExtensionTheme.color([255, 255, 255])?.hexString.uppercased(), "#FFFFFF")
        XCTAssertNil(ExtensionTheme.color("nonsense"))
    }

    func testTabGroupTitlePatterns() {
        XCTAssertTrue(ExtensionTabGroups.titleMatches("Work stuff", pattern: "work*"))
        XCTAssertTrue(ExtensionTabGroups.titleMatches("Work", pattern: "Work"))
        XCTAssertFalse(ExtensionTabGroups.titleMatches("Homework", pattern: "Work"))
        XCTAssertTrue(ExtensionTabGroups.titleMatches("a.b", pattern: "a.b"))
        XCTAssertFalse(ExtensionTabGroups.titleMatches("axb", pattern: "a.b"))
    }

    func testContainerColours() {
        XCTAssertEqual(ExtensionContainers.colorName(for: NSColor(hex: "#2E6BE6")), "blue")
        XCTAssertEqual(ExtensionContainers.colorName(for: NSColor(hex: "#E53935")), "red")
        XCTAssertEqual(ExtensionContainers.colorName(for: NSColor(hex: "#777777")), "toolbar")
        XCTAssertEqual(ExtensionContainers.colorName(for: nil), "toolbar")
    }

    func testOmniboxDescriptionsLoseMarkup() {
        XCTAssertEqual(ExtensionOmnibox.plain("<match>React</match> &amp; <dim>docs</dim> &lt;3"), "React & docs <3")
    }

    func testProxyConfigs() throws {
        XCTAssertNil(try ExtensionSettings.proxyConfigurations(for: ["mode": "system"]))
        XCTAssertNil(try ExtensionSettings.proxyConfigurations(for: ["mode": "direct"]))
        let chrome = try ExtensionSettings.proxyConfigurations(for: [
            "mode": "fixed_servers",
            "rules": ["singleProxy": ["scheme": "socks5", "host": "127.0.0.1", "port": 1080], "bypassList": ["*.local", "<local>", "example.com"]],
        ])
        XCTAssertEqual(chrome?.count, 1)
        var excluded: [String] = []
        if let proxy = chrome?.first { nw_proxy_config_enumerate_excluded_domains(proxy) { excluded.append(String(cString: $0)) } }
        XCTAssertEqual(excluded, ["local", "example.com"])
        XCTAssertEqual(try ExtensionSettings.proxyConfigurations(for: ["proxyType": "manual", "http": "proxy.test:3128"])?.count, 1)
        XCTAssertNil(try ExtensionSettings.proxyConfigurations(for: ["proxyType": "system"]))
        XCTAssertThrowsError(try ExtensionSettings.proxyConfigurations(for: ["mode": "pac_script"]))
        XCTAssertThrowsError(try ExtensionSettings.proxyConfigurations(for: ["mode": "fixed_servers", "rules": ["singleProxy": ["scheme": "socks4", "host": "x"]]]))
        XCTAssertThrowsError(try ExtensionSettings.proxyConfigurations(for: ["proxyType": "manual", "socks": "x:1", "socksVersion": 4]))
    }
}
