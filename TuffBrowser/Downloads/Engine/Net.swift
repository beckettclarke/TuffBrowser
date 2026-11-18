import Foundation
import Network

/// Everything in the torrent engine runs on this queue, apart from disk work.
let engineQueue = DispatchQueue(label: "tuff.torrent", qos: .utility)

/// A peer's address. IPv4-mapped IPv6 addresses are kept in their IPv4 form.
struct PeerAddr: Hashable, CustomStringConvertible {
    let ip: String
    let port: UInt16

    init(ip: String, port: UInt16) {
        var ip = ip
        if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }
        if ip.lowercased().hasPrefix("::ffff:"), ip.contains(".") { ip = String(ip.dropFirst(7)) }
        self.ip = ip
        self.port = port
    }

    init?(_ string: String) {
        var s = Substring(string.trimmingCharacters(in: .whitespaces))
        var host: Substring
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            host = s[s.index(after: s.startIndex)..<close]
            s = s[s.index(after: close)...]
        } else {
            guard let colon = s.lastIndex(of: ":") else { return nil }
            host = s[..<colon]
            s = s[colon...]
        }
        guard s.hasPrefix(":"), let port = UInt16(s.dropFirst()), port > 0, !host.isEmpty else { return nil }
        self.init(ip: String(host), port: port)
    }

    var isV6: Bool { ip.contains(":") }
    var description: String { isV6 ? "[\(ip)]:\(port)" : "\(ip):\(port)" }

    /// 6 bytes (IPv4) or 18 bytes (IPv6), as trackers, PEX and DHT send them.
    var compact: Data? {
        var out = Data()
        if isV6 {
            var a = in6_addr()
            guard inet_pton(AF_INET6, ip, &a) == 1 else { return nil }
            withUnsafeBytes(of: &a) { out.append(contentsOf: $0) }
        } else {
            var a = in_addr()
            guard inet_pton(AF_INET, ip, &a) == 1 else { return nil }
            withUnsafeBytes(of: &a) { out.append(contentsOf: $0) }
        }
        out.put16(port)
        return out
    }

    static func parseCompact(_ data: Data, v6: Bool = false) -> [PeerAddr] {
        let size = v6 ? 18 : 6
        var out: [PeerAddr] = []
        var i = 0
        let bytes = [UInt8](data)
        while i + size <= bytes.count {
            let ip: String
            if v6 {
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                var a = in6_addr()
                withUnsafeMutableBytes(of: &a) { $0.copyBytes(from: bytes[i..<i + 16]) }
                inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count))
                ip = String(cString: buf)
            } else {
                ip = "\(bytes[i]).\(bytes[i + 1]).\(bytes[i + 2]).\(bytes[i + 3])"
            }
            let port = UInt16(bytes[i + size - 2]) << 8 | UInt16(bytes[i + size - 1])
            if port > 0 { out.append(PeerAddr(ip: ip, port: port)) }
            i += size
        }
        return out
    }

    /// The address as a 128-bit number (IPv4 mapped into ::ffff:0:0/96), for filters and BEP 42.
    var numeric: UInt128? {
        if isV6 {
            var a = in6_addr()
            guard inet_pton(AF_INET6, ip, &a) == 1 else { return nil }
            return withUnsafeBytes(of: &a) { $0.reduce(UInt128(0)) { $0 << 8 | UInt128($1) } }
        }
        var a = in_addr()
        guard inet_pton(AF_INET, ip, &a) == 1 else { return nil }
        return UInt128(0xffff) << 32 | UInt128(UInt32(bigEndian: a.s_addr))
    }

    /// On this Mac's network: private ranges, link-local, loopback (LAN peers can skip speed limits).
    var isLocal: Bool {
        let lower = ip.lowercased()
        if isV6 { return lower == "::1" || lower.hasPrefix("fe8") || lower.hasPrefix("fe9") || lower.hasPrefix("fea") || lower.hasPrefix("feb") || lower.hasPrefix("fc") || lower.hasPrefix("fd") }
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || p[0] == 127 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168) || (p[0] == 169 && p[1] == 254)
    }

    /// Not worth dialling: unspecified, multicast, or the broadcast address.
    var isUsable: Bool {
        guard port > 0 else { return false }
        if isV6 { return !ip.lowercased().hasPrefix("ff") && ip != "::" }
        let first = Int(ip.split(separator: ".").first ?? "") ?? 0
        return first != 0 && first < 224
    }
}

/// A byte stream to a peer: TCP or µTP.
protocol PeerTransport: AnyObject {
    var onConnect: (() -> Void)? { get set }
    var onData: ((Data) -> Void)? { get set }
    var onClose: ((String) -> Void)? { get set }
    var remote: PeerAddr { get }
    var isUTP: Bool { get }
    /// Bytes handed to `send` that haven't gone out yet, so uploads can wait for room.
    var backlog: Int { get }
    func start()
    func send(_ data: Data)
    func close()
}

final class TCPTransport: PeerTransport {
    var onConnect: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onClose: ((String) -> Void)?
    let remote: PeerAddr
    let isUTP = false
    private(set) var backlog = 0
    private let connection: NWConnection
    private var closed = false

    init(to addr: PeerAddr, parameters: NWParameters) {
        remote = addr
        connection = NWConnection(host: NWEndpoint.Host(addr.ip), port: NWEndpoint.Port(rawValue: addr.port)!, using: parameters)
    }

    init(accepted: NWConnection) {
        connection = accepted
        if case .hostPort(let host, let port) = accepted.endpoint {
            remote = PeerAddr(ip: "\(host)", port: port.rawValue)
        } else {
            remote = PeerAddr(ip: "0.0.0.0", port: 0)
        }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.onConnect?(); self.receive()
            case .failed(let error): self.finish("\(error)")
            case .waiting(let error): self.finish("\(error)")
            case .cancelled: self.finish("closed")
            default: break
            }
        }
        connection.start(queue: engineQueue)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty { self.onData?(data) }
            if done || error != nil { self.finish(error.map { "\($0)" } ?? "closed by peer") } else { self.receive() }
        }
    }

    func send(_ data: Data) {
        guard !closed else { return }
        backlog += data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in self?.backlog -= data.count })
    }

    private func finish(_ why: String) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        let handler = onClose
        onClose = nil
        onData = nil
        handler?(why)
    }

    func close() {
        onClose = nil
        finish("closed")
    }
}

/// A non-blocking UDP socket (IPv4 or IPv6) on the engine queue, shared by the DHT and µTP.
final class UDPSocket {
    private let fd: Int32
    let v6: Bool
    private(set) var port: UInt16 = 0
    private var source: DispatchSourceRead?
    var onPacket: ((Data, PeerAddr) -> Void)?
    /// After each burst of packets has been handled (µTP sends its acks then).
    var onBurstEnd: (() -> Void)?

    init?(port: UInt16, v6: Bool = false, interface: String = "", reusePort: Bool = false) {
        self.v6 = v6
        fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        let size32 = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, size32)
        if reusePort { setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, size32) }
        if v6 { setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, size32) }
        var buf: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buf, size32)
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buf, size32)
        if !interface.isEmpty {
            var index = Int32(if_nametoindex(interface))
            if index > 0 { setsockopt(fd, v6 ? IPPROTO_IPV6 : IPPROTO_IP, v6 ? IPV6_BOUND_IF : IP_BOUND_IF, &index, size32) }
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var storage = sockaddr_storage()
        let length: socklen_t
        if v6 {
            withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                $0.pointee.sin6_family = sa_family_t(AF_INET6)
                $0.pointee.sin6_port = port.bigEndian
                $0.pointee.sin6_addr = in6addr_any
            } }
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        } else {
            withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_family = sa_family_t(AF_INET)
                $0.pointee.sin_port = port.bigEndian
                $0.pointee.sin_addr = in_addr(s_addr: INADDR_ANY)
            } }
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
        }
        let bound = withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
        guard bound == 0 else { Darwin.close(fd); return nil }
        var actual = sockaddr_storage()
        var actualLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &actualLength) } }
        self.port = Self.address(actual)?.port ?? port
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: engineQueue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }

    func close() { source?.cancel(); source = nil }

    /// Joins a multicast group (Local Service Discovery, SSDP).
    func join(_ group: String) {
        if v6 {
            var request = ipv6_mreq()
            guard inet_pton(AF_INET6, group, &request.ipv6mr_multiaddr) == 1 else { return }
            setsockopt(fd, IPPROTO_IPV6, IPV6_JOIN_GROUP, &request, socklen_t(MemoryLayout<ipv6_mreq>.size))
        } else {
            var request = ip_mreq()
            guard inet_pton(AF_INET, group, &request.imr_multiaddr) == 1 else { return }
            request.imr_interface = in_addr(s_addr: INADDR_ANY)
            setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &request, socklen_t(MemoryLayout<ip_mreq>.size))
        }
    }

    static func address(_ s: sockaddr_storage) -> PeerAddr? {
        var s = s
        switch Int32(s.ss_family) {
        case AF_INET:
            return withUnsafePointer(to: &s) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
                let a = UInt32(bigEndian: p.pointee.sin_addr.s_addr)
                return PeerAddr(ip: "\(a >> 24).\(a >> 16 & 0xff).\(a >> 8 & 0xff).\(a & 0xff)", port: UInt16(bigEndian: p.pointee.sin_port))
            } }
        case AF_INET6:
            return withUnsafePointer(to: &s) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                var addr = p.pointee.sin6_addr
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count))
                return PeerAddr(ip: String(cString: buf), port: UInt16(bigEndian: p.pointee.sin6_port))
            } }
        default: return nil
        }
    }

    private var buffer = [UInt8](repeating: 0, count: 65536)

    private func drain() {
        var count = 0
        while count < 2000 {
            var from = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = buffer.withUnsafeMutableBytes { buf in
                withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, buf.baseAddress, buf.count, 0, $0, &len) } }
            }
            if n <= 0 { break }
            count += 1
            guard let addr = Self.address(from) else { continue }
            onPacket?(Data(buffer[0..<n]), addr)
        }
        onBurstEnd?()
    }

    @discardableResult
    func send(_ data: Data, to addr: PeerAddr) -> Bool {
        guard addr.isV6 == v6 else { return false }
        var storage = sockaddr_storage()
        let length: socklen_t
        if v6 {
            let ok = withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p -> Bool in
                p.pointee.sin6_family = sa_family_t(AF_INET6)
                p.pointee.sin6_port = addr.port.bigEndian
                return inet_pton(AF_INET6, addr.ip, &p.pointee.sin6_addr) == 1
            } }
            guard ok else { return false }
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        } else {
            let ok = withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p -> Bool in
                p.pointee.sin_family = sa_family_t(AF_INET)
                p.pointee.sin_port = addr.port.bigEndian
                return inet_pton(AF_INET, addr.ip, &p.pointee.sin_addr) == 1
            } }
            guard ok else { return false }
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
        }
        let sent = data.withUnsafeBytes { buf in
            withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, buf.baseAddress, buf.count, 0, $0, length) } }
        }
        return sent == data.count
    }

    /// Sets the don't-fragment bit, for µTP's path MTU probes.
    func setDontFragment(_ on: Bool) {
        var v: Int32 = on ? 1 : 0
        if !v6 { setsockopt(fd, IPPROTO_IP, IP_DONTFRAG, &v, socklen_t(MemoryLayout<Int32>.size)) }
        else { setsockopt(fd, IPPROTO_IPV6, 62 /* IPV6_DONTFRAG */, &v, socklen_t(MemoryLayout<Int32>.size)) }
    }
}

/// Builds Network.framework parameters for peer connections: proxy and interface choices.
enum NetParams {
    static func tcp(_ settings: TorrentSettings) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 10
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        apply(settings, to: params, peers: true)
        return params
    }

    static func apply(_ settings: TorrentSettings, to params: NWParameters, peers: Bool) {
        if !settings.bindInterface.isEmpty, let interface = interfaces[settings.bindInterface] { params.requiredInterface = interface }
        if peers, settings.proxyPeers, let proxy = proxy(settings) {
            let context = NWParameters.PrivacyContext(description: "Tuff torrents")
            context.proxyConfigurations = [proxy]
            params.setPrivacyContext(context)
        }
    }

    static func proxy(_ settings: TorrentSettings) -> ProxyConfiguration? {
        guard settings.proxyType != 0, !settings.proxyHost.isEmpty, let port = NWEndpoint.Port(rawValue: UInt16(clamping: settings.proxyPort)) else { return nil }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(settings.proxyHost), port: port)
        let config = settings.proxyType == 1 ? ProxyConfiguration(socksv5Proxy: endpoint) : ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        if !settings.proxyUser.isEmpty { config.applyCredential(username: settings.proxyUser, password: settings.proxyPassword) }
        return config
    }

    /// Interfaces by name, kept current by the session's path monitor.
    static var interfaces: [String: NWInterface] = [:]
}

/// Shares bandwidth out: a token bucket refilled ten times a second. Zero means no limit.
final class RateLimiter {
    var limit: Int = 0 { didSet { tokens = min(tokens, max(limit, 0)) } }
    private(set) var tokens = 0

    func refill(interval: Double) {
        guard limit > 0 else { return }
        tokens = min(limit, tokens + Int(Double(limit) * interval))
    }

    var hasRoom: Bool { limit <= 0 || tokens > 0 }
    func take(_ n: Int) { if limit > 0 { tokens -= n } }
}

/// A smoothed bytes-per-second figure, fed once a second.
struct RateMeter {
    private(set) var rate: Double = 0
    private var pending: Int64 = 0
    private(set) var total: Int64 = 0

    mutating func add(_ n: Int) { pending += Int64(n); total += Int64(n) }

    mutating func tick() {
        rate = rate * 0.6 + Double(pending) * 0.4
        if rate < 1 { rate = 0 }
        pending = 0
    }
}
