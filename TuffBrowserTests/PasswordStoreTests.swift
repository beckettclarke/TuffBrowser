import XCTest
@testable import Tuff

/// Saved passwords: encryption on disk, which logins a site gets, CSV and profile moves.
final class PasswordStoreTests: XCTestCase {
    private var folder: URL!
    private let profile = UUID()

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("passwords-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func settle() {
        // Saves are written on a background queue.
        let done = expectation(description: "written")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testSavedEncryptedAndReadBack() throws {
        let store = PasswordStore(folder: folder)
        store.save(origin: "https://example.com", username: "me", password: "hunter2-secret", profile: profile)
        store.neverSave("https://never.example")
        settle()
        let sealed = try Data(contentsOf: folder.appendingPathComponent("passwords.sealed"))
        XCTAssertNil(sealed.range(of: Data("hunter2-secret".utf8)), "the password must not be on disk in the clear")
        let reopened = PasswordStore(folder: folder)
        XCTAssertEqual(reopened.logins.map(\.password), ["hunter2-secret"])
        XCTAssertTrue(reopened.isNever("https://never.example"))
    }

    func testSavingSameUsernameReplacesPassword() {
        let store = PasswordStore(folder: folder)
        store.save(origin: "https://example.com", username: "me", password: "one", profile: profile)
        store.save(origin: "https://example.com", username: "me", password: "two", profile: profile)
        XCTAssertEqual(store.logins.map(\.password), ["two"])
    }

    func testMatchingSiteSchemeAndProfile() {
        let store = PasswordStore(folder: folder)
        store.save(origin: "https://www.example.com", username: "exact", password: "a", profile: profile)
        store.save(origin: "https://accounts.example.com", username: "sibling", password: "b", profile: profile)
        store.save(origin: "http://www.example.com", username: "insecure", password: "c", profile: profile)
        store.save(origin: "https://www.example.com", username: "other-profile", password: "d", profile: UUID())
        store.save(origin: "https://example.org", username: "other-site", password: "e", profile: profile)
        XCTAssertEqual(store.logins(for: "https://www.example.com", profile: profile).map(\.username), ["exact", "sibling"])
    }

    func testCSVImportAndExport() {
        let store = PasswordStore(folder: folder)
        let csv = "name,url,username,password,note\nEx,https://example.com/login,me,\"pa,ss\"\"word\",x\nBad,,nobody,pw,\n"
        XCTAssertEqual(store.importCSV(csv, profile: profile), 1)
        XCTAssertEqual(store.logins.first?.origin, "https://example.com")
        XCTAssertEqual(store.logins.first?.password, "pa,ss\"word")
        let exported = store.exportCSV(profile: profile)
        let again = PasswordStore(folder: folder.appendingPathComponent("again"))
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("again"), withIntermediateDirectories: true)
        XCTAssertEqual(again.importCSV(exported, profile: profile), 1)
        XCTAssertEqual(again.logins.first?.password, "pa,ss\"word")
    }

    func testMoveAllKeepsTheOtherProfilesLogin() {
        let store = PasswordStore(folder: folder)
        let other = UUID()
        store.save(origin: "https://example.com", username: "me", password: "old", profile: profile)
        store.save(origin: "https://example.org", username: "me", password: "moved", profile: profile)
        store.save(origin: "https://example.com", username: "me", password: "kept", profile: other)
        store.moveAll(from: profile, to: other)
        XCTAssertEqual(Set(store.logins.map(\.password)), ["kept", "moved"])
        XCTAssertTrue(store.logins.allSatisfy { $0.profile == other })
    }
}
