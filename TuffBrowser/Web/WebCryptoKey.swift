import Foundation
import Security
import WebKit

/// The key WebKit encrypts sites' saved WebCrypto keys with (a `CryptoKey` a page puts in
/// IndexedDB). Tuff hands WebKit its own instead of letting WebKit use the keychain.
///
/// WebKit's default keeps the key in the login keychain as "Tuff WebCrypto Master Key", and
/// the keychain lets only the exact app that made it read it without asking. Tuff is signed ad
/// hoc, so every update is a different app to the keychain, and macOS asked for the login
/// password after each one. The key now lives in a file in Tuff's data folder (readable by this
/// user only). The first time it's needed, the keychain's key is copied over if there is one, so
/// keys sites saved before keep working; that can ask for the password one last time.
///
/// WebKit asks the website data store's (private) delegate first, for pages and workers alike;
/// `attach(to:)` sets it on every store Tuff uses.
final class WebCryptoKey: NSObject {
    static let shared = WebCryptoKey()

    private let queue = DispatchQueue(label: "Tuff.WebCryptoKey")
    private var key: Data?
    private let file = Paths.appSupport.appendingPathComponent("webcrypto-key")

    /// Makes `store` ask Tuff for the key. WebKit holds the delegate weakly; `shared` lives on.
    static func attach(to store: WKWebsiteDataStore) {
        let selector = NSSelectorFromString("set_delegate:")
        guard store.responds(to: selector) else { return }
        store.perform(selector, with: shared)
    }

    /// `_WKWebsiteDataStoreDelegate`'s question. The answer may take a keychain prompt the first
    /// time, so it is worked out off the main thread.
    @objc(webCryptoMasterKey:)
    func webCryptoMasterKey(_ completionHandler: @escaping (Data?) -> Void) {
        queue.async {
            let key = self.loadKey()
            DispatchQueue.main.async { completionHandler(key) }
        }
    }

    private func loadKey() -> Data? {
        if let key { return key }
        if let saved = try? Data(contentsOf: file), Self.validSizes.contains(saved.count) {
            key = saved
            return saved
        }
        var made: Data
        if let old = Self.keychainKey() {
            made = old
        } else {
            made = Data(count: 16)
            guard made.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }) == errSecSuccess else { return nil }
        }
        do {
            try made.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            NSLog("Tuff: couldn't save the WebCrypto key: \(error.localizedDescription)")
        }
        key = made
        return made
    }

    /// AES key sizes; WebKit makes 16-byte keys.
    private static let validSizes: Set<Int> = [16, 24, 32]

    /// The key WebKit kept in the keychain before, if there is one. WebKit stores it base64
    /// encoded. Test runs never touch the keychain.
    private static func keychainKey() -> Data? {
        guard Paths.testDataDirectory == nil, NSClassFromString("XCTestCase") == nil,
              let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "com.apple.WebKit.WebCrypto.master+" + bundleID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        if let text = String(data: data, encoding: .utf8), let decoded = Data(base64Encoded: text), validSizes.contains(decoded.count) {
            return decoded
        }
        return validSizes.contains(data.count) ? data : nil
    }
}
