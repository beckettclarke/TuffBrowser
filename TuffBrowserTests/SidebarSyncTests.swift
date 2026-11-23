import XCTest
@testable import Tuff

/// Zen's sidebar sync (`SidebarSync`), with records shaped like the ones Zen uploads.
final class SidebarSyncTests: XCTestCase {
    typealias Record = SidebarSync.Record
    private let personal = UUID(), school = UUID()
    private var options: SidebarSync.Options { .init(syncProfile: personal, includeTabs: false) }

    private func record(_ id: String, _ kind: String, _ data: [String: Any]) -> Record { ["id": id, "kind": kind, "data": data] }

    private func zenTab(_ id: String, _ url: String, space: String?, folder: String? = nil, essential: Bool = false, pinned: Bool = true, container: String? = nil) -> Record {
        record(id, "tab", [
            "tabId": id, "url": url, "title": "Title of \(url)", "icon": "", "containerGuid": container as Any? ?? NSNull(),
            "essential": essential, "pinned": pinned, "workspaceUuid": space as Any? ?? NSNull(), "folderId": folder as Any? ?? NSNull(),
            "staticLabel": NSNull(), "hasStaticIcon": false, "defaultContainer": true,
        ])
    }

    /// Zen: Home (no container) with a pinned tab, a split and an unpinned tab; Science (School)
    /// with a folder holding a nested folder; one Essential.
    private func zenServer() -> [String: Record] {
        var s: [String: Record] = [:]
        s["c1"] = record("c1", "container", ["guid": "c1", "name": "School", "icon": "briefcase", "color": "cyan"])
        s["{home}"] = record("{home}", "space", [
            "uuid": "{home}", "name": "Home", "icon": "chrome://browser/skin/zen-icons/selectable/bookmark.svg",
            "theme": ["type": "gradient", "gradientColors": [["c": [1, 8, 29], "isPrimary": true]], "opacity": 0.5],
            "containerGuid": NSNull(), "children": ["t-a", "split1", "t-open"],
        ])
        s["{sci}"] = record("{sci}", "space", [
            "uuid": "{sci}", "name": "Science", "icon": "chrome://browser/skin/zen-icons/selectable/flask.svg",
            "theme": ["type": "gradient", "gradientColors": [], "opacity": 0.5], "containerGuid": "c1", "children": ["f1"],
        ])
        s["f1"] = record("f1", "folder", ["folderId": "f1", "name": "Labs", "icon": NSNull(), "workspaceUuid": "{sci}", "parentFolderId": NSNull(), "live": NSNull(), "children": ["t-lab", "f2"]])
        s["f2"] = record("f2", "folder", ["folderId": "f2", "name": "Old", "icon": NSNull(), "workspaceUuid": "{sci}", "parentFolderId": "f1", "live": NSNull(), "children": ["t-old"]])
        s["t-a"] = zenTab("t-a", "https://a.example/", space: "{home}")
        s["t-open"] = zenTab("t-open", "https://open.example/", space: "{home}", pinned: false)
        s["t-lab"] = zenTab("t-lab", "https://lab.example/", space: "{sci}", folder: "f1", container: "c1")
        s["t-old"] = zenTab("t-old", "https://old.example/", space: "{sci}", folder: "f2", container: "c1")
        s["t-ess"] = zenTab("t-ess", "https://mail.example/", space: nil, essential: true)
        s["split1"] = record("split1", "split", ["splitId": "split1", "tabs": ["x", "y"], "gridType": "vsep"])
        s["layout"] = record("layout", "layout", ["spaces": ["{home}", "{sci}"], "essentials": ["default": ["t-ess"]]])
        return s
    }

    /// Tuff: Home with a.example (already imported from Zen) and b.example; an Odd Days space;
    /// a School profile.
    private func tuffSidebar() -> SidebarSnapshot {
        SidebarSnapshot(
            profiles: [
                .init(id: personal, name: "Personal", icon: "person.fill", favorites: []),
                .init(id: school, name: "School", icon: "graduationcap.fill", favorites: []),
            ],
            spaces: [
                .init(id: UUID(), name: "Home", icon: "house.fill", colorHex: "#0E1A1C", profile: personal, pinned: [
                    .tab(.init(id: UUID(), url: "https://a.example", title: "A", customTitle: nil)),
                    .tab(.init(id: UUID(), url: "https://b.example/", title: "B", customTitle: "Bee")),
                ], tabs: []),
                .init(id: UUID(), name: "Odd Days", icon: "flask.fill", colorHex: "#111827", profile: personal, pinned: [], tabs: []),
            ]
        )
    }

    /// One sync the way `SyncManager.syncSpaces` runs it.
    @discardableResult
    private func sync(_ sidebar: inout SidebarSnapshot, server: inout [String: Record], memory: inout SidebarSync.Memory, last: [String: Record]?) -> SidebarSync.Merge {
        let base = last ?? [:]
        var incoming: [String: Record?] = [:]
        for (id, r) in server where SidebarSync.digest(r) != SidebarSync.digest(base[id]) { incoming[id] = .some(r) }
        for id in base.keys where server[id] == nil { incoming[id] = .some(nil) }
        if base.isEmpty { SidebarSync.match(sidebar, remote: server, memory: &memory, options: options) }
        let local = SidebarSync.project(sidebar, remote: server, memory: &memory, options: options)
        let merge = SidebarSync.merge(base: base, incoming: incoming, local: local, lastLocal: base.isEmpty ? [:] : memory.local, includeTabs: false)
        if !merge.remoteChanged.isEmpty, let plan = SidebarSync.plan(merge.merged, current: sidebar, memory: &memory, changed: merge.remoteChanged, options: options) {
            sidebar = plan
        }
        server = merge.merged
        SidebarSync.remember(sidebar, in: &memory)
        memory.local = SidebarSync.project(sidebar, remote: merge.merged, memory: &memory, options: options).compactMapValues { SidebarSync.digest($0) }
        return merge
    }

    func testFirstSyncWithZenMergesBothSidebars() throws {
        var sidebar = tuffSidebar(), server = zenServer(), memory = SidebarSync.Memory()
        let tuffHome = sidebar.spaces[0]
        let merge = sync(&sidebar, server: &server, memory: &memory, last: nil)

        // Home matched rather than doubled; Science arrived on the School profile.
        XCTAssertEqual(sidebar.spaces.map(\.name), ["Home", "Science", "Odd Days"])
        XCTAssertEqual(sidebar.spaces[0].id, tuffHome.id)
        XCTAssertEqual(sidebar.spaces[1].profile, school)
        let homeURLs = sidebar.spaces[0].pinned.compactMap { if case .tab(let t) = $0 { t.url } else { nil } }
        XCTAssertEqual(homeURLs.count, 2, "a.example matched, b.example kept")
        XCTAssertTrue(homeURLs.contains("https://b.example/"))
        // The nested folder shows after its parent; the Essential is a favourite.
        let folders = sidebar.spaces[1].pinned.compactMap { if case .folder(let f) = $0 { f.name } else { nil } }
        XCTAssertEqual(folders, ["Labs", "Old"])
        XCTAssertEqual(sidebar.profiles[0].favorites.map(\.url), ["https://mail.example/"])
        // Zen's space wins on a first sync: its colour comes across.
        XCTAssertEqual(sidebar.spaces[0].colorHex, "#01081D")

        // Uploaded: Tuff's new things only, as Zen-shaped records.
        let up = merge.uploads.compactMapValues { $0 }
        XCTAssertTrue(merge.uploads.values.allSatisfy { $0 != nil }, "nothing deleted")
        let bee = try XCTUnwrap(up.values.first { SidebarSync.data($0)?["url"] as? String == "https://b.example/" })
        XCTAssertEqual(SidebarSync.data(bee)?["workspaceUuid"] as? String, "{home}")
        XCTAssertEqual(SidebarSync.data(bee)?["staticLabel"] as? String, "Bee")
        XCTAssertEqual(SidebarSync.data(bee)?["pinned"] as? Bool, true)
        XCTAssertNotNil(up.values.first { SidebarSync.kind($0) == "space" && SidebarSync.data($0)?["name"] as? String == "Odd Days" })
        XCTAssertFalse(merge.uploads.keys.contains("{home}"), "Home itself didn't change here")
        XCTAssertFalse(merge.uploads.keys.contains("split1"))
        XCTAssertFalse(merge.uploads.keys.contains("t-open"))
    }

    func testANextSyncWithNoChangesSendsNothing() {
        var sidebar = tuffSidebar(), server = zenServer(), memory = SidebarSync.Memory()
        sync(&sidebar, server: &server, memory: &memory, last: nil)
        let last = server
        let again = sync(&sidebar, server: &server, memory: &memory, last: last)
        XCTAssertTrue(again.uploads.isEmpty, "\(again.uploads.keys.sorted())")
        XCTAssertTrue(again.remoteChanged.isEmpty)
    }

    func testChangesFromEitherSideGoAcross() throws {
        var sidebar = tuffSidebar(), server = zenServer(), memory = SidebarSync.Memory()
        sync(&sidebar, server: &server, memory: &memory, last: nil)

        // Zen renames Science; Tuff unpins b.example and renames the Labs folder.
        var last = server
        var sci = server["{sci}"]!["data"] as! [String: Any]
        sci["name"] = "Chemistry"
        server["{sci}"]!["data"] = sci
        let bee = sidebar.spaces[0].pinned.firstIndex { if case .tab(let t) = $0 { t.url == "https://b.example/" } else { false } }!
        let beeID = { if case .tab(let t) = sidebar.spaces[0].pinned[bee] { t.id } else { UUID() } }()
        sidebar.spaces[0].pinned.remove(at: bee)
        if case .folder(var labs) = sidebar.spaces[1].pinned[0] {
            labs.name = "Lab work"
            sidebar.spaces[1].pinned[0] = .folder(labs)
        }
        let merge = sync(&sidebar, server: &server, memory: &memory, last: last)

        XCTAssertEqual(sidebar.spaces[1].name, "Chemistry")
        let beeRecord = try XCTUnwrap(memory.ids[beeID])
        XCTAssertEqual(merge.uploads[beeRecord].map { $0 == nil }, true, "unpinning deletes the record")
        XCTAssertEqual(SidebarSync.data(merge.uploads["f1"].flatMap { $0 })?["name"] as? String, "Lab work")
        // Labs still lists its nested folder, which Tuff can't move.
        XCTAssertEqual(SidebarSync.data(merge.uploads["f1"].flatMap { $0 })?["children"] as? [String], ["t-lab", "f2"])
        XCTAssertFalse(merge.uploads.keys.contains("{sci}"))

        // Zen deletes the Essential and a space.
        last = server
        server["t-ess"] = nil
        server["{sci}"] = nil
        sync(&sidebar, server: &server, memory: &memory, last: last)
        XCTAssertTrue(sidebar.profiles[0].favorites.isEmpty)
        XCTAssertFalse(sidebar.spaces.contains { $0.name == "Chemistry" })
    }

    /// Home's children keep Zen's split and unpinned tab (which Tuff doesn't show) in place.
    func testWhatTuffCantShowStaysInPlace() throws {
        var sidebar = tuffSidebar(), server = zenServer(), memory = SidebarSync.Memory()
        sync(&sidebar, server: &server, memory: &memory, last: nil)
        let last = server
        sidebar.spaces[0].pinned.reverse()
        let merge = sync(&sidebar, server: &server, memory: &memory, last: last)
        let children = try XCTUnwrap(SidebarSync.data(merge.uploads["{home}"].flatMap { $0 })?["children"] as? [String])
        XCTAssertTrue(children.contains("split1"))
        XCTAssertTrue(children.contains("t-open"))
        XCTAssertEqual(children.filter { $0.hasPrefix("t-") || $0.contains("-") }.count, children.count - 1)
        // The space's gradient is Zen's still: only its order changed here.
        let theme = SidebarSync.data(merge.uploads["{home}"].flatMap { $0 })?["theme"] as? [String: Any]
        XCTAssertEqual(ZenTheme.hex(theme), "#01081D")
    }

    func testIconsAndThemesTranslate() {
        XCTAssertEqual(ZenIcons.symbol(forZen: "chrome://browser/skin/zen-icons/selectable/flask.svg"), "flask.fill")
        XCTAssertEqual(ZenIcons.zen(forSymbol: "graduationcap.fill"), "chrome://browser/skin/zen-icons/selectable/school.svg")
        XCTAssertNil(ZenIcons.symbol(forZen: "🍕"))
        XCTAssertEqual(ZenTheme.hex(ZenTheme.theme(hex: "#3E5266")), "#3E5266")
    }
}
