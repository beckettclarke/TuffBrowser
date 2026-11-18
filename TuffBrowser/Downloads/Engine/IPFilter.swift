import Foundation

/// Blocks peers by address: PeerGuardian text lists (`name:1.2.3.0-1.2.3.255`), eMule
/// `ipfilter.dat` (`001.002.003.000 - 001.002.003.255 , 000 , name`, levels below 128 block),
/// CIDR blocks and single addresses, IPv4 and IPv6. Lookups are a binary search.
final class IPFilter {
    private var ranges: [(UInt128, UInt128)] = []
    var count: Int { ranges.count }

    init() {}

    init(text: String) {
        var list: [(UInt128, UInt128)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("//") else { continue }
            if let r = Self.parse(line) { list.append(r) }
        }
        list.sort { $0.0 < $1.0 }
        // Merge overlapping ranges.
        for r in list {
            if let last = ranges.last, r.0 <= last.1 &+ 1 { ranges[ranges.count - 1].1 = max(last.1, r.1) } else { ranges.append(r) }
        }
    }

    private static func number(_ s: Substring) -> UInt128? {
        var ip = s.trimmingCharacters(in: .whitespaces)
        // eMule pads with zeros ("001.002.003.000"), which inet_pton refuses.
        if !ip.contains(":") { ip = ip.split(separator: ".").map { String(Int($0) ?? -1) }.joined(separator: ".") }
        return PeerAddr(ip: ip, port: 1).numeric
    }

    private static func parse(_ line: String) -> (UInt128, UInt128)? {
        var body = Substring(line)
        // eMule: "range , level , name"
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        if fields.count >= 2, let level = Int(fields[1].trimmingCharacters(in: .whitespaces)) {
            guard level < 128 else { return nil }
            body = fields[0]
        } else if let colon = line.lastIndex(of: ":"), line[line.index(after: colon)...].contains("."), line[line.index(after: colon)...].contains("-") {
            // PeerGuardian: "name:range" (the name may itself contain colons).
            body = line[line.index(after: colon)...]
        }
        if let slash = body.firstIndex(of: "/"), let bits = Int(body[body.index(after: slash)...].trimmingCharacters(in: .whitespaces)), let base = number(body[..<slash]) {
            let total = body.contains(":") ? 128 : 32
            guard bits >= 0, bits <= total else { return nil }
            let host = UInt128(total - bits) >= 128 ? UInt128.max : (UInt128(1) << UInt128(total - bits)) - 1
            return (base & ~host, base | host)
        }
        let ends = body.split(separator: "-", maxSplits: 1)
        if ends.count == 2, let a = number(ends[0]), let b = number(ends[1]), a <= b { return (a, b) }
        if ends.count == 1, let a = number(ends[0]) { return (a, a) }
        return nil
    }

    func blocks(_ addr: PeerAddr) -> Bool {
        guard !ranges.isEmpty, let n = addr.numeric else { return false }
        var lo = 0, hi = ranges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if n < ranges[mid].0 { hi = mid - 1 } else if n > ranges[mid].1 { lo = mid + 1 } else { return true }
        }
        return false
    }
}

/// CRC-32C (Castagnoli), for BEP 42 node ids.
enum CRC32C {
    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0x82F6_3B78 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xffff_ffff
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xffff_ffff
    }
}
