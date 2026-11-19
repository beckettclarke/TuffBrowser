import XCTest
@testable import Tuff

/// The bookmark store: finding pages, moving things around the tree, and saving.
final class BookmarkTests: XCTestCase {
    private var file: URL!
    private let profile = UUID()

    override func setUp() {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("bookmarks-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
    }

    func testAddFindAndSearch() {
        let store = BookmarkStore(file: file)
        store.add(url: URL(string: "https://example.com/")!, title: "Example", profile: profile)
        store.add(url: URL(string: "https://swift.org/docs")!, title: "Swift Docs", profile: profile)
        XCTAssertNotNil(store.bookmark(for: URL(string: "https://example.com")!, profile: profile))
        XCTAssertNil(store.bookmark(for: URL(string: "https://example.com")!, profile: UUID()))
        XCTAssertEqual(store.search("swift doc", limit: 5, profile: profile).map(\.title), ["Swift Docs"])
        XCTAssertTrue(store.search("nothing", limit: 5, profile: profile).isEmpty)
    }

    func testMoveReorderAndIntoFolders() {
        let store = BookmarkStore(file: file)
        let a = store.add(url: URL(string: "https://a.example")!, title: "A", profile: profile)
        let b = store.add(url: URL(string: "https://b.example")!, title: "B", profile: profile)
        let folder = store.addFolder(named: "F", profile: profile)
        let inner = store.addFolder(named: "Inner", profile: profile)

        store.move(b.id, into: nil, at: 0, profile: profile)
        XCTAssertEqual(store.items(for: profile).map(\.title), ["B", "A", "F", "Inner"])

        store.move(a.id, into: folder.id, at: nil, profile: profile)
        store.move(inner.id, into: folder.id, at: nil, profile: profile)
        XCTAssertEqual(store.items(for: profile).map(\.title), ["B", "F"])
        XCTAssertEqual(store.bookmark(withID: folder.id, profile: profile)?.children.map(\.title), ["A", "Inner"])

        // A folder can't go inside itself or a folder within it.
        store.move(folder.id, into: inner.id, at: nil, profile: profile)
        store.move(folder.id, into: folder.id, at: nil, profile: profile)
        XCTAssertEqual(store.items(for: profile).map(\.title), ["B", "F"])
        // Nor into a page.
        store.move(a.id, into: b.id, at: nil, profile: profile)
        XCTAssertEqual(store.bookmark(withID: folder.id, profile: profile)?.children.count, 2)

        XCTAssertEqual(store.bookmark(withID: folder.id, profile: profile)?.pages.map(\.title), ["A"])
        store.remove(folder.id, profile: profile)
        XCTAssertEqual(store.items(for: profile).map(\.title), ["B"])
    }

    func testUpdateAndSaveRoundTrip() {
        let store = BookmarkStore(file: file)
        let page = store.add(url: URL(string: "https://a.example")!, title: "A", profile: profile)
        store.update(page.id, title: "  Renamed ", url: URL(string: "https://b.example")!, profile: profile)
        let other = UUID()
        store.add(url: URL(string: "https://c.example")!, title: "C", profile: other)
        store.moveAll(from: other, to: profile)
        store.saveNow(synchronously: true)

        let reloaded = BookmarkStore(file: file)
        XCTAssertEqual(reloaded.items(for: profile).map(\.title), ["Renamed", "C"])
        XCTAssertEqual(reloaded.items(for: profile).first?.url, URL(string: "https://b.example"))
        XCTAssertTrue(reloaded.items(for: other).isEmpty)
    }

    func testWhatCanBeSaved() {
        XCTAssertTrue(Bookmark.canSave(URL(string: "https://example.com")))
        XCTAssertFalse(Bookmark.canSave(URL(string: "about:blank")))
        XCTAssertFalse(Bookmark.canSave(nil))
    }
}
