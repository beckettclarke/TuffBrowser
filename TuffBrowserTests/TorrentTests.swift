import XCTest
@testable import Tuff

/// The torrent engine's building blocks: encoding, metadata, hashing, filters and crypto.
final class TorrentTests: XCTestCase {
    func testBencodeRoundTripAndStrictness() throws {
        let value = BValue.d(["a": .int(-42), "list": .list([.s("x"), .int(0)]), "z": .bytes(Data([0, 255]))])
        let encoded = value.encoded
        XCTAssertEqual(String(decoding: encoded.prefix(8), as: UTF8.self), "d1:ai-42")
        let (decoded, _, _) = try BDecoder.decode(encoded)
        XCTAssertEqual(decoded.encoded, encoded)
        // Malformed or hostile input fails instead of crashing.
        for bad in ["i12", "5:abc", "l", "d1:ai1e", "i1x2e", String(repeating: "l", count: 500) + String(repeating: "e", count: 500), "10000000000:x"] {
            XCTAssertThrowsError(try BDecoder.decode(Data(bad.utf8)), bad)
        }
    }

    func testMagnetParsing() throws {
        let hex = try TorrentSource.load(magnet: "magnet:?xt=urn:btih:7acf8fb590b2060dd9c3146ef770169d593433b0&dn=Debian&tr=udp%3A%2F%2Ft.example%3A80&tr=http%3A%2F%2Fa.example%2Fannounce&x.pe=1.2.3.4:5&so=0,2-4&ws=https%3A%2F%2Fmirror.example%2F")
        XCTAssertEqual(hex.infoHash.tHex, "7acf8fb590b2060dd9c3146ef770169d593433b0")
        XCTAssertEqual(hex.name, "Debian")
        XCTAssertEqual(hex.trackers.flatMap { $0 }.count, 2)
        XCTAssertEqual(hex.peers, ["1.2.3.4:5"])
        XCTAssertEqual(hex.selectOnly, [0, 2, 3, 4])
        XCTAssertEqual(hex.webSeeds, ["https://mirror.example/"])
        let b32 = try TorrentSource.load(magnet: "magnet:?xt=urn:btih:PLHY7NMQWIDA3WODCRXPO4AWTVMTIM5Q")
        XCTAssertEqual(b32.infoHash, hex.infoHash)
        let v2 = try TorrentSource.load(magnet: "magnet:?xt=urn:btmh:1220caf1e1c30e81cb361b9ee167c4aa64228a7fa4fa9f6105232b28ad099f3a302e")
        XCTAssertEqual(v2.infoHash.count, 20)
        XCTAssertEqual(v2.infoHashV2?.count, 32)
        XCTAssertThrowsError(try TorrentSource.load(magnet: "magnet:?dn=nothing"))
    }

    func testFileNamesCantEscape() {
        XCTAssertEqual(TorrentInfo.clean(".."), "")
        XCTAssertEqual(TorrentInfo.clean("a/../b"), "a..b")
        XCTAssertEqual(TorrentInfo.clean("..."), "")
        XCTAssertEqual(TorrentInfo.clean("ok.txt"), "ok.txt")
    }

    private func makeContent() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tuff-torrent-\(UUID().uuidString)/share", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data.random(70_000).write(to: dir.appendingPathComponent("a.bin"))
        try Data.random(300_123).write(to: dir.appendingPathComponent("sub/b.bin"))
        try Data.random(5).write(to: dir.appendingPathComponent("sub/c.txt"))
        return dir
    }

    /// Torrents made here read back, and every piece checks out against the files by SHA-1
    /// and by merkle tree.
    func testCreateAndVerifyEveryFormat() throws {
        let dir = try makeContent()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        for format in [TorrentCreator.Format.v1, .v2, .hybrid] {
            var creator = TorrentCreator(path: dir)
            creator.format = format
            creator.pieceLength = 32 * 1024
            creator.trackers = [["udp://t.example:80"], ["https://b.example/announce"]]
            let data = try creator.create(progress: { _ in }, cancelled: { false })
            let source = try TorrentSource.load(torrent: data)
            let info = try XCTUnwrap(source.info)
            XCTAssertEqual(info.hasV1, format != .v2)
            XCTAssertEqual(info.hasV2, format != .v1)
            XCTAssertEqual(source.trackers.count, 2)
            XCTAssertEqual(info.files.filter { !$0.isPad }.count, 3)
            if info.hasV2 { XCTAssertTrue(info.missingLayers.isEmpty, "piece layers came with the file") }
            let storage = TorrentStorage(info: info, base: dir.deletingLastPathComponent())
            for piece in 0..<info.pieceCount { XCTAssertTrue(storage.verify(piece), "\(format) piece \(piece)") }
            // A changed byte fails its piece.
            var broken = try storage.read(at: 0, length: info.pieceSize(0))
            broken[0] ^= 0xff
            XCTAssertFalse(info.verify(0, broken))
        }
    }

    func testPieceLayersAreCheckedAgainstTheRoot() throws {
        let dir = try makeContent()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        var creator = TorrentCreator(path: dir)
        creator.format = .v2
        creator.pieceLength = 16 * 1024
        let info = try XCTUnwrap(try TorrentSource.load(torrent: try creator.create(progress: { _ in }, cancelled: { false })).info)
        let big = try XCTUnwrap(info.files.firstIndex { $0.length > 100_000 })
        let layer = try XCTUnwrap(info.pieceLayers[info.files[big].root!])
        var bad = layer
        bad[5] ^= 1
        XCTAssertFalse(info.accept(layer: bad, forFile: big))
        XCTAssertTrue(info.accept(layer: layer, forFile: big))
    }

    func testIPFilterFormats() {
        let filter = IPFilter(text: """
        # comment
        Some bad range:1.2.3.0-1.2.3.255
        010.000.000.000 - 010.000.000.255 , 000 , eMule entry
        020.000.000.000 - 020.000.000.255 , 200 , allowed level
        192.168.50.0/24
        2001:db8::/32
        """)
        XCTAssertTrue(filter.blocks(PeerAddr(ip: "1.2.3.77", port: 1)))
        XCTAssertTrue(filter.blocks(PeerAddr(ip: "10.0.0.9", port: 1)))
        XCTAssertFalse(filter.blocks(PeerAddr(ip: "20.0.0.9", port: 1)))
        XCTAssertTrue(filter.blocks(PeerAddr(ip: "192.168.50.200", port: 1)))
        XCTAssertFalse(filter.blocks(PeerAddr(ip: "192.168.51.1", port: 1)))
        XCTAssertTrue(filter.blocks(PeerAddr(ip: "2001:db8::1", port: 1)))
        XCTAssertFalse(filter.blocks(PeerAddr(ip: "2001:db9::1", port: 1)))
    }

    func testCompactPeersAndAddresses() {
        let a = PeerAddr(ip: "::ffff:1.2.3.4", port: 6881)
        XCTAssertEqual(a.ip, "1.2.3.4")
        XCTAssertEqual(PeerAddr.parseCompact(a.compact!), [a])
        let six = PeerAddr("[2001:db8::5]:51413")!
        XCTAssertEqual(PeerAddr.parseCompact(six.compact!, v6: true), [six])
        XCTAssertTrue(PeerAddr(ip: "192.168.1.2", port: 1).isLocal)
        XCTAssertFalse(PeerAddr(ip: "8.8.8.8", port: 1).isLocal)
    }

    func testBEP42NodeIDs() {
        // The worked example from BEP 42.
        let id = Data(tHex: "5fbfbff10c5d6a4ec8a88e4c6ab4c28b95eee401")!
        XCTAssertTrue(DHT.isSecure(id, PeerAddr(ip: "124.31.75.21", port: 1)))
        XCTAssertFalse(DHT.isSecure(id, PeerAddr(ip: "124.31.75.22", port: 1)))
        let mine = DHT.secureID(for: PeerAddr(ip: "21.75.31.124", port: 1))!
        XCTAssertTrue(DHT.isSecure(mine, PeerAddr(ip: "21.75.31.124", port: 1)))
    }

    func testModularExponentiation() {
        // Against plain arithmetic, for a small odd modulus.
        let m: UInt64 = 1_000_003
        var expected: UInt64 = 1
        for _ in 0..<12345 { expected = expected * 7 % m }
        let got = BigNum.modExp(base: [7], exp: [12345], mod: [UInt32(m)])
        XCTAssertEqual(UInt64(got[0]), expected)
        // Diffie-Hellman over MSE's prime: both sides reach the same secret.
        let p = MSETransport.prime
        let a = BigNum.random(bits: 160), b = BigNum.random(bits: 160)
        let ya = BigNum.modExp(base: [2], exp: a, mod: p), yb = BigNum.modExp(base: [2], exp: b, mod: p)
        XCTAssertEqual(BigNum.modExp(base: yb, exp: a, mod: p), BigNum.modExp(base: ya, exp: b, mod: p))
    }

    /// Two ends of an in-memory connection.
    private final class Pipe: PeerTransport {
        var onConnect: (() -> Void)?
        var onData: ((Data) -> Void)?
        var onClose: ((String) -> Void)?
        let remote = PeerAddr(ip: "127.0.0.1", port: 1)
        let isUTP = false
        let backlog = 0
        weak var other: Pipe?
        let connectsOnStart: Bool
        init(connects: Bool) { connectsOnStart = connects }
        func start() { if connectsOnStart { engineQueue.async { self.onConnect?() } } }
        func send(_ data: Data) { engineQueue.async { self.other?.onData?(data) } }
        func close() {}
    }

    func testEncryptedHandshakeBothWays() {
        let hash = Data.random(20)
        let left = Pipe(connects: true), right = Pipe(connects: false)
        left.other = right
        right.other = left
        let outgoing = MSETransport(left, infoHash: hash, lookup: nil, allowPlain: true)
        let incoming = MSETransport(right, infoHash: nil, lookup: { req2 in req2 == sha1(Data("req2".utf8) + hash) ? hash : nil }, allowPlain: true)
        let done = expectation(description: "messages cross")
        done.expectedFulfillmentCount = 2
        engineQueue.async {
            incoming.onData = { data in XCTAssertEqual(data, Data("hello from A".utf8)); incoming.send(Data("hello from B".utf8)); done.fulfill() }
            outgoing.onData = { data in XCTAssertEqual(data, Data("hello from B".utf8)); done.fulfill() }
            outgoing.onConnect = { outgoing.send(Data("hello from A".utf8)) }
            incoming.start()
            outgoing.start()
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(outgoing.encrypted)
        XCTAssertTrue(incoming.encrypted)
    }

    func testContentRangeAndFilenames() {
        XCTAssertEqual(HTTPTransfer.contentRange("bytes 100-199/1000")?.total, 1000)
        XCTAssertEqual(HTTPTransfer.contentRange("bytes 0-0/*")?.total, -1)
        XCTAssertNil(HTTPTransfer.contentRange("nonsense"))
        let url = URL(string: "https://example.com/files/thing.zip?x=1")!
        let plain = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!
        XCTAssertEqual(HTTPTransfer.filename(from: plain, url: url), "thing.zip")
        let named = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Disposition": "attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf"])!
        XCTAssertEqual(HTTPTransfer.filename(from: named, url: url), "résumé.pdf")
    }

    func testSettingsTableRoundTrip() {
        var s = TorrentSettings()
        XCTAssertFalse(s.seedAfterDownload, "no seeding unless asked")
        s.apply(["maxPeers": 77, "utp": false, "ratioLimit": 1.5, "proxyHost": "p.example", "unknown": 1])
        XCTAssertEqual(s.maxPeers, 77)
        XCTAssertFalse(s.utp)
        XCTAssertEqual(s.ratioLimit, 1.5)
        var t = TorrentSettings()
        t.apply(s.dict)
        XCTAssertEqual(t.dict as NSDictionary, s.dict as NSDictionary)
    }
}
