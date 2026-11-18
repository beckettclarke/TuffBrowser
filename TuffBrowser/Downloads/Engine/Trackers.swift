import Foundation
import Network

/// One tracker of a torrent, with what it last said.
final class Tracker {
    let url: String
    let tier: Int
    var status = "Not contacted yet"
    var message = ""
    var peers = 0, seeds = -1, leechers = -1
    var interval = 1800, minInterval = 60
    var nextAnnounce = Date()
    var lastAnnounce: Date?
    var updating = false
    var failures = 0
    var sentStarted = false
    var completed = -1
    var trackerID: String?
    var nextScrape = Date()
    fileprivate var udpConnection: (id: UInt64, at: Date)?

    init(url: String, tier: Int) {
        self.url = url
        self.tier = tier
    }
}

struct AnnounceRequest {
    var infoHash: Data
    var peerID: Data
    var port: UInt16
    var uploaded: Int64
    var downloaded: Int64
    var left: Int64
    /// "started", "completed", "stopped" or nil.
    var event: String?
    var key: UInt32
    var numWant = 200
    var trackerID: String?
    /// BEP 7: our global IPv6 address, so the tracker can hand it to IPv6 peers.
    var ipv6: String?
}

struct AnnounceResponse {
    var peers: [PeerAddr] = []
    var interval = 1800
    var minInterval: Int?
    var seeds: Int?
    var leechers: Int?
    var completed: Int?
    var warning: String?
    var trackerID: String?
}

/// Announces to HTTP(S) trackers (BEP 3, 23) and UDP trackers (BEP 15). Calls back on the engine queue.
enum TrackerClient {
    /// Rebuilt when the proxy settings change.
    static var session = makeSession(proxy: nil)

    static func makeSession(proxy: ProxyConfiguration?) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.httpAdditionalHeaders = ["User-Agent": "Tuff/1.0"]
        if let proxy { config.proxyConfigurations = [proxy] }
        return URLSession(configuration: config)
    }

    /// Asks how many seeds, leechers and completed downloads the swarm has.
    static func scrape(_ tracker: Tracker, infoHash: Data, done: @escaping (AnnounceResponse?) -> Void) {
        let finish: (AnnounceResponse?) -> Void = { r in engineQueue.async { done(r) } }
        if tracker.url.lowercased().hasPrefix("udp://") {
            UDPAnnounce(tracker: tracker, request: AnnounceRequest(infoHash: infoHash, peerID: Data(count: 20), port: 0, uploaded: 0, downloaded: 0, left: 0, key: 0), scrape: true) {
                finish(try? $0.get())
            }.start()
            return
        }
        // Only trackers whose announce path ends in "announce…" have a scrape address.
        guard var parts = URLComponents(string: tracker.url), let last = parts.path.split(separator: "/").last, last.hasPrefix("announce") else { finish(nil); return }
        parts.path = String(parts.path.dropLast(last.count)) + "scrape" + last.dropFirst(8)
        let query = "info_hash=" + escape(infoHash)
        parts.percentEncodedQuery = parts.percentEncodedQuery.map { $0 + "&" + query } ?? query
        guard let url = parts.url else { finish(nil); return }
        session.dataTask(with: url) { data, _, _ in
            guard let data, let (root, _, _) = try? BDecoder.decode(data, allowTrailing: true), let file = root["files"]?.dict?[infoHash] else { finish(nil); return }
            var r = AnnounceResponse()
            r.seeds = file["complete"]?.int.map(Int.init)
            r.leechers = file["incomplete"]?.int.map(Int.init)
            r.completed = file["downloaded"]?.int.map(Int.init)
            finish(r)
        }.resume()
    }

    static func announce(_ tracker: Tracker, _ request: AnnounceRequest, done: @escaping (Result<AnnounceResponse, Error>) -> Void) {
        let finish: (Result<AnnounceResponse, Error>) -> Void = { result in engineQueue.async { done(result) } }
        if tracker.url.lowercased().hasPrefix("udp://") {
            UDPAnnounce(tracker: tracker, request: request, scrape: false, done: finish).start()
        } else {
            http(tracker.url, request, done: finish)
        }
    }

    static func escape(_ data: Data) -> String {
        data.map { b -> String in
            let c = Character(UnicodeScalar(b))
            return (c.isASCII && (c.isLetter || c.isNumber || "-_.~".contains(c))) ? String(c) : String(format: "%%%02X", b)
        }.joined()
    }

    private static func http(_ base: String, _ r: AnnounceRequest, done: @escaping (Result<AnnounceResponse, Error>) -> Void) {
        var query = "info_hash=\(escape(r.infoHash))&peer_id=\(escape(r.peerID))&port=\(r.port)&uploaded=\(r.uploaded)"
            + "&downloaded=\(r.downloaded)&left=\(r.left)&corrupt=0&key=\(String(format: "%08X", r.key))&numwant=\(r.numWant)&compact=1&no_peer_id=1&supportcrypto=0"
        if let event = r.event { query += "&event=\(event)" }
        if let id = r.trackerID { query += "&trackerid=" + (id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id) }
        if let v6 = r.ipv6 { query += "&ipv6=" + (v6.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v6) }
        guard let url = URL(string: base + (base.contains("?") ? "&" : "?") + query) else {
            done(.failure(TorrentError.invalid("Bad tracker address")))
            return
        }
        session.dataTask(with: url) { data, response, error in
            if let error { done(.failure(error)); return }
            guard let data, let (root, _, _) = try? BDecoder.decode(data, allowTrailing: true), root.dict != nil else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                done(.failure(TorrentError.invalid(code >= 400 ? "HTTP \(code)" : "Unreadable answer")))
                return
            }
            if let failure = root["failure reason"]?.string { done(.failure(TorrentError.invalid(failure))); return }
            var out = AnnounceResponse()
            out.interval = Int(root["interval"]?.int ?? 1800)
            out.minInterval = root["min interval"]?.int.map(Int.init)
            out.seeds = root["complete"]?.int.map(Int.init)
            out.leechers = root["incomplete"]?.int.map(Int.init)
            out.warning = root["warning message"]?.string
            out.trackerID = root["tracker id"]?.string
            if let compact = root["peers"]?.data {
                out.peers = PeerAddr.parseCompact(compact)
            } else if let list = root["peers"]?.list {
                out.peers = list.compactMap { p in
                    guard let ip = p["ip"]?.string, let port = p["port"]?.int, port > 0, port < 65536 else { return nil }
                    return PeerAddr(ip: ip, port: UInt16(port))
                }
            }
            if let six = root["peers6"]?.data { out.peers += PeerAddr.parseCompact(six, v6: true) }
            done(.success(out))
        }.resume()
    }
}

/// One UDP tracker exchange: connect (unless a connection id is still fresh), then announce.
private final class UDPAnnounce {
    private let tracker: Tracker
    private let request: AnnounceRequest
    private let done: (Result<AnnounceResponse, Error>) -> Void
    private var connection: NWConnection?
    private var transaction = UInt32.random(in: 0...UInt32.max)
    private var tries = 0
    private var finished = false
    private var timer: DispatchWorkItem?
    private var connectionID: UInt64?
    private let scrape: Bool

    init(tracker: Tracker, request: AnnounceRequest, scrape: Bool, done: @escaping (Result<AnnounceResponse, Error>) -> Void) {
        self.tracker = tracker
        self.request = request
        self.scrape = scrape
        self.done = done
    }

    func start() {
        guard let parts = URLComponents(string: tracker.url), let host = parts.host, let port = parts.port, port > 0, port < 65536 else {
            done(.failure(TorrentError.invalid("Bad tracker address")))
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .udp)
        self.connection = connection
        connection.stateUpdateHandler = { [self] state in
            if case .failed(let error) = state { finish(.failure(error)) }
        }
        connection.start(queue: engineQueue)
        receive()
        engineQueue.async { [self] in
            if let fresh = tracker.udpConnection, Date().timeIntervalSince(fresh.at) < 60 {
                connectionID = fresh.id
                sendAnnounce()
            } else {
                sendConnect()
            }
        }
    }

    private func finish(_ result: Result<AnnounceResponse, Error>) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        connection?.cancel()
        connection = nil
        done(result)
    }

    private func arm(_ retry: @escaping () -> Void) {
        timer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            self.tries += 1
            if self.tries >= 3 { self.finish(.failure(TorrentError.invalid("Timed out"))) } else { retry() }
        }
        timer = work
        engineQueue.asyncAfter(deadline: .now() + 5 * Double(tries + 1), execute: work)
    }

    private func sendConnect() {
        var d = Data()
        d.put64(0x41727101980)
        d.put32(0)
        d.put32(transaction)
        connection?.send(content: d, completion: .idempotent)
        arm { [weak self] in self?.sendConnect() }
    }

    private func sendAnnounce() {
        guard let connectionID else { return }
        var d = Data()
        d.put64(connectionID)
        if scrape {
            d.put32(2)
            d.put32(transaction)
            d.append(request.infoHash)
            connection?.send(content: d, completion: .idempotent)
            arm { [weak self] in self?.sendAnnounce() }
            return
        }
        d.put32(1)
        d.put32(transaction)
        d.append(request.infoHash)
        d.append(request.peerID)
        d.put64(UInt64(max(0, request.downloaded)))
        d.put64(UInt64(max(0, request.left)))
        d.put64(UInt64(max(0, request.uploaded)))
        d.put32(["completed": 1, "started": 2, "stopped": 3][request.event ?? ""] ?? 0)
        d.put32(0)
        d.put32(request.key)
        d.put32(UInt32(request.numWant))
        d.put16(request.port)
        connection?.send(content: d, completion: .idempotent)
        arm { [weak self] in self?.sendAnnounce() }
    }

    private func receive() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.finished else { return }
            if let data, data.count >= 8 { self.handle(data) }
            if error == nil, !self.finished { self.receive() }
        }
    }

    private func handle(_ data: Data) {
        let action = data.u32(0)
        guard data.u32(4) == transaction else { return }
        switch action {
        case 0 where data.count >= 16:
            let id = UInt64(data.u32(8)) << 32 | UInt64(data.u32(12))
            connectionID = id
            tracker.udpConnection = (id, Date())
            transaction = UInt32.random(in: 0...UInt32.max)
            tries = 0
            sendAnnounce()
        case 1 where data.count >= 20:
            var out = AnnounceResponse()
            out.interval = Int(data.u32(8))
            out.leechers = Int(data.u32(12))
            out.seeds = Int(data.u32(16))
            let isV6 = (connection?.currentPath?.remoteEndpoint).map { if case .hostPort(.ipv6, _) = $0 { true } else { false } } ?? false
            out.peers = PeerAddr.parseCompact(data.subdata(in: data.startIndex + 20..<data.endIndex), v6: isV6)
            finish(.success(out))
        case 2 where data.count >= 20:
            var out = AnnounceResponse()
            out.seeds = Int(data.u32(8))
            out.completed = Int(data.u32(12))
            out.leechers = Int(data.u32(16))
            finish(.success(out))
        case 3:
            tracker.udpConnection = nil
            finish(.failure(TorrentError.invalid(String(data: data.dropFirst(8), encoding: .utf8) ?? "Tracker error")))
        default:
            break
        }
    }
}
