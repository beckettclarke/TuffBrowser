import Foundation

/// A record as the storage server keeps it (a "BSO"): an ID, when it last changed, and its
/// payload, which is encrypted for everything but meta/global.
struct SyncRecord {
    let id: String
    /// Server time, in seconds.
    let modified: Double
    let payload: String
    var sortindex: Int?
}

/// One record to upload.
struct SyncUpload {
    let id: String
    let payload: String
    var sortindex: Int?
    /// Seconds until the server drops it (tabs and clients records expire if not refreshed).
    var ttl: Int?
}

/// The Sync 1.5 storage server for one signed-in account: gets a token from the token server
/// (with an access token from the account), then signs each request with it (Hawk).
final class SyncStorage {
    private struct Token {
        let id: String
        let key: String
        let endpoint: String
        let expires: Date
    }

    /// How much one upload may carry (`info/configuration`); these are the server's defaults.
    struct Limits {
        var maxPostRecords = 100
        var maxPostBytes = 2_000_000
        var maxTotalRecords = 10_000
        var maxRecordPayloadBytes = 256 * 1024
    }

    private let account: MozillaAccountState
    private var access: (token: String, expires: Date)?
    private var token: Token?
    /// Seconds the server's clock is ahead of this Mac's; Hawk refuses a skewed timestamp.
    private var skew = 0
    private(set) var limits = Limits()

    init(account: MozillaAccountState) {
        self.account = account
    }

    // MARK: Token

    private func currentToken() async throws -> Token {
        if let token, token.expires > Date() { return token }
        for attempt in 0..<2 {
            if attempt > 0 || access == nil || access!.expires < Date() {
                access = try await MozillaAccount.accessToken(refreshToken: account.refreshToken)
            }
            var request = URLRequest(url: MozillaAccount.tokenServer)
            request.setValue("Bearer " + access!.token, forHTTPHeaderField: "Authorization")
            request.setValue(account.keyID, forHTTPHeaderField: "X-KeyID")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 30
            let (data, response) = try await load(request)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if response.statusCode == 401 {
                // A stale access token gets one more try; a key that no longer matches the
                // account (its password was reset) means signing in again.
                let status = object["status"] as? String ?? ""
                if status == "invalid-client-state" || status == "invalid-key-id" || attempt == 1 { throw SyncError.signedOut }
                continue
            }
            guard response.statusCode == 200,
                  let id = object["id"] as? String, let key = object["key"] as? String,
                  let endpoint = object["api_endpoint"] as? String else {
                throw SyncError.server(response.statusCode, Self.message(object))
            }
            let duration = (object["duration"] as? Double) ?? 3600
            let token = Token(id: id, key: key, endpoint: endpoint, expires: Date().addingTimeInterval(duration - 60))
            self.token = token
            return token
        }
        throw SyncError.signedOut
    }

    // MARK: Requests

    /// A signed request to `endpoint/path`. 404 comes back to the caller; 412 is `.conflict`.
    private func send(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, headers: [String: String] = [:]
    ) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0..<2 {
            let token = try await currentToken()
            var parts = URLComponents(string: token.endpoint + "/" + path)!
            if !query.isEmpty { parts.queryItems = query }
            guard let url = parts.url else { throw SyncError.badRecord }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 60
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let now = Int(Date().timeIntervalSince1970) + skew
            request.setValue(Hawk.header(id: token.id, key: token.key, method: method, url: url, timestamp: now), forHTTPHeaderField: "Authorization")
            let (data, response) = try await load(request)
            switch response.statusCode {
            case 200..<300, 404:
                return (data, response)
            case 401 where attempt == 0:
                // A clock that's off, or a token that ran out: correct the one, drop the other.
                if let server = response.value(forHTTPHeaderField: "X-Weave-Timestamp").flatMap(Double.init) {
                    skew = Int(server) - Int(Date().timeIntervalSince1970)
                }
                self.token = nil
                continue
            case 412:
                throw SyncError.conflict
            default:
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                throw SyncError.server(response.statusCode, Self.message(object))
            }
        }
        throw SyncError.signedOut
    }

    private func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await MozillaAccount.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SyncError.network("No answer from the sync server.") }
            return (data, http)
        } catch let error as SyncError {
            throw error
        } catch {
            throw SyncError.network(error.localizedDescription)
        }
    }

    private static func message(_ object: [String: Any]) -> String {
        if let errors = object["errors"] as? [[String: Any]], let first = errors.first?["description"] as? String { return first }
        return object["message"] as? String ?? ""
    }

    private static func lastModified(_ response: HTTPURLResponse) -> Double {
        response.value(forHTTPHeaderField: "X-Last-Modified").flatMap(Double.init) ?? 0
    }

    static func timestamp(_ value: Double) -> String { String(format: "%.2f", value) }

    // MARK: Info

    /// When each collection last changed.
    func collections() async throws -> [String: Double] {
        let (data, response) = try await send("GET", "info/collections")
        guard response.statusCode == 200 else { return [:] }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return object.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    func loadLimits() async {
        guard let (data, response) = try? await send("GET", "info/configuration"), response.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        func int(_ key: String) -> Int? { (object[key] as? NSNumber)?.intValue }
        limits.maxPostRecords = int("max_post_records") ?? limits.maxPostRecords
        limits.maxPostBytes = int("max_post_bytes") ?? limits.maxPostBytes
        limits.maxTotalRecords = int("max_total_records") ?? limits.maxTotalRecords
        limits.maxRecordPayloadBytes = int("max_record_payload_bytes") ?? limits.maxRecordPayloadBytes
    }

    // MARK: Records

    /// One record, or nil if the server has none.
    func record(_ collection: String, _ id: String) async throws -> SyncRecord? {
        let (data, response) = try await send("GET", "storage/\(collection)/\(id)")
        guard response.statusCode != 404 else { return nil }
        // Anything else unreadable is an error, not "missing": missing can start the account over.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let record = Self.parse(object) else {
            throw SyncError.badRecord
        }
        return record
    }

    /// Records changed after `newer` (all of them for nil), newest first, at most `limit`.
    /// Also returns the collection's last-modified time.
    func records(_ collection: String, newer: Double?, limit: Int? = nil) async throws -> (records: [SyncRecord], modified: Double) {
        var all: [SyncRecord] = []
        var offset: String?
        var modified = 0.0
        let page = 1000
        repeat {
            var query = [URLQueryItem(name: "full", value: "1"), URLQueryItem(name: "sort", value: "newest")]
            if let newer, newer > 0 { query.append(URLQueryItem(name: "newer", value: Self.timestamp(newer))) }
            let want = limit.map { min(page, $0 - all.count) } ?? page
            query.append(URLQueryItem(name: "limit", value: String(want)))
            if let offset { query.append(URLQueryItem(name: "offset", value: offset)) }
            let (data, response) = try await send("GET", "storage/\(collection)", query: query)
            guard response.statusCode == 200 else { break }
            modified = max(modified, Self.lastModified(response))
            let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            all += list.compactMap(Self.parse)
            offset = response.value(forHTTPHeaderField: "X-Weave-Next-Offset")
        } while offset != nil && (limit.map { all.count < $0 } ?? true)
        return (all, modified)
    }

    private static func parse(_ object: [String: Any]) -> SyncRecord? {
        guard let id = object["id"] as? String, let payload = object["payload"] as? String else { return nil }
        return SyncRecord(
            id: id, modified: (object["modified"] as? NSNumber)?.doubleValue ?? 0, payload: payload,
            sortindex: (object["sortindex"] as? NSNumber)?.intValue
        )
    }

    /// Replaces one record. Returns the server's new time for it.
    @discardableResult
    func put(_ collection: String, _ record: SyncUpload, ifUnmodifiedSince: Double? = nil) async throws -> Double {
        var headers: [String: String] = [:]
        if let ifUnmodifiedSince { headers["X-If-Unmodified-Since"] = Self.timestamp(ifUnmodifiedSince) }
        let body = try JSONSerialization.data(withJSONObject: Self.object(record))
        let (_, response) = try await send("PUT", "storage/\(collection)/\(record.id)", body: body, headers: headers)
        return Self.lastModified(response)
    }

    /// Uploads records in as few requests as the server allows, as one batch so other devices
    /// never see half of it. Fails with `.conflict` if the collection changed after
    /// `ifUnmodifiedSince`. Returns the collection's new last-modified time.
    @discardableResult
    func upload(_ collection: String, _ records: [SyncUpload], ifUnmodifiedSince: Double?) async throws -> Double {
        guard !records.isEmpty else { return ifUnmodifiedSince ?? 0 }
        let fitting = records.filter { $0.payload.utf8.count <= limits.maxRecordPayloadBytes }
        var chunks: [[SyncUpload]] = []
        var current: [SyncUpload] = []
        var bytes = 2
        for record in fitting.prefix(limits.maxTotalRecords) {
            let size = record.payload.utf8.count + record.id.utf8.count + 64
            if !current.isEmpty, current.count >= limits.maxPostRecords || bytes + size > limits.maxPostBytes {
                chunks.append(current)
                current = []
                bytes = 2
            }
            current.append(record)
            bytes += size
        }
        if !current.isEmpty { chunks.append(current) }

        var since = ifUnmodifiedSince
        var batch: String?
        var batching = true
        var modified = since ?? 0
        for (index, chunk) in chunks.enumerated() {
            let last = index == chunks.count - 1
            var query: [URLQueryItem] = []
            if batching {
                query.append(URLQueryItem(name: "batch", value: batch ?? "true"))
                if last { query.append(URLQueryItem(name: "commit", value: "true")) }
            }
            var headers: [String: String] = [:]
            if let since { headers["X-If-Unmodified-Since"] = Self.timestamp(since) }
            let body = try JSONSerialization.data(withJSONObject: chunk.map(Self.object))
            let (data, response) = try await send("POST", "storage/\(collection)", query: query, body: body, headers: headers)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let failed = object["failed"] as? [String: Any], !failed.isEmpty {
                NSLog("Tuff: sync server refused \(failed.count) \(collection) record(s)")
            }
            if batching, batch == nil, !last {
                if let id = object["batch"] as? String {
                    batch = id
                } else {
                    // A server without batches took this part on its own.
                    batching = false
                }
            }
            if !batching || last {
                modified = (object["modified"] as? NSNumber)?.doubleValue ?? Self.lastModified(response)
                since = modified
            }
        }
        return modified
    }

    private static func object(_ record: SyncUpload) -> [String: Any] {
        var object: [String: Any] = ["id": record.id, "payload": record.payload]
        if let sortindex = record.sortindex { object["sortindex"] = sortindex }
        if let ttl = record.ttl { object["ttl"] = ttl }
        return object
    }

    /// Deletes everything the account has on the server, before starting it over.
    func wipe() async throws {
        _ = try await send("DELETE", "storage", headers: ["X-Confirm-Delete": "1"])
    }
}
