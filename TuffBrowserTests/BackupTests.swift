import XCTest
@testable import Tuff

/// Backup files: password protection, what a backup without open tabs keeps, cookies, and
/// refusing files that aren't backups.
final class BackupTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func testPasswordProtectionRoundTrip() throws {
        let plain = Data("PK-pretend-zip".utf8)
        let sealed = try BackupCrypto.seal(plain, password: "correct horse")
        XCTAssertTrue(BackupCrypto.isProtected(sealed))
        XCTAssertNil(sealed.range(of: plain), "the contents must not be readable in the file")
        XCTAssertEqual(try BackupCrypto.open(sealed, password: "correct horse"), plain)
    }

    func testWrongPasswordIsRefused() throws {
        let sealed = try BackupCrypto.seal(Data("secret".utf8), password: "one")
        XCTAssertThrowsError(try BackupCrypto.open(sealed, password: "two")) { error in
            guard case BackupError.wrongPassword = error else { return XCTFail("\(error)") }
        }
    }

    func testSessionWithoutOpenTabsKeepsSpacesAndPinned() throws {
        let session = """
        {"spaces":[{"id":"A","name":"Home","pinned":[{"id":"P"}],"tabs":[{"id":"T1"},{"id":"T2"}],"selected":"T1"}],
         "profiles":[{"id":"X","name":"Personal"}],"currentSpace":0,"sidebarVisible":true,"closedTabs":[{"url":"https://a.example"}]}
        """
        let stripped = try XCTUnwrap(BackupSession.withoutOpenTabs(Data(session.utf8)))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: stripped) as? [String: Any])
        let space = try XCTUnwrap((root["spaces"] as? [[String: Any]])?.first)
        XCTAssertEqual((space["tabs"] as? [Any])?.count, 0)
        XCTAssertEqual((space["pinned"] as? [Any])?.count, 1)
        XCTAssertEqual(space["name"] as? String, "Home")
        XCTAssertNil(root["closedTabs"])
        XCTAssertEqual((root["profiles"] as? [Any])?.count, 1)
    }

    func testCookieSurvivesRoundTrip() throws {
        let original = try XCTUnwrap(HTTPCookie(properties: [
            .name: "sid", .value: "abc", .domain: ".example.com", .path: "/", .secure: "TRUE",
            .expires: Date().addingTimeInterval(3600), HTTPCookiePropertyKey("HttpOnly"): "TRUE",
        ]))
        let data = try JSONEncoder().encode(BackupCookie(original))
        let restored = try XCTUnwrap(try JSONDecoder().decode(BackupCookie.self, from: data).httpCookie)
        XCTAssertEqual(restored.name, "sid")
        XCTAssertEqual(restored.value, "abc")
        XCTAssertEqual(restored.domain, ".example.com")
        XCTAssertTrue(restored.isSecure)
        XCTAssertTrue(restored.isHTTPOnly)
    }

    func testExpiredCookieIsNotRestored() throws {
        let old = try XCTUnwrap(HTTPCookie(properties: [
            .name: "old", .value: "x", .domain: "example.com", .path: "/", .expires: Date().addingTimeInterval(-60),
        ]))
        XCTAssertNil(BackupCookie(old).httpCookie)
    }

    func testOpenTabsNeedSpaces() {
        XCTAssertEqual(BackupItem.tabs.requires, .spaces)
        XCTAssertNil(BackupItem.spaces.requires)
        XCTAssertTrue(BackupItem.passwords.isSensitive)
        XCTAssertFalse(BackupItem.bookmarks.isSensitive)
    }

    func testNoItemsShareAFile() {
        let all = BackupItem.allCases.flatMap(\.paths)
        XCTAssertEqual(all.count, Set(all).count)
    }

    func testReaderRefusesFilesThatAreNotBackups() async throws {
        let text = folder.appendingPathComponent("notes.tuffbackup")
        try Data("just some text".utf8).write(to: text)
        do {
            _ = try await BackupReader.open(text, password: nil)
            XCTFail("opened a text file")
        } catch BackupError.notABackup {}
    }

    func testReaderReadsAZipWithAManifest() async throws {
        let content = folder.appendingPathComponent("content")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifest = BackupManifest(appVersion: "1.0", created: Date(), items: [.bookmarks], summaries: ["bookmarks": "3 bookmarks"], profiles: [])
        try encoder.encode(manifest).write(to: content.appendingPathComponent("manifest.json"))
        let zip = folder.appendingPathComponent("made.tuffbackup")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", content.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()

        let opened = try await BackupReader.open(zip, password: nil)
        defer { opened.discard() }
        XCTAssertEqual(opened.manifest.items, [.bookmarks])
        XCTAssertEqual(opened.manifest.summaries["bookmarks"], "3 bookmarks")

        // The same file, protected.
        let sealed = folder.appendingPathComponent("sealed.tuffbackup")
        try BackupCrypto.seal(Data(contentsOf: zip), password: "pw").write(to: sealed)
        XCTAssertTrue(BackupReader.isProtected(sealed))
        let again = try await BackupReader.open(sealed, password: "pw")
        again.discard()
        do {
            _ = try await BackupReader.open(sealed, password: "nope")
            XCTFail("opened with the wrong password")
        } catch BackupError.wrongPassword {}
    }
}
