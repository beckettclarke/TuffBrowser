import XCTest
@testable import Tuff

/// Which addresses HTTPS-first leaves alone.
final class HTTPSUpgradeTests: XCTestCase {
    func testLocalAndIntranetNamesAreExempt() {
        for host in ["localhost", "app.localhost", "printer.local", "router", "192.168.1.1", "[::1]", "::1", "nas.home.arpa", "site.test"] {
            XCTAssertTrue(HTTPSUpgrade.isExempt(host), host)
        }
        for host in ["example.com", "www.example.co.uk", "httpforever.com", "localhost.example.com"] {
            XCTAssertFalse(HTTPSUpgrade.isExempt(host), host)
        }
    }

    func testExemptAndAllowedSitesKeepTheirAddress() {
        XCTAssertEqual(HTTPSUpgrade.policy(for: URL(string: "http://localhost:3000/")!, incognito: false), .keepAsRequested)
        XCTAssertEqual(HTTPSUpgrade.policy(for: URL(string: "file:///tmp/a.html")!, incognito: false), .keepAsRequested)
        HTTPSUpgrade.allowHTTP(host: "Insecure.Example", incognito: true)
        XCTAssertTrue(HTTPSUpgrade.allowsHTTP(host: "insecure.example", incognito: true))
        XCTAssertFalse(HTTPSUpgrade.allowsHTTP(host: "insecure.example", incognito: false))
        XCTAssertEqual(HTTPSUpgrade.policy(for: URL(string: "http://insecure.example/")!, incognito: true), .keepAsRequested)
        HTTPSUpgrade.forgetIncognito()
        XCTAssertFalse(HTTPSUpgrade.allowsHTTP(host: "insecure.example", incognito: true))
    }
}
