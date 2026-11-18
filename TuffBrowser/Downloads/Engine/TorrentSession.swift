import Foundation
import Network

/// The torrent client: owns every torrent, the listening sockets, DHT, µTP, LSD, port mapping
/// and the shared speed limits. Nothing touches the network until the first torrent is added
/// or restored, so Tuff stays quiet for people who never use torrents.
final class TorrentSession {
    static let shared = TorrentSession()

    private(set) var settings = TorrentSettings()
    let peerID: Data = {
        let chars = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        return Data("-TF1000-".utf8) + Data((0..<12).map { _ in chars.randomElement()! })
    }()
    private(set) var listenPort: UInt16 = 0
    let disk = DiskIO()
    private(set) var torrents: [Torrent] = []
    private var listener: NWListener?
    private var udp4: UDPSocket?, udp6: UDPSocket?
    private var utp4: UTPManager?, utp6: UTPManager?
    private(set) var dhts: [DHT] = []
    private(set) var lsd: LocalDiscovery?
    private var portMapper: PortMapper?
    private(set) var ipFilter = IPFilter()
    private(set) var webSession = TrackerClient.makeSession(proxy: nil)
    private(set) var externalIP: String?
    private(set) var globalIPv6: String?
    private var ipVotes: [String: Int] = [:]
    private var pending: [ObjectIdentifier: Peer] = [:]
    let downLimiter = RateLimiter(), upLimiter = RateLimiter()
    var down = RateMeter(), up = RateMeter()
    private var started = false
    /// Torrenting is switched on (the downloads page's toggle). Off: no sockets, no DHT, no
    /// peers; torrents stay on the list, stopped.
    private(set) var enabled = true
    private var directory: URL?
    private var defaultSavePath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    private var tickTimer: DispatchSourceTimer?
    private var ticks = 0
    private var pathMonitor: NWPathMonitor?
    private var allTime: (down: Int64, up: Int64) = (0, 0)
    private var events: [[String: Any]] = []

    /// Read on the main thread by the downloads page.
    private let lock = NSLock()
    private var published: [[String: Any]] = []
    private var publishedGlobal: [String: Any] = [:]
    private var publishedEvents: [[String: Any]] = []
    /// Called on the main thread when a torrent finishes downloading: (name, path).
    var onFinished: ((String, String) -> Void)?
    /// Called on the main thread when settings change, so the app can save them.
    var onSettingsChanged: (([String: Any]) -> Void)?

    // MARK: Setup

    /// Points the client at its folder and puts back saved torrents. Called once at launch.
    func configure(directory: URL, savePath: URL, settings saved: [String: Any], enabled: Bool = true) {
        engineQueue.async { [self] in
            self.directory = directory
            self.enabled = enabled
            defaultSavePath = savePath
            settings.apply(saved)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            applySettings(old: nil)
            loadAll()
            if !torrents.isEmpty, enabled { startNetwork() }
            publish()
        }
    }

    /// Turns torrenting on or off. Off stops every torrent (telling trackers) and closes the
    /// sockets; on puts back the ones that were running.
    func setEnabled(_ on: Bool) {
        engineQueue.async { [self] in
            guard on != enabled else { return }
            if on {
                enabled = true
                if !torrents.isEmpty { startNetwork() }
                for t in torrents { t.reannounce() }
                log("torrents turned on", nil)
            } else {
                for t in torrents where t.isRunning { t.stop(announce: true) }
                enabled = false
                stopNetwork()
                for t in torrents { save(t) }
                log("torrents turned off", nil)
            }
            publish()
        }
    }

    var saveFolder: URL { engineQueue.sync { defaultSavePath } }

    func setDefaultSavePath(_ url: URL) { engineQueue.async { self.defaultSavePath = url } }

    func utp(for addr: PeerAddr) -> UTPManager? { addr.isV6 ? utp6 : utp4 }
    func dht(for addr: PeerAddr) -> DHT? { dhts.first { $0.v6 == addr.isV6 } }

    private func startNetwork() {
        guard !started, enabled else { return }
        started = true
        let state = (try? Data(contentsOf: stateFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if let stats = state["stats"] as? [String: NSNumber] { allTime = (stats["down"]?.int64Value ?? 0, stats["up"]?.int64Value ?? 0) }
        var port = UInt16(clamping: settings.port)
        if settings.randomPort || port == 0 { port = UInt16.random(in: 20000...60000) }
        // The UDP sockets take the port first; on a clash, another port is tried.
        for _ in 0..<8 {
            if let socket = UDPSocket(port: port, interface: settings.bindInterface) { udp4 = socket; break }
            port = UInt16.random(in: 20000...60000)
        }
        udp6 = UDPSocket(port: port, v6: true, interface: settings.bindInterface)
        listenPort = port
        if settings.port == 0 { settings.port = Int(port); notifySettings() }
        for (n, socket) in [udp4, udp6].enumerated() {
            guard let socket else { continue }
            let utp = UTPManager(socket: socket)
            utp.onAccept = { [weak self] s in self?.incoming(s) }
            if n == 0 { utp4 = utp } else { utp6 = utp }
            let key = n == 0 ? "dht" : "dht6"
            let dht = DHT(socket: socket, nodeID: (state[key + "ID"] as? String).flatMap { Data(tHex: $0) }, nodes: (state[key + "Nodes"] as? String).flatMap { Data(base64Encoded: $0) })
            dht.enabled = settings.dht && !settings.proxyOnly
            dht.onExternalIP = { [weak self] ip in self?.voteExternalIP(ip, weight: 3) }
            dhts.append(dht)
            socket.onPacket = { [weak self, weak utp, weak dht] data, from in
                guard let self else { return }
                if UTPManager.isUTP(data) {
                    if self.settings.utp, !self.settings.proxyOnly, !self.ipFilter.blocks(from) { utp?.handle(data, from: from) }
                } else if data.first == UInt8(ascii: "d") {
                    dht?.handle(data, from: from)
                }
            }
            socket.onBurstEnd = { [weak utp] in utp?.burstEnd() }
            if dht.enabled { dht.bootstrap() }
        }
        startListener()
        if settings.lsd, !settings.proxyOnly { startLSD() }
        if settings.portMapping { startPortMapping() }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let v6 = PortMapper.globalIPv6()
            engineQueue.async { self?.globalIPv6 = v6 }
        }
        let timer = DispatchSource.makeTimerSource(queue: engineQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.fastTick() }
        timer.resume()
        tickTimer = timer
        let monitor = NWPathMonitor()
        var lastInterfaces: [String] = []
        monitor.pathUpdateHandler = { [weak self] path in
            NetParams.interfaces = Dictionary(path.availableInterfaces.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            let names = path.availableInterfaces.map(\.name)
            if path.status == .satisfied, names != lastInterfaces, !lastInterfaces.isEmpty { self?.networkChanged() }
            lastInterfaces = names
        }
        monitor.start(queue: engineQueue)
        pathMonitor = monitor
        log("listening on port \(port)", nil)
    }

    private func startListener() {
        listener?.cancel()
        listener = nil
        guard settings.tcp, let port = NWEndpoint.Port(rawValue: listenPort) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        NetParams.apply(settings, to: params, peers: false)
        guard let listener = try? NWListener(using: params, on: port) else { return }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.pending.count < 100, !self.settings.proxyOnly else { connection.cancel(); return }
            let transport = TCPTransport(accepted: connection)
            guard !self.ipFilter.blocks(transport.remote) else { connection.cancel(); return }
            self.incoming(transport)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.log("couldn’t listen on port \(port): \(error)", nil) }
        }
        listener.start(queue: engineQueue)
        self.listener = listener
    }

    private func startLSD() {
        lsd?.close()
        let lsd = LocalDiscovery(port: listenPort)
        lsd.onPeer = { [weak self] hash, addr in
            guard let self, self.settings.lsd else { return }
            self.torrents.first { $0.wireHashes.contains(hash) && !($0.info?.isPrivate ?? false) }?.addCandidates([addr], source: "LSD")
        }
        self.lsd = lsd
    }

    private func startPortMapping() {
        let mapper = PortMapper(port: listenPort)
        mapper.onExternalIP = { [weak self] ip in self?.voteExternalIP(ip, weight: 10) }
        mapper.start()
        portMapper = mapper
    }

    /// Our address as others see it: router, DHT and peers vote; a clear winner is used for BEP 42.
    func voteExternalIP(_ ip: String, weight: Int = 1) {
        guard !PeerAddr(ip: ip, port: 1).isLocal else { return }
        ipVotes[ip, default: 0] += weight
        guard let (best, votes) = ipVotes.max(by: { $0.value < $1.value }), votes >= 10, best != externalIP else { return }
        externalIP = best
        for dht in dhts { dht.externalAddress(best) }
        log("external address is \(best)", nil)
    }

    /// Network or sleep changed: rebuild the listener, and tell trackers and the DHT where we are.
    func networkChanged() {
        engineQueue.async { [self] in
            guard started else { return }
            startListener()
            for dht in dhts { dht.bootstrap() }
            portMapper?.removeAll()
            if settings.portMapping { startPortMapping() }
            for t in torrents { t.reannounce() }
            log("network changed", nil)
        }
    }

    /// How many new outgoing connections may start now (connection pacing: at most 10 a tick).
    func connectBudget() -> Int {
        let open = torrents.reduce(0) { $0 + $1.peers.count }
        let halfOpen = torrents.reduce(0) { $0 + $1.countHalfOpen() }
        return max(0, min(settings.maxPeers - open, settings.maxHalfOpen - halfOpen, 10))
    }

    // MARK: Incoming

    private func incoming(_ raw: PeerTransport) {
        // MSE or plaintext: the wrapper tells them apart from the first bytes.
        var transport = raw
        if settings.encryption > 0 {
            transport = MSETransport(raw, infoHash: nil, lookup: { [weak self] req2 in
                guard let self else { return nil }
                for t in self.torrents { for h in t.wireHashes where sha1(Data("req2".utf8) + h) == req2 { return h } }
                return nil
            }, allowPlain: settings.encryption < 2)
        }
        let peer = Peer(transport: transport, incoming: true)
        peer.phase = .handshaking
        let key = ObjectIdentifier(peer)
        pending[key] = peer
        transport.onData = { [weak self, weak peer] data in
            guard let self, let peer else { return }
            peer.received(data, handshake: { p, hash, id in
                self.pending[key] = nil
                guard id != self.peerID, let torrent = self.torrents.first(where: { $0.wireHashes.contains(hash) }) else { return false }
                return torrent.accept(p)
            }, message: { p, id, payload in p.torrent?.handle(p, id, payload) })
        }
        transport.onClose = { [weak self, weak peer] why in
            self?.pending[key] = nil
            peer?.close(why)
        }
        transport.start()
        engineQueue.asyncAfter(deadline: .now() + 20) { [weak self] in
            if let p = self?.pending.removeValue(forKey: key) { p.close("no handshake") }
        }
    }

    // MARK: Ticks

    private func fastTick() {
        downLimiter.refill(interval: 0.1)
        upLimiter.refill(interval: 0.1)
        for t in torrents { t.service() }
        ticks += 1
        guard ticks % 10 == 0 else { return }
        let now = Date()
        down.tick()
        up.tick()
        for dht in dhts { dht.tick() }
        manageQueue()
        for t in torrents { t.tick(now) }
        publish()
        if ticks % 600 == 0 { saveState() }
    }

    /// Lets the first few downloads and seeds run and queues the rest; force-started ones skip the line.
    private func manageQueue() {
        var downloads = 0, seeds = 0
        for t in torrents.sorted(by: { $0.queuePosition < $1.queuePosition }) {
            guard !t.paused, t.error == nil else { t.queued = false; continue }
            let complete = t.isComplete
            let allowed = t.forceStart || (complete
                ? settings.maxActiveSeeds == 0 || seeds < settings.maxActiveSeeds
                : settings.maxActiveDownloads == 0 || downloads < settings.maxActiveDownloads)
            if allowed {
                if !t.forceStart { if complete { seeds += 1 } else { downloads += 1 } }
                if t.queued { t.queued = false; t.reannounce() }
            } else if !t.queued {
                t.queued = true
                t.stop(announce: true)
            }
        }
    }

    private func publish() {
        let list = torrents.sorted { $0.queuePosition < $1.queuePosition }.map { $0.summary() }
        var mapping = portMapper?.status ?? [:]
        if !settings.portMapping { mapping = [:] }
        let global: [String: Any] = [
            "down": down.rate, "up": up.rate, "port": started ? Int(listenPort) : 0, "dhtNodes": dhts.reduce(0) { $0 + $1.nodeCount },
            "peers": torrents.reduce(0) { $0 + $1.peers.count }, "utp": (utp4?.count ?? 0) + (utp6?.count ?? 0),
            "downloadedSession": down.total, "uploadedSession": up.total,
            "downloadedAll": allTime.down + down.total, "uploadedAll": allTime.up + up.total,
            "externalIP": externalIP ?? "", "portMapping": mapping.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", "),
            "filtered": ipFilter.count, "running": started,
        ]
        lock.lock()
        published = list
        publishedGlobal = global
        publishedEvents = Array(events.suffix(100))
        lock.unlock()
    }

    /// What the downloads page shows; safe on any thread.
    func snapshot() -> (torrents: [[String: Any]], global: [String: Any], events: [[String: Any]]) {
        lock.lock()
        defer { lock.unlock() }
        return (published, publishedGlobal, publishedEvents)
    }

    // MARK: Torrent callbacks

    func didFinish(_ t: Torrent) {
        let name = t.name, path = t.displayPath
        log("finished downloading", t)
        DispatchQueue.main.async { self.onFinished?(name, path) }
    }

    func metadataArrived(_ t: Torrent) {}

    /// The alert stream shown on the downloads page.
    func log(_ text: String, _ t: Torrent?) {
        var e: [String: Any] = ["text": text, "time": Date().timeIntervalSince1970 * 1000]
        if let t { e["name"] = t.name; e["id"] = t.infoHash.tHex }
        events.append(e)
        if events.count > 300 { events.removeFirst(events.count - 300) }
    }

    // MARK: Commands (from the main thread; answers come back on the main thread)

    private func find(_ id: String) -> Torrent? { torrents.first { $0.infoHash.tHex == id } }

    func add(_ source: TorrentSource, savePath: URL? = nil, paused: Bool = false, sequential: Bool = false, priorities: [Int]? = nil, done: @escaping (Result<String, Error>) -> Void) {
        engineQueue.async { [self] in
            let id = source.infoHash.tHex
            if let existing = torrents.first(where: { $0.wireHashes.contains(source.infoHash) }) {
                // Already here: take any new trackers and peers, like other clients do.
                existing.setTrackers(source.trackers)
                existing.addCandidates(source.peers.compactMap(PeerAddr.init), source: "Magnet")
                save(existing)
                DispatchQueue.main.async { done(.success(existing.infoHash.tHex)) }
                return
            }
            let t = Torrent(session: self, source: source, savePath: savePath ?? defaultSavePath, paused: paused)
            t.sequential = sequential
            if let priorities, priorities.count == t.filePriority.count { t.filePriority = priorities; t.updatePriorities() }
            t.queuePosition = (torrents.map(\.queuePosition).max() ?? -1) + 1
            torrents.append(t)
            startNetwork()
            if let storage = t.storage, storage.anyFileExists { t.recheck() }
            save(t)
            log("added", t)
            publish()
            DispatchQueue.main.async { done(.success(id)) }
            // `xs`: a magnet that says where its .torrent is.
            if source.info == nil, let xs = source.exactSource, let url = URL(string: xs) {
                webSession.dataTask(with: url) { data, _, _ in
                    guard let data, let loaded = try? TorrentSource.load(torrent: data), loaded.infoHash == source.infoHash else { return }
                    self.add(loaded) { _ in }
                }.resume()
            }
        }
    }

    /// Downloads a .torrent from the web (with the proxy, if one is set), then reads it.
    func fetchTorrent(_ url: URL, done: @escaping (Result<TorrentSource, Error>) -> Void) {
        webSession.dataTask(with: url) { data, _, error in
            let result: Result<TorrentSource, Error>
            if let data { result = Result { try TorrentSource.load(torrent: data) } } else { result = .failure(error ?? TorrentError.invalid("Couldn’t download it")) }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }

    enum Action: String {
        case pause, resume, recheck, reannounce, remove, removeWithFiles, forceStart, sequential, firstLast,
             queueUp, queueDown, queueTop, queueBottom, superSeed, seed
    }

    func perform(_ action: Action, on ids: [String], value: Bool = false) {
        engineQueue.async { [self] in
            for id in ids {
                guard let t = find(id) else { continue }
                switch action {
                case .pause: t.forceStart = false; t.pause()
                case .resume: t.forceStart = false; t.resume()
                case .forceStart: t.forceStart = true; t.resume()
                case .recheck: t.recheck()
                case .reannounce: t.reannounce()
                case .sequential: t.sequential = value
                case .firstLast: t.firstLast = value
                case .superSeed: t.superSeeding = value
                case .seed: t.manualSeed = true; t.resume()
                case .remove, .removeWithFiles:
                    t.pause()
                    torrents.removeAll { $0 === t }
                    if action == .removeWithFiles, let storage = t.storage { disk.queue.async { storage.trashFiles() } }
                    if let directory {
                        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id + ".json"))
                        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id + ".torrent"))
                    }
                    log(action == .removeWithFiles ? "removed with its files" : "removed", t)
                    continue
                case .queueUp, .queueDown, .queueTop, .queueBottom:
                    var ordered = torrents.sorted { $0.queuePosition < $1.queuePosition }
                    guard let i = ordered.firstIndex(where: { $0 === t }) else { continue }
                    ordered.remove(at: i)
                    let to = switch action {
                    case .queueUp: max(0, i - 1)
                    case .queueDown: min(ordered.count, i + 1)
                    case .queueTop: 0
                    default: ordered.count
                    }
                    ordered.insert(t, at: to)
                    for (n, x) in ordered.enumerated() { x.queuePosition = n; x.dirty = true }
                }
                t.dirty = true
                save(t)
            }
            publish()
        }
    }

    func setLimits(_ id: String, download: Int?, upload: Int?) {
        engineQueue.async { [self] in
            guard let t = find(id) else { return }
            if let download { t.downloadLimit = max(0, download) }
            if let upload { t.uploadLimit = max(0, upload) }
            save(t)
        }
    }

    func setFilePriorities(_ id: String, _ changes: [Int: Int]) {
        engineQueue.async { [self] in
            guard let t = find(id) else { return }
            for (i, p) in changes where i < t.filePriority.count { t.filePriority[i] = max(0, min(p, 3)) }
            t.updatePriorities()
            save(t)
        }
    }

    func stream(_ id: String, file: Int) {
        engineQueue.async { [self] in find(id)?.stream(file: file) }
    }

    func addTrackers(_ id: String, _ urls: [String]) {
        engineQueue.async { [self] in
            guard let t = find(id) else { return }
            t.setTrackers(urls.filter(TorrentSource.isTracker).map { [$0] })
            save(t)
        }
    }

    func removeTracker(_ id: String, _ url: String) {
        engineQueue.async { [self] in
            guard let t = find(id) else { return }
            t.trackers.removeAll { $0.url == url }
            save(t)
        }
    }

    func addPeer(_ id: String, _ addr: String) {
        engineQueue.async { [self] in
            guard let t = find(id), let a = PeerAddr(addr) else { return }
            t.addCandidates([a], source: "Manual")
        }
    }

    func move(_ id: String, to url: URL, done: @escaping (String?) -> Void) {
        engineQueue.async { [self] in
            guard let t = find(id) else { return }
            t.move(to: url) { error in
                self.save(t)
                DispatchQueue.main.async { done(error) }
            }
        }
    }

    func rename(_ id: String, file: Int?, to name: String, done: @escaping (String?) -> Void) {
        engineQueue.async { [self] in
            guard let t = find(id) else { return }
            t.rename(file: file, to: name) { error in
                self.save(t)
                DispatchQueue.main.async { done(error) }
            }
        }
    }

    /// The .torrent for a torrent we know the info of (Export .torrent, Copy as file).
    func torrentFile(_ id: String, done: @escaping (Data?, String) -> Void) {
        engineQueue.async { [self] in
            let t = find(id)
            let data = t?.info?.torrentFile(trackers: Dictionary(grouping: t!.trackers, by: \.tier).sorted { $0.key < $1.key }.map { $0.value.map(\.url) }, webSeeds: t!.webSeeds.map(\.url))
            let name = t?.name ?? id
            DispatchQueue.main.async { done(data, name) }
        }
    }

    func updateSettings(_ changes: [String: Any]) {
        engineQueue.async { [self] in
            let old = settings
            settings.apply(changes)
            applySettings(old: old)
            notifySettings()
        }
    }

    private func notifySettings() {
        let d = settings.dict
        DispatchQueue.main.async { self.onSettingsChanged?(d) }
    }

    /// Puts settings into effect without a relaunch.
    private func applySettings(old: TorrentSettings?) {
        downLimiter.limit = settings.downloadLimit
        upLimiter.limit = settings.uploadLimit
        disk.budget = max(8, settings.diskCacheMB) << 20
        for dht in dhts { dht.enabled = settings.dht && !settings.proxyOnly }
        let proxy = settings.proxyTrackers ? NetParams.proxy(settings) : nil
        if old == nil || old!.proxyType != settings.proxyType || old!.proxyHost != settings.proxyHost || old!.proxyPort != settings.proxyPort
            || old!.proxyUser != settings.proxyUser || old!.proxyPassword != settings.proxyPassword || old!.proxyTrackers != settings.proxyTrackers {
            TrackerClient.session = TrackerClient.makeSession(proxy: proxy)
            webSession = TrackerClient.makeSession(proxy: proxy)
        }
        if old == nil || old!.ipFilterPath != settings.ipFilterPath || old!.ipFilterEnabled != settings.ipFilterEnabled {
            let path = settings.ipFilterPath, on = settings.ipFilterEnabled
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let text = on && !path.isEmpty ? (try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8))
                    ?? (try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .isoLatin1)) : nil
                let filter = IPFilter(text: text ?? "")
                engineQueue.async {
                    self?.ipFilter = filter
                    if on { self?.log("IP filter: \(filter.count) ranges", nil) }
                }
            }
        }
        guard let old, started else { return }
        for t in torrents { t.dirty = true }
        if old.port != settings.port || old.tcp != settings.tcp || old.bindInterface != settings.bindInterface || old.randomPort != settings.randomPort {
            restartSockets()
            return
        }
        if old.lsd != settings.lsd || old.proxyOnly != settings.proxyOnly {
            if settings.lsd, !settings.proxyOnly { startLSD() } else { lsd?.close(); lsd = nil }
        }
        if old.portMapping != settings.portMapping {
            if settings.portMapping { startPortMapping() } else { portMapper?.removeAll(); portMapper = nil }
        }
        for dht in dhts where settings.dht && !old.dht { dht.bootstrap() }
    }

    private func restartSockets() {
        for t in torrents where t.isRunning { t.stop(announce: false) }
        stopNetwork()
        startNetwork()
        for t in torrents { t.reannounce() }
    }

    private func stopNetwork() {
        guard started else { return }
        listener?.cancel()
        listener = nil
        udp4?.close(); udp6?.close()
        udp4 = nil; udp6 = nil; utp4 = nil; utp6 = nil
        saveState()
        dhts = []
        lsd?.close()
        lsd = nil
        portMapper?.removeAll()
        portMapper = nil
        started = false
        tickTimer?.cancel()
        tickTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    func currentSettings(_ done: @escaping ([String: Any]) -> Void) {
        engineQueue.async { let d = self.settings.dict; DispatchQueue.main.async { done(d) } }
    }

    func detail(_ id: String, done: @escaping ([String: Any]?) -> Void) {
        engineQueue.async { [self] in
            let d = find(id)?.detail()
            DispatchQueue.main.async { done(d) }
        }
    }

    // MARK: Saving

    private var stateFile: URL { (directory ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent("session.json") }

    func save(_ t: Torrent) {
        guard let directory else { return }
        t.dirty = false
        let id = t.infoHash.tHex
        let resume = t.resumeData()
        let file = t.info?.torrentFile()
        disk.queue.async {
            if let file {
                let url = directory.appendingPathComponent(id + ".torrent")
                // Rewritten only when it gains something (v2 piece layers fetched later).
                let existing = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? -1
                if existing != file.count { try? file.write(to: url, options: .atomic) }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: resume) else { return }
            // The last good copy stays as a backup, in case this write is cut short.
            let url = directory.appendingPathComponent(id + ".json")
            let backup = directory.appendingPathComponent(id + ".json.bak")
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.copyItem(at: url, to: backup)
            }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func saveState() {
        guard directory != nil else { return }
        var state: [String: Any] = ["stats": ["down": allTime.down + down.total, "up": allTime.up + up.total]]
        for dht in dhts {
            let key = dht.v6 ? "dht6" : "dht"
            state[key + "ID"] = dht.nodeID.tHex
            state[key + "Nodes"] = dht.savedNodes.base64EncodedString()
        }
        if let data = try? JSONSerialization.data(withJSONObject: state) { try? data.write(to: stateFile, options: .atomic) }
    }

    /// At quit: write everything to disk and tell trackers we're gone. Blocks briefly.
    func shutdown() {
        engineQueue.sync {
            for t in torrents where t.isRunning { t.stop(announce: true) }
            // Buffered blocks reach the files first, so the saved sizes and dates match them.
            disk.queue.sync {}
            for t in torrents { save(t) }
            saveState()
            portMapper?.removeAll()
        }
        disk.queue.sync {}
    }

    private func loadAll() {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let names = Set(files.map(\.lastPathComponent))
        for file in files where file.pathExtension == "json" && file.lastPathComponent != "session.json" {
            // A damaged file falls back to its backup.
            let parse = { (url: URL) in (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
            guard let d = parse(file) ?? (names.contains(file.lastPathComponent + ".bak") ? parse(file.appendingPathExtension("bak")) : nil),
                  let hashHex = d["hash"] as? String, let hash = Data(tHex: hashHex), hash.count == 20 else {
                log("couldn’t read saved torrent \(file.lastPathComponent)", nil)
                continue
            }
            var source = TorrentSource(infoHash: hash, infoHashV2: (d["hashV2"] as? String).flatMap { Data(tHex: $0) }, name: d["name"] as? String ?? hashHex)
            if let raw = try? Data(contentsOf: directory.appendingPathComponent(hashHex + ".torrent")), let loaded = try? TorrentSource.load(torrent: raw) { source.info = loaded.info }
            var tiers: [Int: [String]] = [:]
            for row in d["trackers"] as? [[String]] ?? [] where row.count == 2 { tiers[Int(row[1]) ?? 0, default: []].append(row[0]) }
            source.trackers = tiers.keys.sorted().map { tiers[$0]! }
            source.webSeeds = d["webSeeds"] as? [String] ?? []
            source.httpSeeds = d["httpSeeds"] as? [String] ?? []
            source.peers = d["peers"] as? [String] ?? []
            let path = (d["path"] as? String).map { URL(fileURLWithPath: $0) } ?? defaultSavePath
            let t = Torrent(session: self, source: source, savePath: path, paused: d["paused"] as? Bool ?? false)
            if let name = d["name"] as? String { t.name = name }
            t.addedAt = Date(timeIntervalSince1970: d["added"] as? Double ?? Date().timeIntervalSince1970)
            t.completedAt = (d["completed"] as? Double).map { Date(timeIntervalSince1970: $0) }
            t.sequential = d["sequential"] as? Bool ?? false
            t.downloadedTotal = (d["downloaded"] as? NSNumber)?.int64Value ?? 0
            t.uploadedTotal = (d["uploaded"] as? NSNumber)?.int64Value ?? 0
            t.activeSeconds = d["active"] as? Int ?? 0
            t.seedingSeconds = d["seeding"] as? Int ?? 0
            t.manualSeed = d["manualSeed"] as? Bool ?? false
            t.queuePosition = d["queue"] as? Int ?? torrents.count
            t.restoreExtras(d)
            let needsCheck = t.restore(
                info: source.info, have: (d["have"] as? String).flatMap { Data(base64Encoded: $0) },
                priorities: d["priorities"] as? [Int] ?? [], partials: d["partials"] as? [String: [Int]] ?? [:],
                stamps: d["stamps"] as? [[Double]] ?? [], renamed: d["renamed"] as? [String: [String]] ?? [:],
                rootName: d["rootName"] as? String
            )
            t.firstLast = d["firstLast"] as? Bool ?? false
            torrents.append(t)
            if needsCheck { t.recheck() }
        }
        torrents.sort { $0.queuePosition < $1.queuePosition }
    }
}
