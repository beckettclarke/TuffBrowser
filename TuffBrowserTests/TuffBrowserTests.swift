import AppKit
import JavaScriptCore
import Network
import WebKit
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

    func testExtensionTabPlacementAcrossSpacesAndPinnedSections() {
        let state = BrowserState.makeIncognito()
        let first = state.newTab(url: URL(string: "https://one.example"), select: false)
        let second = state.newTab(url: URL(string: "https://two.example"), select: false, extensionIndex: 0)
        XCTAssertTrue(state.allTabs[0] === second)
        XCTAssertTrue(state.allTabs[1] === first)

        let pinned = state.newTab(url: URL(string: "https://pin.example"), select: false, extensionIndex: 0, pinned: true)
        XCTAssertTrue(state.allTabs[0] === pinned)
        XCTAssertEqual(state.section(of: pinned), .pinned)

        let space = Space(name: "Other", icon: "folder", colorHex: "#000000", profileID: state.currentProfile.id)
        state.spaces.append(space)
        let other = state.newTab(url: URL(string: "https://other.example"), select: false, in: space)
        let index = state.allTabs.firstIndex { $0 === other }!
        let before = state.newTab(url: URL(string: "https://before.example"), select: false, extensionIndex: index)
        XCTAssertTrue(state.space(containing: before) === space)
        XCTAssertEqual(space.tabs.firstIndex { $0 === before }, space.tabs.firstIndex { $0 === other }! - 1)

        state.move(first, to: .pinned)
        XCTAssertEqual(state.section(of: first), .pinned)
        state.move(first, to: .tabs, at: 1)
        XCTAssertEqual(state.section(of: first), .tabs)
        XCTAssertEqual(space.tabs.contains { $0 === first }, false)
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
    func testUpdatePreservesDisabledStateAndBrowserPreferences() {
        let links = [UUID(), UUID()]
        let existing = ExtensionRecord(
            id: "test", source: .chrome, storeID: "test", name: "Old", version: "1.0", enabled: false,
            path: nil, lastError: nil, sidePanel: SidePanelPrefs(path: "panel.html", enabled: true, openOnActionClick: true),
            linkedTo: links, pinned: true
        )
        let update = ExtensionRecord(
            id: "test", source: .chrome, storeID: "test", name: "New", version: "2.0", enabled: true, path: nil
        )
        let merged = ExtensionManager.preservingState(of: existing, into: update)
        XCTAssertFalse(merged.enabled)
        XCTAssertEqual(merged.linkedTo, links)
        XCTAssertEqual(merged.pinned, true)
        XCTAssertEqual(merged.sidePanel, existing.sidePanel)
        XCTAssertEqual(merged.version, "2.0")
        XCTAssertEqual(ExtensionManager.preservingState(of: nil, into: update), update)
    }

    func testReadsVersionFromChromeUpdateCheck() {
        let tag = #"<updatecheck _esbAllowlist="true" prodversion="1.2" status="ok" version="2026.1116.1650"/>"#
        XCTAssertEqual(ExtensionManager.updateCheckVersion(in: tag, installed: "1.0"), "2026.1116.1650")
        XCTAssertEqual(ExtensionManager.updateCheckVersion(in: #"<updatecheck status="noupdate"/>"#, installed: "1.0"), "1.0")
    }
}

final class ExtensionResourceTests: XCTestCase {
    func testPowerAssertionIsReleasedOnExtensionUnload() {
        let id = "power-cleanup-test"
        let system = ExtensionSystem.shared
        defer { system.releaseKeepAwake(extensionID: id) }
        system.requestKeepAwake(level: "display", extensionID: id)
        XCTAssertTrue(system.hasKeepAwakeAssertion(extensionID: id))
        system.extensionUnloaded(id)
        XCTAssertFalse(system.hasKeepAwakeAssertion(extensionID: id))
        system.requestKeepAwake(level: "system", extensionID: id)
        XCTAssertTrue(system.hasKeepAwakeAssertion(extensionID: id))
        system.extensionUnloaded(id)
        XCTAssertFalse(system.hasKeepAwakeAssertion(extensionID: id))
    }

    func testNotificationIdentifiersAreNamespaced() {
        let a = ExtensionNotifications.storageID("same", extensionID: "extension-a")
        let b = ExtensionNotifications.storageID("same", extensionID: "extension-b")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(ExtensionNotifications.parse(storageID: a)?.id, "same")
        XCTAssertEqual(ExtensionNotifications.parse(storageID: a)?.extensionID, "extension-a")
        XCTAssertNil(ExtensionNotifications.parse(storageID: "website-notification"))
    }

    func testPausedDownloadShape() {
        let item = DownloadItem(filename: "file")
        item.chromeID = 42
        item.state = .failed(DownloadItem.pausedReason)
        XCTAssertEqual(ExtensionDownloads.chromeState(item), "in_progress")
        XCTAssertEqual(ExtensionDownloads.chromeItem(item)["paused"] as? Bool, true)
        item.state = .failed("Server failed")
        XCTAssertEqual(ExtensionDownloads.chromeState(item), "interrupted")
        XCTAssertEqual(ExtensionDownloads.chromeItem(item)["paused"] as? Bool, false)
        XCTAssertEqual(ExtensionDownloads.chromeItem(item)["error"] as? String, "Server failed")
    }

    func testExtensionDownloadFilenameAndConflictAction() throws {
        XCTAssertTrue(ExtensionDownloads.isValidFilename("folder/report.txt"))
        XCTAssertFalse(ExtensionDownloads.isValidFilename("../report.txt"))
        XCTAssertFalse(ExtensionDownloads.isValidFilename("/tmp/report.txt"))
        XCTAssertFalse(ExtensionDownloads.isValidFilename("folder//report.txt"))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tuff-downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = AppSettings.shared.downloads
        defer {
            AppSettings.shared.downloads = original
            try? FileManager.default.removeItem(at: folder)
        }
        var downloads = original
        downloads.folderPath = folder.path
        AppSettings.shared.downloads = downloads

        let item = DownloadItem(filename: "report.txt")
        item.requestedFilename = "nested/report.txt"
        item.conflictAction = .overwrite
        let destination = DownloadManager.preferredDestination(for: item, suggested: "other.txt")
        XCTAssertEqual(destination, folder.appendingPathComponent("nested/report.txt"))
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination)
        XCTAssertEqual(DownloadManager.preferredDestination(for: item, suggested: "other.txt"), destination)
        item.conflictAction = .uniquify
        XCTAssertEqual(DownloadManager.preferredDestination(for: item, suggested: "other.txt").lastPathComponent, "report 2.txt")
        item.conflictAction = .prompt
        item.saveLocation = .downloadsFolder
        XCTAssertTrue(DownloadManager.shouldAsk(for: item, destination: destination))
        item.conflictAction = .overwrite
        XCTAssertFalse(DownloadManager.shouldAsk(for: item, destination: destination))
        item.saveLocation = .ask
        XCTAssertTrue(DownloadManager.shouldAsk(for: item, destination: destination))
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

    func testCookiePathBoundariesEmptyPathsAndExactExpiry() {
        let now = Date()
        let scoped = cookie("path", domain: ".example.com", path: "/foo")
        let expired = cookie("expired", domain: ".example.com", expires: now)
        XCTAssertEqual(FaviconStore.cookies([scoped], for: URL(string: "https://example.com/foo")!).map(\.name), ["path"])
        XCTAssertEqual(FaviconStore.cookies([scoped], for: URL(string: "https://example.com/foo/bar")!).map(\.name), ["path"])
        XCTAssertEqual(FaviconStore.cookies([scoped], for: URL(string: "https://example.com/foobar")!).map(\.name), [])
        let root = cookie("root", domain: ".example.com")
        XCTAssertEqual(FaviconStore.cookies([root], for: URL(string: "https://example.com")!).map(\.name), ["root"])
        XCTAssertEqual(FaviconStore.cookies([scoped], for: URL(string: "https://example.com")!).map(\.name), [])
        XCTAssertEqual(FaviconStore.cookies([expired], for: URL(string: "https://example.com/")!, now: now).map(\.name), [])
        XCTAssertEqual(FaviconStore.cookies([scoped], for: URL(string: "https://other.example.org/foo")!).map(\.name), [])
    }
}

/// Parsing for the extension APIs Tuff implements itself.
final class ExtensionAPITests: XCTestCase {
    func testNativeAPIPermissionPolicy() {
        for (namespace, permission) in ["history": "history", "downloads": "downloads", "management": "management", "browsingData": "browsingData"] {
            XCTAssertEqual(ExtensionAPIPermissions.required(namespace: namespace, method: "deleteAll"), permission)
        }
        XCTAssertEqual(ExtensionAPIPermissions.required(namespace: "settings", method: "set", args: ["path": "proxy.settings"]), "proxy")
        XCTAssertEqual(ExtensionAPIPermissions.required(namespace: "settings", method: "set", args: ["path": "privacy.services.safeBrowsingEnabled"]), "privacy")
        XCTAssertEqual(ExtensionAPIPermissions.required(namespace: "notifications", method: "getAll"), "notifications")
        XCTAssertEqual(ExtensionAPIPermissions.required(namespace: "userScripts", method: "register"), "userScripts")
        XCTAssertEqual(ExtensionAPIPermissions.required(namespace: "__events", method: "subscribe", args: ["event": "history.onVisited"]), "history")
        XCTAssertNil(ExtensionAPIPermissions.required(namespace: "__events", method: "subscribe", args: ["event": "tabs.onZoomChange"]))
        XCTAssertNil(ExtensionAPIPermissions.required(namespace: "tabs", method: "extras"))
    }

    func testContentSettingsPatterns() throws {
        XCTAssertNil(try ExtensionContentSettings.parse("<all_urls>"))
        XCTAssertNil(try ExtensionContentSettings.parse("*://*/*"))
        let site = try XCTUnwrap(try ExtensionContentSettings.parse("https://*.Example.com/*"))
        XCTAssertEqual(site.scheme, "https")
        XCTAssertEqual(site.host, "*.example.com")
        XCTAssertTrue(site.matches(URL(string: "https://example.com/a")))
        XCTAssertTrue(site.matches(URL(string: "https://mail.example.com/a")))
        XCTAssertFalse(site.matches(URL(string: "http://mail.example.com/a")))
        let wildcard = try XCTUnwrap(try ExtensionContentSettings.parse("*://example.org:8080/"))
        XCTAssertEqual(wildcard.scheme, "*")
        XCTAssertEqual(wildcard.port, "8080")
        XCTAssertTrue(wildcard.matches(URL(string: "http://example.org:8080/a")))
        XCTAssertTrue(wildcard.matches(URL(string: "https://example.org:8080/a")))
        XCTAssertFalse(wildcard.matches(URL(string: "https://example.org:8443/a")))
        XCTAssertFalse(wildcard.matches(URL(string: "https://sub.example.org:8080/a")))
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

    func testDynamicScriptGlobConversion() {
        let include = ExtensionContentScripts.globRegex("https://*.example.com/path/*")
        let exclude = ExtensionContentScripts.globRegex("*secret?")
        XCTAssertNotNil(try? NSRegularExpression(pattern: include))
        let url = "https://sub.example.com/path/file"
        XCTAssertTrue((try? NSRegularExpression(pattern: include))?.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil)
        XCTAssertEqual(exclude, "^.*secret.$")
    }

    func testProxyConfigs() throws {
        XCTAssertNil(try ExtensionSettings.proxyConfigurations(for: ["mode": "system"]))
        XCTAssertNotNil(try ExtensionSettings.proxyConfigurations(for: ["mode": "direct"]))
        XCTAssertNotNil(try ExtensionSettings.proxyConfigurations(for: ["proxyType": "none"]))
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
        XCTAssertNotNil(try ExtensionSettings.proxyConfigurations(for: ["mode": "fixed_servers", "rules": ["singleProxy": ["scheme": "socks4", "host": "x"]]]))
        XCTAssertNotNil(try ExtensionSettings.proxyConfigurations(for: ["proxyType": "manual", "socks": "x:1", "socksVersion": 4]))
        XCTAssertThrowsError(try ExtensionSettings.proxyConfigurations(for: ["mode": "fixed_servers", "rules": ["singleProxy": ["scheme": "quic", "host": "x"]]]))
        XCTAssertThrowsError(try ExtensionSettings.proxyConfigurations(for: ["mode": "bogus"]))
    }

    func testDeclarativeContentURLFilters() {
        let url = URL(string: "https://docs.example.com:8443/guide/intro?lang=en#top")!
        let match = { ExtensionDeclarativeContent.urlMatches(url, $0) }
        XCTAssertTrue(match([:]))
        XCTAssertTrue(match(["hostSuffix": "example.com", "schemes": ["https"]]))
        XCTAssertTrue(match(["hostEquals": "docs.example.com", "pathPrefix": "/guide"]))
        XCTAssertTrue(match(["hostContains": ".example."]))
        XCTAssertTrue(match(["queryContains": "lang=en", "urlSuffix": "lang=en"]))  // the fragment isn't part of the URL
        XCTAssertTrue(match(["ports": [80, [8000, 9000]]]))
        XCTAssertTrue(match(["urlMatches": "^https://docs\\.example\\.com"]))
        XCTAssertTrue(match(["originAndPathMatches": "example\\.com:8443/guide/"]))
        XCTAssertFalse(match(["hostSuffix": "example.org"]))
        XCTAssertFalse(match(["hostSuffix": "example.com", "schemes": ["http"]]))
        XCTAssertFalse(match(["ports": [443]]))
        XCTAssertFalse(match(["pathEquals": "/guide"]))
        XCTAssertEqual(ExtensionAPIPermissions.required(namespace: "declarativeContent", method: "addRules"), "declarativeContent")
        XCTAssertEqual(ExtensionAPIPermissions.required(namespace: "bookmarks", method: "create"), "bookmarks")
        XCTAssertNil(ExtensionAPIPermissions.required(namespace: "i18n", method: "detectLanguage"))
    }
}

final class HistoryStoreTests: XCTestCase {
    func testVisitsAreRetainedAndProfilesAreIndependent() throws {
        let original = AppSettings.shared.privacy
        var privacy = original
        privacy.saveHistory = true
        AppSettings.shared.privacy = privacy
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tuff-history-\(UUID().uuidString)")
        var store: HistoryStore! = HistoryStore(file: file, loadInBackground: false)
        defer {
            store = nil
            AppSettings.shared.privacy = original
            try? FileManager.default.removeItem(at: file)
        }
        let home = UUID()
        let school = UUID()
        let url = URL(string: "https://example.com/page")!
        store.record(url: url, title: "Example", profileID: home)
        store.record(url: url, title: "Example", profileID: home)
        store.record(url: url, title: "School example", profileID: school)

        XCTAssertEqual(store.chromeVisits(for: url, profileID: home).count, 2)
        XCTAssertEqual(store.chromeVisits(for: url, profileID: school).count, 1)
        XCTAssertEqual(store.browse(HistoryStore.Filter(), offset: 0, limit: 20, profileID: home).total, 2)
        XCTAssertEqual(store.browse(HistoryStore.Filter(), offset: 0, limit: 20, profileID: school).total, 1)
        store.deleteUrl(url, profileID: home)
        XCTAssertEqual(store.chromeVisits(for: url, profileID: home).count, 0)
        XCTAssertEqual(store.chromeVisits(for: url, profileID: school).count, 1)

        store.saveNow(synchronously: true)
        let saved = try JSONDecoder().decode([HistoryEntry].self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.profileID, school)
    }

    func testDeletingARangeKeepsVisitsOutsideIt() {
        let original = AppSettings.shared.privacy
        var privacy = original
        privacy.saveHistory = true
        AppSettings.shared.privacy = privacy
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tuff-history-\(UUID().uuidString)")
        var store: HistoryStore! = HistoryStore(file: file, loadInBackground: false)
        defer {
            store = nil
            AppSettings.shared.privacy = original
            try? FileManager.default.removeItem(at: file)
        }
        let profile = UUID()
        let url = URL(string: "https://example.com/repeated")!
        let yesterday = Date().addingTimeInterval(-86400)
        let today = Date()
        store.merge([HistoryEntry(url: url, title: "Repeated", lastVisit: today, visits: 2, visitDates: [yesterday, today])], profileID: profile)
        store.deleteRange(startTime: today.addingTimeInterval(-1).timeIntervalSince1970 * 1000, endTime: today.addingTimeInterval(1).timeIntervalSince1970 * 1000, profileID: profile)
        let visits = store.chromeVisits(for: url, profileID: profile)
        XCTAssertEqual(visits.count, 1)
        XCTAssertEqual(visits.first?["visitTime"] as? Double, yesterday.timeIntervalSince1970 * 1000)
        XCTAssertEqual(store.browse(HistoryStore.Filter(), offset: 0, limit: 20, profileID: profile).total, 1)
        store.deleteVisit(url: url, at: yesterday.timeIntervalSince1970 * 1000, profileID: profile)
        XCTAssertEqual(store.chromeVisits(for: url, profileID: profile).count, 0)
    }
}

final class SitePermissionDecisionTests: XCTestCase {
    func testCombinedCaptureAndIncognitoInheritance() {
        let permissions = SitePermissions.shared
        let origin = "https://\(UUID().uuidString).example"
        XCTAssertNil(permissions.decision(origin: origin, kind: .cameraAndMicrophone, incognito: false))
        permissions.record(origin: origin, kind: .camera, granted: false, remember: false, incognito: false)
        permissions.record(origin: origin, kind: .microphone, granted: false, remember: false, incognito: false)
        XCTAssertEqual(permissions.decision(origin: origin, kind: .cameraAndMicrophone, incognito: false), false)
        XCTAssertEqual(permissions.decision(origin: origin, kind: .camera, incognito: true), false)

        let allowed = "https://\(UUID().uuidString).example"
        permissions.record(origin: allowed, kind: .camera, granted: true, remember: false, incognito: false)
        XCTAssertNil(permissions.decision(origin: allowed, kind: .camera, incognito: true))
        permissions.record(origin: allowed, kind: .camera, granted: true, remember: true, incognito: true)
        XCTAssertEqual(permissions.decision(origin: allowed, kind: .camera, incognito: true), true)
    }

    func testPerSiteSettings() {
        let permissions = SitePermissions.shared
        let origin = "https://\(UUID().uuidString).example"
        defer { permissions.removeAll(origin: origin) }
        XCTAssertEqual(permissions.setting(origin: origin, kind: .camera, incognito: false), .ask)

        // Each device is set on its own; a request for both needs both allowed.
        permissions.set(.allow, origin: origin, kind: .camera, incognito: false)
        XCTAssertEqual(permissions.setting(origin: origin, kind: .camera, incognito: false), .allow)
        XCTAssertNil(permissions.decision(origin: origin, kind: .cameraAndMicrophone, incognito: false))
        permissions.set(.allow, origin: origin, kind: .microphone, incognito: false)
        XCTAssertEqual(permissions.decision(origin: origin, kind: .cameraAndMicrophone, incognito: false), true)
        permissions.set(.deny, origin: origin, kind: .camera, incognito: false)
        XCTAssertEqual(permissions.decision(origin: origin, kind: .cameraAndMicrophone, incognito: false), false)

        // Ask forgets the answer, including one given only for this session.
        permissions.record(origin: origin, kind: .location, granted: true, remember: false, incognito: false)
        XCTAssertEqual(permissions.setting(origin: origin, kind: .location, incognito: false), .allow)
        permissions.set(.ask, origin: origin, kind: .location, incognito: false)
        XCTAssertNil(permissions.decision(origin: origin, kind: .location, incognito: false))

        // A setting replaces a session answer that disagrees with it.
        permissions.record(origin: origin, kind: .notifications, granted: false, remember: false, incognito: false)
        permissions.set(.allow, origin: origin, kind: .notifications, incognito: false)
        XCTAssertEqual(permissions.decision(origin: origin, kind: .notifications, incognito: false), true)

        // A camera-and-microphone answer is kept for each device.
        let both = "https://\(UUID().uuidString).example"
        defer { permissions.removeAll(origin: both) }
        permissions.record(origin: both, kind: .cameraAndMicrophone, granted: true, remember: true, incognito: false)
        XCTAssertEqual(permissions.setting(origin: both, kind: .camera, incognito: false), .allow)
        XCTAssertEqual(permissions.setting(origin: both, kind: .microphone, incognito: false), .allow)
        XCTAssertTrue(permissions.origins.contains(both))

        // Incognito's settings stay there; it inherits Deny but not Allow.
        permissions.set(.allow, origin: both, kind: .location, incognito: true)
        XCTAssertEqual(permissions.setting(origin: both, kind: .location, incognito: true), .allow)
        XCTAssertEqual(permissions.setting(origin: both, kind: .location, incognito: false), .ask)
        XCTAssertEqual(permissions.setting(origin: both, kind: .camera, incognito: true), .ask)
        XCTAssertEqual(permissions.setting(origin: origin, kind: .camera, incognito: true), .deny)
        permissions.forgetIncognito()
    }

    func testOriginOfAddress() {
        XCTAssertEqual(SitePermissions.origin(of: URL(string: "https://Example.com/a?b")), "https://example.com")
        XCTAssertEqual(SitePermissions.origin(of: URL(string: "http://example.com:8080/")), "http://example.com:8080")
        XCTAssertEqual(SitePermissions.origin(of: URL(string: "https://example.com:443/")), "https://example.com")
        XCTAssertNil(SitePermissions.origin(of: URL(string: "about:blank")))
    }
}

private final class PageWaiter: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation
    init(_ loaded: XCTestExpectation) { self.loaded = loaded }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
}

final class BrowserRegressionTests: XCTestCase {
    func testAllowlistIsRecordedBeforeBlockerListsActivate() {
        let blocker = ContentBlocker.shared
        let controller = WKUserContentController()
        let original = AppSettings.shared.privacy
        defer {
            AppSettings.shared.privacy = original
            blocker.prepare(controller, for: URL(string: "https://outside.example")!)
        }
        var privacy = original
        privacy.blockAds = true
        privacy.adBlockAllowlist = ["allowed.example"]
        AppSettings.shared.privacy = privacy
        blocker.prepare(controller, for: URL(string: "https://allowed.example")!)
        XCTAssertTrue(blocker.isSkipping(controller))
        blocker.prepare(controller, for: URL(string: "https://outside.example")!)
        XCTAssertFalse(blocker.isSkipping(controller))
    }

    func testDelayedHistoryWriteCannotOverwriteNewerState() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tuff-history-writer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let writer = HistoryWriter(label: "test.history-writer-\(UUID().uuidString)")
        let started = expectation(description: "old write started")
        let release = DispatchSemaphore(value: 0)
        writer.write {
            started.fulfill()
            _ = release.wait(timeout: .now() + 2)
            try? Data("old".utf8).write(to: file, options: .atomic)
        }
        wait(for: [started], timeout: 1)
        writer.write { try? Data("new".utf8).write(to: file, options: .atomic) }
        release.signal()
        writer.write(synchronously: true) {}
        XCTAssertEqual(String(decoding: try Data(contentsOf: file), as: UTF8.self), "new")
    }

    func testIncognitoDownloadsHideAndRejectPersistentTorrentState() {
        let browser = BrowserState.makeIncognito()
        let loaded = expectation(description: "private downloads state")
        DownloadsWebPage.handle("dl.state", [:], browser: browser) { value, error in
            let state = value as? [String: Any]
            XCTAssertNil(error)
            XCTAssertEqual((state?["torrents"] as? [[String: Any]])?.count, 0)
            XCTAssertEqual((state?["events"] as? [[String: Any]])?.count, 0)
            XCTAssertEqual((state?["pending"] as? [[String: Any]])?.count, 0)
            XCTAssertEqual(state?["torrentsEnabled"] as? Bool, false)
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 1)
        let rejected = expectation(description: "private torrent command rejected")
        DownloadsWebPage.handle("dl.torrent", ["action": "pause", "id": "not-present"], browser: browser) { value, error in
            XCTAssertNil(value)
            XCTAssertEqual(error, "Torrents aren’t available in Incognito")
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 1)
    }

    @MainActor
    func testUnsavedInputIncludesOrdinaryFieldsAndContenteditable() async {
        let loaded = expectation(description: "editor page loaded")
        let waiter = PageWaiter(loaded)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Tab.installUnsavedInputTracking(into: configuration.userContentController)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = waiter
        view.loadHTMLString("<input value='default'><div id='editor' contenteditable='true'>Initial</div>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 2)

        func run(_ source: String) async {
            await withCheckedContinuation { continuation in
                view.evaluateJavaScript(source, in: nil, in: .page) { _ in continuation.resume() }
            }
        }
        func dirty() async -> Bool {
            await withCheckedContinuation { continuation in
                view.evaluateJavaScript(Tab.unsavedInputScript, in: nil, in: WebEngine.scriptWorld) { result in
                    if case .success(let value) = result { continuation.resume(returning: (value as? Bool) ?? false) }
                    else { continuation.resume(returning: false) }
                }
            }
        }

        var value = await dirty()
        XCTAssertFalse(value)
        await run("document.querySelector('input').value = 'typed';")
        value = await dirty()
        XCTAssertTrue(value)
        await run("document.querySelector('input').value = 'default';")
        value = await dirty()
        XCTAssertFalse(value)

        await run("""
        var editor = document.getElementById('editor');
        editor.focus();
        editor.dispatchEvent(new InputEvent('beforeinput', { bubbles: true, inputType: 'insertText' }));
        editor.innerHTML = 'Edited';
        editor.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText' }));
        """)
        value = await dirty()
        XCTAssertTrue(value)
        await run("""
        var editor = document.getElementById('editor');
        editor.innerHTML = 'Initial';
        editor.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContentBackward' }));
        """)
        value = await dirty()
        XCTAssertFalse(value)
        view.navigationDelegate = nil
    }
}


final class ContentBlockerFilterTests: XCTestCase {
    private func lists(_ filters: String) throws -> [[[String: Any]]] {
        let result = FilterListParser.parse([filters], validSelectors: { Set($0) })
        return try result.lists.map { source in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(source.utf8)) as? [[String: Any]])
        }
    }

    /// Every list's rules, in order.
    private func rules(_ filters: String) throws -> [[String: Any]] {
        try lists(filters).flatMap { $0 }
    }

    private func type(_ rule: [String: Any]) -> String? {
        (rule["action"] as? [String: Any])?["type"] as? String
    }

    private func trigger(_ rule: [String: Any]) -> [String: Any]? {
        rule["trigger"] as? [String: Any]
    }

    func testNetworkDomainExclusionDoesNotProduceAnInvalidTrigger() throws {
        let rules = try rules("||ads.example.test^$script,domain=news.example|~allowed.news.example")
        for rule in rules {
            let trigger = try XCTUnwrap(trigger(rule))
            XCTAssertFalse(trigger["if-domain"] != nil && trigger["unless-domain"] != nil)
        }
        let block = try XCTUnwrap(rules.first { ($0["action"] as? [String: Any])?["type"] as? String == "block" })
        XCTAssertEqual(trigger(block)?["if-domain"] as? [String], ["*news.example"])
        let exception = try XCTUnwrap(rules.first { ($0["action"] as? [String: Any])?["type"] as? String == "ignore-previous-rules" })
        XCTAssertEqual(trigger(exception)?["if-domain"] as? [String], ["*allowed.news.example"])
    }

    func testSpecificCosmeticExceptionOnlyCancelsTheNamedDomain() throws {
        let rules = try rules("""
        a.example,b.example##.advert
        a.example#@#.advert
        """)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(trigger(rules[0])?["if-domain"] as? [String], ["*b.example"])
    }

    func testCosmeticExclusionUsesOnlyOneWebKitDomainCondition() throws {
        let rules = try rules("a.example,~allowed.a.example##.advert")
        XCTAssertEqual(rules.count, 1)
        let trigger = try XCTUnwrap(trigger(rules[0]))
        XCTAssertNil(trigger["if-domain"])
        XCTAssertEqual(trigger["unless-domain"] as? [String], ["*allowed.a.example"])
        XCTAssertTrue((trigger["url-filter"] as? String)?.contains("a\\.example") == true)
    }

    func testGenericCosmeticExceptionRestoresItsExcludedSubdomain() throws {
        let rules = try rules("""
        ##.advert
        a.example,~allowed.a.example#@#.advert
        """)
        XCTAssertEqual(rules.count, 2)
        let generic = try XCTUnwrap(rules.first { trigger($0)?["unless-domain"] != nil })
        XCTAssertEqual(trigger(generic)?["unless-domain"] as? [String], ["*a.example"])
        let restored = try XCTUnwrap(rules.first { trigger($0)?["if-domain"] != nil })
        XCTAssertEqual(trigger(restored)?["if-domain"] as? [String], ["*allowed.a.example"])
    }

    /// Site-bound hiding fires on document loads only: as `url-filter: .*` rules on every load,
    /// each subresource a page fetched ran through all of them (Speedometer NewsSite, 3.5×).
    func testSiteBoundHidingOnlyTriggersOnDocumentLoads() throws {
        let rules = try rules("""
        news.example##.advert
        a.example,~allowed.a.example##.banner
        ##.sponsor
        b.example#@#.sponsor
        ##.plain
        """)
        let hiding = rules.filter { type($0) == "css-display-none" && trigger($0)?.count ?? 0 > 1 }
        XCTAssertEqual(hiding.count, 3)
        for rule in hiding {
            XCTAssertEqual(trigger(rule)?["resource-type"] as? [String], ["document"])
        }
        // Unconditional generic hiding stays untouched (one shared style sheet per process).
        let generic = try XCTUnwrap(rules.first { type($0) == "css-display-none" && trigger($0)?.count == 1 })
        XCTAssertNil(trigger(generic)?["resource-type"])
    }

    func testUnsupportedEntityDomainCannotWidenRuleToEverySite() throws {
        let networkRules = try rules("*$script,1p,domain=~kat.ai|kat.*|kickass.*")
        XCTAssertTrue(networkRules.isEmpty)
        let cosmetic = try rules("kat.*,~allowed.example##.advert")
        XCTAssertTrue(cosmetic.isEmpty)
    }

    func testMixedDomainFiltersCompileInWebKit() throws {
        let result = FilterListParser.parse(["""
        ||ads.example.test^$script,domain=news.example|~allowed.news.example
        a.example,~allowed.a.example##.advert
        ##.advert
        ##.banner
        a.example,~allowed.a.example#@#.advert
        @@||quiet.example^$generichide
        """], validSelectors: { Set($0) })
        XCTAssertEqual(result.lists.count, 2)
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        for source in result.lists {
            let id = "test.\(UUID().uuidString)"
            let compiled = expectation(description: "content rules compiled")
            store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: source) { list, error in
                XCTAssertNil(error)
                XCTAssertNotNil(list)
                store.removeContentRuleList(forIdentifier: id) { _ in compiled.fulfill() }
            }
            wait(for: [compiled], timeout: 10)
        }
    }

    /// Generic hiding stays free of conditions (so WebKit makes it one shared style sheet), in a
    /// list of its own where `$generichide` can switch it off without touching network blocking.
    func testGenericHidingIsUnconditionalInAListOfItsOwn() throws {
        let lists = try lists("""
        ##.banner
        ||ads.example^
        @@||quiet.example^$generichide
        """)
        let generic = try XCTUnwrap(lists.first { list in list.contains { type($0) == "css-display-none" } })
        let hiding = try XCTUnwrap(generic.first { type($0) == "css-display-none" })
        XCTAssertEqual(trigger(hiding)?.count, 1)
        XCTAssertEqual(trigger(hiding)?["url-filter"] as? String, ".*")
        let off = try XCTUnwrap(generic.last)
        XCTAssertEqual(type(off), "ignore-previous-rules")
        XCTAssertEqual(trigger(off)?["if-domain"] as? [String], ["*quiet.example"])
        XCTAssertFalse(generic.contains { type($0) == "block" })
        XCTAssertTrue(lists.contains { list in list.contains { type($0) == "block" } })
    }

    func testGenericSelectorsReadingStyleAboveTheSubjectAreLeftOut() throws {
        for selector in [
            "html[lang] > body:not([style]) > div.captchaBody",
            ".wp-singular > div[data-sm][style*=\"2147483647\"] > iframe",
            "[STYLE] ~ div",
            "div:has([style])",
            ":not(.a [style]) .b",
        ] {
            XCTAssertTrue(FilterListParser.readsStyleAttributeAboveSubject(selector), selector)
        }
        for selector in [
            "div[style=\"position: fixed; inset: 0px; z-index: 2147483647;\"]",
            "[class^=\"div-gpt-ad\"]:not([style^=\"width: 1px; height: 1px; position: absolute;\"])",
            "#kt_player > div[style$=\"display: block;\"][style*=\"inset: 0px;\"]",
            ".ad > .banner",
            "a[href*=\"style\"] > img",
        ] {
            XCTAssertFalse(FilterListParser.readsStyleAttributeAboveSubject(selector), selector)
        }
        let rules = try rules("""
        ##body:not([style]) > .gate
        ##.banner
        """)
        let selectors = rules.compactMap { ($0["action"] as? [String: Any])?["selector"] as? String }
        XCTAssertEqual(selectors, [".banner"])
    }

    /// In WebKit itself: generic hiding applies to an ordinary page and not to a `$generichide` one.
    func testGenericHidingAppliesExceptOnGenerichideSites() throws {
        let result = FilterListParser.parse(["""
        ##.banner
        @@||quiet.example^$generichide
        """], validSelectors: { Set($0) })
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        var compiled: [(id: String, list: WKContentRuleList)] = []
        for source in result.lists {
            let id = "test.\(UUID().uuidString)"
            let done = expectation(description: "compiled")
            store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: source) { list, error in
                XCTAssertNil(error)
                if let list { compiled.append((id, list)) }
                done.fulfill()
            }
            wait(for: [done], timeout: 10)
        }
        defer {
            for entry in compiled { store.removeContentRuleList(forIdentifier: entry.id) { _ in } }
        }
        func display(on host: String) -> String? {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            for entry in compiled { configuration.userContentController.add(entry.list) }
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
            let loaded = expectation(description: "loaded \(host)")
            let waiter = PageWaiter(loaded)
            view.navigationDelegate = waiter
            view.loadHTMLString("<div class='banner'>ad</div>", baseURL: URL(string: "https://\(host)/")!)
            wait(for: [loaded], timeout: 10)
            var value: String?
            let read = expectation(description: "read \(host)")
            view.evaluateJavaScript("getComputedStyle(document.querySelector('.banner')).display") { result, _ in
                value = result as? String
                read.fulfill()
            }
            wait(for: [read], timeout: 10)
            view.navigationDelegate = nil
            return value
        }
        XCTAssertEqual(display(on: "news.example"), "none")
        XCTAssertEqual(display(on: "www.quiet.example"), "block")
    }

    func testProceduralRulesKeepTheirExceptionsWhenReindexed() throws {
        let input: [String: Any] = [
            "selectors": [".plain", "{\"selector\":\".one\"}", "{\"selector\":\".two\"}"],
            "selectorLists": ["0,1,-2", "2", "0"],
            "selectorListRefs": ["0", "1"],
            "hostnames": ["a.example", "b.example"],
            "regexes": [],
            "hasEntities": false,
        ]
        let output = try XCTUnwrap(AdvancedContentBlocker.proceduralOnly(JSONSerialization.data(withJSONObject: input)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(object["selectors"] as? [String], ["{\"selector\":\".one\"}", "{\"selector\":\".two\"}"])
        XCTAssertEqual(object["selectorLists"] as? [String], ["0,-1", "1", ""])
    }

    /// The scriptlet bundles' data arrays become `JSON.parse` of a string, with the same values.
    func testScriptletDataLiteralsBecomeJSONParseWithTheSameValues() throws {
        let hosts = (0..<400).map { "host\($0).example" } + ["quote\"d", "back\\slash", "slash/"]
        let hostsJSON = String(data: try JSONSerialization.data(withJSONObject: hosts, options: [.withoutEscapingSlashes]), encoding: .utf8)!
        let source = """
        (function () {
        const scriptletHostnames = /* \(hosts.count) */ \(hostsJSON);
        const functionRefs = /* 2 */ [Math.min, Math.max];
        self.result = scriptletHostnames;
        })();
        """
        let compacted = AdvancedContentBlocker.compactingDataLiterals(source)
        XCTAssertTrue(compacted.contains("const scriptletHostnames = /* \(hosts.count) */ JSON.parse(\""))
        XCTAssertTrue(compacted.contains("const functionRefs = /* 2 */ [Math.min, Math.max];"))
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("var self = this;")
        context.evaluateScript(compacted)
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.objectForKeyedSubscript("result").toArray() as? [String], hosts)
    }

    /// The cosmetic script finds a host's procedural filters (minus its exceptions), and doesn't
    /// load uBO's engine at all for a host that has none.
    func testCosmeticScriptAppliesOnlyTheFramesHostsFilters() throws {
        let one = #"{\"selector\":\".one\"}"#, two = #"{\"selector\":\".two\"}"#, three = #"{\"selector\":\".three\"}"#
        let dataSet = """
        {"selectors":["\(one)","\(two)","\(three)"],"selectorLists":["0,1","-2","2"],"selectorListRefs":[0,1,2],
         "hostnames":["a.example","sub.a.example","shop.*"],"regexes":[],"hasEntities":true}
        """
        let api = """
        self.apiLoaded = true;
        self.ProceduralFiltererAPI = class {
          addDeclaratives(list) { self.applied = (self.applied || []).concat(list.map(f => f.selector)); }
          addProcedurals(list) { self.applied = (self.applied || []).concat(list.map(f => f.selector)); }
        };
        """
        let script = AdvancedContentBlocker.cosmeticScript(api: api, dataSets: [dataSet])
        func run(on host: String) throws -> (loaded: Bool, applied: [String]) {
            let context = try XCTUnwrap(JSContext())
            context.evaluateScript("""
            var self = this;
            var location = { hostname: '\(host)' };
            var document = { adoptedStyleSheets: [] };
            """)
            context.evaluateScript(script)
            XCTAssertNil(context.exception, host)
            let loaded = context.objectForKeyedSubscript("apiLoaded").toBool()
            let applied = (context.objectForKeyedSubscript("applied").toArray() as? [String]) ?? []
            return (loaded, applied.sorted())
        }
        XCTAssertEqual(try run(on: "a.example").applied, [".one", ".two"])
        // The subdomain's exception takes `.two` away again.
        XCTAssertEqual(try run(on: "www.sub.a.example").applied, [".one"])
        XCTAssertEqual(try run(on: "shop.co.uk").applied, [".three"])
        let elsewhere = try run(on: "other.example")
        XCTAssertFalse(elsewhere.loaded)
        XCTAssertEqual(elsewhere.applied, [])
    }

    @MainActor
    func testAdvancedScriptsFollowAllowlistAndGlobalSwitch() {
        let blocker = AdvancedContentBlocker()
        let controller = WKUserContentController()
        let original = AppSettings.shared.privacy
        defer {
            AppSettings.shared.privacy = original
            blocker.settingsChanged()
        }
        var privacy = original
        privacy.blockAds = true
        privacy.adBlockAllowlist = ["allowed.example"]
        AppSettings.shared.privacy = privacy
        blocker.activate(.init(main: "void 0;", isolated: "void 0;", cosmetic: "void 0;"))
        blocker.attach(controller)
        XCTAssertEqual(controller.userScripts.count, 3)
        blocker.prepare(controller, for: URL(string: "https://sub.allowed.example")!)
        XCTAssertEqual(controller.userScripts.count, 0)
        blocker.prepare(controller, for: URL(string: "https://outside.example")!)
        XCTAssertEqual(controller.userScripts.count, 3)
        privacy.blockAds = false
        AppSettings.shared.privacy = privacy
        blocker.settingsChanged()
        XCTAssertEqual(controller.userScripts.count, 0)
    }
}

/// `pageCapture.saveAsMHTML`: a Web Archive repacked as MHTML.
final class PageCaptureTests: XCTestCase {
    func testWebArchiveBecomesMHTML() throws {
        let archive: [String: Any] = [
            "WebMainResource": [
                "WebResourceURL": "https://example.com/", "WebResourceMIMEType": "text/html",
                "WebResourceTextEncodingName": "UTF-8", "WebResourceData": Data("<p>hi</p>".utf8),
            ],
            "WebSubresources": [
                ["WebResourceURL": "https://example.com/a.png", "WebResourceMIMEType": "image/png", "WebResourceData": Data([1, 2, 3])],
            ],
            "WebSubframeArchives": [[
                "WebMainResource": [
                    "WebResourceURL": "https://frame.example/", "WebResourceMIMEType": "text/html", "WebResourceData": Data("<b>f</b>".utf8),
                ],
                // Already in the parent: listed once.
                "WebSubresources": [
                    ["WebResourceURL": "https://example.com/a.png", "WebResourceMIMEType": "image/png", "WebResourceData": Data([1, 2, 3])],
                ],
            ]],
        ]
        let mhtml = try XCTUnwrap(ExtensionPageCapture.mhtml(from: archive, title: "Café"))
        XCTAssertTrue(mhtml.hasPrefix("From: <Saved by Tuff>\r\nSnapshot-Content-Location: https://example.com/\r\n"))
        XCTAssertTrue(mhtml.contains("Subject: =?utf-8?B?\(Data("Café".utf8).base64EncodedString())?="))
        XCTAssertTrue(mhtml.contains("Content-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\nContent-Location: https://example.com/\r\n\r\n\(Data("<p>hi</p>".utf8).base64EncodedString())"))
        XCTAssertEqual(mhtml.components(separatedBy: "Content-Location: https://example.com/a.png").count, 2)
        XCTAssertTrue(mhtml.contains("Content-Location: https://frame.example/"))
        let boundary = try XCTUnwrap(mhtml.range(of: "boundary=\"").map { mhtml[$0.upperBound...].prefix { $0 != "\"" } })
        XCTAssertEqual(mhtml.components(separatedBy: "--\(boundary)\r\n").count, 4)
        XCTAssertTrue(mhtml.hasSuffix("--\(boundary)--\r\n"))
    }
}

final class CommandShortcutTests: XCTestCase {
    func testFirefoxShortcutsBecomeWebKitKeys() throws {
        typealias Keys = ExtensionCommands.Keys
        XCTAssertEqual(try ExtensionCommands.parse("Ctrl+Shift+U"), Keys(key: "u", modifiers: [.command, .shift]))
        XCTAssertEqual(try ExtensionCommands.parse("MacCtrl+Alt+Comma"), Keys(key: ",", modifiers: [.control, .option]))
        XCTAssertEqual(try ExtensionCommands.parse("Command+Up"), Keys(key: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), modifiers: [.command]))
        XCTAssertEqual(try ExtensionCommands.parse("F5"), Keys(key: String(Character(UnicodeScalar(NSF5FunctionKey)!)), modifiers: []))
        XCTAssertEqual(try ExtensionCommands.parse(""), Keys(key: nil, modifiers: []))
        // Shift alone isn't enough, and unknown keys or modifiers are refused.
        XCTAssertThrowsError(try ExtensionCommands.parse("Shift+K"))
        XCTAssertThrowsError(try ExtensionCommands.parse("Ctrl+Escape"))
        XCTAssertThrowsError(try ExtensionCommands.parse("Hyper+K"))
    }
}

final class DebuggerKeyTests: XCTestCase {
    /// CDP key events name keys as the DOM does; AppKit wants Mac key codes and characters.
    func testDOMKeysBecomeAppKitKeys() {
        XCTAssertEqual(CDPKeys.code(forKey: "a"), "KeyA")
        XCTAssertEqual(CDPKeys.code(forKey: "7"), "Digit7")
        XCTAssertEqual(CDPKeys.code(forKey: "?"), "Slash")
        XCTAssertEqual(CDPKeys.code(forKey: "Enter"), "Enter")
        XCTAssertEqual(CDPKeys.macKeyCodes["KeyA"], 0x00)
        XCTAssertEqual(CDPKeys.macKeyCodes["Enter"], 0x24)
        XCTAssertEqual(CDPKeys.macKeyCodes["ArrowLeft"], 0x7B)
        XCTAssertEqual(CDPKeys.characters(forKey: "Enter"), "\r")
        XCTAssertEqual(CDPKeys.characters(forKey: "Backspace"), "\u{7F}")
        XCTAssertEqual(CDPKeys.characters(forKey: "ArrowUp"), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)))
        XCTAssertEqual(CDPKeys.characters(forKey: "x"), "x")
        // CDP's bits: Alt 1, Ctrl 2, Meta 4, Shift 8.
        XCTAssertEqual(CDPKeys.modifierFlags(4 | 8), [.command, .shift])
        XCTAssertEqual(CDPKeys.modifierFlags(1 | 2), [.option, .control])
    }
}

final class DebuggerBackgroundTabTests: XCTestCase {
    @MainActor
    private func loadHTML(_ html: String, in tab: Tab) async {
        let loaded = expectation(description: "tab loaded")
        let waiter = PageWaiter(loaded)
        let webView = tab.wake()
        let previousDelegate = webView.navigationDelegate
        webView.navigationDelegate = waiter
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.test/"))
        await fulfillment(of: [loaded], timeout: 5)
        webView.navigationDelegate = previousDelegate
    }

    @MainActor
    private func cdp(_ method: String, _ params: [String: Any] = [:], tabID: Int, extID: String = "bg-test") async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try ExtensionDebugger.shared.sendCommandForTesting(
                    tabID: tabID, extensionID: extID, method: method, params: params,
                    finish: { continuation.resume(returning: $0) },
                    fail: { continuation.resume(throwing: $0) }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    @MainActor
    private func eval(_ expression: String, tabID: Int, extID: String = "bg-test") async throws -> Any? {
        let response = try await cdp("Runtime.evaluate", ["expression": expression], tabID: tabID, extID: extID) as? [String: Any]
        return (response?["result"] as? [String: Any])?["value"]
    }

    @MainActor
    func testBackgroundTabTrustedInputFocusEmulationScreenshotsAndTeardown() async throws {
        let browser = BrowserState.makeIncognito()
        let viewport = NSSize(width: 820, height: 610)
        let mainWindow = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: viewport),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        mainWindow.isReleasedWhenClosed = false
        let stack = WebStackView(frame: NSRect(origin: .zero, size: viewport))
        mainWindow.contentView?.addSubview(stack)
        browser.window = mainWindow
        mainWindow.orderFront(nil)

        let tabA = browser.newTab(url: nil, select: true)
        let tabB = browser.newTab(url: nil, select: false)
        let tabID = 4242
        let extID = "bg-test-\(UUID().uuidString)"
        defer {
            try? ExtensionDebugger.shared.detachForTesting(tabID: tabID, extensionID: extID)
            tabA.tearDown()
            tabB.tearDown()
            mainWindow.orderOut(nil)
            mainWindow.close()
        }

        let htmlA = """
        <!doctype html><html><body style="margin:0;height:2000px;background:#fff">
        <button id="btn" style="position:fixed;left:20px;top:20px;width:120px;height:40px;border:0;background:#0f0">Go</button>
        <input id="inp" style="position:fixed;left:20px;top:80px;width:220px;height:30px">
        <canvas id="cv" width="100" height="100" style="position:fixed;left:20px;top:130px;background:#00ff00"></canvas>
        <div id="scroller" style="position:fixed;left:260px;top:130px;width:200px;height:150px;overflow:auto">
          <div style="height:1000px">Scrollable</div>
        </div>
        <div id="drop" style="position:fixed;left:260px;top:20px;width:160px;height:80px;background:#eee">Drop</div>
        <script>
        window.log = [];
        window.raf = 0;
        function tick() { window.raf++; requestAnimationFrame(tick); }
        requestAnimationFrame(tick);
        const btn = document.getElementById('btn');
        btn.addEventListener('mousemove', e => window.log.push('move:' + e.isTrusted + ':' + Math.round(e.clientX) + ',' + Math.round(e.clientY)));
        btn.addEventListener('click', e => {
          window.log.push('click:' + e.isTrusted + ':' + Math.round(e.clientX) + ',' + Math.round(e.clientY));
          const ctx = document.getElementById('cv').getContext('2d');
          ctx.fillStyle = '#ff0000';
          ctx.fillRect(0, 0, 100, 100);
        });
        const inp = document.getElementById('inp');
        inp.addEventListener('keydown', e => window.log.push('kd:' + e.isTrusted + ':' + e.key));
        inp.addEventListener('keyup', e => window.log.push('ku:' + e.isTrusted + ':' + e.key));
        inp.addEventListener('input', e => window.log.push('in:' + e.isTrusted + ':' + inp.value));
        document.getElementById('scroller').addEventListener('wheel', e => {
          window.log.push('wheel:' + e.isTrusted + ':' + Math.round(e.clientX) + ',' + Math.round(e.clientY));
        });
        const drop = document.getElementById('drop');
        drop.addEventListener('dragover', e => { e.preventDefault(); window.log.push('dragover:' + e.isTrusted); });
        drop.addEventListener('drop', e => { e.preventDefault(); window.log.push('drop:' + e.isTrusted + ':' + e.dataTransfer.getData('text/plain')); });
        </script>
        </body></html>
        """
        await loadHTML(htmlA, in: tabA)
        await loadHTML("<!doctype html><html><body><input id='b'></body></html>", in: tabB)
        let webA = try XCTUnwrap(tabA.webView)
        let webB = try XCTUnwrap(tabB.webView)

        // Show Tab A on screen first, attach debugger, enable focus emulation.
        stack.show(webA, animated: false)
        mainWindow.makeFirstResponder(webA)
        try ExtensionDebugger.shared.attachForTesting(tab: tabA, tabID: tabID, extensionID: extID)
        _ = try await cdp("Emulation.setFocusEmulationEnabled", ["enabled": true], tabID: tabID, extID: extID)
        XCTAssertTrue(tabA.isBusy)

        // Switch user to Tab B in the same window.
        browser.select(tabB)
        stack.show(webB, animated: false)
        mainWindow.makeFirstResponder(webB)

        // Tab A moved seamlessly to its off-screen backing window; Tab B stays active in mainWindow.
        XCTAssertTrue(browser.selectedTab === tabB)
        XCTAssertTrue(webB.window === mainWindow)
        XCTAssertTrue(mainWindow.firstResponder === webB)
        XCTAssertTrue(webA.window is DebuggerBackingWindow)
        XCTAssertEqual(ExtensionDebugger.shared.backingWindowCount, 1)

        // Focus emulation keeps background Tab A visible, focused, sized to viewport, and ticking rAF.
        let rafBefore = (try await eval("window.raf", tabID: tabID, extID: extID) as? NSNumber)?.intValue ?? 0
        try await Task.sleep(nanoseconds: 120_000_000)
        let rawState = try await eval("[document.visibilityState, document.hasFocus(), innerWidth, innerHeight, window.raf]", tabID: tabID, extID: extID)
        let state = try XCTUnwrap(rawState as? [Any])
        XCTAssertEqual(state[0] as? String, "visible")
        XCTAssertEqual((state[1] as? NSNumber)?.boolValue, true)
        XCTAssertEqual((state[2] as? NSNumber)?.intValue, Int(viewport.width))
        XCTAssertEqual((state[3] as? NSNumber)?.intValue, Int(viewport.height))
        XCTAssertGreaterThan((state[4] as? NSNumber)?.intValue ?? 0, rafBefore)

        // Trusted mouseMoved + mousePressed + mouseReleased on button (CSS 60, 40).
        _ = try await cdp("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": 60, "y": 40], tabID: tabID, extID: extID)
        _ = try await cdp("Input.dispatchMouseEvent", ["type": "mousePressed", "x": 60, "y": 40, "button": "left", "clickCount": 1], tabID: tabID, extID: extID)
        _ = try await cdp("Input.dispatchMouseEvent", ["type": "mouseReleased", "x": 60, "y": 40, "button": "left", "clickCount": 1], tabID: tabID, extID: extID)

        // Trusted mouseWheel inside #scroller (CSS 320, 180).
        _ = try await cdp("Input.dispatchMouseEvent", ["type": "mouseWheel", "x": 320, "y": 180, "deltaX": 0, "deltaY": 90], tabID: tabID, extID: extID)

        // Click #inp (CSS 80, 95), type 'a' via dispatchKeyEvent, then insertText 'bc', then ⌘A selectAll + replace.
        _ = try await cdp("Input.dispatchMouseEvent", ["type": "mousePressed", "x": 80, "y": 95, "button": "left", "clickCount": 1], tabID: tabID, extID: extID)
        _ = try await cdp("Input.dispatchMouseEvent", ["type": "mouseReleased", "x": 80, "y": 95, "button": "left", "clickCount": 1], tabID: tabID, extID: extID)
        _ = try await cdp("Input.dispatchKeyEvent", ["type": "keyDown", "key": "a", "text": "a"], tabID: tabID, extID: extID)
        _ = try await cdp("Input.dispatchKeyEvent", ["type": "keyUp", "key": "a"], tabID: tabID, extID: extID)
        _ = try await cdp("Input.insertText", ["text": "bc"], tabID: tabID, extID: extID)
        let typedValue = try await eval("document.getElementById('inp').value", tabID: tabID, extID: extID) as? String
        XCTAssertEqual(typedValue, "abc")
        _ = try await cdp("Input.dispatchKeyEvent", ["type": "rawKeyDown", "key": "a", "code": "KeyA", "modifiers": 4, "commands": ["selectAll"]], tabID: tabID, extID: extID)
        _ = try await cdp("Input.dispatchKeyEvent", ["type": "keyUp", "key": "a", "code": "KeyA", "modifiers": 4], tabID: tabID, extID: extID)
        _ = try await cdp("Input.insertText", ["text": "done"], tabID: tabID, extID: extID)
        let replacedValue = try await eval("document.getElementById('inp').value", tabID: tabID, extID: extID) as? String
        XCTAssertEqual(replacedValue, "done")

        // Trusted drag & drop onto #drop (CSS 320, 50).
        let dragData: [String: Any] = ["items": [["mimeType": "text/plain", "data": "payload"]], "dragOperationsMask": 1]
        _ = try await cdp("Input.dispatchDragEvent", ["type": "dragEnter", "x": 320, "y": 50, "data": dragData], tabID: tabID, extID: extID)
        _ = try await cdp("Input.dispatchDragEvent", ["type": "dragOver", "x": 320, "y": 50, "data": dragData], tabID: tabID, extID: extID)
        _ = try await cdp("Input.dispatchDragEvent", ["type": "drop", "x": 320, "y": 50, "data": dragData], tabID: tabID, extID: extID)

        // Verify all events were trusted and hit the exact coordinates, and Tab B never lost focus.
        let rawEvents = try await eval("window.log", tabID: tabID, extID: extID)
        let events = try XCTUnwrap(rawEvents as? [String])
        XCTAssertTrue(events.contains("move:true:60,40"), "Expected trusted mousemove, got \(events)")
        XCTAssertTrue(events.contains("click:true:60,40"), "Expected trusted click, got \(events)")
        XCTAssertTrue(events.contains("wheel:true:320,180"), "Expected trusted wheel, got \(events)")
        XCTAssertTrue(events.contains("kd:true:a"), "Expected trusted keydown, got \(events)")
        XCTAssertTrue(events.contains("ku:true:a"), "Expected trusted keyup, got \(events)")
        XCTAssertTrue(events.contains("in:true:abc"), "Expected trusted input, got \(events)")
        XCTAssertTrue(events.contains("dragover:true"), "Expected trusted dragover, got \(events)")
        XCTAssertTrue(events.contains("drop:true:payload"), "Expected trusted drop, got \(events)")
        let scrollTop = (try await eval("document.getElementById('scroller').scrollTop", tabID: tabID, extID: extID) as? NSNumber)?.doubleValue ?? 0
        XCTAssertGreaterThan(scrollTop, 0)
        XCTAssertTrue(browser.selectedTab === tabB)
        XCTAssertTrue(mainWindow.firstResponder === webB)

        // Screenshot captures the live red canvas updated by the background click without switching tabs.
        let rawShot = try await cdp("Page.captureScreenshot", ["format": "png"], tabID: tabID, extID: extID)
        let shot = try XCTUnwrap(rawShot as? [String: Any])
        let pngData = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(shot["data"] as? String)))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: pngData))
        let scale = Double(rep.pixelsWide) / Double(viewport.width)
        let pixel = try XCTUnwrap(rep.colorAt(x: Int(60 * scale), y: Int(170 * scale)))
        XCTAssertGreaterThan(pixel.redComponent, 0.9)
        XCTAssertLessThan(pixel.greenComponent, 0.1)
        XCTAssertTrue(browser.selectedTab === tabB)

        // Disabling focus emulation sets document.hasFocus() back to false in background.
        _ = try await cdp("Emulation.setFocusEmulationEnabled", ["enabled": false], tabID: tabID, extID: extID)
        let focusedAfterDisable = (try await eval("document.hasFocus()", tabID: tabID, extID: extID) as? NSNumber)?.boolValue
        XCTAssertEqual(focusedAfterDisable, false)

        // Switching back to Tab A seamlessly reparents it into mainWindow and closes the backing window.
        browser.select(tabA)
        stack.show(webA, animated: false)
        mainWindow.makeFirstResponder(webA)
        XCTAssertTrue(webA.window === mainWindow)
        XCTAssertEqual(ExtensionDebugger.shared.backingWindowCount, 0)
        let preservedValue = try await eval("document.getElementById('inp').value", tabID: tabID, extID: extID) as? String
        XCTAssertEqual(preservedValue, "done")

        // Switch away again, then detach: backing window is cleaned up and normal hidden state returns.
        browser.select(tabB)
        stack.show(webB, animated: false)
        XCTAssertEqual(ExtensionDebugger.shared.backingWindowCount, 1)
        try ExtensionDebugger.shared.detachForTesting(tabID: tabID, extensionID: extID)
        XCTAssertEqual(ExtensionDebugger.shared.backingWindowCount, 0)
        XCTAssertNil(webA.window)
        XCTAssertFalse(tabA.isBusy)

        // Wait for WebKit to flush its post-detach activity-state update to the web process.
        try await Task.sleep(nanoseconds: 150_000_000)
        let hiddenState: [Any] = await withCheckedContinuation { continuation in
            webA.evaluateJavaScript("[document.visibilityState, document.hasFocus()]") { result, _ in
                continuation.resume(returning: (result as? [Any]) ?? [])
            }
        }
        XCTAssertEqual(hiddenState.first as? String, "hidden")
        XCTAssertEqual((hiddenState.last as? NSNumber)?.boolValue, false)
    }

    @MainActor
    func testTabCloseCleansUpBackgroundDebuggerBackingWindow() async throws {
        let browser = BrowserState.makeIncognito()
        let tabA = browser.newTab(url: nil, select: true)
        let tabB = browser.newTab(url: nil, select: false)
        let tabID = 4243
        let extID = "bg-close-\(UUID().uuidString)"
        defer {
            tabA.tearDown()
            tabB.tearDown()
        }

        await loadHTML("<!doctype html><html><body>hi</body></html>", in: tabA)
        browser.select(tabB)
        try ExtensionDebugger.shared.attachForTesting(tab: tabA, tabID: tabID, extensionID: extID)
        XCTAssertEqual(ExtensionDebugger.shared.backingWindowCount, 1)

        ExtensionDebugger.shared.tabClosed(tabA)
        XCTAssertEqual(ExtensionDebugger.shared.backingWindowCount, 0)
        XCTAssertNil(tabA.webView?.window)
    }
}

final class SidePanelDownloadTests: XCTestCase {
    @MainActor
    func testBlobAnchorDownloadSavesFileInsteadOfNavigatingPanel() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("tuff-sidepanel-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let savedDownloads = AppSettings.shared.downloads
        AppSettings.shared.downloads.folderPath = tempDir.path
        AppSettings.shared.downloads.askWhereToSave = false
        AppSettings.shared.downloads.openSafeFiles = false
        AppSettings.shared.downloads.showPanelOnStart = false

        let manager = DownloadManager.shared
        let existingIDs = Set(manager.items.map(\.id))
        let host = SidePanelHost(extensionID: "test-panel", configuration: WKWebViewConfiguration(), url: URL(string: "about:blank")!)

        defer {
            host.tearDown()
            for item in manager.items where !existingIDs.contains(item.id) {
                manager.remove(item, deleteFile: true)
            }
            AppSettings.shared.downloads = savedDownloads
            try? FileManager.default.removeItem(at: tempDir)
        }

        host.webView.loadHTMLString("<!doctype html><html><body><div id='panel'>sidebar</div></body></html>", baseURL: nil)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let text = try? await host.webView.evaluateJavaScript("document.getElementById('panel')?.textContent") as? String
            if text == "sidebar" { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        _ = try await host.webView.evaluateJavaScript("""
            (() => {
              const blob = new Blob([JSON.stringify({ app: 'TuffAgent', ok: true })], { type: 'application/json' });
              const url = URL.createObjectURL(blob);
              const a = document.createElement('a');
              a.href = url;
              a.download = 'tuffagent-log.json';
              document.body.appendChild(a);
              a.click();
              a.remove();
              return true;
            })()
        """)

        var downloaded: DownloadItem?
        let dlDeadline = Date().addingTimeInterval(5)
        while Date() < dlDeadline {
            if let item = manager.items.first(where: { !existingIDs.contains($0.id) && $0.state == .finished }) {
                downloaded = item
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let item = try XCTUnwrap(downloaded, "Expected side panel blob anchor to complete a download")
        XCTAssertEqual(item.filename, "tuffagent-log.json")
        let destination = try XCTUnwrap(item.destination)
        XCTAssertEqual(destination.deletingLastPathComponent().standardizedFileURL, tempDir.standardizedFileURL)
        let contents = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(contents, #"{"app":"TuffAgent","ok":true}"#)

        // The side panel must stay on its own page rather than replacing itself with the JSON text.
        let panelText = try await host.webView.evaluateJavaScript("document.getElementById('panel')?.textContent") as? String
        XCTAssertEqual(panelText, "sidebar")
    }
}
