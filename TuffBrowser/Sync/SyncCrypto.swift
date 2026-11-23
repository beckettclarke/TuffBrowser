import CommonCrypto
import CryptoKit
import Foundation

// The cryptography Firefox Sync needs: records are AES-256-CBC with an HMAC-SHA256 over the
// ciphertext (`SyncKeyBundle`), requests to the storage server are signed with Hawk, and the
// account's sync key arrives at sign-in as a JWE encrypted to a key made for that sign-in.

extension Data {
    init?(base64URL text: String) {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }

    /// Base64url without padding, as JOSE and Firefox's GUIDs use it.
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    static func secureRandom(_ count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }
}

enum SyncGUID {
    /// A new 12-character ID, the shape Firefox gives bookmarks, history and clients.
    static func make() -> String { Data.secureRandom(9).base64URL }
}

// MARK: - Records

/// An encryption key and an HMAC key: the account's sync key (which only opens crypto/keys), or
/// one of the keys stored there (which open everything else).
struct SyncKeyBundle: Equatable {
    let encryption: Data
    let hmac: Data

    init(encryption: Data, hmac: Data) {
        self.encryption = encryption
        self.hmac = hmac
    }

    /// The 64-byte kSync from the account: encryption key, then HMAC key.
    init?(syncKey: Data) {
        guard syncKey.count == 64 else { return nil }
        encryption = syncKey.prefix(32)
        hmac = syncKey.suffix(32)
    }

    /// The `[encryption, hmac]` pair crypto/keys keeps, each base64.
    init?(base64Pair: [Any]) {
        guard base64Pair.count == 2,
              let e = (base64Pair[0] as? String).flatMap({ Data(base64Encoded: $0) }),
              let h = (base64Pair[1] as? String).flatMap({ Data(base64Encoded: $0) }),
              e.count == 32, h.count == 32 else { return nil }
        encryption = e
        hmac = h
    }

    static func random() -> SyncKeyBundle { SyncKeyBundle(encryption: .secureRandom(32), hmac: .secureRandom(32)) }

    var base64Pair: [String] { [encryption.base64EncodedString(), hmac.base64EncodedString()] }

    /// The payload a record carries: `{"ciphertext", "IV", "hmac"}` as JSON text.
    func encrypt(_ cleartext: Data) throws -> String {
        let iv = Data.secureRandom(kCCBlockSizeAES128)
        let ciphertext = try Self.aesCBC(CCOperation(kCCEncrypt), cleartext, key: encryption, iv: iv).base64EncodedString()
        let payload: [String: String] = [
            "ciphertext": ciphertext,
            "IV": iv.base64EncodedString(),
            "hmac": mac(ciphertext),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }

    /// The cleartext of a record's payload, if its HMAC checks out.
    func decrypt(_ payload: String) throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let ciphertext = object["ciphertext"] as? String,
              let ivText = object["IV"] as? String, let iv = Data(base64Encoded: ivText),
              let hmacText = object["hmac"] as? String,
              let encrypted = Data(base64Encoded: ciphertext) else { throw SyncError.badRecord }
        // The HMAC is over the base64 text, not the bytes it stands for.
        guard Self.constantTimeEqual(mac(ciphertext), hmacText.lowercased()) else { throw SyncError.wrongKey }
        return try Self.aesCBC(CCOperation(kCCDecrypt), encrypted, key: encryption, iv: iv)
    }

    private func mac(_ ciphertext: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(ciphertext.utf8), using: SymmetricKey(data: hmac))).hexString
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func aesCBC(_ operation: CCOperation, _ input: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            inBytes.baseAddress, input.count, out.baseAddress, capacity, &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw SyncError.badRecord }
        return output.prefix(moved)
    }
}

// MARK: - Hawk

/// Signs requests to the storage server with the ID and key the token server handed out.
enum Hawk {
    static func header(id: String, key: String, method: String, url: URL, timestamp: Int, nonce: String = Data.secureRandom(6).base64URL, ext: String? = nil) -> String {
        var resource = url.path(percentEncoded: true)
        if resource.isEmpty { resource = "/" }
        if let query = url.query(percentEncoded: true) { resource += "?" + query }
        let host = url.host(percentEncoded: true)?.lowercased() ?? ""
        let port = url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443)
        let normalized = "hawk.1.header\n\(timestamp)\n\(nonce)\n\(method.uppercased())\n\(resource)\n\(host)\n\(port)\n\n\(ext ?? "")\n"
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Data(normalized.utf8), using: SymmetricKey(data: Data(key.utf8))))
            .base64EncodedString()
        var header = "Hawk id=\"\(id)\", ts=\"\(timestamp)\", nonce=\"\(nonce)\""
        if let ext { header += ", ext=\"\(ext)\"" }
        return header + ", mac=\"\(mac)\""
    }
}

// MARK: - Sign-in keys

/// The one-off key pair a sign-in asks for the account's keys with (`keys_jwk`), and opening
/// the JWE they come back in (ECDH-ES with A256GCM, RFC 7516 / 7518).
struct ScopedKeysRequest {
    let privateKey = P256.KeyAgreement.PrivateKey()

    /// The public half as a JWK, base64url'd, for the authorization URL.
    var jwkParameter: String {
        let raw = privateKey.publicKey.x963Representation  // 0x04 ‖ x ‖ y
        let jwk: [String: String] = [
            "kty": "EC", "crv": "P-256",
            "x": raw.dropFirst().prefix(32).base64URL,
            "y": raw.suffix(32).base64URL,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: jwk, options: .sortedKeys)) ?? Data()
        return data.base64URL
    }

    func decrypt(_ compact: String) throws -> Data {
        try JWE.decrypt(compact, with: privateKey)
    }
}

enum JWE {
    static func decrypt(_ compact: String, with key: P256.KeyAgreement.PrivateKey) throws -> Data {
        let parts = compact.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5,
              let headerData = Data(base64URL: parts[0]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "ECDH-ES", let enc = header["enc"] as? String, enc == "A256GCM",
              let epk = header["epk"] as? [String: Any],
              let x = (epk["x"] as? String).flatMap({ Data(base64URL: $0) }),
              let y = (epk["y"] as? String).flatMap({ Data(base64URL: $0) }),
              let iv = Data(base64URL: parts[2]), let ciphertext = Data(base64URL: parts[3]), let tag = Data(base64URL: parts[4])
        else { throw SyncError.signInFailed("The account’s keys came back in a form Tuff doesn’t understand.") }
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: Data([0x04]) + x + y)
        let z = try key.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
        let apu = (header["apu"] as? String).flatMap { Data(base64URL: $0) } ?? Data()
        let apv = (header["apv"] as? String).flatMap { Data(base64URL: $0) } ?? Data()
        let cek = concatKDF(z: z, algorithm: enc, apu: apu, apv: apv, bits: 256)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
        // The protected header, as sent, is the additional authenticated data.
        return try AES.GCM.open(box, using: SymmetricKey(data: cek), authenticating: Data(parts[0].utf8))
    }

    /// RFC 7518 §4.6.2: the content key from the shared secret.
    static func concatKDF(z: Data, algorithm: String, apu: Data, apv: Data, bits: Int) -> Data {
        func lengthPrefixed(_ data: Data) -> Data { bigEndian(UInt32(data.count)) + data }
        func bigEndian(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        let otherInfo = lengthPrefixed(Data(algorithm.utf8)) + lengthPrefixed(apu) + lengthPrefixed(apv) + bigEndian(UInt32(bits))
        var output = Data()
        var counter: UInt32 = 1
        while output.count * 8 < bits {
            output += Data(SHA256.hash(data: bigEndian(counter) + z + otherInfo))
            counter += 1
        }
        return output.prefix(bits / 8)
    }
}

/// PKCE (RFC 7636) for the sign-in's authorization code.
struct PKCE {
    let verifier = Data.secureRandom(32).base64URL
    var challenge: String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URL }
}

// MARK: - Storage on disk

/// Small files kept AES-GCM encrypted, with the key in a file beside them readable by this user
/// only: the same arrangement as passwords (`PasswordStore`), for the same reason (an ad hoc
/// signed app can't use the keychain without a password prompt after every update).
struct SealedFolder {
    let folder: URL

    private var keyFile: URL { folder.appendingPathComponent("sync.key") }

    func read(_ name: String) -> Data? {
        guard let sealed = try? Data(contentsOf: folder.appendingPathComponent(name)),
              let key = loadKey(create: false),
              let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    func write(_ data: Data, to name: String) {
        guard let key = loadKey(create: true), let sealed = try? AES.GCM.seal(data, using: key).combined else { return }
        let file = folder.appendingPathComponent(name)
        do {
            try sealed.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            NSLog("Tuff: couldn't save \(name): \(error.localizedDescription)")
        }
    }

    func remove(_ name: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }

    private func loadKey(create: Bool) -> SymmetricKey? {
        if let data = try? Data(contentsOf: keyFile), data.count == 32 { return SymmetricKey(data: data) }
        guard create else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = SymmetricKey(size: .bits256)
        do {
            try key.withUnsafeBytes { Data($0) }.write(to: keyFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        } catch {
            return nil
        }
        return key
    }
}

// MARK: - Errors

enum SyncError: LocalizedError {
    case signInFailed(String)
    /// The account needs signing in again (password changed, access revoked).
    case signedOut
    case network(String)
    case server(Int, String)
    case badRecord
    /// A record's HMAC didn't match: the keys changed elsewhere.
    case wrongKey
    /// Someone else wrote to the collection while this sync was running; try again shortly.
    case conflict
    case newerStorage

    var errorDescription: String? {
        switch self {
        case .signInFailed(let message): message
        case .signedOut: "Your Mozilla account needs you to sign in again."
        case .network(let message): message
        case .server(let status, let message): message.isEmpty ? "The sync server answered with error \(status)." : message
        case .badRecord: "A synced item couldn’t be read."
        case .wrongKey: "Your sync data was encrypted with a key Tuff doesn’t have. Sign out and back in."
        case .conflict: "Another device was syncing at the same time. Tuff will try again in a moment."
        case .newerStorage: "Your account’s sync data is in a newer format than this version of Tuff understands. Update Tuff."
        }
    }
}
