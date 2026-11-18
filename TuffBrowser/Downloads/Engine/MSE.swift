import Foundation

/// Message Stream Encryption / Protocol Encryption: a Diffie-Hellman exchange, then RC4 over
/// the peer connection. Wraps another transport, so peers above it just see bytes.
final class MSETransport: PeerTransport {
    var onConnect: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onClose: ((String) -> Void)?
    var remote: PeerAddr { inner.remote }
    var isUTP: Bool { inner.isUTP }
    var backlog: Int { inner.backlog }
    private(set) var encrypted = false

    private let inner: PeerTransport
    private let outgoing: Bool
    /// Outgoing: the torrent's info hash. Incoming: looked up from what the peer sends.
    private var skey: Data?
    private let lookup: ((Data) -> Data?)?
    private let allowPlain: Bool
    private let preferPlain: Bool

    private enum Stage { case start, waitY, findVC, readSelect, readPadD, findReq1, readReq2, readProvide, readPadC, readIA, plainIncoming, done }
    private var stage = Stage.start
    private var buffer = Data()
    private let x = BigNum.random(bits: 160)
    private var secret = Data()
    private var encryptor: RC4?, decryptor: RC4?
    private var expectedVC = Data()
    private var scanned = 0
    private var select: UInt32 = 0
    private var padLength = 0
    private var provide: UInt32 = 0
    private var iaLength = 0
    private var initialPayload = Data()

    /// `infoHash` for outgoing connections; `lookup` (req2 hash → info hash) for incoming ones.
    init(_ inner: PeerTransport, infoHash: Data?, lookup: ((Data) -> Data?)?, allowPlain: Bool, preferPlain: Bool = false) {
        self.inner = inner
        outgoing = infoHash != nil
        skey = infoHash
        self.lookup = lookup
        self.allowPlain = allowPlain
        self.preferPlain = preferPlain
    }

    static let prime: [UInt32] = BigNum.parse("FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A63A36210000000000090563")

    private var publicKey: Data { BigNum.bytes(BigNum.modExp(base: [2], exp: x, mod: Self.prime), count: 96) }

    func start() {
        if outgoing {
            inner.onConnect = { [weak self] in
                guard let self else { return }
                self.stage = .waitY
                self.inner.send(self.publicKey + Data.random(Int.random(in: 0...64)))
            }
        }
        inner.onData = { [weak self] data in self?.received(data) }
        inner.onClose = { [weak self] why in self?.onClose?(why) }
        inner.start()
    }

    func send(_ data: Data) {
        guard stage == .done else {
            if outgoing, initialPayload.count + data.count <= 68 * 2 { initialPayload.append(data) }
            return
        }
        inner.send(encryptor.map { $0.process(data) } ?? data)
    }

    func close() {
        onClose = nil
        inner.close()
    }

    private func fail(_ why: String) {
        let handler = onClose
        onClose = nil
        inner.close()
        handler?(why)
    }

    private func key(_ label: String) -> Data { sha1(Data(label.utf8) + secret + (skey ?? Data())) }

    private func computeSecret(_ y: Data) {
        secret = BigNum.bytes(BigNum.modExp(base: BigNum.parse(bytes: y), exp: x, mod: Self.prime), count: 96)
    }

    private func received(_ data: Data) {
        if stage == .done {
            if !data.isEmpty { onData?(decryptor.map { $0.process(data) } ?? data) }
            return
        }
        buffer.append(data)
        while advance() {}
    }

    /// Takes one step of the handshake; true if it should be called again.
    private func advance() -> Bool {
        switch stage {
        case .start:
            // Incoming: a plain BitTorrent handshake, or the start of MSE.
            guard buffer.count >= 20 else { return false }
            if buffer.first == 19, buffer.prefix(20).dropFirst() == Data("BitTorrent protocol".utf8) {
                guard allowPlain else { fail("plaintext refused"); return false }
                stage = .done
                let rest = buffer
                buffer = Data()
                onData?(rest)
                return false
            }
            guard buffer.count >= 96 else { return false }
            computeSecret(buffer.prefix(96))
            buffer.removeFirst(96)
            inner.send(publicKey + Data.random(Int.random(in: 0...64)))
            stage = .findReq1
            scanned = 0
            return true
        case .waitY:
            guard buffer.count >= 96 else { return false }
            computeSecret(buffer.prefix(96))
            buffer.removeFirst(96)
            var step3 = sha1(Data("req1".utf8) + secret)
            let req2 = sha1(Data("req2".utf8) + skey!), req3 = sha1(Data("req3".utf8) + secret)
            step3.append(Data(zip(req2, req3).map { $0 ^ $1 }))
            encryptor = RC4(key(outgoing ? "keyA" : "keyB"))
            decryptor = RC4(key(outgoing ? "keyB" : "keyA"))
            var payload = Data(count: 8)
            payload.put32(preferPlain && allowPlain ? 0x01 : (allowPlain ? 0x03 : 0x02))
            payload.put16(0)
            payload.put16(UInt16(initialPayload.count))
            step3.append(encryptor!.process(payload))
            if !initialPayload.isEmpty {
                step3.append(encryptor!.process(initialPayload))
                initialPayload = Data()
            }
            inner.send(step3)
            expectedVC = decryptor!.process(Data(count: 8))
            stage = .findVC
            return true
        case .findVC:
            if let range = buffer.range(of: expectedVC) {
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                stage = .readSelect
                return true
            }
            if buffer.count > 512 + 8 { fail("no MSE answer") }
            return false
        case .readSelect:
            guard buffer.count >= 6 else { return false }
            let plain = decryptor!.process(buffer.prefix(6))
            buffer.removeFirst(6)
            select = plain.u32(0)
            padLength = Int(plain.u16(4))
            guard padLength <= 512, select == 1 || select == 2, select != 1 || allowPlain else { fail("bad crypto select"); return false }
            stage = .readPadD
            return true
        case .readPadD:
            guard buffer.count >= padLength else { return false }
            _ = decryptor!.process(buffer.prefix(padLength))
            buffer.removeFirst(padLength)
            finish(rest: buffer)
            return false
        case .findReq1:
            let target = sha1(Data("req1".utf8) + secret)
            if let range = buffer.range(of: target) {
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                stage = .readReq2
                return true
            }
            if buffer.count > 512 + 20 { fail("no MSE request") }
            return false
        case .readReq2:
            guard buffer.count >= 20 else { return false }
            let req3 = sha1(Data("req3".utf8) + secret)
            let req2 = Data(zip(buffer.prefix(20), req3).map { $0 ^ $1 })
            buffer.removeFirst(20)
            guard let hash = lookup?(req2) else { fail("unknown torrent"); return false }
            skey = hash
            encryptor = RC4(key("keyB"))
            decryptor = RC4(key("keyA"))
            stage = .readProvide
            return true
        case .readProvide:
            guard buffer.count >= 14 else { return false }
            let plain = decryptor!.process(buffer.prefix(14))
            buffer.removeFirst(14)
            guard plain.prefix(8) == Data(count: 8) else { fail("bad MSE check"); return false }
            provide = plain.u32(8)
            padLength = Int(plain.u16(12))
            guard padLength <= 512 else { fail("bad MSE padding"); return false }
            stage = .readPadC
            return true
        case .readPadC:
            guard buffer.count >= padLength + 2 else { return false }
            let plain = decryptor!.process(buffer.prefix(padLength + 2))
            buffer.removeFirst(padLength + 2)
            iaLength = Int(plain.u16(padLength))
            guard iaLength <= 68 * 2 else { fail("bad MSE payload"); return false }
            stage = .readIA
            return true
        case .readIA:
            guard buffer.count >= iaLength else { return false }
            let ia = decryptor!.process(buffer.prefix(iaLength))
            buffer.removeFirst(iaLength)
            if provide & 0x02 != 0, !(preferPlain && allowPlain && provide & 0x01 != 0) { select = 2 } else if provide & 0x01 != 0, allowPlain { select = 1 } else {
                fail("no common encryption")
                return false
            }
            var reply = Data(count: 8)
            reply.put32(select)
            reply.put16(0)
            inner.send(encryptor!.process(reply))
            finish(initial: ia, rest: buffer)
            return false
        case .plainIncoming, .done:
            return false
        }
    }

    private func finish(initial: Data = Data(), rest: Data) {
        stage = .done
        encrypted = select == 2
        if !encrypted { encryptor = nil; decryptor = nil }
        buffer = Data()
        let connect = onConnect
        onConnect = nil
        connect?()
        var incomingData = initial
        if let decryptor { incomingData += decryptor.process(rest) } else { incomingData += rest }
        if !incomingData.isEmpty { onData?(incomingData) }
    }
}

/// RC4, with the first 1024 bytes of keystream thrown away as MSE requires.
final class RC4 {
    private var s = [UInt8](0...255)
    private var i: UInt8 = 0, j: UInt8 = 0

    init(_ key: Data) {
        let k = [UInt8](key)
        var j: UInt8 = 0
        for i in 0..<256 {
            j = j &+ s[i] &+ k[i % k.count]
            s.swapAt(i, Int(j))
        }
        _ = process(Data(count: 1024))
    }

    func process(_ data: Data) -> Data {
        var out = [UInt8](data)
        for n in out.indices {
            i &+= 1
            j &+= s[Int(i)]
            s.swapAt(Int(i), Int(j))
            out[n] ^= s[Int(s[Int(i)] &+ s[Int(j)])]
        }
        return Data(out)
    }
}

/// Just enough big-number arithmetic for MSE's 768-bit Diffie-Hellman: Montgomery
/// multiplication and a ladder whose steps don't depend on the secret exponent's bits.
enum BigNum {
    static func parse(_ hex: String) -> [UInt32] { parse(bytes: Data(tHex: hex)!) }

    /// Big-endian bytes to little-endian 32-bit limbs.
    static func parse(bytes: Data) -> [UInt32] {
        let b = [UInt8](bytes)
        var limbs = [UInt32](repeating: 0, count: (b.count + 3) / 4)
        for (n, byte) in b.reversed().enumerated() { limbs[n / 4] |= UInt32(byte) << (8 * (n % 4)) }
        return limbs
    }

    static func bytes(_ limbs: [UInt32], count: Int) -> Data {
        var out = Data(count: count)
        for n in 0..<count {
            let limb = n / 4
            out[count - 1 - n] = limb < limbs.count ? UInt8(limbs[limb] >> (8 * (n % 4)) & 0xff) : 0
        }
        return out
    }

    static func random(bits: Int) -> [UInt32] {
        var limbs = (0..<(bits + 31) / 32).map { _ in UInt32.random(in: 0...UInt32.max) }
        limbs[limbs.count - 1] |= 0x8000_0000
        return limbs
    }

    private static func greaterOrEqual(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        for i in stride(from: max(a.count, b.count) - 1, through: 0, by: -1) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    private static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: Int64 = 0
        for i in a.indices {
            let d = Int64(a[i]) - Int64(i < b.count ? b[i] : 0) - borrow
            a[i] = UInt32(truncatingIfNeeded: d)
            borrow = d < 0 ? 1 : 0
        }
    }

    /// x * 2 mod n, for x < n.
    private static func double(_ x: [UInt32], _ n: [UInt32]) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: n.count + 1)
        var carry: UInt32 = 0
        for i in 0..<n.count {
            out[i] = x[i] << 1 | carry
            carry = x[i] >> 31
        }
        out[n.count] = carry
        if greaterOrEqual(out, n) { subtract(&out, n) }
        return Array(out.prefix(n.count))
    }

    private static func montMul(_ a: [UInt32], _ b: [UInt32], _ n: [UInt32], _ n0: UInt32) -> [UInt32] {
        let k = n.count
        var t = [UInt32](repeating: 0, count: k + 2)
        for i in 0..<k {
            var c: UInt64 = 0
            for j in 0..<k {
                let s = UInt64(t[j]) + UInt64(a[j]) * UInt64(b[i]) + c
                t[j] = UInt32(truncatingIfNeeded: s)
                c = s >> 32
            }
            var s = UInt64(t[k]) + c
            t[k] = UInt32(truncatingIfNeeded: s)
            t[k + 1] = UInt32(s >> 32)
            let m = t[0] &* n0
            s = UInt64(t[0]) + UInt64(m) * UInt64(n[0])
            c = s >> 32
            for j in 1..<k {
                s = UInt64(t[j]) + UInt64(m) * UInt64(n[j]) + c
                t[j - 1] = UInt32(truncatingIfNeeded: s)
                c = s >> 32
            }
            s = UInt64(t[k]) + c
            t[k - 1] = UInt32(truncatingIfNeeded: s)
            t[k] = t[k + 1] &+ UInt32(s >> 32)
        }
        var out = Array(t.prefix(k + 1))
        if greaterOrEqual(out, n) { subtract(&out, n) }
        return Array(out.prefix(k))
    }

    static func modExp(base: [UInt32], exp: [UInt32], mod n: [UInt32]) -> [UInt32] {
        let k = n.count
        // -n^-1 mod 2^32 by Newton's iteration.
        var inv: UInt32 = 1
        for _ in 0..<5 { inv = inv &* (2 &- n[0] &* inv) }
        let n0 = 0 &- inv
        // R mod n and R² mod n, by doubling.
        var r = [UInt32](repeating: 0, count: k)
        r[0] = 1
        for _ in 0..<(32 * k) { r = double(r, n) }
        var r2 = r
        for _ in 0..<(32 * k) { r2 = double(r2, n) }
        var b = base + [UInt32](repeating: 0, count: max(0, k - base.count))
        b = Array(b.prefix(k))
        let bm = montMul(b, r2, n, n0)
        var r0 = r, r1 = bm
        for i in stride(from: exp.count * 32 - 1, through: 0, by: -1) {
            let bit = exp[i / 32] >> (i % 32) & 1
            if bit == 0 {
                r1 = montMul(r0, r1, n, n0)
                r0 = montMul(r0, r0, n, n0)
            } else {
                r0 = montMul(r0, r1, n, n0)
                r1 = montMul(r1, r1, n, n0)
            }
        }
        var one = [UInt32](repeating: 0, count: k)
        one[0] = 1
        return montMul(r0, one, n, n0)
    }
}
