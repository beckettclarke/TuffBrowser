import Foundation

/// The mainline DHT (BEP 5): finds peers for torrents without a tracker, and answers other
/// nodes' questions so the network stays healthy. One instance per address family (BEP 32),
/// each over its shared UDP socket, with BEP 42 node ids, per-address rate limits and BEP 51.
final class DHT {
    private struct Node {
        let id: Data
        let addr: PeerAddr
        var lastSeen: Date
        var fails = 0
    }

    private final class Lookup {
        struct Candidate {
            let id: Data?
            let addr: PeerAddr
            let distance: Data
            var state = 0  // 0 new, 1 asked, 2 answered, 3 failed
            var token: Data?
        }
        let target: Data
        let getPeers: Bool
        let announcePort: UInt16?
        var candidates: [Candidate] = []
        var seen = Set<PeerAddr>()
        var inflight = 0
        var found = Set<PeerAddr>()
        var done = false
        var started = Date()
        let onPeers: ([PeerAddr]) -> Void

        init(target: Data, getPeers: Bool, announcePort: UInt16?, onPeers: @escaping ([PeerAddr]) -> Void) {
            self.target = target
            self.getPeers = getPeers
            self.announcePort = announcePort
            self.onPeers = onPeers
        }
    }

    private struct Pending {
        let addr: PeerAddr
        let sent: Date
        let lookup: Lookup?
    }

    private let socket: UDPSocket
    let v6: Bool
    private(set) var nodeID: Data
    private var nodeSize: Int { v6 ? 38 : 26 }
    private var nodesKey: String { v6 ? "nodes6" : "nodes" }
    /// Refuse nodes whose id doesn't match their address (BEP 42). Off by default, like libtorrent.
    var enforceNodeID = false
    /// Votes on our external address from the "ip" field of answers.
    var onExternalIP: ((String) -> Void)?
    private var ipVotes: [String: Int] = [:]
    private var queryCounts: [String: (count: Int, since: Date)] = [:]
    private var globalQueries = 0, globalSince = Date()
    private var buckets = [[Node]](repeating: [], count: 160)
    private var pending: [Data: Pending] = [:]
    private var lookups: [Lookup] = []
    private var stored: [Data: [PeerAddr: Date]] = [:]
    private var secret = Data.random(8), oldSecret = Data.random(8)
    private var secretChanged = Date()
    private var tid: UInt16 = 0
    private var lastBootstrap = Date.distantPast
    private var lastRefresh = Date()
    var enabled = true

    static let routers = ["router.bittorrent.com:6881", "dht.transmissionbt.com:6881", "router.utorrent.com:6881", "dht.libtorrent.org:25401", "dht.aelitis.com:6881"]

    init(socket: UDPSocket, nodeID: Data?, nodes: Data?) {
        self.socket = socket
        v6 = socket.v6
        self.nodeID = nodeID?.count == 20 ? nodeID! : Data.random(20)
        if let nodes {
            // Saved as id + compact address entries.
            var i = 0
            while i + nodeSize <= nodes.count {
                if let addr = PeerAddr.parseCompact(nodes.subdata(in: i + 20..<i + nodeSize), v6: v6).first { ping(addr) }
                i += nodeSize
            }
        }
    }

    // MARK: BEP 42 node ids

    private static func masked(_ ip: PeerAddr, _ r: UInt8) -> [UInt8]? {
        guard let c = ip.compact else { return nil }
        let mask: [UInt8] = ip.isV6 ? [0x01, 0x03, 0x07, 0x0f, 0x1f, 0x3f, 0x7f, 0xff] : [0x03, 0x0f, 0x3f, 0xff]
        var b = zip(c.prefix(mask.count), mask).map { $0 & $1 }
        b[0] |= r << 5
        return b
    }

    static func secureID(for ip: PeerAddr) -> Data? {
        let r = UInt8.random(in: 0...7)
        guard let b = masked(ip, r) else { return nil }
        let crc = CRC32C.checksum(b)
        var id = Data.random(20)
        id[0] = UInt8(crc >> 24)
        id[1] = UInt8(crc >> 16 & 0xff)
        id[2] = UInt8(crc >> 8 & 0xf8) | (id[2] & 7)
        id[19] = r
        return id
    }

    static func isSecure(_ id: Data, _ ip: PeerAddr) -> Bool {
        if ip.isLocal { return true }
        guard id.count == 20, let b = masked(ip, id[id.startIndex + 19] & 7) else { return false }
        let crc = CRC32C.checksum(b)
        let x = [UInt8](id)
        return x[0] == UInt8(crc >> 24) && x[1] == UInt8(crc >> 16 & 0xff) && x[2] & 0xf8 == UInt8(crc >> 8 & 0xf8)
    }

    /// We learned our external address: take an id that matches it, keeping the nodes we know.
    func externalAddress(_ ip: String) {
        let addr = PeerAddr(ip: ip, port: 1)
        guard addr.isV6 == v6, !Self.isSecure(nodeID, addr), let id = Self.secureID(for: addr) else { return }
        let known = buckets.flatMap { $0 }
        nodeID = id
        buckets = [[Node]](repeating: [], count: 160)
        for n in known { saw(n.id, n.addr) }
    }

    var nodeCount: Int { buckets.reduce(0) { $0 + $1.count } }

    var savedNodes: Data {
        var out = Data()
        for node in buckets.flatMap({ $0 }).sorted(by: { $0.lastSeen > $1.lastSeen }).prefix(300) {
            guard let c = node.addr.compact else { continue }
            out.append(node.id)
            out.append(c)
        }
        return out
    }

    // MARK: Routing table

    private static func xor(_ a: Data, _ b: Data) -> Data { Data(zip(a, b).map { $0 ^ $1 }) }

    private func bucket(for id: Data) -> Int {
        var bits = 0
        for (x, y) in zip(nodeID, id) {
            let v = x ^ y
            if v == 0 { bits += 8; continue }
            bits += v.leadingZeroBitCount
            break
        }
        return min(bits, 159)
    }

    private func saw(_ id: Data, _ addr: PeerAddr) {
        guard id.count == 20, id != nodeID, addr.isUsable, addr.isV6 == v6, !enforceNodeID || Self.isSecure(id, addr) else { return }
        let b = bucket(for: id)
        if let i = buckets[b].firstIndex(where: { $0.id == id }) {
            buckets[b][i].lastSeen = Date()
            buckets[b][i].fails = 0
            return
        }
        if buckets[b].count < 8 {
            buckets[b].append(Node(id: id, addr: addr, lastSeen: Date()))
        } else if let i = buckets[b].firstIndex(where: { $0.fails >= 2 || Date().timeIntervalSince($0.lastSeen) > 900 }) {
            buckets[b][i] = Node(id: id, addr: addr, lastSeen: Date())
        }
    }

    private func failed(_ addr: PeerAddr) {
        for b in buckets.indices {
            if let i = buckets[b].firstIndex(where: { $0.addr == addr }) {
                buckets[b][i].fails += 1
                if buckets[b][i].fails >= 3 { buckets[b].remove(at: i) }
                return
            }
        }
    }

    private func closest(_ target: Data, count: Int = 8) -> [Node] {
        buckets.flatMap { $0 }.filter { $0.fails < 2 }
            .map { ($0, Self.xor($0.id, target)) }
            .sorted { $0.1.lexicographicallyPrecedes($1.1) }
            .prefix(count).map(\.0)
    }

    private func compactNodes(_ nodes: [Node]) -> Data {
        var out = Data()
        for n in nodes { if let c = n.addr.compact, c.count == nodeSize - 20 { out.append(n.id); out.append(c) } }
        return out
    }

    // MARK: Sending

    private func query(_ method: String, _ args: [String: BValue], to addr: PeerAddr, lookup: Lookup? = nil) {
        tid &+= 1
        var t = Data()
        t.put16(tid)
        var a = args
        a["id"] = .bytes(nodeID)
        a["want"] = .list([.s(v6 ? "n6" : "n4")])
        let msg = BValue.d(["t": .bytes(t), "y": .s("q"), "q": .s(method), "a": .d(a), "v": .bytes(Data("TF10".utf8))])
        pending[t] = Pending(addr: addr, sent: Date(), lookup: lookup)
        socket.send(msg.encoded, to: addr)
    }

    private func reply(_ t: Data, _ r: [String: BValue], to addr: PeerAddr) {
        var r = r
        r["id"] = .bytes(nodeID)
        var msg: [String: BValue] = ["t": .bytes(t), "y": .s("r"), "r": .d(r)]
        if let ip = addr.compact { msg["ip"] = .bytes(ip) }  // BEP 42: tell them what we see
        socket.send(BValue.d(msg).encoded, to: addr)
    }

    func addNode(_ addr: PeerAddr) { if nodeCount < 1000 { ping(addr) } }

    private func ping(_ addr: PeerAddr) { query("find_node", ["target": .bytes(nodeID)], to: addr) }

    private func token(for addr: PeerAddr, secret: Data) -> Data {
        sha1(secret + Data(addr.ip.utf8)).prefix(8)
    }

    // MARK: Lookups

    /// Looks for peers of `infoHash`, reporting them as they come in, then announces us.
    func getPeers(_ infoHash: Data, announcePort: UInt16?, onPeers: @escaping ([PeerAddr]) -> Void) {
        guard enabled else { return }
        let lookup = Lookup(target: infoHash, getPeers: true, announcePort: announcePort, onPeers: onPeers)
        if let local = stored[infoHash], !local.isEmpty { onPeers(Array(local.keys)) }
        start(lookup)
    }

    private func start(_ lookup: Lookup) {
        for node in closest(lookup.target, count: 16) { add(node.id, node.addr, to: lookup) }
        lookups.append(lookup)
        if lookup.candidates.isEmpty { bootstrap() }
        step(lookup)
    }

    private func add(_ id: Data?, _ addr: PeerAddr, to lookup: Lookup) {
        guard addr.isUsable, lookup.candidates.count < 300, lookup.seen.insert(addr).inserted, id != nodeID else { return }
        let distance = id.map { Self.xor($0, lookup.target) } ?? Data(repeating: 0xff, count: 20)
        let c = Lookup.Candidate(id: id, addr: addr, distance: distance)
        let i = lookup.candidates.firstIndex { c.distance.lexicographicallyPrecedes($0.distance) } ?? lookup.candidates.count
        lookup.candidates.insert(c, at: i)
    }

    private func step(_ lookup: Lookup) {
        guard !lookup.done else { return }
        var considered = 0
        for i in lookup.candidates.indices where lookup.candidates[i].state != 3 {
            considered += 1
            if considered > 16 { break }
            guard lookup.inflight < 8 else { break }
            if lookup.candidates[i].state == 0 {
                lookup.candidates[i].state = 1
                lookup.inflight += 1
                let method = lookup.getPeers ? "get_peers" : "find_node"
                let key = lookup.getPeers ? "info_hash" : "target"
                query(method, [key: .bytes(lookup.target)], to: lookup.candidates[i].addr, lookup: lookup)
            }
        }
        if lookup.inflight == 0 { finish(lookup) }
    }

    private func finish(_ lookup: Lookup) {
        guard !lookup.done else { return }
        lookup.done = true
        lookups.removeAll { $0 === lookup }
        guard let port = lookup.announcePort else { return }
        for c in lookup.candidates.filter({ $0.state == 2 && $0.token != nil }).prefix(8) {
            query("announce_peer", ["info_hash": .bytes(lookup.target), "port": .int(Int64(port)), "implied_port": .int(1), "token": .bytes(c.token!)], to: c.addr)
        }
    }

    // MARK: Receiving

    func handle(_ data: Data, from addr: PeerAddr) {
        guard enabled, let (msg, _, _) = try? BDecoder.decode(data, allowTrailing: true), let t = msg["t"]?.data, let y = msg["y"]?.string else { return }
        switch y {
        case "q": handleQuery(msg, t: t, from: addr)
        case "r", "e":
            guard let p = pending.removeValue(forKey: t), p.addr.ip == addr.ip else { return }
            let r = msg["r"]
            if let ip = msg["ip"]?.data, let me = PeerAddr.parseCompact(ip, v6: ip.count == 18).first { vote(me.ip) }
            if let id = r?["id"]?.data { saw(id, addr) }
            guard let lookup = p.lookup else { return }
            lookup.inflight -= 1
            if let i = lookup.candidates.firstIndex(where: { $0.addr == p.addr }) {
                lookup.candidates[i].state = y == "r" ? 2 : 3
                lookup.candidates[i].token = r?["token"]?.data
            }
            if let r {
                if let nodes = r[nodesKey]?.data {
                    var i = 0
                    while i + nodeSize <= nodes.count {
                        let id = nodes.subdata(in: nodes.startIndex + i..<nodes.startIndex + i + 20)
                        if let a = PeerAddr.parseCompact(nodes.subdata(in: nodes.startIndex + i + 20..<nodes.startIndex + i + nodeSize), v6: v6).first { add(id, a, to: lookup) }
                        i += nodeSize
                    }
                }
                if let values = r["values"]?.list {
                    let peers = values.compactMap { $0.data }.filter { $0.count == 6 || $0.count == 18 }.flatMap { PeerAddr.parseCompact($0, v6: $0.count == 18) }.filter { lookup.found.insert($0).inserted }
                    if !peers.isEmpty { lookup.onPeers(peers) }
                }
            }
            step(lookup)
        default: break
        }
    }

    private func vote(_ ip: String) {
        ipVotes[ip, default: 0] += 1
        if ipVotes[ip] == 10 { onExternalIP?(ip); externalAddress(ip) }
        if ipVotes.count > 50 { ipVotes.removeAll() }
    }

    /// At most 50 queries per address per 5 s and 1,000 a second overall: no amplification or flooding.
    private func allowQuery(from addr: PeerAddr) -> Bool {
        let now = Date()
        if now.timeIntervalSince(globalSince) >= 1 { globalSince = now; globalQueries = 0 }
        globalQueries += 1
        guard globalQueries <= 1000 else { return false }
        var entry = queryCounts[addr.ip] ?? (0, now)
        if now.timeIntervalSince(entry.since) > 5 { entry = (0, now) }
        entry.count += 1
        queryCounts[addr.ip] = entry
        if queryCounts.count > 5000 { queryCounts = queryCounts.filter { now.timeIntervalSince($0.value.since) < 5 } }
        return entry.count <= 50
    }

    private func handleQuery(_ msg: BValue, t: Data, from addr: PeerAddr) {
        guard let q = msg["q"]?.string, let a = msg["a"], let id = a["id"]?.data, id.count == 20, allowQuery(from: addr) else { return }
        if a["ro"]?.int != 1 { saw(id, addr) }
        switch q {
        case "ping":
            reply(t, [:], to: addr)
        case "find_node":
            guard let target = a["target"]?.data, target.count == 20 else { return }
            reply(t, [nodesKey: .bytes(compactNodes(closest(target)))], to: addr)
        case "sample_infohashes":
            guard let target = a["target"]?.data, target.count == 20 else { return }
            let sample = stored.keys.shuffled().prefix(20).reduce(Data(), +)
            reply(t, ["samples": .bytes(sample), "num": .int(Int64(stored.count)), "interval": .int(21600), nodesKey: .bytes(compactNodes(closest(target)))], to: addr)
        case "get_peers":
            guard let hash = a["info_hash"]?.data, hash.count == 20 else { return }
            var r: [String: BValue] = ["token": .bytes(token(for: addr, secret: secret)), nodesKey: .bytes(compactNodes(closest(hash)))]
            if let peers = stored[hash], !peers.isEmpty {
                r["values"] = .list(peers.keys.shuffled().prefix(50).compactMap { $0.compact.map(BValue.bytes) })
            }
            reply(t, r, to: addr)
        case "announce_peer":
            guard let hash = a["info_hash"]?.data, hash.count == 20, let tok = a["token"]?.data,
                  tok == token(for: addr, secret: secret) || tok == token(for: addr, secret: oldSecret) else { return }
            let port = a["implied_port"]?.int == 1 ? addr.port : UInt16(clamping: a["port"]?.int ?? 0)
            guard port > 0 else { return }
            if stored.count < 2000 || stored[hash] != nil {
                var peers = stored[hash] ?? [:]
                if peers.count < 200 { peers[PeerAddr(ip: addr.ip, port: port)] = Date() }
                stored[hash] = peers
            }
            reply(t, [:], to: addr)
        default:
            socket.send(BValue.d(["t": .bytes(t), "y": .s("e"), "e": .list([.int(204), .s("Method Unknown")])]).encoded, to: addr)
        }
    }

    // MARK: Upkeep

    func bootstrap() {
        guard Date().timeIntervalSince(lastBootstrap) > 20 else { return }
        lastBootstrap = Date()
        let target = nodeID
        let family = v6 ? AF_INET6 : AF_INET
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var found: [PeerAddr] = []
            for router in Self.routers {
                guard let addr = PeerAddr(router) else { continue }
                var hints = addrinfo()
                hints.ai_family = family
                hints.ai_socktype = SOCK_DGRAM
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(addr.ip, String(addr.port), &hints, &result) == 0 else { continue }
                var p = result
                while let info = p {
                    if let sa = info.pointee.ai_addr, info.pointee.ai_family == family {
                        var storage = sockaddr_storage()
                        memcpy(&storage, sa, Int(info.pointee.ai_addrlen))
                        if let a = UDPSocket.address(storage) { found.append(a) }
                    }
                    p = info.pointee.ai_next
                }
                freeaddrinfo(result)
            }
            engineQueue.async {
                guard let self else { return }
                let lookup = Lookup(target: target, getPeers: false, announcePort: nil) { _ in }
                for a in found { self.add(nil, a, to: lookup) }
                for node in self.closest(target, count: 16) { self.add(node.id, node.addr, to: lookup) }
                self.lookups.append(lookup)
                self.step(lookup)
            }
        }
    }

    func tick() {
        let now = Date()
        for (t, p) in pending where now.timeIntervalSince(p.sent) > 4 {
            pending[t] = nil
            failed(p.addr)
            if let lookup = p.lookup {
                lookup.inflight -= 1
                if let i = lookup.candidates.firstIndex(where: { $0.addr == p.addr }) { lookup.candidates[i].state = 3 }
                step(lookup)
            }
        }
        for lookup in lookups where now.timeIntervalSince(lookup.started) > 60 { finish(lookup) }
        if now.timeIntervalSince(secretChanged) > 300 {
            oldSecret = secret
            secret = Data.random(8)
            secretChanged = now
            for (hash, peers) in stored {
                let fresh = peers.filter { now.timeIntervalSince($0.value) < 1800 }
                stored[hash] = fresh.isEmpty ? nil : fresh
            }
        }
        if nodeCount < 20 { bootstrap() }
        // Refresh: a lookup into each of the nearest buckets that has gone quiet.
        if now.timeIntervalSince(lastRefresh) > 900 {
            lastRefresh = now
            let depth = (buckets.lastIndex { !$0.isEmpty } ?? 0) + 1
            for b in 0..<min(depth, 160) where buckets[b].allSatisfy({ now.timeIntervalSince($0.lastSeen) > 900 }) {
                var target = Data.random(20)
                for bit in 0...b {  // same first b bits as us, then a different one
                    let byte = bit / 8, mask = UInt8(0x80 >> (bit % 8))
                    let ours = nodeID[nodeID.startIndex + byte] & mask
                    target[byte] = (target[byte] & ~mask) | (bit == b ? (ours ^ mask) : ours)
                }
                start(Lookup(target: target, getPeers: false, announcePort: nil) { _ in })
            }
        }
    }
}
