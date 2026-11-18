import Foundation

/// µTP (BEP 29): BitTorrent's reliable stream over UDP, with LEDBAT congestion control so
/// torrents back off when other traffic needs the line. Shares the DHT's UDP socket.
final class UTPManager {
    private let socket: UDPSocket
    private var sockets: [Key: UTPSocket] = [:]
    private var needsAck: [UTPSocket] = []
    private var timer: DispatchSourceTimer?
    var onAccept: ((UTPSocket) -> Void)?
    var acceptsIncoming = true

    struct Key: Hashable { let addr: PeerAddr; let id: UInt16 }

    init(socket: UDPSocket) {
        self.socket = socket
        socket.setDontFragment(true)
        let timer = DispatchSource.makeTimerSource(queue: engineQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    deinit { timer?.cancel() }

    var count: Int { sockets.count }

    static func isUTP(_ data: Data) -> Bool {
        guard data.count >= 20 else { return false }
        let b = data[data.startIndex]
        return b & 0x0f == 1 && b >> 4 <= 4
    }

    func connect(to addr: PeerAddr) -> UTPSocket {
        var id = UInt16.random(in: 0...UInt16.max)
        while sockets[Key(addr: addr, id: id)] != nil { id &+= 2 }
        let s = UTPSocket(manager: self, remote: addr, recvID: id, sendID: id &+ 1, outgoing: true)
        sockets[Key(addr: addr, id: id)] = s
        return s
    }

    func handle(_ data: Data, from addr: PeerAddr) {
        let b = [UInt8](data)
        let type = b[0] >> 4
        let id = UInt16(b[2]) << 8 | UInt16(b[3])
        if type == UTPSocket.SYN {
            let key = Key(addr: addr, id: id &+ 1)
            if let existing = sockets[key] { existing.receive(b); return }
            guard acceptsIncoming, sockets.count < 1000 else { return }
            let s = UTPSocket(manager: self, remote: addr, recvID: id &+ 1, sendID: id, outgoing: false)
            sockets[key] = s
            s.receive(b)
            onAccept?(s)
            return
        }
        sockets[Key(addr: addr, id: id)]?.receive(b)
    }

    func burstEnd() {
        let list = needsAck
        needsAck.removeAll()
        for s in list { s.sendAckIfNeeded() }
    }

    fileprivate func wantsAck(_ s: UTPSocket) { needsAck.append(s) }
    @discardableResult
    fileprivate func transmit(_ data: Data, to addr: PeerAddr, allowFragments: Bool = false) -> Bool {
        if allowFragments { socket.setDontFragment(false) }
        let ok = socket.send(data, to: addr)
        if allowFragments { socket.setDontFragment(true) }
        return ok
    }
    fileprivate func remove(_ s: UTPSocket) { sockets[Key(addr: s.remote, id: s.recvID)] = nil }

    private func tick() {
        let now = UTPSocket.micros()
        for s in Array(sockets.values) { s.tick(now) }
    }
}

final class UTPSocket: PeerTransport {
    static let DATA: UInt8 = 0, FIN: UInt8 = 1, STATE: UInt8 = 2, RESET: UInt8 = 3, SYN: UInt8 = 4
    /// Payload sizes: start where every path copes, and probe upward (path MTU discovery).
    static let mss = 1150
    private var mtuFloor = UTPSocket.mss
    private lazy var mtuCeiling = remote.isV6 ? 1432 : 1452
    private var probeSeq: UInt16?
    private var mtuReset = UTPSocket.micros()
    private var segment: Int { mtuFloor }
    private static let target: Int64 = 100_000  // µs of queueing delay LEDBAT aims for
    private static let receiveWindow = 1 << 20

    var onConnect: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onClose: ((String) -> Void)?
    let remote: PeerAddr
    let isUTP = true
    var backlog: Int { queued + curWindow }

    private weak var manager: UTPManager?
    fileprivate let recvID: UInt16
    private let sendID: UInt16
    private enum State { case idle, synSent, connected, closed }
    private var state: State
    private var seqNr = UInt16.random(in: 1...UInt16.max)
    private var ackNr: UInt16 = 0
    private var oldest: UInt16 = 0

    private struct Packet {
        var payload: Data
        var type: UInt8
        var sentAt: UInt64 = 0
        var transmissions = 0
        var needsResend = false
        var probe = false
    }
    private var inflight: [UInt16: Packet] = [:]
    private var curWindow = 0
    private var outQueue: [Data] = []
    private var outOffset = 0
    private var queued = 0
    private var reorder: [UInt16: [UInt8]] = [:]
    private var reorderBytes = 0

    private var maxWindow = Double(UTPSocket.mss * 2)
    private var slowStart = true
    private var ssthresh = Double(8 << 20)
    private var peerWindow = UTPSocket.mss * 4
    private var rtt: Int64 = 0, rttVar: Int64 = 0, rto: Int64 = 1_000_000
    private var rtoDeadline: UInt64 = 0
    private var timeouts = 0
    private var replyMicro: UInt32 = 0
    private var baseNow: UInt32?, basePrev: UInt32?, baseSince: UInt64 = 0
    private var lastAck: UInt16 = 0
    private var drift = 0.0
    private var dupAcks = 0
    private var lastReceived = UTPSocket.micros()
    private var lastSent: UInt64 = 0
    private var synSentAt: UInt64 = 0
    private var synTries = 0
    private var ackPending = false
    private var flushScheduled = false

    fileprivate init(manager: UTPManager, remote: PeerAddr, recvID: UInt16, sendID: UInt16, outgoing: Bool) {
        self.manager = manager
        self.remote = remote
        self.recvID = recvID
        self.sendID = sendID
        state = outgoing ? .idle : .connected
    }

    static func micros() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1000 }

    @inline(__always) private static func before(_ a: UInt16, _ b: UInt16) -> Bool { Int16(bitPattern: a &- b) < 0 }

    // MARK: PeerTransport

    func start() {
        guard state == .idle else { return }
        state = .synSent
        sendSYN()
    }

    func send(_ data: Data) {
        guard state != .closed, !data.isEmpty else { return }
        outQueue.append(data)
        queued += data.count
        scheduleFlush()
    }

    func close() {
        onClose = nil
        shut(nil, sendFin: true)
    }

    private func shut(_ why: String?, sendFin: Bool) {
        guard state != .closed else { return }
        if sendFin, state == .connected { transmit(type: Self.FIN, seq: seqNr, payload: Data()); seqNr &+= 1 }
        state = .closed
        manager?.remove(self)
        inflight.removeAll()
        outQueue.removeAll()
        reorder.removeAll()
        let handler = onClose
        onClose = nil
        onData = nil
        onConnect = nil
        if let why { handler?(why) }
    }

    // MARK: Sending

    private func header(_ type: UInt8, seq: UInt16, sack: Bool) -> Data {
        var h = Data(capacity: 20 + 8)
        h.append(type << 4 | 1)
        let mask = sack ? selectiveAck() : nil
        h.append(mask == nil ? 0 : 1)
        h.put16(type == Self.SYN ? recvID : sendID)
        h.put32(UInt32(truncatingIfNeeded: Self.micros()))
        h.put32(replyMicro)
        h.put32(UInt32(max(0, Self.receiveWindow - reorderBytes)))
        h.put16(seq)
        h.put16(ackNr)
        if let mask {
            h.append(0)
            h.append(UInt8(mask.count))
            h.append(contentsOf: mask)
        }
        return h
    }

    /// Which packets past the next expected one have arrived (bit i = ack_nr + 2 + i).
    private func selectiveAck() -> [UInt8]? {
        guard !reorder.isEmpty else { return nil }
        var mask = [UInt8](repeating: 0, count: 8)
        for seq in reorder.keys {
            let i = Int(seq &- ackNr &- 2)
            guard i >= 0, i < 64 * 8 else { continue }
            if i / 8 >= mask.count { mask += [UInt8](repeating: 0, count: (i / 8 / 4 + 1) * 4 - mask.count) }
            mask[i / 8] |= 1 << (i % 8)
        }
        return mask
    }

    @discardableResult
    private func transmit(type: UInt8, seq: UInt16, payload: Data, allowFragments: Bool = false) -> Bool {
        var packet = header(type, seq: seq, sack: type == Self.STATE)
        packet.append(payload)
        lastSent = Self.micros()
        ackPending = false
        return manager?.transmit(packet, to: remote, allowFragments: allowFragments) ?? false
    }

    /// A probe didn't get through at that size: the path's limit is below it.
    private func probeLost(_ seq: UInt16) {
        guard probeSeq == seq, let p = inflight[seq] else { return }
        mtuCeiling = max(mtuFloor, p.payload.count - 1)
        probeSeq = nil
    }

    private func sendSYN() {
        synTries += 1
        synSentAt = Self.micros()
        transmit(type: Self.SYN, seq: seqNr, payload: Data())
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        engineQueue.async { [weak self] in
            self?.flushScheduled = false
            self?.flush()
        }
    }

    private func flush() {
        guard state == .connected else { return }
        let now = Self.micros()
        // Lost packets first.
        if resendPending {
            resendPending = false
            var seq = oldest
            while seq != seqNr {
                if var p = inflight[seq], p.needsResend {
                    if p.probe { probeLost(seq) }
                    p.needsResend = false
                    p.transmissions += 1
                    p.sentAt = now
                    inflight[seq] = p
                    // A packet bigger than the path allows goes again fragmented.
                    transmit(type: p.type, seq: seq, payload: p.payload, allowFragments: p.payload.count > mtuFloor)
                }
                seq &+= 1
            }
        }
        if now - mtuReset > 600_000_000 { mtuReset = now; mtuCeiling = remote.isV6 ? 1432 : 1452 }
        let window = max(min(Int(maxWindow), peerWindow), curWindow == 0 ? segment : 0)
        while queued > 0, curWindow + min(segment, queued) <= window, inflight.count < 1000 {
            // Now and then, one bigger packet to see if the path takes it.
            let probing = probeSeq == nil && mtuCeiling - mtuFloor > 16 && queued >= (mtuFloor + mtuCeiling) / 2
            let size = probing ? (mtuFloor + mtuCeiling) / 2 : segment
            var payload = Data(capacity: size)
            while payload.count < size, let first = outQueue.first {
                let take = min(size - payload.count, first.count - outOffset)
                payload.append(first[first.startIndex + outOffset..<first.startIndex + outOffset + take])
                outOffset += take
                if outOffset == first.count { outQueue.removeFirst(); outOffset = 0 }
            }
            queued -= payload.count
            if inflight.isEmpty { oldest = seqNr; rtoDeadline = now + UInt64(rto) }
            inflight[seqNr] = Packet(payload: payload, type: Self.DATA, sentAt: now, transmissions: 1, probe: probing)
            if probing { probeSeq = seqNr }
            curWindow += payload.count
            if !transmit(type: Self.DATA, seq: seqNr, payload: payload), probing {
                // Too big for this Mac's own link: mark it lost straight away.
                probeLost(seqNr)
                inflight[seqNr]?.needsResend = true
                resendPending = true
            }
            seqNr &+= 1
        }
    }

    fileprivate func sendAckIfNeeded() {
        guard ackPending, state == .connected else { return }
        transmit(type: Self.STATE, seq: seqNr, payload: Data())
    }

    // MARK: Receiving

    fileprivate func receive(_ b: [UInt8]) {
        guard state != .closed, b.count >= 20 else { return }
        let type = b[0] >> 4
        let now = Self.micros()
        let timestamp = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        let delaySample = UInt32(b[8]) << 24 | UInt32(b[9]) << 16 | UInt32(b[10]) << 8 | UInt32(b[11])
        let window = Int(UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15]))
        let seq = UInt16(b[16]) << 8 | UInt16(b[17])
        let ack = UInt16(b[18]) << 8 | UInt16(b[19])
        var at = 20
        var ext = b[1]
        var sack: ArraySlice<UInt8>?
        while ext != 0 {
            guard at + 2 <= b.count else { return }
            let next = b[at], len = Int(b[at + 1])
            guard at + 2 + len <= b.count else { return }
            if ext == 1 { sack = b[at + 2..<at + 2 + len] }
            ext = next
            at += 2 + len
        }
        lastReceived = now
        replyMicro = UInt32(truncatingIfNeeded: now) &- timestamp
        peerWindow = window

        switch type {
        case Self.RESET:
            shut("connection reset", sendFin: false)
            return
        case Self.SYN:
            // A new connection (or our answer to it got lost): answer with where we are.
            if state == .connected, !synAnswered || !gotData {
                synAnswered = true
                ackNr = seq
                transmit(type: Self.STATE, seq: seqNr, payload: Data())
            }
            return
        default: break
        }

        if state == .synSent {
            guard type == Self.STATE else { return }
            state = .connected
            ackNr = seq &- 1
            seqNr &+= 1  // the SYN took one
            oldest = seqNr
            lastAck = ack
            let connect = onConnect
            onConnect = nil
            connect?()
            scheduleFlush()
        }
        guard state == .connected else { return }

        handleAck(ack, sack: sack, delaySample: delaySample, isState: type == Self.STATE, now: now)

        if type == Self.DATA || type == Self.FIN {
            gotData = true
            let payload = b[at...]
            var finished = false
            if !Self.before(ackNr, seq) {
                ackPending = true  // already have it; the ack got lost
            } else if seq == ackNr &+ 1 {
                ackNr = seq
                if type == Self.FIN { finished = true } else if !payload.isEmpty { onData?(Data(payload)) }
                while !finished, state == .connected {
                    if let next = reorder.removeValue(forKey: ackNr &+ 1) {
                        ackNr &+= 1
                        reorderBytes -= next.count
                        onData?(Data(next))
                    } else if finAt == ackNr &+ 1 {
                        ackNr &+= 1
                        finished = true
                    } else { break }
                }
                ackPending = true
            } else if Int(seq &- ackNr) < 1024 {
                if type == Self.FIN { finAt = seq } else if reorder[seq] == nil, !payload.isEmpty {
                    reorder[seq] = Array(payload)
                    reorderBytes += payload.count
                }
                ackPending = true
            }
            if finished {
                transmit(type: Self.STATE, seq: seqNr, payload: Data())
                shut("closed by peer", sendFin: false)
                return
            }
            if ackPending { manager?.wantsAck(self) }
        }
        if queued > 0 || resendPending { flush() }
    }

    private var finAt: UInt16?
    private var synAnswered = false
    private var gotData = false
    private var resendPending = false

    private func handleAck(_ ack: UInt16, sack: ArraySlice<UInt8>?, delaySample: UInt32, isState: Bool, now: UInt64) {
        var bytesAcked = 0
        var rttSample: Int64?
        func acknowledge(_ seq: UInt16) {
            guard let p = inflight.removeValue(forKey: seq) else { return }
            if p.probe, seq == probeSeq {
                if p.transmissions == 1 { mtuFloor = max(mtuFloor, p.payload.count) }
                probeSeq = nil
            }
            bytesAcked += p.payload.count
            curWindow -= p.payload.count
            if p.transmissions == 1 { rttSample = Int64(now) - Int64(p.sentAt) }
        }
        while oldest != seqNr, !Self.before(ack, oldest) {
            acknowledge(oldest)
            oldest &+= 1
        }
        if let sack {
            var acked = 0
            for (j, byte) in sack.enumerated() where byte != 0 {
                for bit in 0..<8 where byte & (1 << bit) != 0 {
                    acknowledge(ack &+ 2 &+ UInt16(j * 8 + bit))
                    acked += 1
                }
            }
            // Three or more later packets got through: the one before them is lost.
            if acked >= 3, var p = inflight[ack &+ 1], p.transmissions == 1 {
                p.needsResend = true
                resendPending = true
                inflight[ack &+ 1] = p
                lose()
            }
        }
        while oldest != seqNr, inflight[oldest] == nil { oldest &+= 1 }

        if let rttSample, rttSample > 0 {
            if rtt == 0 { rtt = rttSample; rttVar = rttSample / 2 } else {
                rttVar += (abs(rtt - rttSample) - rttVar) / 4
                rtt += (rttSample - rtt) / 8
            }
            rto = max(rtt + rttVar * 4, 500_000)
        }

        if bytesAcked > 0 {
            dupAcks = 0
            timeouts = 0
            rtoDeadline = now + UInt64(rto)
            congestionControl(bytesAcked: bytesAcked, delaySample: delaySample, now: now)
        } else if isState, ack == lastAck, !inflight.isEmpty {
            dupAcks += 1
            if dupAcks == 3, var p = inflight[ack &+ 1] {
                p.needsResend = true
                resendPending = true
                inflight[ack &+ 1] = p
                lose()
            }
        }
        lastAck = ack
    }

    private func congestionControl(bytesAcked: Int, delaySample: UInt32, now: UInt64) {
        var offTarget = 1.0
        if delaySample != 0 {
            if now - baseSince > 60_000_000 {
                // Clock drift: how far the minimum moved since the last window, per second.
                if let prev = baseNow, let older = basePrev {
                    let moved = Double(Int32(bitPattern: prev &- older)) / 60
                    drift = drift * 0.5 + moved * 0.5
                }
                basePrev = baseNow
                baseNow = nil
                baseSince = now
            }
            if baseNow == nil || Int32(bitPattern: delaySample &- baseNow!) < 0 { baseNow = delaySample }
            var base = baseNow!
            if let prev = basePrev, Int32(bitPattern: prev &- base) < 0 { base = prev }
            var ourDelay = Int64(Int32(bitPattern: delaySample &- base))
            // A peer clock running faster than ours looks like growing delay: take that out.
            if drift > 0 { ourDelay -= Int64(drift * Double(now - baseSince) / 1_000_000) }
            ourDelay = max(0, ourDelay)
            offTarget = Double(Self.target - min(ourDelay, Self.target * 4)) / Double(Self.target)
            if slowStart, ourDelay > Self.target * 9 / 10 { slowStart = false; ssthresh = maxWindow }
        }
        let wasLimited = Double(curWindow + bytesAcked) < maxWindow / 2
        if slowStart {
            if !wasLimited { maxWindow += Double(bytesAcked) }
            if maxWindow >= ssthresh { slowStart = false }
        } else {
            let factor = Double(min(bytesAcked, Int(maxWindow))) / max(maxWindow, Double(bytesAcked))
            let gain = 3000 * offTarget * factor
            if gain < 0 || !wasLimited { maxWindow += gain }
        }
        maxWindow = min(max(maxWindow, Double(Self.mss)), Double(16 << 20))
    }

    private func lose() {
        maxWindow = max(maxWindow / 2, Double(Self.mss))
        ssthresh = maxWindow
        slowStart = false
    }

    // MARK: Timers

    fileprivate func tick(_ now: UInt64) {
        switch state {
        case .synSent:
            if now - synSentAt > 1_500_000 {
                if synTries >= 3 { shut("no µTP answer", sendFin: false) } else { sendSYN() }
            }
        case .connected:
            if !inflight.isEmpty, now > rtoDeadline {
                timeouts += 1
                if timeouts > 6 { shut("timed out", sendFin: false); return }
                ssthresh = max(maxWindow / 2, Double(Self.mss * 2))
                maxWindow = Double(Self.mss)
                slowStart = true
                rto = min(rto * 2, 30_000_000)
                rtoDeadline = now + UInt64(rto)
                if var p = inflight[oldest] {
                    p.needsResend = true
                    resendPending = true
                    inflight[oldest] = p
                }
                flush()
            } else if now - lastReceived > 120_000_000 {
                shut("timed out", sendFin: false)
            } else if now - lastSent > 29_000_000 {
                transmit(type: Self.STATE, seq: seqNr, payload: Data())
            }
        default: break
        }
    }
}
