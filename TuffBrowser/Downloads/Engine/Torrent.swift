import Foundation

/// One torrent: its pieces, peers, trackers, web seeds and the decisions about what to ask
/// whom for. Lives on the engine queue.
final class Torrent {
    struct Candidate {
        var source: String
        var fails = 0
        var nextTry = Date()
        var connected = false
        /// Remembered per peer: µTP didn't answer (use TCP), or TCP didn't (use µTP).
        var preferTCP = false
        var preferUTP = false
        /// MSE failed with this peer: talk plaintext next time (when allowed).
        var plainOnly = false
    }

    private struct PieceProgress {
        var blocks: [UInt8]  // 0 missing, 1 requested, 2 arrived
        var arrived = 0
        var from: [Int: String] = [:]  // block → address it came from (smart ban)
        var verifying = false
    }

    unowned let session: TorrentSession
    let infoHash: Data
    let infoHashV2: Data?
    private(set) var info: TorrentInfo?
    private(set) var storage: TorrentStorage?
    var name: String
    private(set) var savePath: URL
    var trackers: [Tracker] = []
    var webSeeds: [WebSeed] = []
    var addedAt = Date()
    var completedAt: Date?
    var paused: Bool
    var queued = false
    var manualSeed = false
    var forceStart = false
    var superSeeding = false
    var downloadLimit = 0 { didSet { downLimiter.limit = downloadLimit } }
    var uploadLimit = 0 { didSet { upLimiter.limit = uploadLimit } }
    let downLimiter = RateLimiter(), upLimiter = RateLimiter()
    var sequential = false { didSet { orderDirty = true } }
    var firstLast = false { didSet { updatePriorities() } }
    var filePriority: [Int] = []
    private(set) var have = Bitfield(count: 0)
    var error: String?
    private var retryAfterError: Date?
    private(set) var checking: Double?
    var queuePosition = 0
    /// Streaming: pieces wanted by a time (Play while downloading).
    private var deadlines: [Int: Date] = [:]

    private(set) var peers: [Peer] = []
    var candidates: [PeerAddr: Candidate] = [:]
    private var banned = Set<String>()
    private var availability: [UInt16] = []
    private var piecePriority: [UInt8] = []
    private var downloading: [Int: PieceProgress] = [:]
    private var pickOrder: [Int] = []
    private var orderDirty = true
    private var orderBuilt = Date.distantPast
    private var need = [UInt8]()
    private var endgame = false
    /// Smart ban: blocks of a piece that failed, by who sent them and what they hashed to.
    private var failedBlocks: [Int: [Int: (ip: String, hash: Data)]] = [:]
    private var superOffered: [Int: Int] = [:]
    private var layerParts: [Int: [Int: Data]] = [:]

    var downloadedTotal: Int64 = 0, uploadedTotal: Int64 = 0, wasted: Int64 = 0
    var down = RateMeter(), up = RateMeter()
    var activeSeconds = 0, seedingSeconds = 0
    private var lastUpload = Date()
    private var lastDHT = Date.distantPast
    private var lastLSD = Date.distantPast
    private var lastChoke = Date.distantPast, lastOptimistic = Date.distantPast
    private var stalledSince: Date?
    var dirty = true
    /// Resume data for partly downloaded pieces, applied once the info is known.
    private var savedPartials: [String: [Int]] = [:]
    var savedStamps: [[Double]] = []

    private var metaSize = 0
    private var metaPieces: [Data?] = []
    private var metaAsked: [Date?] = []
    private final class Flag { var cancelled = false }
    private var checkFlag = Flag()
    private var announceKey = UInt32.random(in: 0...UInt32.max)

    init(session: TorrentSession, source: TorrentSource, savePath: URL, paused: Bool) {
        self.session = session
        infoHash = source.infoHash
        infoHashV2 = source.infoHashV2 ?? source.info?.infoHashV2
        name = source.name
        self.savePath = savePath
        self.paused = paused
        webSeeds = source.webSeeds.map { WebSeed(url: $0, hoffman: false) } + source.httpSeeds.map { WebSeed(url: $0, hoffman: true) }
        setTrackers(source.trackers)
        for p in source.peers { if let a = PeerAddr(p) { candidates[a] = Candidate(source: "Magnet") } }
        if let info = source.info { adopt(info, fresh: true) }
        if let only = source.selectOnly, info != nil {
            filePriority = filePriority.indices.map { only.contains($0) && !info!.files[$0].isPad ? 1 : 0 }
            updatePriorities()
        }
    }

    /// The hashes this torrent is known by on the wire (v1 and/or truncated v2).
    var wireHashes: [Data] { [infoHash] + (infoHashV2.map { [Data($0.prefix(20))] } ?? []).filter { $0 != infoHash } }

    func setTrackers(_ tiers: [[String]]) {
        var seen = Set(trackers.map(\.url))
        let base = (trackers.map(\.tier).max() ?? -1) + 1
        for (n, list) in tiers.enumerated() {
            // Shuffled within each tier, as BEP 12 asks.
            for url in list.shuffled() where seen.insert(url).inserted { trackers.append(Tracker(url: url, tier: base + n)) }
        }
    }

    // MARK: Metadata and storage

    private func adopt(_ info: TorrentInfo, fresh: Bool) {
        self.info = info
        if name == infoHash.tHex || fresh { name = info.name }
        let storage = TorrentStorage(info: info, base: savePath)
        self.storage = storage
        if have.count != info.pieceCount { have = Bitfield(count: info.pieceCount) }
        if filePriority.count != info.files.count { filePriority = info.files.map { $0.isPad ? 0 : 1 } }
        availability = [UInt16](repeating: 0, count: info.pieceCount)
        configureStorage()
        for peer in peers { absorbPendingHaves(peer) }
        updatePriorities()
    }

    private func configureStorage() {
        guard let storage, let info else { return }
        let settings = session.settings
        let skipped = Set(filePriority.indices.filter { filePriority[$0] == 0 })
        let incomplete = Set(info.files.indices.filter { !info.files[$0].isPad && !fileComplete($0) })
        storage.locked {
            $0.preallocate = settings.preallocate
            $0.usePartsFile = settings.partFile
            $0.skipped = skipped
            $0.suffix = settings.incompleteSuffix ? ".part" : ""
            $0.incomplete = settings.incompleteSuffix ? incomplete : []
        }
    }

    private func fileComplete(_ i: Int) -> Bool {
        guard let info, let range = info.pieces(ofFile: i) else { return true }
        return range.allSatisfy { have[$0] }
    }

    /// Haves a peer sent before we knew the piece count (magnets) take effect now.
    private func absorbPendingHaves(_ peer: Peer) {
        guard let info else { return }
        if peer.have == nil || peer.have!.count != info.pieceCount {
            var b = Bitfield(count: info.pieceCount)
            if peer.haveAll { b.setAll() }
            peer.have = b
        }
        for p in peer.pendingHaves where p < info.pieceCount { peer.have![p] = true }
        peer.pendingHaves.removeAll()
        if let b = peer.have { for i in 0..<b.count where b[i] { availability[i] &+= 1 } }
    }

    /// Restores a torrent saved earlier; returns whether its files need checking.
    func restore(info: TorrentInfo?, have: Data?, priorities: [Int], partials: [String: [Int]], stamps: [[Double]], renamed: [String: [String]], rootName: String?) -> Bool {
        if !priorities.isEmpty { filePriority = priorities }
        savedPartials = partials
        savedStamps = stamps
        guard let info else { return false }
        adopt(info, fresh: false)
        if let rootName { name = rootName }
        let renames = Dictionary(uniqueKeysWithValues: renamed.compactMap { k, v in Int(k).map { ($0, v) } })
        storage?.locked { $0.renamed = renames; $0.rootName = rootName }
        if let have { self.have = Bitfield(count: info.pieceCount, data: have) }
        configureStorage()
        updatePriorities()
        applyPartials()
        // Quick check: any file whose size or date changed since we last saw it means a full check.
        guard self.have.setCount > 0 || !downloading.isEmpty else { return false }
        let now = storage!.stamps()
        guard now.count == stamps.count else { return true }
        for i in now.indices where !info.files[i].isPad && (filePriority[i] > 0 || fileHasPieces(i)) {
            if now[i][0] != stamps[i][0] || abs(now[i][1] - stamps[i][1]) > 2 { return true }
        }
        return false
    }

    private func fileHasPieces(_ i: Int) -> Bool { info?.pieces(ofFile: i)?.contains { have[$0] } ?? false }

    private func applyPartials() {
        guard let info else { return }
        for (key, blocks) in savedPartials {
            guard let piece = Int(key), piece < info.pieceCount, !have[piece] else { continue }
            let count = (info.pieceSize(piece) + Peer.blockSize - 1) / Peer.blockSize
            var progress = PieceProgress(blocks: [UInt8](repeating: 0, count: count))
            for b in blocks where b < count { progress.blocks[b] = 2; progress.arrived += 1 }
            if progress.arrived > 0, progress.arrived < count { downloading[piece] = progress }
        }
        savedPartials = [:]
    }

    func updatePriorities() {
        guard let info else { return }
        var pr = [UInt8](repeating: 0, count: info.pieceCount)
        for (i, f) in info.files.enumerated() where !f.isPad && i < filePriority.count && filePriority[i] > 0 {
            guard let range = info.pieces(ofFile: i) else { continue }
            let p = UInt8(min(filePriority[i], 3))
            for piece in range where pr[piece] < p { pr[piece] = p }
            if firstLast {
                pr[range.lowerBound] = 4
                pr[range.upperBound] = 4
            }
        }
        piecePriority = pr
        orderDirty = true
        rebuildNeed()
        dirty = true
        if !isComplete { completedAt = nil }
        // Files picked again come out of the parts file; newly skipped ones go into it from now on.
        if let storage {
            let nowSkipped = Set(filePriority.indices.filter { filePriority[$0] == 0 })
            let have = self.have
            session.disk.queue.async {
                var unskipped: [Int] = []
                storage.locked { s in unskipped = Array(s.skipped.subtracting(nowSkipped)) }
                for i in unskipped { storage.unskip(i) { have[$0] } }
                storage.locked { $0.skipped = nowSkipped }
            }
        }
        for peer in peers where peer.phase == .active { updateInterest(peer) }
    }

    private func rebuildNeed() {
        guard let info else { return }
        need = [UInt8](repeating: 0, count: (info.pieceCount + 7) / 8)
        for i in 0..<info.pieceCount where piecePriority[i] > 0 && !have[i] { need[i >> 3] |= 0x80 >> (i & 7) }
    }

    /// Every wanted piece is here.
    var isComplete: Bool { info != nil && !need.contains { $0 != 0 } }

    var wantedBytes: Int64 {
        guard let info else { return 0 }
        return info.files.indices.reduce(0) { $0 + (filePriority[$1] > 0 && !info.files[$1].isPad ? info.files[$1].length : 0) }
    }

    var leftBytes: Int64 {
        guard let info else { return 0 }
        var left: Int64 = 0
        for i in 0..<info.pieceCount where need[i >> 3] & (0x80 >> (i & 7)) != 0 { left += Int64(info.pieceSize(i)) }
        return min(left, wantedBytes)
    }

    // MARK: Running

    var isRunning: Bool { session.enabled && !paused && !queued && error == nil && checking == nil }

    func stop(announce: Bool) {
        for peer in peers { peer.close("stopped") }
        peers.removeAll()
        downloading = downloading.filter { $0.value.arrived > 0 }.mapValues { p in
            var p = p
            p.blocks = p.blocks.map { $0 == 1 ? 0 : $0 }
            p.verifying = false
            return p
        }
        for w in webSeeds { w.cancel() }
        for k in candidates.keys { candidates[k]?.connected = false }
        if announce { announceAll(event: "stopped") }
        if let storage { session.disk.drop(storage); session.disk.queue.async { storage.flush() } }
        dirty = true
    }

    func pause() {
        guard !paused else { return }
        paused = true
        manualSeed = false
        checkFlag.cancelled = true
        checking = nil
        stop(announce: true)
    }

    func resume() {
        guard paused || error != nil else { return }
        error = nil
        retryAfterError = nil
        paused = false
        if isComplete { manualSeed = true }
        for t in trackers { t.nextAnnounce = Date(); t.failures = 0 }
        lastDHT = .distantPast
        lastUpload = Date()
        dirty = true
    }

    func move(to url: URL, done: @escaping (String?) -> Void) {
        let wasPaused = paused
        if !wasPaused { stop(announce: false) }
        paused = true
        guard let storage else { savePath = url; paused = wasPaused; done(nil); return }
        session.disk.queue.async {
            var failure: String?
            do { try storage.move(to: url) } catch { failure = error.localizedDescription }
            engineQueue.async {
                if failure == nil { self.savePath = url }
                self.paused = wasPaused
                self.dirty = true
                done(failure)
            }
        }
    }

    func rename(file: Int?, to newName: String, done: @escaping (String?) -> Void) {
        let clean = TorrentInfo.clean(newName)
        guard !clean.isEmpty else { done("That name can’t be used"); return }
        guard let storage else { name = clean; done(nil); return }
        session.disk.queue.async {
            var failure: String?
            do { try storage.rename(file: file, to: clean) } catch { failure = error.localizedDescription }
            engineQueue.async {
                if failure == nil, file == nil || self.info?.isSingleFile == true { self.name = clean }
                self.dirty = true
                done(failure)
            }
        }
    }

    /// Hashes every piece on disk again (Force Recheck, or files changed since last time).
    func recheck() {
        guard let storage else { return }
        stop(announce: false)
        checkFlag.cancelled = true
        let flag = Flag()
        checkFlag = flag
        checking = 0
        downloading.removeAll()
        session.disk.check(storage, cancelled: { flag.cancelled }, progress: { [weak self] p in
            if !flag.cancelled { self?.checking = p }
        }, done: { [weak self] found in
            guard let self, !flag.cancelled, let found else { return }
            self.checking = nil
            self.have = found
            self.rebuildNeed()
            self.orderDirty = true
            self.configureStorage()
            if self.isComplete, self.completedAt == nil { self.completedAt = Date() }
            if self.isComplete { for i in self.info!.files.indices { self.finishFileIfDone(i) } }
            self.dirty = true
            self.session.log("checked", self)
        })
    }

    // MARK: Streaming

    /// Wants the start of file `i` first, in order, so it can play while it downloads.
    func stream(file i: Int) {
        guard let info, let range = info.pieces(ofFile: i) else { return }
        if filePriority[i] == 0 { filePriority[i] = 1; updatePriorities() }
        let now = Date()
        deadlines = [:]
        for (n, p) in range.prefix(64).enumerated() where !have[p] { deadlines[p] = now.addingTimeInterval(1 + Double(n) * 0.5) }
        deadlines[range.upperBound] = now.addingTimeInterval(2)  // players read the end for the index
        sequential = true
    }

    // MARK: Ticks

    func tick(_ now: Date) {
        down.tick()
        up.tick()
        for peer in peers { peer.down.tick(); peer.up.tick() }
        if let retry = retryAfterError, now >= retry, error != nil {
            // A full disk may have room again.
            error = nil
            retryAfterError = nil
        }
        guard isRunning else { return }
        activeSeconds += 1
        if isComplete { seedingSeconds += 1 }

        // Finished: stop, unless seeding was asked for and the limits allow it.
        if isComplete {
            if completedAt == nil {
                completedAt = Date()
                announceAll(event: "completed")
                if let storage { session.disk.queue.async { storage.flush() } }
                session.didFinish(self)
                for peer in peers where peer.phase == .active { peer.sendUploadOnly(true) }
                dirty = true
            }
            let settings = session.settings
            let seeding = manualSeed || settings.seedAfterDownload
            let ratioHit = settings.ratioLimit > 0 && Double(uploadedTotal) >= settings.ratioLimit * Double(max(wantedBytes, 1))
            let timeHit = settings.seedTimeLimit > 0 && seedingSeconds >= settings.seedTimeLimit * 60
            let idleHit = settings.inactiveSeedLimit > 0 && now.timeIntervalSince(lastUpload) >= Double(settings.inactiveSeedLimit * 60)
            if !seeding || (!manualSeed && (ratioHit || timeHit || idleHit)) {
                paused = true
                manualSeed = false
                stop(announce: true)
                session.log(seeding ? "seeding limit reached" : "stopped after downloading", self)
                return
            }
        }

        stalledSince = down.rate > 0 || isComplete ? nil : (stalledSince ?? now)
        expireRequests(now)
        if info == nil { requestMetadata(now) } else if !(info!.missingLayers.isEmpty) { requestLayers(now) }
        if now.timeIntervalSince(lastChoke) >= 10 { choke(now) }
        announceDue(now)
        let isPrivate = info?.isPrivate ?? false
        if !isPrivate, session.settings.dht, now.timeIntervalSince(lastDHT) > (peers.count < 10 ? 300 : 900) {
            lastDHT = now
            for dht in session.dhts {
                for hash in wireHashes { dht.getPeers(hash, announcePort: session.listenPort) { [weak self] found in self?.addCandidates(found, source: "DHT") } }
            }
        }
        if !isPrivate, session.settings.lsd, now.timeIntervalSince(lastLSD) > 300 {
            lastLSD = now
            session.lsd?.announce(wireHashes)
        }
        connectMore(now)
        useWebSeeds(now)
        for peer in peers where peer.phase == .active {
            if now.timeIntervalSince(peer.lastSent) > 110 { peer.keepAlive() }
            if now.timeIntervalSince(peer.lastMessage) > 240 { peer.close("idle") }
            if session.settings.pex, !isPrivate, peer.extIDs["ut_pex"] != nil, now.timeIntervalSince(peer.lastPex) > 60 { sendPex(to: peer, now: now) }
            // Neither side wants anything from the other: make room for someone useful.
            if isComplete, peer.uploadOnly || peer.haveAll || peer.have?.isFull == true { peer.close("both complete") }
        }
        if orderDirty || now.timeIntervalSince(orderBuilt) > 5 { buildOrder() }
        endgame = pickOrder.allSatisfy({ have[$0] || downloading[$0] != nil }) && !downloading.values.contains { $0.blocks.contains(0) }
        deadlines = deadlines.filter { !have[$0.key] }
        service()
        if dirty, Int(now.timeIntervalSince1970) % 30 == 0 { session.save(self) }
    }

    /// Ten times a second: keep request pipelines full and send what peers asked for.
    func service() {
        guard isRunning else { return }
        downLimiter.refill(interval: 0.1)
        upLimiter.refill(interval: 0.1)
        for peer in peers where peer.phase == .active {
            if info != nil, !peer.peerChoking || !peer.allowedFast.isEmpty { fillRequests(peer) }
            serveUploads(peer)
        }
    }

    // MARK: Speed limits

    private func mayDownload(_ peer: Peer) -> Bool {
        if session.settings.lanUnlimited, peer.addr.isLocal { return true }
        return session.downLimiter.hasRoom && downLimiter.hasRoom
    }

    private func mayUpload(_ peer: Peer) -> Bool {
        if session.settings.lanUnlimited, peer.addr.isLocal { return true }
        return session.upLimiter.hasRoom && upLimiter.hasRoom
    }

    // MARK: Peers

    func addCandidates(_ list: [PeerAddr], source: String) {
        for addr in list where addr.isUsable && candidates[addr] == nil && !banned.contains(addr.ip) && candidates.count < 3000 {
            if session.ipFilter.blocks(addr) { continue }
            candidates[addr] = Candidate(source: source)
        }
    }

    private func connectMore(_ now: Date) {
        let limit = session.settings.maxPeersPerTorrent
        guard peers.count < limit else { return }
        var budget = min(limit - peers.count, session.connectBudget())
        guard budget > 0 else { return }
        let ready = candidates.filter { !$0.value.connected && $0.value.nextTry <= now }.sorted { $0.value.fails < $1.value.fails }
        for (addr, _) in ready {
            guard budget > 0 else { break }
            budget -= 1
            connect(addr)
        }
    }

    private func connect(_ addr: PeerAddr) {
        guard var c = candidates[addr] else { return }
        let settings = session.settings
        let utpPossible = settings.utp && !settings.proxyOnly && session.utp(for: addr) != nil
        let tcpPossible = settings.tcp || !utpPossible
        let useUTP = utpPossible && (!c.preferTCP || !tcpPossible) || (c.preferUTP && utpPossible)
        guard useUTP || tcpPossible else { return }
        c.connected = true
        candidates[addr] = c
        var transport: PeerTransport = useUTP ? session.utp(for: addr)!.connect(to: addr) : TCPTransport(to: addr, parameters: NetParams.tcp(settings))
        let encrypt = settings.encryption == 2 || (settings.encryption == 1 && !c.plainOnly)
        if encrypt { transport = MSETransport(transport, infoHash: infoHash, lookup: nil, allowPlain: settings.encryption < 2) }
        let peer = Peer(transport: transport, incoming: false)
        peer.torrent = self
        peers.append(peer)
        transport.onConnect = { [weak self, weak peer] in
            guard let self, let peer else { return }
            peer.phase = .handshaking
            peer.connectedAt = Date()
            peer.sendHandshake(infoHash: self.infoHash, peerID: self.session.peerID)
        }
        wire(peer, start: true)
    }

    /// An incoming connection whose handshake named this torrent.
    func accept(_ peer: Peer) -> Bool {
        guard isRunning, peers.count < session.settings.maxPeersPerTorrent + 10, !banned.contains(peer.addr.ip), !session.ipFilter.blocks(peer.addr),
              !peers.contains(where: { $0.addr.ip == peer.addr.ip && $0.peerID == peer.peerID }) else { return false }
        peer.torrent = self
        peers.append(peer)
        peer.sendHandshake(infoHash: infoHash, peerID: session.peerID)
        wire(peer, start: false)
        greet(peer)
        return true
    }

    private func wire(_ peer: Peer, start: Bool) {
        peer.transport.onData = { [weak self, weak peer] data in
            guard let self, let peer else { return }
            peer.received(data, handshake: { p, hash, id in
                guard self.wireHashes.contains(hash), id != self.session.peerID else { return false }
                if !p.incoming { self.greet(p) }
                return true
            }, message: { p, id, payload in self.handle(p, id, payload) })
        }
        peer.transport.onClose = { [weak peer] why in peer?.close(why) }
        if start { peer.transport.start() }
    }

    private func greet(_ peer: Peer) {
        if var c = candidates[peer.addr] {
            c.fails = 0
            candidates[peer.addr] = c
        }
        if peer.supportsExt {
            peer.sendExtHandshake(listenPort: session.listenPort, metadataSize: info?.raw.count, isPrivate: info?.isPrivate ?? false, uploadOnly: isComplete, ipv6: session.globalIPv6)
        }
        if info != nil, superSeeding, isComplete {
            peer.sendBitfield(Bitfield(count: have.count))
            offerSuperSeedPiece(to: peer)
        } else if info != nil {
            peer.sendBitfield(have)
        } else if peer.supportsFast {
            peer.sendBitfield(Bitfield(count: 0))
        }
        if session.settings.dht, !session.dhts.isEmpty { peer.sendPort(session.listenPort) }
        if info != nil, peer.have == nil { peer.have = Bitfield(count: info!.pieceCount) }
    }

    func peerClosed(_ peer: Peer, why: String) {
        guard let i = peers.firstIndex(where: { $0 === peer }) else { return }
        peers.remove(at: i)
        if let b = peer.have, info != nil, b.count == availability.count { for p in 0..<b.count where b[p] { availability[p] &-= 1 } }
        for block in peer.requests { release(block, by: peer) }
        if let offer = peer.superSeedOffer { superOffered[offer, default: 1] -= 1 }
        guard var c = candidates[peer.addr] else { return }
        c.connected = false
        if peer.peerID.isEmpty {
            // Never got to the handshake: try the other transport, or plaintext, before backing off.
            let mse = peer.transport as? MSETransport
            if let mse, !mse.encrypted, session.settings.encryption == 1, !c.plainOnly {
                c.plainOnly = true
                c.nextTry = Date()
            } else if peer.transport.isUTP, !c.preferTCP, session.settings.tcp {
                c.preferTCP = true
                c.nextTry = Date()
            } else if !peer.transport.isUTP, !c.preferUTP, session.settings.utp, !c.preferTCP {
                c.preferUTP = true
                c.nextTry = Date()
            } else {
                c.fails += 1
                c.nextTry = Date().addingTimeInterval(min(60 * pow(2, Double(c.fails)), 3600))
            }
            if c.fails >= 5 { candidates[peer.addr] = nil; return }
        } else {
            c.nextTry = Date().addingTimeInterval(peer.listenAddr == nil ? 120 : 60)
        }
        candidates[peer.addr] = c
    }

    func countHalfOpen() -> Int { peers.filter { $0.phase == .connecting }.count }

    // MARK: Messages

    func handle(_ peer: Peer, _ id: UInt8, _ p: Data) {
        switch id {
        case 0:
            peer.peerChoking = true
            if !peer.supportsFast { for b in peer.requests { release(b, by: peer) }; peer.requests.removeAll(); peer.requestedAt.removeAll() }
        case 1:
            peer.peerChoking = false
            peer.idleUntil = .distantPast
            fillRequests(peer)
        case 2: peer.peerInterested = true
        case 3: peer.peerInterested = false
        case 4 where p.count == 4:
            gotHave(peer, Int(p.u32(0)))
        case 5:
            guard let info else {
                guard p.count < 1 << 17 else { return }
                peer.pendingHaves = (0..<p.count * 8).filter { p[p.startIndex + $0 / 8] & (0x80 >> ($0 % 8)) != 0 }
                return
            }
            guard p.count == (info.pieceCount + 7) / 8 else { peer.close("bad bitfield"); return }
            if let old = peer.have { for i in 0..<old.count where old[i] { availability[i] &-= 1 } }
            let b = Bitfield(count: info.pieceCount, data: p)
            peer.have = b
            for i in 0..<b.count where b[i] { availability[i] &+= 1 }
            updateInterest(peer)
        case 6 where p.count == 12:
            let b = Block(piece: Int(p.u32(0)), offset: Int(p.u32(4)), length: Int(p.u32(8)))
            guard let info, b.piece < info.pieceCount, have[b.piece], b.length > 0, b.length <= 128 * 1024,
                  b.offset >= 0, b.offset + b.length <= info.pieceSize(b.piece) else { peer.reject(b); return }
            if superSeeding, isComplete, peer.superSeedOffer != b.piece, !(peer.have?[b.piece] ?? false) { peer.reject(b); return }
            if peer.amChoking { peer.reject(b); return }
            // Request flooding: a peer may queue at most 500 blocks.
            if peer.peerRequests.count >= 500 { peer.reject(b); return }
            peer.peerRequests.append(b)
            serveUploads(peer)
        case 7 where p.count >= 8:
            gotBlock(peer, Block(piece: Int(p.u32(0)), offset: Int(p.u32(4)), length: p.count - 8), p.subdata(in: p.startIndex + 8..<p.endIndex))
        case 8 where p.count == 12:
            let b = Block(piece: Int(p.u32(0)), offset: Int(p.u32(4)), length: Int(p.u32(8)))
            peer.peerRequests.removeAll { $0 == b }
        case 9 where p.count == 2:
            let port = p.u16(0)
            if port > 0, session.settings.dht { session.dht(for: peer.addr)?.addNode(PeerAddr(ip: peer.addr.ip, port: port)) }
        case 13 where p.count == 4:
            if peer.suggested.count < 64 { peer.suggested.insert(Int(p.u32(0))) }
        case 14:
            peer.haveAll = true
            if let info {
                if let old = peer.have { for i in 0..<old.count where old[i] { availability[i] &-= 1 } }
                var b = Bitfield(count: info.pieceCount)
                b.setAll()
                peer.have = b
                for i in 0..<availability.count { availability[i] &+= 1 }
                updateInterest(peer)
            }
        case 15:
            if let info, peer.have == nil { peer.have = Bitfield(count: info.pieceCount) }
        case 16 where p.count == 12:
            let b = Block(piece: Int(p.u32(0)), offset: Int(p.u32(4)), length: Int(p.u32(8)))
            if let i = peer.requests.firstIndex(of: b) {
                peer.requests.remove(at: i)
                peer.requestedAt[b] = nil
                release(b, by: peer)
            }
        case 17 where p.count == 4:
            if peer.allowedFast.count < 64 { peer.allowedFast.insert(Int(p.u32(0))) }
        case 20 where !p.isEmpty:
            handleExtended(peer, p[p.startIndex], p.dropFirst())
        case 21 where p.count == 48:
            serveHashes(peer, p)
        case 22 where p.count >= 48:
            gotHashes(peer, p)
        case 23 where p.count == 48:
            peer.hashRequests[Int(p.u32(36))] = nil
        default: break
        }
    }

    private func gotHave(_ peer: Peer, _ i: Int) {
        guard let info else { if i >= 0, i < 1 << 22, peer.pendingHaves.count < 1 << 16 { peer.pendingHaves.append(i) }; return }
        guard i >= 0, i < info.pieceCount else { peer.close("bad have"); return }
        if peer.have == nil { peer.have = Bitfield(count: info.pieceCount) }
        if !peer.have![i] {
            peer.have![i] = true
            availability[i] &+= 1
            peer.idleUntil = .distantPast
        }
        if !peer.amInterested, piecePriority[i] > 0, !have[i] { peer.interested() }
        // Super-seeding: once a piece we offered has spread, offer that peer another.
        if superSeeding, isComplete {
            for other in peers where other.superSeedOffer == i && (other === peer || availability[i] > 1) { offerSuperSeedPiece(to: other) }
        }
    }

    private func updateInterest(_ peer: Peer) {
        guard let b = peer.have else { return }
        var wants = false
        let bytes = b.bytes
        for i in 0..<min(bytes.count, need.count) where bytes[i] & need[i] != 0 { wants = true; break }
        if wants { peer.interested() } else { peer.notInterested() }
    }

    // MARK: Extension protocol

    private func handleExtended(_ peer: Peer, _ id: UInt8, _ body: Data) {
        if id == Peer.donthaveID, body.count == 4 {
            let piece = Int(body.u32(0))
            if let info, piece < info.pieceCount, peer.have?[piece] == true {
                peer.have![piece] = false
                peer.haveAll = false
                availability[piece] &-= 1
            }
            return
        }
        if id == Peer.uploadOnlyID {
            peer.uploadOnly = body.first.map { $0 != 0 } ?? false
            return
        }
        guard body.count < 1 << 20, let (dict, end, _) = try? BDecoder.decode(body, allowTrailing: true) else { return }
        switch id {
        case 0:
            if let m = dict["m"]?.dict {
                for (k, v) in m {
                    guard let key = String(data: k, encoding: .utf8), let n = v.int else { continue }
                    peer.extIDs[key] = n > 0 && n < 256 ? UInt8(n) : nil
                }
            }
            if let port = dict["p"]?.int, port > 0, port < 65536 { peer.listenAddr = PeerAddr(ip: peer.addr.ip, port: UInt16(port)) }
            if let v = dict["v"]?.string, !v.isEmpty { peer.client = String(v.prefix(40)) }
            if let reqq = dict["reqq"]?.int { peer.reqq = Int(min(max(2, reqq), 500)) }
            if dict["upload_only"]?.int == 1 { peer.uploadOnly = true }
            if let mine = dict["yourip"]?.data, mine.count == 4 || mine.count == 16,
               let ip = PeerAddr.parseCompact(mine + Data([0, 1]), v6: mine.count == 16).first { session.voteExternalIP(ip.ip) }
            if let size = dict["metadata_size"]?.int, size > 0, size < 16 << 20, info == nil, metaSize == 0 {
                metaSize = Int(size)
                let count = (metaSize + Peer.blockSize - 1) / Peer.blockSize
                metaPieces = [Data?](repeating: nil, count: count)
                metaAsked = [Date?](repeating: nil, count: count)
            }
            if peer.incoming, let addr = peer.listenAddr, candidates[addr] == nil { candidates[addr] = Candidate(source: "Incoming", connected: true) }
            if info == nil { requestMetadata(Date()) }
        case Peer.metadataID:
            guard let type = dict["msg_type"]?.int, let piece = dict["piece"]?.int, piece >= 0, piece < 1024 else { return }
            switch type {
            case 0:
                guard let info, let their = peer.extIDs["ut_metadata"] else { return }
                let start = Int(piece) * Peer.blockSize
                if start < info.raw.count {
                    let chunk = info.raw.subdata(in: start..<min(start + Peer.blockSize, info.raw.count))
                    peer.sendExtended(their, .d(["msg_type": .int(1), "piece": .int(piece), "total_size": .int(Int64(info.raw.count))]), trailer: chunk)
                } else {
                    peer.sendExtended(their, .d(["msg_type": .int(2), "piece": .int(piece)]))
                }
            case 1:
                guard info == nil, Int(piece) < metaPieces.count else { return }
                let chunk = body.subdata(in: body.startIndex + end..<body.endIndex)
                let expected = Int(piece) == metaPieces.count - 1 ? metaSize - Int(piece) * Peer.blockSize : Peer.blockSize
                guard chunk.count == expected else { return }
                metaPieces[Int(piece)] = chunk
                if !metaPieces.contains(where: { $0 == nil }) { assembleMetadata() }
            case 2:
                if Int(piece) < metaAsked.count { metaAsked[Int(piece)] = nil }
            default: break
            }
        case Peer.pexID:
            guard session.settings.pex, !(info?.isPrivate ?? false) else { return }
            var found: [PeerAddr] = []
            if let added = dict["added"]?.data { found += PeerAddr.parseCompact(added) }
            if let added = dict["added6"]?.data { found += PeerAddr.parseCompact(added, v6: true) }
            addCandidates(Array(found.prefix(100)), source: "PEX")
        default: break
        }
    }

    private func requestMetadata(_ now: Date) {
        guard info == nil, metaSize > 0 else { return }
        let able = peers.filter { $0.phase == .active && $0.extIDs["ut_metadata"] != nil }
        guard !able.isEmpty else { return }
        var n = 0
        for i in metaPieces.indices where metaPieces[i] == nil {
            if let asked = metaAsked[i], now.timeIntervalSince(asked) < 10 { continue }
            let peer = able[(i + n) % able.count]
            n += 1
            metaAsked[i] = now
            peer.sendExtended(peer.extIDs["ut_metadata"]!, .d(["msg_type": .int(0), "piece": .int(Int64(i))]))
        }
    }

    private func assembleMetadata() {
        let raw = metaPieces.reduce(into: Data()) { $0.append($1!) }
        let matches = sha1(raw) == infoHash || (infoHashV2 != nil && sha256(raw) == infoHashV2)
        guard raw.count == metaSize, matches, let parsed = try? TorrentInfo(raw: raw) else {
            metaPieces = metaPieces.map { _ in nil }
            metaAsked = metaAsked.map { _ in nil }
            return
        }
        adopt(parsed, fresh: true)
        session.log("metadata received", self)
        for peer in peers where peer.phase == .active {
            if peer.have == nil || peer.have!.count != parsed.pieceCount { absorbPendingHaves(peer) }
            updateInterest(peer)
        }
        if storage?.anyFileExists ?? false { recheck() }
        dirty = true
        session.save(self)
        session.metadataArrived(self)
    }

    private func sendPex(to peer: Peer, now: Date) {
        guard let their = peer.extIDs["ut_pex"] else { return }
        peer.lastPex = now
        let current = Set(peers.compactMap { p -> PeerAddr? in p.phase == .active && p !== peer ? (p.listenAddr ?? (p.incoming ? nil : p.addr)) : nil })
        let added = current.subtracting(peer.pexSent).prefix(50)
        let dropped = peer.pexSent.subtracting(current).prefix(50)
        guard !added.isEmpty || !dropped.isEmpty else { return }
        func pack(_ list: [PeerAddr], v6: Bool) -> Data { list.filter { $0.isV6 == v6 }.compactMap(\.compact).reduce(Data(), +) }
        let a = Array(added), d = Array(dropped)
        let flags = Data(a.filter { !$0.isV6 }.map { addr -> UInt8 in
            var f: UInt8 = 0
            if let p = peers.first(where: { $0.listenAddr == addr || $0.addr == addr }) {
                if (p.transport as? MSETransport)?.encrypted == true { f |= 0x01 }
                if p.uploadOnly || p.haveAll || p.have?.isFull == true { f |= 0x02 }
                if p.transport.isUTP { f |= 0x04 }
                if !p.incoming { f |= 0x10 }  // reachable: we connected to it
            }
            return f
        })
        peer.sendExtended(their, .d([
            "added": .bytes(pack(a, v6: false)), "added.f": .bytes(flags),
            "added6": .bytes(pack(a, v6: true)), "dropped": .bytes(pack(d, v6: false)), "dropped6": .bytes(pack(d, v6: true)),
        ]))
        peer.pexSent.formUnion(added)
        peer.pexSent.subtract(dropped)
    }

    // MARK: v2 hashes (BEP 52)

    /// v2-only pieces whose hashes haven't arrived yet can't be checked, so they wait.
    private var layerWait: [ClosedRange<Int>] {
        guard let info, !info.hasV1 else { return [] }
        return info.missingLayers.compactMap { info.pieces(ofFile: $0) }
    }

    private var pieceLevels: Int { Merkle.log2((info?.pieceLength ?? Merkle.blockSize) / Merkle.blockSize) }

    /// Asks v2 peers for the piece layers a magnet didn't bring, 512 hashes at a time with proofs.
    private func requestLayers(_ now: Date) {
        guard let info else { return }
        let able = peers.filter { $0.phase == .active && $0.supportsV2 }
        guard !able.isEmpty else { return }
        for (n, i) in info.missingLayers.prefix(8).enumerated() {
            let f = info.files[i]
            let count = Int((f.length + Int64(info.pieceLength) - 1) / Int64(info.pieceLength))
            let width = Merkle.nextPow2(count)
            let chunk = min(width, 512)
            let proof = Merkle.log2(width / chunk)
            for start in stride(from: 0, to: count, by: chunk) where layerParts[i]?[start] == nil {
                let peer = able[(n + start / chunk) % able.count]
                let key = i * 1_000_000 + start
                if let asked = peer.hashRequests[key], now.timeIntervalSince(asked) < 20 { continue }
                peer.hashRequests[key] = now
                peer.hashMessage(21, root: f.root!, base: pieceLevels, index: start, length: chunk, proof: proof)
            }
        }
    }

    private func gotHashes(_ peer: Peer, _ p: Data) {
        guard let info else { return }
        let root = p.prefix(32)
        let base = Int(p.u32(32)), index = Int(p.u32(36)), length = Int(p.u32(40)), proof = Int(p.u32(44))
        guard let i = info.files.firstIndex(where: { $0.root == root }), base == pieceLevels, length > 0, length <= 512, proof < 32,
              p.count == 48 + (length + proof) * 32 else { return }
        peer.hashRequests[i * 1_000_000 + index] = nil
        let hashes = stride(from: 48, to: 48 + length * 32, by: 32).map { p.subdata(in: p.startIndex + $0..<p.startIndex + $0 + 32) }
        let uncles = stride(from: 48 + length * 32, to: p.count, by: 32).map { p.subdata(in: p.startIndex + $0..<p.startIndex + $0 + 32) }
        // Fold this run's subtree up through the uncles to the file's root.
        var node = Merkle.root(hashes, width: length, pad: Merkle.zeroRoot(levels: pieceLevels))
        var position = index / length
        for uncle in uncles {
            node = position % 2 == 0 ? Merkle.pair(node, uncle) : Merkle.pair(uncle, node)
            position /= 2
        }
        guard node == root else { return }
        let count = Int((info.files[i].length + Int64(info.pieceLength) - 1) / Int64(info.pieceLength))
        layerParts[i, default: [:]][index] = hashes.prefix(max(0, min(length, count - index))).reduce(Data(), +)
        let parts = layerParts[i]!
        if parts.values.reduce(0, { $0 + $1.count / 32 }) >= count {
            let layer = parts.keys.sorted().map { parts[$0]! }.reduce(Data(), +)
            if info.accept(layer: layer, forFile: i) { layerParts[i] = nil; dirty = true }
        }
    }

    private func serveHashes(_ peer: Peer, _ p: Data) {
        guard let info else { return }
        let root = p.prefix(32)
        let base = Int(p.u32(32)), index = Int(p.u32(36)), length = Int(p.u32(40)), proof = Int(p.u32(44))
        func reject() { peer.hashMessage(23, root: root, base: base, index: index, length: length, proof: proof) }
        guard let layer = info.pieceLayers[root], base == pieceLevels, length >= 1, length <= 512, length & (length - 1) == 0, index % length == 0, proof < 32 else { reject(); return }
        let pad = Merkle.zeroRoot(levels: pieceLevels)
        var nodes = stride(from: 0, to: layer.count, by: 32).map { layer.subdata(in: $0..<$0 + 32) }
        let width = Merkle.nextPow2(nodes.count)
        guard index + length <= width else { reject(); return }
        nodes += [Data](repeating: pad, count: width - nodes.count)
        var out = nodes[index..<index + length].reduce(Data(), +)
        // Uncles: siblings of this run's ancestors, from the run's own level upward.
        var level = stride(from: 0, to: nodes.count, by: length).map { Merkle.root(Array(nodes[$0..<$0 + length]), width: length, pad: pad) }
        var position = index / length
        var uncles = 0
        while uncles < proof, level.count > 1 {
            out.append(level[position ^ 1])
            level = stride(from: 0, to: level.count, by: 2).map { Merkle.pair(level[$0], level[$0 + 1]) }
            position /= 2
            uncles += 1
        }
        peer.hashMessage(22, root: root, base: base, index: index, length: length, proof: uncles, hashes: out)
    }

    // MARK: Picking pieces

    private func buildOrder() {
        guard let info else { return }
        orderDirty = false
        orderBuilt = Date()
        var list = (0..<info.pieceCount).filter { piecePriority[$0] > 0 && !have[$0] }
        if sequential {
            list.sort { piecePriority[$0] != piecePriority[$1] ? piecePriority[$0] > piecePriority[$1] : $0 < $1 }
        } else {
            list.shuffle()
            // Random first pieces: until we have a few, any piece gets us trading sooner.
            if have.setCount >= 4 {
                list.sort { piecePriority[$0] != piecePriority[$1] ? piecePriority[$0] > piecePriority[$1] : availability[$0] < availability[$1] }
            } else {
                list.sort { piecePriority[$0] > piecePriority[$1] }
            }
        }
        pickOrder = list
    }

    private func fillRequests(_ peer: Peer) {
        guard let info, let peerHave = peer.have, peer.phase == .active, !isComplete, peer.idleUntil < Date(), mayDownload(peer) else { return }
        if !peer.amInterested { updateInterest(peer); if !peer.amInterested { return } }
        let depth = max(8, min(peer.reqq, Int(peer.down.rate * 1.5) / Peer.blockSize + 8))
        guard peer.requests.count < depth else { return }
        let choked = peer.peerChoking
        let waiting = layerWait
        func allowed(_ piece: Int) -> Bool {
            piece >= 0 && piece < peerHave.count && peerHave[piece] && !have[piece] && (!choked || peer.allowedFast.contains(piece))
                && !waiting.contains { $0.contains(piece) }
        }
        func take(_ piece: Int, duplicates: Bool) {
            if downloading[piece] == nil {
                let blocks = (info.pieceSize(piece) + Peer.blockSize - 1) / Peer.blockSize
                downloading[piece] = PieceProgress(blocks: [UInt8](repeating: 0, count: blocks))
            }
            guard let progress = downloading[piece], !progress.verifying else { return }
            for (i, s) in progress.blocks.enumerated() where peer.requests.count < depth {
                let b = block(piece, i, info)
                if s == 0 || (duplicates && s == 1 && !peer.requests.contains(b) && peers.filter({ $0.requests.contains(b) }).count < 2) {
                    downloading[piece]?.blocks[i] = 1
                    peer.request(b)
                }
            }
        }
        // Streaming deadlines first, earliest first; overdue ones may be asked of two peers.
        if !deadlines.isEmpty {
            let now = Date()
            for (piece, due) in deadlines.sorted(by: { $0.value < $1.value }) where peer.requests.count < depth && allowed(piece) {
                take(piece, duplicates: due < now)
            }
        }
        // Pieces already under way, so they finish and can be shared.
        for (piece, progress) in downloading where peer.requests.count < depth && !progress.verifying && allowed(piece) && progress.blocks.contains(0) {
            take(piece, duplicates: false)
        }
        // Pieces the peer suggested (it has them cached), then the picker's order.
        for piece in peer.suggested where peer.requests.count < depth && piecePriority.indices.contains(piece) && piecePriority[piece] > 0 && downloading[piece] == nil && allowed(piece) {
            take(piece, duplicates: false)
        }
        peer.suggested.removeAll()
        if peer.requests.count < depth {
            for piece in pickOrder where peer.requests.count < depth && downloading[piece] == nil && allowed(piece) {
                take(piece, duplicates: false)
            }
        }
        // Endgame: ask for blocks already requested from someone slower.
        if peer.requests.count < depth, endgame {
            for (piece, progress) in downloading where peer.requests.count < depth && !progress.verifying && allowed(piece) { take(piece, duplicates: true) }
        }
        // Nothing this peer can give us right now: don't look again until it has something new.
        if peer.requests.isEmpty { peer.idleUntil = Date().addingTimeInterval(2) }
    }

    private func block(_ piece: Int, _ index: Int, _ info: TorrentInfo) -> Block {
        let offset = index * Peer.blockSize
        return Block(piece: piece, offset: offset, length: min(Peer.blockSize, info.pieceSize(piece) - offset))
    }

    private func release(_ b: Block, by peer: Peer) {
        guard var progress = downloading[b.piece], b.offset / Peer.blockSize < progress.blocks.count else { return }
        let i = b.offset / Peer.blockSize
        if progress.blocks[i] == 1, !peers.contains(where: { $0 !== peer && $0.requests.contains(b) }) {
            progress.blocks[i] = 0
            downloading[b.piece] = progress
        }
    }

    private func expireRequests(_ now: Date) {
        for peer in peers where !peer.requests.isEmpty {
            let timeout: TimeInterval = peer.down.rate > 0 ? 30 : 20
            if now.timeIntervalSince(peer.lastPiece) > 60 { peer.snubbed = true }
            let old = peer.requests.filter { now.timeIntervalSince(peer.requestedAt[$0] ?? now) > timeout }
            for b in old {
                peer.requests.removeAll { $0 == b }
                peer.requestedAt[b] = nil
                release(b, by: peer)
            }
        }
    }

    private func gotBlock(_ peer: Peer, _ b: Block, _ data: Data) {
        peer.requests.removeAll { $0 == b }
        peer.requestedAt[b] = nil
        guard let info, var progress = downloading[b.piece], b.offset % Peer.blockSize == 0 else { return }
        let i = b.offset / Peer.blockSize
        guard i < progress.blocks.count, b.length == min(Peer.blockSize, info.pieceSize(b.piece) - b.offset) else { return }
        peer.lastPiece = Date()
        peer.snubbed = false
        peer.down.add(data.count)
        down.add(data.count)
        session.down.add(data.count)
        if !(session.settings.lanUnlimited && peer.addr.isLocal) {
            session.downLimiter.take(data.count)
            downLimiter.take(data.count)
        }
        downloadedTotal += Int64(data.count)
        guard progress.blocks[i] != 2 else { wasted += Int64(data.count); return }
        progress.blocks[i] = 2
        progress.arrived += 1
        progress.from[i] = peer.addr.ip
        // Endgame duplicates: tell the others not to bother.
        for other in peers where other !== peer && other.requests.contains(b) { other.cancel(b) }
        let complete = progress.arrived == progress.blocks.count
        if complete { progress.verifying = true }
        downloading[b.piece] = progress
        writeBlock(b.piece, b.offset, data, complete: complete)
        fillRequests(peer)
    }

    private func writeBlock(_ piece: Int, _ offset: Int, _ data: Data, complete: Bool) {
        guard let storage else { return }
        session.disk.write(storage, piece: piece, offset: offset, data: data, complete: complete, wantHashes: failedBlocks[piece] != nil) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.diskFailed(error)
            case .success(let check): if complete { self.verified(piece, check) }
            }
        }
    }

    private func diskFailed(_ error: Error) {
        guard self.error == nil else { return }
        let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        self.error = why
        // A full disk might clear up: try again in a while.
        if why.contains("full") { retryAfterError = Date().addingTimeInterval(120) }
        stop(announce: true)
        session.log("disk error: \(why)", self)
    }

    private func verified(_ piece: Int, _ check: DiskIO.Check) {
        guard let progress = downloading.removeValue(forKey: piece), let info else { return }
        if check.ok {
            have[piece] = true
            need[piece >> 3] &= ~(0x80 >> (piece & 7))
            dirty = true
            // Smart ban: compare against what each peer sent the time it failed.
            if let failed = failedBlocks.removeValue(forKey: piece), let good = check.blockHashes {
                for (block, entry) in failed where block < good.count && good[block] != entry.hash { ban(entry.ip) }
            }
            for peer in peers where peer.phase == .active {
                if !(peer.have?[piece] ?? false) && !(superSeeding && isComplete) { peer.sendHave(piece) }
                if peer.amInterested { updateInterest(peer) }
            }
            for f in filesTouching(piece) { finishFileIfDone(f) }
        } else {
            wasted += Int64(info.pieceSize(piece))
            let contributors = Set(progress.from.values)
            if contributors.count == 1, let only = contributors.first, !only.hasPrefix("web:") {
                ban(only)
            } else if let hashes = check.blockHashes {
                var record: [Int: (ip: String, hash: Data)] = [:]
                for (block, ip) in progress.from where block < hashes.count { record[block] = (ip, hashes[block]) }
                failedBlocks[piece] = record
            }
            session.log("piece \(piece) failed its hash check", self)
        }
    }

    private func ban(_ ip: String) {
        guard !ip.hasPrefix("web:"), banned.insert(ip).inserted else { return }
        for peer in peers where peer.addr.ip == ip { peer.close("sent bad data") }
        session.log("banned \(ip) for sending bad data", self)
    }

    private func filesTouching(_ piece: Int) -> [Int] {
        guard let info else { return [] }
        let start = Int64(piece) * Int64(info.pieceLength), end = start + Int64(info.pieceSize(piece))
        return info.files.indices.filter { info.files[$0].length > 0 && info.files[$0].offset < end && info.files[$0].offset + info.files[$0].length > start }
    }

    private func finishFileIfDone(_ i: Int) {
        guard let storage, let info, !info.files[i].isPad, fileComplete(i) else { return }
        session.disk.queue.async { storage.finish(file: i) }
    }

    private func serveUploads(_ peer: Peer) {
        guard let storage else { return }
        while !peer.reading, !peer.peerRequests.isEmpty, peer.transport.backlog < 256 * 1024, mayUpload(peer) {
            let b = peer.peerRequests.removeFirst()
            if peer.amChoking { peer.reject(b); continue }
            peer.reading = true
            if !(session.settings.lanUnlimited && peer.addr.isLocal) {
                session.upLimiter.take(b.length)
                upLimiter.take(b.length)
            }
            session.disk.read(storage, piece: b.piece, offset: b.offset, length: b.length) { [weak self, weak peer] data in
                guard let self, let peer else { return }
                peer.reading = false
                guard let data, peer.phase == .active else { return }
                peer.sendPiece(b, data: data)
                self.up.add(data.count)
                self.session.up.add(data.count)
                self.uploadedTotal += Int64(data.count)
                self.lastUpload = Date()
                self.serveUploads(peer)
            }
        }
    }

    // MARK: Choking

    private func choke(_ now: Date) {
        lastChoke = now
        // Not sharing while downloading: everyone stays choked, so nothing goes up. (A finished
        // torrent only runs when seeding was allowed.)
        if !isComplete, !session.settings.uploadWhileDownloading {
            for p in peers where p.phase == .active { p.choke(); p.optimistic = false }
            return
        }
        let interested = peers.filter { $0.phase == .active && $0.peerInterested }
        let slots = max(1, session.settings.uploadSlots)
        let ranked: [Peer]
        if isComplete {
            switch session.settings.seedStrategy {
            case 1:  // round robin: longest waiting first
                ranked = interested.sorted { $0.lastUnchoked < $1.lastUnchoked }
            case 2:  // anti-leech: favour peers just starting or nearly done
                func score(_ p: Peer) -> Double { abs((p.have.map { Double($0.setCount) / Double(max($0.count, 1)) } ?? 0) - 0.5) }
                ranked = interested.sorted { score($0) > score($1) }
            default:  // fastest upload
                ranked = interested.sorted { $0.up.rate > $1.up.rate }
            }
        } else {
            // Tit-for-tat: those giving us the most.
            ranked = interested.filter { !$0.snubbed }.sorted { $0.down.rate > $1.down.rate }
        }
        var unchoke = Set(ranked.prefix(slots).map { ObjectIdentifier($0) })
        if now.timeIntervalSince(lastOptimistic) >= 30 {
            lastOptimistic = now
            for p in peers { p.optimistic = false }
            let others = interested.filter { !unchoke.contains(ObjectIdentifier($0)) }
            // New peers get three times the chance: they have nothing to offer yet.
            let weighted = others.flatMap { now.timeIntervalSince($0.connectedAt) < 60 ? [$0, $0, $0] : [$0] }
            weighted.randomElement()?.optimistic = true
        }
        for p in peers where p.optimistic && p.peerInterested { unchoke.insert(ObjectIdentifier(p)) }
        for p in peers where p.phase == .active {
            if unchoke.contains(ObjectIdentifier(p)) {
                p.unchoke()
                p.lastUnchoked = now
            } else {
                p.choke()
            }
        }
    }

    /// BEP 16: offer this peer a piece few others have, one at a time.
    private func offerSuperSeedPiece(to peer: Peer) {
        guard let info else { return }
        if let old = peer.superSeedOffer { superOffered[old, default: 1] -= 1 }
        let candidates = (0..<info.pieceCount).filter { have[$0] && !(peer.have?[$0] ?? false) }
        guard let piece = candidates.min(by: { (availability[$0], superOffered[$0] ?? 0) < (availability[$1], superOffered[$1] ?? 0) }) else { return }
        peer.superSeedOffer = piece
        superOffered[piece, default: 0] += 1
        peer.sendHave(piece)
    }

    // MARK: Web seeds

    private func useWebSeeds(_ now: Date) {
        guard let info, !isComplete, !webSeeds.isEmpty, session.downLimiter.hasRoom, downLimiter.hasRoom else { return }
        for seed in webSeeds where !seed.busy && seed.retryAt <= now {
            // A whole piece nobody else is fetching, in the picker's order.
            guard let piece = pickOrder.first(where: { !have[$0] && downloading[$0] == nil }) else { return }
            let blocks = (info.pieceSize(piece) + Peer.blockSize - 1) / Peer.blockSize
            downloading[piece] = PieceProgress(blocks: [UInt8](repeating: 1, count: blocks))
            seed.fetch(piece, info: info, session: session.webSession) { [weak self] data in
                guard let self else { return }
                guard let data, data.count == info.pieceSize(piece), var progress = self.downloading[piece] else {
                    self.downloading[piece] = nil
                    return
                }
                progress.blocks = [UInt8](repeating: 2, count: blocks)
                progress.arrived = blocks
                progress.verifying = true
                progress.from = [0: "web:" + seed.url]
                self.downloading[piece] = progress
                self.down.add(data.count)
                self.session.down.add(data.count)
                self.session.downLimiter.take(data.count)
                self.downLimiter.take(data.count)
                self.downloadedTotal += Int64(data.count)
                for (n, offset) in stride(from: 0, to: data.count, by: Peer.blockSize).enumerated() {
                    let chunk = data.subdata(in: offset..<min(offset + Peer.blockSize, data.count))
                    self.writeBlock(piece, offset, chunk, complete: n == blocks - 1)
                }
            }
        }
    }

    // MARK: Trackers

    /// Each tier announces to one tracker at a time, moving on when it fails (BEP 12), unless
    /// Settings ask for every tracker or every tier.
    private func announceDue(_ now: Date) {
        let settings = session.settings
        let tiers = Dictionary(grouping: trackers, by: \.tier).sorted { $0.key < $1.key }
        for (n, entry) in tiers.enumerated() {
            if !settings.announceToAllTiers, n > 0, tiers[0].value.contains(where: { $0.status == "Working" }) { break }
            let list = entry.value
            let chosen: [Tracker]
            if settings.announceToAllTrackers {
                chosen = list
            } else if let working = list.first(where: { $0.failures == 0 && $0.lastAnnounce != nil }) {
                chosen = [working]
            } else {
                chosen = Array(list.sorted { $0.failures < $1.failures }.prefix(1))
            }
            for t in chosen where !t.updating && t.nextAnnounce <= now {
                // UDP can't go through the proxy: with "only through the proxy", UDP trackers wait.
                if settings.proxyOnly, t.url.lowercased().hasPrefix("udp:") {
                    t.status = "Off (proxy only)"
                    t.nextAnnounce = now.addingTimeInterval(60)
                    continue
                }
                announce(t, event: t.sentStarted ? nil : "started")
            }
        }
        for t in trackers where !t.updating && t.nextScrape <= now && t.lastAnnounce != nil && !(settings.proxyOnly && t.url.lowercased().hasPrefix("udp:")) {
            t.nextScrape = now.addingTimeInterval(1800)
            TrackerClient.scrape(t, infoHash: infoHash) { r in
                guard let r else { return }
                t.seeds = r.seeds ?? t.seeds
                t.leechers = r.leechers ?? t.leechers
                t.completed = r.completed ?? t.completed
            }
        }
    }

    func reannounce() {
        for t in trackers where !t.updating { t.nextAnnounce = Date() }
        lastDHT = .distantPast
        lastLSD = .distantPast
    }

    private func announceAll(event: String) {
        for t in trackers where t.sentStarted && !t.updating { announce(t, event: event) }
    }

    private func announce(_ t: Tracker, event: String?) {
        t.updating = true
        t.status = "Updating…"
        let request = AnnounceRequest(
            infoHash: infoHash, peerID: session.peerID, port: session.listenPort, uploaded: uploadedTotal,
            downloaded: downloadedTotal, left: info == nil ? 16384 : leftBytes, event: event, key: announceKey,
            numWant: event == "stopped" ? 0 : 200, trackerID: t.trackerID, ipv6: session.globalIPv6
        )
        TrackerClient.announce(t, request) { [weak self] result in
            guard let self else { return }
            t.updating = false
            t.lastAnnounce = Date()
            if event == "stopped" { t.sentStarted = false; t.status = "Stopped"; return }
            switch result {
            case .success(let r):
                t.sentStarted = true
                t.failures = 0
                t.status = "Working"
                t.message = r.warning ?? ""
                t.trackerID = r.trackerID ?? t.trackerID
                t.interval = max(60, min(r.interval, 3600))
                t.minInterval = r.minInterval ?? 60
                t.peers = r.peers.count
                t.seeds = r.seeds ?? t.seeds
                t.leechers = r.leechers ?? t.leechers
                t.nextAnnounce = Date().addingTimeInterval(TimeInterval(self.peers.count < 5 ? max(t.minInterval, 120) : t.interval))
                self.addCandidates(r.peers, source: "Tracker")
            case .failure(let error):
                t.failures += 1
                t.status = "Not working"
                t.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                t.nextAnnounce = Date().addingTimeInterval(min(60 * pow(2, Double(min(t.failures, 6))), 3600))
            }
        }
    }

    // MARK: Snapshot

    var state: String {
        if !session.enabled { return "off" }
        if error != nil { return "error" }
        if checking != nil { return "checking" }
        if paused { return isComplete ? "completed" : "paused" }
        if queued { return "queued" }
        if info == nil { return "metadata" }
        if isComplete { return "seeding" }
        if let since = stalledSince, Date().timeIntervalSince(since) > 15 { return "stalled" }
        return "downloading"
    }

    var displayPath: String { storage?.contentURL.path ?? savePath.appendingPathComponent(name).path }

    func summary() -> [String: Any] {
        let wanted = wantedBytes
        let left = leftBytes
        let progress = info == nil ? 0 : (wanted == 0 ? 1 : Double(wanted - left) / Double(wanted))
        let seeds = peers.filter { $0.phase == .active && ($0.haveAll || $0.uploadOnly || $0.have?.isFull == true) }.count
        var d: [String: Any] = [
            "id": infoHash.tHex, "kind": "torrent", "name": name, "state": state,
            "progress": checking ?? progress, "size": wanted, "total": info?.totalLength ?? 0, "done": wanted - left,
            "down": down.rate, "up": up.rate, "downloaded": downloadedTotal, "uploaded": uploadedTotal,
            "ratio": Double(uploadedTotal) / Double(max(downloadedTotal, wanted - left, 1)),
            "peers": peers.filter { $0.phase == .active }.count - seeds, "seeds": seeds,
            "swarmSeeds": trackers.map(\.seeds).max() ?? -1, "swarmPeers": trackers.map(\.leechers).max() ?? -1,
            "added": addedAt.timeIntervalSince1970 * 1000, "path": displayPath,
            "sequential": sequential, "firstLast": firstLast, "queue": queuePosition, "forceStart": forceStart,
            "superSeed": superSeeding, "downloadLimit": downloadLimit, "uploadLimit": uploadLimit,
            "eta": down.rate > 0 ? Double(left) / down.rate : -1,
        ]
        if let error { d["error"] = error }
        if let completedAt { d["completed"] = completedAt.timeIntervalSince1970 * 1000 }
        return d
    }

    func detail() -> [String: Any] {
        var d = summary()
        d["hash"] = infoHash.tHex
        if let infoHashV2 { d["hashV2"] = infoHashV2.tHex }
        d["magnet"] = TorrentSource.magnet(hash: infoHash, v2: infoHashV2, name: name, trackers: trackers.map(\.url))
        d["savePath"] = savePath.path
        d["wasted"] = wasted
        d["active"] = activeSeconds
        d["seeding"] = seedingSeconds
        d["candidates"] = candidates.count
        d["banned"] = banned.count
        d["dht"] = session.dhts.reduce(0) { $0 + $1.nodeCount }
        if let info {
            d["pieceSize"] = info.pieceLength
            d["pieceCount"] = info.pieceCount
            d["havePieces"] = have.setCount
            d["private"] = info.isPrivate
            d["version"] = info.hasV1 && info.hasV2 ? "Hybrid (v1 + v2)" : info.hasV2 ? "v2" : "v1"
            if let c = info.comment { d["comment"] = c }
            if let c = info.createdBy { d["createdBy"] = c }
            if let c = info.creationDate { d["created"] = c.timeIntervalSince1970 * 1000 }
            // Availability: copies of the rarest piece, plus the share of pieces above that.
            if !availability.isEmpty {
                let lowest = availability.min() ?? 0
                d["availability"] = Double(lowest) + Double(availability.filter { $0 > lowest }.count) / Double(availability.count)
            }
            d["files"] = info.files.enumerated().compactMap { i, f -> [String: Any]? in
                guard !f.isPad else { return nil }
                var done: Int64 = 0
                if let range = info.pieces(ofFile: i) {
                    for p in range where have[p] {
                        let start = max(Int64(p) * Int64(info.pieceLength), f.offset)
                        let end = min(Int64(p) * Int64(info.pieceLength) + Int64(info.pieceSize(p)), f.offset + f.length)
                        done += max(0, end - start)
                    }
                }
                let path = storage?.renamed[i]?.joined(separator: "/") ?? f.path.joined(separator: "/")
                return ["i": i, "path": path, "size": f.length, "done": done, "priority": filePriority[i], "full": storage?.url(ofFile: i, final: true).path ?? ""]
            }
            // The piece map, squeezed into at most 600 cells: 0–9 how much of each cell is here, "d" under way.
            let cells = min(info.pieceCount, 600)
            var map = ""
            for c in 0..<cells {
                let lo = c * info.pieceCount / cells, hi = max(lo + 1, (c + 1) * info.pieceCount / cells)
                var got = 0, busy = false
                for p in lo..<hi { if have[p] { got += 1 } else if downloading[p] != nil { busy = true } }
                map += got == hi - lo ? "9" : busy ? "d" : String(got * 9 / (hi - lo))
            }
            d["pieces"] = map
        }
        d["peerList"] = peers.filter { $0.phase == .active }.map { p -> [String: Any] in
            [
                "addr": p.addr.description, "client": p.client, "flags": p.flags, "down": p.down.rate, "up": p.up.rate,
                "progress": p.haveAll || p.uploadOnly ? 1 : p.have.map { Double($0.setCount) / Double(max($0.count, 1)) } ?? 0,
                "downloaded": p.down.total, "uploaded": p.up.total, "utp": p.transport.isUTP,
                "encrypted": (p.transport as? MSETransport)?.encrypted ?? false,
                "source": candidates[p.listenAddr ?? p.addr]?.source ?? (p.incoming ? "Incoming" : ""),
            ]
        }
        var trackerList: [[String: Any]] = trackers.map {
            ["url": $0.url, "tier": $0.tier, "status": $0.status, "message": $0.message, "peers": $0.peers, "seeds": $0.seeds,
             "leechers": $0.leechers, "completed": $0.completed, "next": $0.updating ? 0 : max(0, $0.nextAnnounce.timeIntervalSinceNow)]
        }
        let isPrivate = info?.isPrivate ?? false
        let settings = session.settings
        func source(_ name: String, _ on: Bool) -> [String: Any] {
            ["url": name, "status": isPrivate ? "Off (private torrent)" : on ? "Working" : "Off", "peers": candidates.values.filter { $0.source == name }.count, "special": true]
        }
        trackerList.insert(contentsOf: [source("DHT", settings.dht), source("PEX", settings.pex), source("LSD", settings.lsd)], at: 0)
        d["trackers"] = trackerList
        d["webSeeds"] = webSeeds.map { ["url": $0.url, "status": $0.status, "downloaded": $0.downloaded, "kind": $0.hoffman ? "BEP 17" : "BEP 19"] }
        return d
    }

    // MARK: Saving

    func restoreExtras(_ d: [String: Any]) {
        forceStart = d["forceStart"] as? Bool ?? false
        superSeeding = d["superSeed"] as? Bool ?? false
        downloadLimit = d["downloadLimit"] as? Int ?? 0
        uploadLimit = d["uploadLimit"] as? Int ?? 0
        banned = Set(d["banned"] as? [String] ?? [])
    }

    func resumeData() -> [String: Any] {
        var d: [String: Any] = [
            "hash": infoHash.tHex, "name": name, "path": savePath.path, "trackers": trackers.map { [$0.url, String($0.tier)] },
            "webSeeds": webSeeds.filter { !$0.hoffman }.map(\.url), "httpSeeds": webSeeds.filter(\.hoffman).map(\.url),
            "added": addedAt.timeIntervalSince1970, "paused": paused, "sequential": sequential,
            "firstLast": firstLast, "priorities": filePriority, "have": have.data.base64EncodedString(),
            "downloaded": downloadedTotal, "uploaded": uploadedTotal, "active": activeSeconds, "seeding": seedingSeconds,
            "manualSeed": manualSeed, "queue": queuePosition, "forceStart": forceStart, "superSeed": superSeeding,
            "downloadLimit": downloadLimit, "uploadLimit": uploadLimit, "banned": Array(banned.prefix(500)),
            "peers": candidates.filter { $0.value.fails == 0 && $0.value.source != "Incoming" }.keys.prefix(100).map(\.description),
            "partials": Dictionary(uniqueKeysWithValues: downloading.compactMap { piece, p -> (String, [Int])? in
                let got = p.blocks.indices.filter { p.blocks[$0] == 2 }
                return got.isEmpty || p.verifying ? nil : (String(piece), got)
            }),
        ]
        if let infoHashV2 { d["hashV2"] = infoHashV2.tHex }
        if let storage {
            d["stamps"] = storage.stamps()
            d["renamed"] = Dictionary(uniqueKeysWithValues: storage.renamed.map { (String($0.key), $0.value) })
            if let root = storage.rootName { d["rootName"] = root }
        }
        if let completedAt { d["completed"] = completedAt.timeIntervalSince1970 }
        return d
    }
}
