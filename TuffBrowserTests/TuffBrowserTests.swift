import AppKit
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
        XCTAssertThrowsError(try ExtensionSettings.proxyConfigurations(for: ["mode": "direct"]))
        XCTAssertThrowsError(try ExtensionSettings.proxyConfigurations(for: ["proxyType": "none"]))
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
                view.evaluateJavaScript(Tab.unsavedInputScript, in: nil, in: .defaultClient) { result in
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
    private func rules(_ filters: String) throws -> [[String: Any]] {
        let result = FilterListParser.parse([filters], validSelectors: { Set($0) })
        let source = try XCTUnwrap(result.lists.first)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(source.utf8)) as? [[String: Any]])
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
        a.example,~allowed.a.example#@#.advert
        """], validSelectors: { Set($0) })
        let source = try XCTUnwrap(result.lists.first)
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        let id = "test.\(UUID().uuidString)"
        let compiled = expectation(description: "content rules compiled")
        store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: source) { list, error in
            XCTAssertNil(error)
            XCTAssertNotNil(list)
            store.removeContentRuleList(forIdentifier: id) { _ in compiled.fulfill() }
        }
        wait(for: [compiled], timeout: 10)
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
