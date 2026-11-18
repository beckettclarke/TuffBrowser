import Foundation

/// Opens the listening port on the router so peers can reach us: PCP (falling back to
/// NAT-PMP) and UPnP IGD side by side, renewing leases and removing the mappings at exit.
/// Also learns the external address.
final class PortMapper {
    private(set) var externalIP: String?
    private(set) var status: [String: String] = [:]
    var onExternalIP: ((String) -> Void)?
    private let port: UInt16
    private var gateway: String?
    private var localIP: String?
    private var pmpSocket: UDPSocket?
    private var ssdp: UDPSocket?
    private var upnpControl: (url: URL, service: String)?
    private var renewTimer: DispatchSourceTimer?
    private var usePCP = true
    private var nonce = Data.random(12)

    init(port: UInt16) { self.port = port }

    func start() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let gateway = Self.defaultGateway()
            engineQueue.async {
                guard let self else { return }
                self.gateway = gateway
                self.localIP = gateway.flatMap(Self.localAddress(toward:))
                self.mapAll()
                self.discoverUPnP()
                let timer = DispatchSource.makeTimerSource(queue: engineQueue)
                timer.schedule(deadline: .now() + 1500, repeating: 1500)
                timer.setEventHandler { [weak self] in self?.mapAll(); self?.upnpMap(lease: 3600) }
                timer.resume()
                self.renewTimer = timer
            }
        }
    }

    // MARK: PCP / NAT-PMP

    private func mapAll(lifetime: UInt32 = 3600) {
        guard let gateway, !gateway.contains(":") else { return }
        if pmpSocket == nil {
            pmpSocket = UDPSocket(port: 0)
            pmpSocket?.onPacket = { [weak self] data, from in if from.ip == gateway { self?.pmpReply(data) } }
        }
        let target = PeerAddr(ip: gateway, port: 5351)
        for proto: UInt8 in [6, 17] {
            if usePCP, let localIP {
                var d = Data([2, 1, 0, 0])
                d.put32(lifetime)
                d.append(Data(repeating: 0, count: 10) + Data([0xff, 0xff]))
                d.append(contentsOf: localIP.split(separator: ".").compactMap { UInt8($0) })
                d.append(nonce)
                d.append(proto)
                d.append(Data(count: 3))
                d.put16(port)
                d.put16(port)
                d.append(Data(count: 16))
                pmpSocket?.send(d, to: target)
            } else {
                var d = Data([0, proto == 6 ? 2 : 1, 0, 0])
                d.put16(port)
                d.put16(port)
                d.put32(lifetime)
                pmpSocket?.send(d, to: target)
            }
        }
        if !usePCP { pmpSocket?.send(Data([0, 0]), to: target) }
        // No PCP answer at all: try NAT-PMP.
        if usePCP, lifetime > 0 {
            engineQueue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.usePCP, self.status["PCP"] == nil else { return }
                self.usePCP = false
                self.mapAll()
            }
        }
    }

    private func pmpReply(_ d: Data) {
        guard d.count >= 4 else { return }
        if d[d.startIndex] == 0, usePCP {
            // A NAT-PMP router answering a PCP request: speak NAT-PMP instead.
            usePCP = false
            mapAll()
            return
        }
        if d[d.startIndex] == 2, d.count >= 60 {
            let result = d[d.startIndex + 3]
            status["PCP"] = result == 0 ? "Mapped" : "Error \(result)"
            let ip = d.subdata(in: d.startIndex + 44..<d.startIndex + 60)
            if result == 0, ip.prefix(12) == Data(repeating: 0, count: 10) + Data([0xff, 0xff]) { found(ip.suffix(4).map(String.init).joined(separator: ".")) }
        } else if d[d.startIndex] == 0 {
            let op = d[d.startIndex + 1], result = d.u16(2)
            if op == 128, result == 0, d.count >= 12 { found(d.subdata(in: d.startIndex + 8..<d.startIndex + 12).map(String.init).joined(separator: ".")) }
            if op > 128 { status["NAT-PMP"] = result == 0 ? "Mapped" : "Error \(result)" }
        }
    }

    private func found(_ ip: String) {
        guard ip != externalIP, ip != "0.0.0.0" else { return }
        externalIP = ip
        onExternalIP?(ip)
    }

    // MARK: UPnP IGD

    private func discoverUPnP() {
        guard let socket = UDPSocket(port: 0) else { return }
        ssdp = socket
        socket.onPacket = { [weak self] data, _ in
            guard let self, self.upnpControl == nil, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("location:") {
                if let url = URL(string: line.dropFirst(9).trimmingCharacters(in: .whitespaces)) { self.describe(url) }
            }
        }
        for st in ["urn:schemas-upnp-org:device:InternetGatewayDevice:1", "urn:schemas-upnp-org:service:WANIPConnection:1"] {
            let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nST: \(st)\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\n\r\n"
            socket.send(Data(msg.utf8), to: PeerAddr(ip: "239.255.255.250", port: 1900))
        }
        engineQueue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.ssdp?.close(); self?.ssdp = nil }
    }

    private func describe(_ location: URL) {
        URLSession.shared.dataTask(with: location) { [weak self] data, _, _ in
            guard let data, let xml = String(data: data, encoding: .utf8) else { return }
            for service in ["WANIPConnection:2", "WANIPConnection:1", "WANPPPConnection:1"] {
                let type = "urn:schemas-upnp-org:service:" + service
                guard let at = xml.range(of: type), let open = xml.range(of: "<controlURL>", range: at.upperBound..<xml.endIndex),
                      let close = xml.range(of: "</controlURL>", range: open.upperBound..<xml.endIndex) else { continue }
                let path = String(xml[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
                guard let url = URL(string: path, relativeTo: location)?.absoluteURL else { continue }
                engineQueue.async {
                    guard let self, self.upnpControl == nil else { return }
                    self.upnpControl = (url, type)
                    self.upnpMap(lease: 3600)
                    self.soap("GetExternalIPAddress", [:]) { body in
                        if let ip = Self.tag("NewExternalIPAddress", in: body), !ip.isEmpty { self.found(ip) }
                    }
                }
                return
            }
        }.resume()
    }

    private func upnpMap(lease: Int) {
        guard upnpControl != nil, let localIP else { return }
        for proto in ["TCP", "UDP"] {
            soap("AddPortMapping", [
                "NewRemoteHost": "", "NewExternalPort": "\(port)", "NewProtocol": proto, "NewInternalPort": "\(port)",
                "NewInternalClient": localIP, "NewEnabled": "1", "NewPortMappingDescription": "Tuff", "NewLeaseDuration": "\(lease)",
            ]) { [weak self] body in
                // Some routers only take permanent mappings.
                if body.contains("<errorCode>725</errorCode>"), lease != 0 { self?.upnpMap(lease: 0); return }
                self?.status["UPnP"] = body.contains("AddPortMappingResponse") ? "Mapped" : "Refused"
            }
        }
    }

    private func soap(_ action: String, _ args: [String: String], done: @escaping (String) -> Void) {
        guard let (url, service) = upnpControl else { return }
        let order = ["NewRemoteHost", "NewExternalPort", "NewProtocol", "NewInternalPort", "NewInternalClient", "NewEnabled", "NewPortMappingDescription", "NewLeaseDuration"]
        let body = order.compactMap { k in args[k].map { "<\(k)>\($0)</\(k)>" } }.joined()
        let envelope = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"\(service)\">\(body)</u:\(action)></s:Body></s:Envelope>"
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data(envelope.utf8)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            engineQueue.async { done(text) }
        }.resume()
    }

    private static func tag(_ name: String, in xml: String) -> String? {
        guard let a = xml.range(of: "<\(name)>"), let b = xml.range(of: "</\(name)>", range: a.upperBound..<xml.endIndex) else { return nil }
        return String(xml[a.upperBound..<b.lowerBound])
    }

    /// At quit: lifetime 0 removes PCP / NAT-PMP mappings; UPnP ones are deleted.
    func removeAll() {
        renewTimer?.cancel()
        mapAll(lifetime: 0)
        guard upnpControl != nil else { return }
        let group = DispatchGroup()
        for proto in ["TCP", "UDP"] {
            group.enter()
            soap("DeletePortMapping", ["NewRemoteHost": "", "NewExternalPort": "\(port)", "NewProtocol": proto]) { _ in group.leave() }
        }
        _ = group.wait(timeout: .now() + 1)
    }

    // MARK: Finding the router

    static func defaultGateway() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "gateway" { return parts[1] }
        }
        return nil
    }

    /// Our address on the router's network: what a UDP socket aimed at it would use.
    static func localAddress(toward gateway: String) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var to = sockaddr_in()
        to.sin_family = sa_family_t(AF_INET)
        to.sin_port = UInt16(5351).bigEndian
        guard inet_pton(AF_INET, gateway, &to.sin_addr) == 1 else { return nil }
        let connected = withUnsafePointer(to: &to) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { return nil }
        var mine = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &mine) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return UDPSocket.address(mine)?.ip
    }

    /// A global IPv6 address of this Mac, for BEP 7's `ipv6=` tracker parameter.
    static func globalIPv6() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var p = list
        while let entry = p {
            if let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET6) {
                var storage = sockaddr_storage()
                memcpy(&storage, sa, MemoryLayout<sockaddr_in6>.size)
                if let addr = UDPSocket.address(storage), !addr.isLocal, addr.ip.hasPrefix("2") || addr.ip.hasPrefix("3") { return addr.ip }
            }
            p = entry.pointee.ifa_next
        }
        return nil
    }
}

/// Local Service Discovery (BEP 14): finds peers on the same network by multicast, over IPv4 and IPv6.
final class LocalDiscovery {
    private var sockets: [(UDPSocket, PeerAddr)] = []
    private let cookie = String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    var onPeer: ((Data, PeerAddr) -> Void)?
    private let port: UInt16

    init(port: UInt16) {
        self.port = port
        for (v6, group) in [(false, "239.192.152.143"), (true, "ff15::efc0:988f")] {
            guard let s = UDPSocket(port: 6771, v6: v6, reusePort: true) else { continue }
            s.join(group)
            s.onPacket = { [weak self] data, from in self?.received(data, from) }
            sockets.append((s, PeerAddr(ip: group, port: 6771)))
        }
    }

    func close() { sockets.forEach { $0.0.close() } }

    func announce(_ hashes: [Data]) {
        guard !hashes.isEmpty else { return }
        for (socket, group) in sockets {
            let host = group.isV6 ? "[\(group.ip)]:6771" : "\(group.ip):6771"
            for chunk in stride(from: 0, to: hashes.count, by: 8) {
                let lines = hashes[chunk..<min(chunk + 8, hashes.count)].map { "Infohash: \($0.tHex)\r\n" }.joined()
                let msg = "BT-SEARCH * HTTP/1.1\r\nHost: \(host)\r\nPort: \(port)\r\n\(lines)cookie: \(cookie)\r\n\r\n\r\n"
                socket.send(Data(msg.utf8), to: group)
            }
        }
    }

    private func received(_ data: Data, _ from: PeerAddr) {
        guard data.count < 2048, let text = String(data: data, encoding: .utf8), text.hasPrefix("BT-SEARCH"), !text.contains("cookie: \(cookie)") else { return }
        var port: UInt16?
        var hashes: [Data] = []
        for line in text.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "port": port = UInt16(parts[1])
            case "infohash": if let h = Data(tHex: parts[1]), h.count == 20 { hashes.append(h) }
            default: break
            }
        }
        guard let port, port > 0 else { return }
        for h in hashes { onPeer?(h, PeerAddr(ip: from.ip, port: port)) }
    }
}
