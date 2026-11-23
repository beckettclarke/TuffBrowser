import CryptoKit
import XCTest
@testable import Tuff

/// Firefox Sync: the cryptography (checked against published vectors where there are some) and
/// the bookmark merge.
final class SyncTests: XCTestCase {
    // MARK: Crypto

    /// The example in Hawk's specification.
    func testHawkHeaderMatchesSpecExample() {
        let header = Hawk.header(
            id: "dh37fgj492je", key: "werxhqb98rpaxn39848xrunpaw3489ruxnpa98w4rxn", method: "GET",
            url: URL(string: "http://example.com:8000/resource/1?b=1&a=2")!, timestamp: 1353832234, nonce: "j4h3g2",
            ext: "some-app-ext-data"
        )
        XCTAssertTrue(header.contains("mac=\"6R4rV5iE+NPoym+WwjeHzjAGXUtLNIxmo1vpMofpLAE=\""), header)
        XCTAssertTrue(header.hasPrefix("Hawk id=\"dh37fgj492je\", ts=\"1353832234\", nonce=\"j4h3g2\""))
    }

    /// RFC 7518 appendix C: the Concat KDF for ECDH-ES.
    func testConcatKDFMatchesRFC7518() {
        let z = Data([158, 86, 217, 29, 129, 113, 53, 211, 114, 131, 66, 131, 191, 132, 38, 156,
                      251, 49, 110, 163, 218, 128, 106, 72, 246, 218, 167, 121, 140, 254, 144, 196])
        let key = JWE.concatKDF(z: z, algorithm: "A128GCM", apu: Data("Alice".utf8), apv: Data("Bob".utf8), bits: 128)
        XCTAssertEqual(key.base64URL, "VqqN6vgjbSBcIijNcacQGg")
    }

    /// A JWE made the way Mozilla's servers make `keys_jwe`, opened with the sign-in's key.
    func testScopedKeysJWEOpens() throws {
        let request = ScopedKeysRequest()
        let jwk = try XCTUnwrap(Data(base64URL: request.jwkParameter).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
        let x = try XCTUnwrap(jwk["x"].flatMap { Data(base64URL: $0) }), y = try XCTUnwrap(jwk["y"].flatMap { Data(base64URL: $0) })
        let recipient = try P256.KeyAgreement.PublicKey(x963Representation: Data([0x04]) + x + y)

        let sender = P256.KeyAgreement.PrivateKey()
        let raw = sender.publicKey.x963Representation
        let header: [String: Any] = [
            "alg": "ECDH-ES", "enc": "A256GCM",
            "epk": ["kty": "EC", "crv": "P-256", "x": raw.dropFirst().prefix(32).base64URL, "y": raw.suffix(32).base64URL],
        ]
        let protected = try JSONSerialization.data(withJSONObject: header).base64URL
        let z = try sender.sharedSecretFromKeyAgreement(with: recipient).withUnsafeBytes { Data($0) }
        let cek = JWE.concatKDF(z: z, algorithm: "A256GCM", apu: Data(), apv: Data(), bits: 256)
        let plaintext = Data(#"{"https://identity.mozilla.com/apps/oldsync":{"k":"abc","kid":"1-x"}}"#.utf8)
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: cek), authenticating: Data(protected.utf8))
        let compact = [protected, "", Data(box.nonce).base64URL, box.ciphertext.base64URL, box.tag.base64URL].joined(separator: ".")

        XCTAssertEqual(try request.decrypt(compact), plaintext)
        XCTAssertThrowsError(try ScopedKeysRequest().decrypt(compact))
    }

    /// Mozilla only sends the sync key when the public key goes out as `keys_jwk`.
    func testSignInAsksForTheSyncKey() throws {
        let signIn = MozillaAccount.SignIn()
        let query = try XCTUnwrap(URLComponents(url: signIn.url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "keys_jwk" }?.value, signIn.keys.jwkParameter)
        XCTAssertTrue(query.contains { $0.name == "scope" && $0.value?.contains(MozillaAccount.syncScope) == true })
        XCTAssertEqual(query.first { $0.name == "access_type" }?.value, "offline")
    }

    /// RFC 8291 appendix A: a Web Push message, byte for byte.
    func testWebPushMatchesRFC8291() throws {
        func data(_ text: String) throws -> Data { try XCTUnwrap(Data(base64URL: text)) }
        let sender = try P256.KeyAgreement.PrivateKey(rawRepresentation: data("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"))
        let receiver = try P256.KeyAgreement.PrivateKey(rawRepresentation: data("q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"))
        XCTAssertEqual(receiver.publicKey.x963Representation.base64URL, "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4")
        let auth = try data("BTBZMqHH6r4Tts7J_aSIgg")
        let plaintext = Data("When I grow up, I want to be a watermelon".utf8)
        let message = try WebPushCrypto.encrypt(plaintext, to: receiver.publicKey, authSecret: auth, sender: sender, salt: data("DGv6ra1nlYgDCS1FRnbzlw"))
        XCTAssertEqual(message.base64URL, "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN")
        XCTAssertEqual(try WebPushCrypto.decrypt(message, with: receiver, authSecret: auth), plaintext)
        XCTAssertThrowsError(try WebPushCrypto.decrypt(message, with: .init(), authSecret: auth))
    }

    /// A tab sent to this device opens here: the keys in the device list, sealed with the sync
    /// key, then a payload made the way Firefox makes it.
    func testSendTabRoundTrip() throws {
        let syncKey = SyncKeyBundle.random()
        let keys = SendTab.Keys.make()
        let listed = try keys.commandData(syncKey: syncKey, keyID: "1-YWJj")
        let url = URL(string: "https://example.com/page")!
        let payload = try SendTab.payload(url: url, title: "Example", to: listed, syncKey: syncKey, keyID: "1-YWJj")
        let page = try SendTab.page(from: payload, keys: keys)
        XCTAssertEqual(page.url, url)
        XCTAssertEqual(page.title, "Example")
        XCTAssertThrowsError(try SendTab.payload(url: url, title: "", to: listed, syncKey: syncKey, keyID: "2-bmV3"), "keys from an older sync key")
        // Firefox names the key by its fingerprint in hex.
        XCTAssertEqual(SendTab.kid("1573930172878-qaNBKVZcofqGMUHwiTuIQw"), "a9a34129565ca1fa863141f0893b8843")
    }

    func testRecordsRoundTripAndRejectTampering() throws {
        let bundle = SyncKeyBundle.random()
        let payload = try bundle.encrypt(Data(#"{"id":"abc","title":"Hi"}"#.utf8))
        XCTAssertEqual(try bundle.decrypt(payload), Data(#"{"id":"abc","title":"Hi"}"#.utf8))
        XCTAssertThrowsError(try SyncKeyBundle.random().decrypt(payload))

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: String])
        object["ciphertext"] = Data.secureRandom(32).base64EncodedString()
        let tampered = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        XCTAssertThrowsError(try bundle.decrypt(tampered))

        let kSync = Data.secureRandom(64)
        let fromKey = try XCTUnwrap(SyncKeyBundle(syncKey: kSync))
        XCTAssertEqual(fromKey.encryption, kSync.prefix(32))
        XCTAssertEqual(SyncKeyBundle(base64Pair: fromKey.base64Pair), fromKey)
    }

    func testGUIDsLookLikeFirefoxs() {
        let guid = SyncGUID.make()
        XCTAssertEqual(guid.count, 12)
        XCTAssertTrue(guid.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    // MARK: Bookmarks

    private func bookmark(_ title: String, _ url: String, parent: String) -> SyncBookmarkNode {
        SyncBookmarkNode(kind: .bookmark, title: title, url: url, parent: parent)
    }

    private func folder(_ title: String, parent: String, _ children: [String]) -> SyncBookmarkNode {
        SyncBookmarkNode(kind: .folder, title: title, parent: parent, children: children)
    }

    private func roots(_ children: [String: [String]] = [:]) -> SyncBookmarkTree {
        var tree = SyncBookmarkTree()
        for root in BookmarkMerge.roots { tree[root] = folder(root, parent: "places", children[root] ?? []) }
        return tree
    }

    /// Signing in with bookmarks imported from Zen earlier: the same bookmarks aren't doubled,
    /// and Firefox's other folders show up at the end of the bar.
    func testFirstSyncMatchesBookmarksTuffAlreadyHas() {
        let shared = Bookmark(title: "Example", url: URL(string: "https://example.com/")!)
        let mine = Bookmark(title: "Mine", url: URL(string: "https://mine.example/")!)
        var ids: [UUID: String] = [:]
        let local = BookmarkMerge.localTree([shared, mine], base: [:], ids: &ids)

        var remote = roots(["toolbar": ["remoteExampl"], "menu": ["menuItem0001"]])
        remote["remoteExampl"] = bookmark("Example", "https://example.com/", parent: "toolbar")
        remote["menuItem0001"] = bookmark("Menu page", "https://menu.example/", parent: "menu")

        let renames = BookmarkMerge.duplicates(base: [:], local: local, remote: remote)
        XCTAssertEqual(renames[ids[shared.id]!], "remoteExampl")
        let merged = BookmarkMerge.merge(base: [:], local: BookmarkMerge.renamed(local, renames), remote: remote)
        for (uuid, guid) in ids { if let new = renames[guid] { ids[uuid] = new } }

        XCTAssertEqual(merged["toolbar"]?.children.count, 2)
        XCTAssertEqual(merged["toolbar"]?.children.first, "remoteExampl")
        let list = BookmarkMerge.tuffList(merged, previous: [shared, mine], ids: &ids)
        XCTAssertEqual(list.map(\.displayTitle), ["Example", "Mine", "Bookmarks Menu"])
        XCTAssertEqual(list[0].id, shared.id, "the Tuff bookmark keeps its identity")
        XCTAssertEqual(list[2].children.map(\.title), ["Menu page"])
    }

    func testChangesFromBothSidesAreKept() {
        var base = roots(["toolbar": ["a", "b"]])
        base["a"] = bookmark("A", "https://a.example/", parent: "toolbar")
        base["b"] = bookmark("B", "https://b.example/", parent: "toolbar")

        // Here: renamed A, added C at the end. There: deleted B, added D at the start.
        var local = base
        local["a"]!.title = "A renamed"
        local["c"] = bookmark("C", "https://c.example/", parent: "toolbar")
        local["toolbar"]!.children = ["a", "b", "c"]
        var remote = base
        remote["b"] = nil
        remote["d"] = bookmark("D", "https://d.example/", parent: "toolbar")
        remote["toolbar"]!.children = ["d", "a"]

        let merged = BookmarkMerge.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(merged["toolbar"]?.children, ["d", "a", "c"])
        XCTAssertEqual(merged["a"]?.title, "A renamed")
        XCTAssertNil(merged["b"])
    }

    func testServerWinsWhenBothChangedTheSameBookmark() {
        var base = roots(["toolbar": ["a"]])
        base["a"] = bookmark("A", "https://a.example/", parent: "toolbar")
        var local = base, remote = base
        local["a"]!.title = "Here"
        remote["a"]!.title = "There"
        XCTAssertEqual(BookmarkMerge.merge(base: base, local: local, remote: remote)["a"]?.title, "There")
    }

    func testDeletingAFolderElsewhereKeepsWhatWasAddedToItHere() {
        var base = roots(["toolbar": ["f"]])
        base["f"] = folder("F", parent: "toolbar", [])
        var local = base
        local["n"] = bookmark("New", "https://new.example/", parent: "f")
        local["f"]!.children = ["n"]
        var remote = base
        remote["f"] = nil
        remote["toolbar"]!.children = []

        let merged = BookmarkMerge.merge(base: base, local: local, remote: remote)
        XCTAssertNil(merged["f"])
        XCTAssertEqual(merged["n"]?.parent, "toolbar")
        XCTAssertEqual(merged["toolbar"]?.children, ["n"])
    }

    /// Tuff has no separators; one on the server stays where it is when Tuff's bookmarks are
    /// turned back into a tree.
    func testSeparatorsSurviveARoundTripThroughTuff() {
        var base = roots(["toolbar": ["a", "sep", "b"]])
        base["a"] = bookmark("A", "https://a.example/", parent: "toolbar")
        base["sep"] = SyncBookmarkNode(kind: .other, title: "", parent: "toolbar")
        base["b"] = bookmark("B", "https://b.example/", parent: "toolbar")
        let a = Bookmark(title: "A", url: URL(string: "https://a.example/")!)
        let b = Bookmark(title: "B", url: URL(string: "https://b.example/")!)
        var ids: [UUID: String] = [a.id: "a", b.id: "b"]

        let local = BookmarkMerge.localTree([a, b], base: base, ids: &ids)
        XCTAssertEqual(local["toolbar"]?.children, ["a", "sep", "b"])
        let merged = BookmarkMerge.merge(base: base, local: local, remote: base)
        XCTAssertEqual(merged, base)
        XCTAssertEqual(BookmarkMerge.tuffList(merged, previous: [a, b], ids: &ids).map(\.id), [a.id, b.id])
    }

    func testRecordsCarryWhatFirefoxExpects() {
        var tree = roots(["toolbar": ["f"]])
        tree["f"] = folder("Folder", parent: "toolbar", ["x"])
        tree["x"] = bookmark("X", "https://x.example/", parent: "f")
        let record = BookmarkMerge.record("x", tree["x"]!, in: tree, existing: ["tags": ["kept"]])
        XCTAssertEqual(record["type"] as? String, "bookmark")
        XCTAssertEqual(record["bmkUri"] as? String, "https://x.example/")
        XCTAssertEqual(record["parentid"] as? String, "f")
        XCTAssertEqual(record["parentName"] as? String, "Folder")
        XCTAssertEqual(record["tags"] as? [String], ["kept"])
        XCTAssertNotNil(record["dateAdded"])
        XCTAssertEqual(BookmarkMerge.record("f", tree["f"]!, in: tree, existing: nil)["children"] as? [String], ["x"])
    }
}
