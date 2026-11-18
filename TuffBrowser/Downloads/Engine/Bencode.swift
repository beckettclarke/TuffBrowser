import Foundation

/// A bencoded value (BEP 3): what .torrent files, trackers, DHT and the extension protocol speak.
indirect enum BValue {
    case int(Int64)
    case bytes(Data)
    case list([BValue])
    case dict([Data: BValue])

    static func s(_ string: String) -> BValue { .bytes(Data(string.utf8)) }
    static func d(_ pairs: [String: BValue]) -> BValue {
        .dict(Dictionary(uniqueKeysWithValues: pairs.map { (Data($0.key.utf8), $0.value) }))
    }

    subscript(key: String) -> BValue? {
        if case .dict(let d) = self { return d[Data(key.utf8)] }
        return nil
    }

    var int: Int64? { if case .int(let v) = self { return v }; return nil }
    var data: Data? { if case .bytes(let v) = self { return v }; return nil }
    var list: [BValue]? { if case .list(let v) = self { return v }; return nil }
    var dict: [Data: BValue]? { if case .dict(let v) = self { return v }; return nil }
    var string: String? { data.flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) } }

    var encoded: Data {
        var out = Data()
        encode(into: &out)
        return out
    }

    func encode(into out: inout Data) {
        switch self {
        case .int(let v):
            out.append(contentsOf: Array("i\(v)e".utf8))
        case .bytes(let v):
            out.append(contentsOf: Array("\(v.count):".utf8))
            out.append(v)
        case .list(let items):
            out.append(UInt8(ascii: "l"))
            for item in items { item.encode(into: &out) }
            out.append(UInt8(ascii: "e"))
        case .dict(let pairs):
            out.append(UInt8(ascii: "d"))
            // Keys in raw byte order, as the spec requires (info hashes depend on it).
            for key in pairs.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                BValue.bytes(key).encode(into: &out)
                pairs[key]!.encode(into: &out)
            }
            out.append(UInt8(ascii: "e"))
        }
    }
}

struct BencodeError: Error {}

/// Decodes bencode from untrusted input (peers, DHT nodes, trackers): bounded depth, no traps.
struct BDecoder {
    private let bytes: [UInt8]
    private var i = 0
    /// Byte range of the top-level dictionary's "info" value, for hashing it exactly as sent.
    private(set) var infoRange: Range<Int>?

    init(_ data: Data) { bytes = [UInt8](data) }

    /// Decodes one value; `end` is where it stopped (for messages with data after the dict).
    static func decode(_ data: Data, allowTrailing: Bool = false) throws -> (BValue, end: Int, info: Range<Int>?) {
        var d = BDecoder(data)
        let value = try d.value(depth: 0)
        if !allowTrailing, d.i != d.bytes.count { throw BencodeError() }
        return (value, d.i, d.infoRange)
    }

    private mutating func value(depth: Int) throws -> BValue {
        guard depth < 48, i < bytes.count else { throw BencodeError() }
        switch bytes[i] {
        case UInt8(ascii: "i"):
            i += 1
            let v = try number(until: UInt8(ascii: "e"))
            return .int(v)
        case UInt8(ascii: "l"):
            i += 1
            var items: [BValue] = []
            while true {
                guard i < bytes.count else { throw BencodeError() }
                if bytes[i] == UInt8(ascii: "e") { i += 1; break }
                items.append(try value(depth: depth + 1))
            }
            return .list(items)
        case UInt8(ascii: "d"):
            i += 1
            var pairs: [Data: BValue] = [:]
            while true {
                guard i < bytes.count else { throw BencodeError() }
                if bytes[i] == UInt8(ascii: "e") { i += 1; break }
                guard case .bytes(let key) = try value(depth: depth + 1) else { throw BencodeError() }
                let start = i
                let v = try value(depth: depth + 1)
                if depth == 0, key == Data("info".utf8) { infoRange = start..<i }
                pairs[key] = v
            }
            return .dict(pairs)
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            let length = try number(until: UInt8(ascii: ":"))
            guard length >= 0, length <= bytes.count - i else { throw BencodeError() }
            let start = i
            i += Int(length)
            return .bytes(Data(bytes[start..<i]))
        default:
            throw BencodeError()
        }
    }

    private mutating func number(until terminator: UInt8) throws -> Int64 {
        var negative = false
        var v: Int64 = 0
        var digits = 0
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") { negative = true; i += 1 }
        while i < bytes.count, bytes[i] != terminator {
            let c = bytes[i]
            guard c >= 48, c <= 57, digits < 18 else { throw BencodeError() }
            v = v * 10 + Int64(c - 48)
            digits += 1
            i += 1
        }
        guard i < bytes.count, digits > 0 else { throw BencodeError() }
        i += 1
        return negative ? -v : v
    }
}

// MARK: - Small byte helpers shared by the engine

extension Data {
    var tHex: String { map { String(format: "%02x", $0) }.joined() }

    init?(tHex hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 65...70: c - 55
            case 97...102: c - 87
            default: nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        self = out
    }

    func u32(_ at: Int) -> UInt32 {
        let b = startIndex + at
        return UInt32(self[b]) << 24 | UInt32(self[b + 1]) << 16 | UInt32(self[b + 2]) << 8 | UInt32(self[b + 3])
    }

    func u16(_ at: Int) -> UInt16 {
        let b = startIndex + at
        return UInt16(self[b]) << 8 | UInt16(self[b + 1])
    }

    mutating func put32(_ v: UInt32) { append(contentsOf: [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]) }
    mutating func put16(_ v: UInt16) { append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xff)]) }
    mutating func put64(_ v: UInt64) { put32(UInt32(v >> 32)); put32(UInt32(v & 0xffff_ffff)) }

    static func random(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }
}

/// A set of piece indexes, as sent in the wire protocol's bitfield message.
struct Bitfield: Equatable {
    private(set) var bytes: [UInt8]
    let count: Int
    private(set) var setCount = 0

    init(count: Int) {
        self.count = count
        bytes = [UInt8](repeating: 0, count: (count + 7) / 8)
    }

    init(count: Int, data: Data) {
        self.count = count
        bytes = [UInt8](data.prefix((count + 7) / 8))
        if bytes.count < (count + 7) / 8 { bytes += [UInt8](repeating: 0, count: (count + 7) / 8 - bytes.count) }
        // Spare bits past the end must be clear.
        if count % 8 != 0, !bytes.isEmpty { bytes[bytes.count - 1] &= UInt8(0xff) << (8 - count % 8) }
        setCount = bytes.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    subscript(i: Int) -> Bool {
        get { i >= 0 && i < count && bytes[i >> 3] & (0x80 >> (i & 7)) != 0 }
        set {
            guard i >= 0, i < count, self[i] != newValue else { return }
            if newValue { bytes[i >> 3] |= 0x80 >> (i & 7); setCount += 1 } else { bytes[i >> 3] &= ~(0x80 >> (i & 7)); setCount -= 1 }
        }
    }

    var isFull: Bool { setCount == count }
    var data: Data { Data(bytes) }

    mutating func setAll() {
        for i in 0..<count { self[i] = true }
    }
}
