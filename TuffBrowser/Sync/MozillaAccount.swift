import Foundation
import SystemConfiguration

/// A signed-in Mozilla account, as kept between launches (sealed, see `SealedFolder`).
struct MozillaAccountState: Codable, Equatable {
    var uid: String?
    var email: String
    var displayName: String?
    /// Long-lived; gets access tokens, and identifies this device to the account.
    var refreshToken: String
    /// kSync (64 bytes, base64url): opens the account's crypto/keys record.
    var syncKey: String
    /// The key's ID, which the token server wants with every request (`X-KeyID`).
    var keyID: String
    /// This browser in the account's device list, when registering it worked.
    var deviceID: String?
}

/// Signing in to a Mozilla account the way Firefox for iOS and Android do: Mozilla's own sign-in
/// pages in a tab (passwords, two-step codes, passkeys and all), an OAuth code back through a
/// redirect Tuff catches (`SyncManager.handleRedirect`), and the account's sync key sent
/// encrypted to a key pair made for this sign-in (`keys_jwe`), so it never travels in the clear.
///
/// Mozilla doesn't register OAuth clients for other browsers, so this uses the Firefox for iOS
/// client, as Firefox-based browsers use Firefox's: the account's settings list Tuff under that
/// name.
enum MozillaAccount {
    static let clientID = "1b1a3e44c54fbb58"
    static let redirectURI = "https://accounts.firefox.com/oauth/success/1b1a3e44c54fbb58"
    static let syncScope = "https://identity.mozilla.com/apps/oldsync"

    private static let contentServer = "https://accounts.firefox.com"
    private static let oauthServer = "https://oauth.accounts.firefox.com/v1"
    private static let authServer = "https://api.accounts.firefox.com/v1"
    private static let profileServer = "https://profile.accounts.firefox.com/v1"
    static var tokenServer: URL {
        #if DEBUG
        if let debugServer { return URL(string: debugServer + "/token/1.0/sync/1.5")! }
        #endif
        return URL(string: "https://token.services.mozilla.com/1.0/sync/1.5")!
    }

    #if DEBUG
    /// `scripts/fake-sync-server.py`, standing in for Mozilla's servers in debug builds.
    static let debugServer = ProcessInfo.processInfo.environment["TUFF_SYNC_SERVER"]
    #endif

    /// No cookies or cache: everything this talks to is an API.
    static let session = URLSession(configuration: .ephemeral)

    /// One sign-in in progress: what the redirect has to match, and how to open the keys.
    struct SignIn {
        let state = Data.secureRandom(16).base64URL
        let pkce = PKCE()
        let keys = ScopedKeysRequest()

        var url: URL {
            var parts = URLComponents(string: contentServer + "/authorization")!
            parts.queryItems = [
                .init(name: "action", value: "email"),
                .init(name: "response_type", value: "code"),
                .init(name: "client_id", value: clientID),
                .init(name: "scope", value: "profile \(syncScope)"),
                .init(name: "state", value: state),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "code_challenge", value: pkce.challenge),
                .init(name: "access_type", value: "offline"),
                .init(name: "keys_jwe", value: keys.jwkParameter),
                .init(name: "redirect_uri", value: redirectURI),
            ]
            return parts.url!
        }
    }

    static func isRedirect(_ url: URL) -> Bool {
        url.absoluteString.hasPrefix(redirectURI)
    }

    /// Trades the code the redirect brought for tokens and the sync key, then fills in who the
    /// account is and registers this browser as one of its devices.
    static func finish(_ signIn: SignIn, redirect: URL) async throws -> MozillaAccountState {
        let query = URLComponents(url: redirect, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        if let error = value("error") { throw SyncError.signInFailed("Mozilla stopped the sign-in (\(error)).") }
        guard value("state") == signIn.state, let code = value("code") else {
            throw SyncError.signInFailed("The sign-in page sent back something Tuff didn’t ask for. Try again.")
        }

        let tokens = try await post(oauthServer + "/token", [
            "client_id": clientID,
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": signIn.pkce.verifier,
        ])
        guard let refreshToken = tokens["refresh_token"] as? String,
              let accessToken = tokens["access_token"] as? String,
              let jwe = tokens["keys_jwe"] as? String else {
            throw SyncError.signInFailed("Mozilla didn’t send the keys sync needs. Try signing in again.")
        }
        let keysData = try signIn.keys.decrypt(jwe)
        guard let keys = try JSONSerialization.jsonObject(with: keysData) as? [String: Any],
              let scoped = keys[syncScope] as? [String: Any],
              let k = scoped["k"] as? String, let kid = scoped["kid"] as? String,
              Data(base64URL: k)?.count == 64 else {
            throw SyncError.signInFailed("The account’s sync key couldn’t be read.")
        }

        var account = MozillaAccountState(email: "", refreshToken: refreshToken, syncKey: k, keyID: kid)
        if let profile = try? await get(profileServer + "/profile", bearer: accessToken) {
            account.email = profile["email"] as? String ?? ""
            account.uid = profile["uid"] as? String
            account.displayName = (profile["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        account.deviceID = await registerDevice(refreshToken: refreshToken)
        return account
    }

    /// An access token for the token server.
    static func accessToken(refreshToken: String) async throws -> (token: String, expires: Date) {
        #if DEBUG
        if debugServer != nil { return ("debug", Date().addingTimeInterval(3600)) }
        #endif
        let answer: [String: Any]
        do {
            answer = try await post(oauthServer + "/token", [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "scope": syncScope,
            ])
        } catch SyncError.server(let status, _) where status == 400 || status == 401 {
            // The token was revoked: signed out from the account's settings, or the password changed.
            throw SyncError.signedOut
        }
        guard let token = answer["access_token"] as? String else { throw SyncError.signedOut }
        let lifetime = (answer["expires_in"] as? Double) ?? 3600
        return (token, Date().addingTimeInterval(lifetime - 60))
    }

    /// The name other devices show for this one.
    static var deviceName: String {
        "Tuff on " + ((SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac")
    }

    /// Puts this browser in the account's device list. Not needed for syncing, so a failure is
    /// only logged.
    static func registerDevice(refreshToken: String) async -> String? {
        do {
            let device = try await post(authServer + "/account/device", ["name": deviceName, "type": "desktop"], bearer: refreshToken)
            return device["id"] as? String
        } catch {
            NSLog("Tuff: couldn't register with the Mozilla account: \(error.localizedDescription)")
            return nil
        }
    }

    /// Takes this browser off the account and revokes its token. Best effort: signing out of
    /// Tuff happens either way.
    static func signOut(_ account: MozillaAccountState) async {
        if let device = account.deviceID {
            _ = try? await post(authServer + "/account/device/destroy", ["id": device], bearer: account.refreshToken)
        }
        _ = try? await post(oauthServer + "/destroy", ["refresh_token": account.refreshToken])
    }

    // MARK: HTTP

    private static func post(_ address: String, _ body: [String: Any], bearer: String? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: address)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        return try await send(request)
    }

    private static func get(_ address: String, bearer: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: address)!)
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        var request = request
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SyncError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            throw SyncError.server(status, object["message"] as? String ?? "")
        }
        return object
    }
}
