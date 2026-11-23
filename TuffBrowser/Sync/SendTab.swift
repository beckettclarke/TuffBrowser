import CryptoKit
import Foundation

/// Web Push message encryption: RFC 8291's keys over RFC 8188's aes128gcm content coding. Mozilla
/// accounts carry device commands (Send Tab) in it, encrypted to the receiving device's key.
enum WebPushCrypto {
    private static let recordSize: UInt32 = 4096

    static func encrypt(
        _ plaintext: Data, to receiver: P256.KeyAgreement.PublicKey, authSecret: Data,
        sender: P256.KeyAgreement.PrivateKey = .init(), salt: Data = .secureRandom(16)
    ) throws -> Data {
        let senderPublic = sender.publicKey.x963Representation
        let (key, nonce) = try keys(
            shared: sender.sharedSecretFromKeyAgreement(with: receiver), authSecret: authSecret,
            receiver: receiver.x963Representation, sender: senderPublic, salt: salt
        )
        // One record: the message, then the "last record" delimiter.
        let box = try AES.GCM.seal(plaintext + [2], using: key, nonce: AES.GCM.Nonce(data: nonce))
        var header = salt
        withUnsafeBytes(of: recordSize.bigEndian) { header.append(contentsOf: $0) }
        header.append(UInt8(senderPublic.count))
        return header + senderPublic + box.ciphertext + box.tag
    }

    static func decrypt(_ message: Data, with receiver: P256.KeyAgreement.PrivateKey, authSecret: Data) throws -> Data {
        let bytes = [UInt8](message)
        guard bytes.count > 21 else { throw SyncError.badRecord }
        let salt = Data(bytes[0..<16])
        let size = Int(UInt32(bytes[16]) << 24 | UInt32(bytes[17]) << 16 | UInt32(bytes[18]) << 8 | UInt32(bytes[19]))
        let idLength = Int(bytes[20])
        guard size > 17, bytes.count > 21 + idLength else { throw SyncError.badRecord }
        let senderPublic = Data(bytes[21..<(21 + idLength)])
        let (key, nonce) = try keys(
            shared: receiver.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: senderPublic)),
            authSecret: authSecret, receiver: receiver.publicKey.x963Representation, sender: senderPublic, salt: salt
        )
        var output = Data()
        var offset = 21 + idLength
        var sequence: UInt64 = 0
        while offset < bytes.count {
            let end = min(offset + size, bytes.count)
            let record = Data(bytes[offset..<end])
            guard record.count > 16 else { throw SyncError.badRecord }
            // Each record's nonce is the base nonce XOR its sequence number.
            var recordNonce = [UInt8](nonce)
            for i in 0..<8 { recordNonce[11 - i] ^= UInt8(truncatingIfNeeded: sequence >> (8 * UInt64(i))) }
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: recordNonce), ciphertext: record.dropLast(16), tag: record.suffix(16))
            var plain = [UInt8](try AES.GCM.open(box, using: key))
            while plain.last == 0 { plain.removeLast() }
            guard let delimiter = plain.popLast(), delimiter == 1 || delimiter == 2 else { throw SyncError.badRecord }
            output.append(contentsOf: plain)
            offset = end
            sequence += 1
            if delimiter == 2 { break }
        }
        return output
    }

    private static func keys(shared: SharedSecret, authSecret: Data, receiver: Data, sender: Data, salt: Data) throws -> (SymmetricKey, Data) {
        let ecdh = shared.withUnsafeBytes { Data($0) }
        let ikm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ecdh), salt: authSecret,
            info: Data("WebPush: info\0".utf8) + receiver + sender, outputByteCount: 32
        )
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aes128gcm\0".utf8), outputByteCount: 16)
        let nonce = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce\0".utf8), outputByteCount: 12)
        return (key, nonce.withUnsafeBytes { Data($0) })
    }
}

/// Send Tab between devices on a Mozilla account, as Firefox and Zen do it: each device lists a
/// key pair under the open-uri command (the public half encrypted with the account's sync key,
/// so only the account's devices can use it), and a sent tab is a Web Push message encrypted to
/// it, queued by Mozilla until the device asks for its commands.
enum SendTab {
    static let command = "https://identity.mozilla.com/cmd/open-uri"

    /// How Send Tab names the sync key: the fingerprint part of its ID ("1573…-qaNBKV…") in hex.
    static func kid(_ keyID: String) -> String {
        keyID.split(separator: "-", maxSplits: 1).last.flatMap { Data(base64URL: String($0)) }?.hexString ?? keyID
    }

    /// This device's side: the key pair other devices encrypt to.
    struct Keys: Codable, Equatable {
        var privateKey: String
        var authSecret: String

        static func make() -> Keys {
            Keys(privateKey: P256.KeyAgreement.PrivateKey().rawRepresentation.base64URL, authSecret: Data.secureRandom(16).base64URL)
        }

        var key: P256.KeyAgreement.PrivateKey? {
            Data(base64URL: privateKey).flatMap { try? P256.KeyAgreement.PrivateKey(rawRepresentation: $0) }
        }

        /// What goes in the account's device list: the public key, sealed with the sync key.
        func commandData(syncKey: SyncKeyBundle, keyID: String) throws -> String {
            guard let key, let secret = Data(base64URL: authSecret) else { throw SyncError.badRecord }
            let keys = try JSONSerialization.data(withJSONObject: ["publicKey": key.publicKey.x963Representation.base64URL, "authSecret": secret.base64URL])
            guard var sealed = try JSONSerialization.jsonObject(with: Data(syncKey.encrypt(keys).utf8)) as? [String: Any] else { throw SyncError.badRecord }
            sealed["kid"] = SendTab.kid(keyID)
            return String(decoding: try JSONSerialization.data(withJSONObject: sealed), as: UTF8.self)
        }
    }

    /// Another device's public key and auth secret, from its entry in the device list.
    static func receiver(_ commandData: String, syncKey: SyncKeyBundle, keyID: String) throws -> (P256.KeyAgreement.PublicKey, Data) {
        guard let sealed = try JSONSerialization.jsonObject(with: Data(commandData.utf8)) as? [String: Any] else { throw SyncError.badRecord }
        // Keys sealed with an older sync key (from before a password reset) can't be opened.
        if let listed = sealed["kid"] as? String, listed != kid(keyID) { throw SyncError.wrongKey }
        let opened = try syncKey.decrypt(commandData)
        guard let keys = try JSONSerialization.jsonObject(with: opened) as? [String: String],
              let publicKey = keys["publicKey"].flatMap({ Data(base64URL: $0) }),
              let secret = keys["authSecret"].flatMap({ Data(base64URL: $0) }) else { throw SyncError.badRecord }
        return (try P256.KeyAgreement.PublicKey(x963Representation: publicKey), secret)
    }

    /// The command payload for a page.
    static func payload(url: URL, title: String, to commandData: String, syncKey: SyncKeyBundle, keyID: String) throws -> [String: Any] {
        let (publicKey, secret) = try receiver(commandData, syncKey: syncKey, keyID: keyID)
        let message = try JSONSerialization.data(withJSONObject: [
            "entries": [["title": title, "url": url.absoluteString]],
            "flowID": Data.secureRandom(16).hexString, "streamID": Data.secureRandom(16).hexString,
        ])
        return ["encrypted": try WebPushCrypto.encrypt(message, to: publicKey, authSecret: secret).base64URL]
    }

    /// The page a received command opens: the tab's current entry, which is the last.
    static func page(from payload: [String: Any], keys: Keys) throws -> (url: URL, title: String) {
        guard let encrypted = (payload["encrypted"] as? String).flatMap({ Data(base64URL: $0) }),
              let key = keys.key, let secret = Data(base64URL: keys.authSecret) else { throw SyncError.badRecord }
        let message = try WebPushCrypto.decrypt(encrypted, with: key, authSecret: secret)
        guard let object = try JSONSerialization.jsonObject(with: message) as? [String: Any],
              let entry = (object["entries"] as? [[String: Any]])?.last,
              let url = (entry["url"] as? String).flatMap(URL.init(string:)) else { throw SyncError.badRecord }
        return (url, entry["title"] as? String ?? "")
    }
}
