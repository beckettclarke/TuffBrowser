import Foundation

/// A block request: 16 KiB of a piece.
struct Block: Hashable {
    let piece: Int
    let offset: Int
    let length: Int
}

/// One connection to a peer, speaking the BitTorrent wire protocol (BEP 3) with the Fast
/// extension (BEP 6), the extension protocol (BEP 10), ut_metadata (BEP 9), ut_pex (BEP 11),
/// upload_only (BEP 21), v2 hash transfer (BEP 52) and lt_donthave (BEP 54).
/// Decoding lives here; what to do about each message is the torrent's business.
final class Peer {
    static let blockSize = 16 * 1024
    static let pexID: UInt8 = 1, metadataID: UInt8 = 2, donthaveID: UInt8 = 3, uploadOnlyID: UInt8 = 4

    let transport: PeerTransport
    let incoming: Bool
    var addr: PeerAddr { transport.remote }
    weak var torrent: Torrent?
    /// Where the peer says it accepts connections (its listen port, from the ext handshake).
    var listenAddr: PeerAddr?

    enum Phase { case connecting, handshaking, active, closed }
    var phase = Phase.connecting
    var infoHash: Data?
    var peerID = Data()
    var client = ""
    var amChoking = true, amInterested = false
    var peerChoking = true, peerInterested = false
    var have: Bitfield?
    /// Have-all / have-none / haves seen before the torrent knows its piece count (magnets).
    var haveAll = false
    var pendingHaves: [Int] = []
    var supportsFast = false, supportsExt = false, supportsDHT = false, supportsV2 = false
    /// The peer only uploads (a seed, or done with what it wants): BEP 21.
    var uploadOnly = false
    /// Super-seeding: the piece we last offered this peer.
    var superSeedOffer: Int?
    var lastUnchoked = Date.distantPast
    /// v2 hash requests in flight (file index → asked at).
    var hashRequests: [Int: Date] = [:]
    var extIDs: [String: UInt8] = [:]
    var metadataSize = 0
    var requests: [Block] = []
    var requestedAt: [Block: Date] = [:]
    var peerRequests: [Block] = []
    var allowedFast = Set<Int>()
    /// Pieces the peer suggested we fetch (BEP 6).
    var suggested = Set<Int>()
    var down = RateMeter(), up = RateMeter()
    var connectedAt = Date()
    var lastPiece = Date()
    var lastMessage = Date()
    var lastSent = Date()
    var lastPex = Date.distantPast
    var pexSent = Set<PeerAddr>()
    var optimistic = false
    var snubbed = false
    /// How many requests the peer will queue (its "reqq"), and when to look for work for it again.
    var reqq = 250
    var idleUntil = Date.distantPast
    var failedHashes = 0
    var reading = false

    private var buffer = [UInt8]()
    private var head = 0

    init(transport: PeerTransport, incoming: Bool) {
        self.transport = transport
        self.incoming = incoming
    }

    var flags: String {
        var f = ""
        if transport.isUTP { f += "µ" }
        if (transport as? MSETransport)?.encrypted == true { f += "E" }
        f += incoming ? "I" : "O"
        if !peerChoking && amInterested { f += "D" } else if amInterested { f += "d" }
        if !amChoking && peerInterested { f += "U" } else if peerInterested { f += "u" }
        if optimistic { f += "O" }
        if snubbed { f += "S" }
        return f
    }

    // MARK: Sending

    func sendHandshake(infoHash: Data, peerID: Data) {
        var d = Data([19])
        d.append(contentsOf: Array("BitTorrent protocol".utf8))
        // Reserved bits: extension protocol (BEP 10), v2 (BEP 52), Fast extension (BEP 6), DHT (BEP 5).
        d.append(contentsOf: [0, 0, 0, 0, 0, 0x10, 0, 0x15])
        d.append(infoHash)
        d.append(peerID)
        transport.send(d)
        lastSent = Date()
    }

    private func message(_ id: UInt8, _ payload: Data = Data()) {
        guard phase == .active else { return }
        var d = Data(capacity: 5 + payload.count)
        d.put32(UInt32(1 + payload.count))
        d.append(id)
        d.append(payload)
        transport.send(d)
        lastSent = Date()
    }

    private func ints(_ values: Int...) -> Data {
        var d = Data(capacity: values.count * 4)
        for v in values { d.put32(UInt32(truncatingIfNeeded: v)) }
        return d
    }

    func choke() { if !amChoking { amChoking = true; message(0); if !supportsFast { peerRequests.removeAll() } else { rejectAll() } } }
    func unchoke() { if amChoking { amChoking = false; message(1) } }
    func interested() { if !amInterested { amInterested = true; message(2) } }
    func notInterested() { if amInterested { amInterested = false; message(3) } }
    func sendHave(_ piece: Int) { message(4, ints(piece)) }
    func sendBitfield(_ b: Bitfield) {
        if supportsFast, b.isFull { message(14) } else if supportsFast, b.setCount == 0 { message(15) } else { message(5, b.data) }
    }
    func request(_ b: Block) {
        requests.append(b)
        requestedAt[b] = Date()
        message(6, ints(b.piece, b.offset, b.length))
    }
    func cancel(_ b: Block) {
        guard let i = requests.firstIndex(of: b) else { return }
        requests.remove(at: i)
        requestedAt[b] = nil
        message(8, ints(b.piece, b.offset, b.length))
    }
    func sendPiece(_ b: Block, data: Data) {
        var d = ints(b.piece, b.offset)
        d.append(data)
        message(7, d)
        up.add(data.count)
    }
    func reject(_ b: Block) { if supportsFast { message(16, ints(b.piece, b.offset, b.length)) } }
    private func rejectAll() { for b in peerRequests { reject(b) }; peerRequests.removeAll() }
    func suggest(_ piece: Int) { if supportsFast { message(13, ints(piece)) } }
    func allowFast(_ piece: Int) { if supportsFast { message(17, ints(piece)) } }

    /// BEP 52: ask for (or send) a run of hashes from a file's merkle tree.
    func hashMessage(_ id: UInt8, root: Data, base: Int, index: Int, length: Int, proof: Int, hashes: Data = Data()) {
        var d = root
        d.append(ints(base, index, length, proof))
        d.append(hashes)
        message(id, d)
    }

    func sendDontHave(_ piece: Int) {
        guard let id = extIDs["lt_donthave"] else { return }
        var d = Data([id])
        d.put32(UInt32(piece))
        message(20, d)
    }

    func sendUploadOnly(_ on: Bool) {
        guard let id = extIDs["upload_only"] else { return }
        message(20, Data([id, on ? 1 : 0]))
    }

    func sendPort(_ port: UInt16) { if supportsDHT { var d = Data(); d.put16(port); message(9, d) } }
    func keepAlive() { guard phase == .active else { return }; transport.send(Data([0, 0, 0, 0])); lastSent = Date() }

    func sendExtended(_ id: UInt8, _ dict: BValue, trailer: Data = Data()) {
        var d = Data([id])
        d.append(dict.encoded)
        d.append(trailer)
        message(20, d)
    }

    func sendExtHandshake(listenPort: UInt16, metadataSize: Int?, isPrivate: Bool, uploadOnly: Bool, ipv6: String?) {
        var m: [String: BValue] = ["ut_metadata": .int(Int64(Self.metadataID)), "lt_donthave": .int(Int64(Self.donthaveID)), "upload_only": .int(Int64(Self.uploadOnlyID))]
        if !isPrivate { m["ut_pex"] = .int(Int64(Self.pexID)) }
        var d: [String: BValue] = ["m": .d(m), "p": .int(Int64(listenPort)), "v": .s("Tuff 1.0"), "reqq": .int(500)]
        if let metadataSize { d["metadata_size"] = .int(Int64(metadataSize)) }
        if uploadOnly { d["upload_only"] = .int(1) }
        if let ipv6, let c = PeerAddr(ip: ipv6, port: 0).compact { d["ipv6"] = .bytes(c.prefix(16)) }
        if let ip = addr.compact?.dropLast(2) { d["yourip"] = .bytes(Data(ip)) }
        sendExtended(0, .d(d))
    }

    // MARK: Receiving

    /// Splits incoming bytes into the handshake and messages, handing each to the torrent / session.
    func received(_ data: Data, handshake: (Peer, Data, Data) -> Bool, message: (Peer, UInt8, Data) -> Void) {
        buffer.append(contentsOf: data)
        lastMessage = Date()
        while phase != .closed {
            let available = buffer.count - head
            if phase == .handshaking || phase == .connecting {
                guard available >= 68 else { break }
                guard buffer[head] == 19, Array(buffer[head + 1..<head + 20]) == Array("BitTorrent protocol".utf8) else {
                    close("not BitTorrent"); return
                }
                let reserved = buffer[head + 20..<head + 28]
                supportsExt = reserved[reserved.startIndex + 5] & 0x10 != 0
                supportsFast = reserved[reserved.startIndex + 7] & 0x04 != 0
                supportsDHT = reserved[reserved.startIndex + 7] & 0x01 != 0
                supportsV2 = reserved[reserved.startIndex + 7] & 0x10 != 0
                let hash = Data(buffer[head + 28..<head + 48])
                peerID = Data(buffer[head + 48..<head + 68])
                client = Peer.clientName(peerID)
                head += 68
                phase = .active
                guard handshake(self, hash, peerID) else { close("unwanted"); return }
                continue
            }
            guard available >= 4 else { break }
            let length = Int(UInt32(buffer[head]) << 24 | UInt32(buffer[head + 1]) << 16 | UInt32(buffer[head + 2]) << 8 | UInt32(buffer[head + 3]))
            guard length <= 2 << 20 else { close("message too large"); return }
            guard available >= 4 + length else { break }
            if length > 0 {
                let id = buffer[head + 4]
                let payload = Data(buffer[head + 5..<head + 4 + length])
                head += 4 + length
                message(self, id, payload)
            } else {
                head += 4
            }
        }
        if head > 0 && (head == buffer.count || head > 1 << 16) {
            buffer.removeFirst(head)
            head = 0
        }
    }

    func close(_ why: String) {
        guard phase != .closed else { return }
        phase = .closed
        transport.close()
        torrent?.peerClosed(self, why: why)
    }

    /// Names the client from its peer id: Azureus-style ("-qB4650-") or a few others.
    static func clientName(_ id: Data) -> String {
        let b = [UInt8](id)
        guard b.count == 20 else { return "" }
        if b[0] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-") {
            let code = String(bytes: b[1...2], encoding: .ascii) ?? ""
            let v = b[3...6].compactMap { c -> String? in
                switch c {
                case 48...57: String(c - 48)
                case 65...90: String(Int(c) - 55)
                case 97...122: String(Int(c) - 61)
                default: nil
                }
            }
            let names = [
                "qB": "qBittorrent", "TR": "Transmission", "UT": "µTorrent", "LT": "libtorrent", "lt": "libTorrent",
                "DE": "Deluge", "AZ": "Vuze", "BI": "BiglyBT", "BT": "BitTorrent", "TX": "Tixati", "FD": "Free Download Manager",
                "WW": "WebTorrent", "TF": "Tuff", "KT": "KTorrent", "FX": "Flashget", "AG": "Ares", "BC": "BitComet",
                "XL": "Xunlei", "SD": "Thunder", "PI": "PicoTorrent", "RT": "rTorrent", "UM": "µTorrent Mac", "XF": "Xfplay",
            ]
            let name = names[code] ?? code
            return v.count == 4 ? "\(name) \(v[0]).\(v[1]).\(v[2])" : name
        }
        if b[0] == UInt8(ascii: "M"), let s = String(bytes: b[0..<8], encoding: .ascii) { return "Mainline " + s.dropFirst().replacingOccurrences(of: "-", with: ".") }
        return String(bytes: b[0..<8].filter { $0 >= 32 && $0 < 127 }, encoding: .ascii) ?? ""
    }
}
