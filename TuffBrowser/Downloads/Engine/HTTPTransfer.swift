import Foundation

/// A speed limit shared by many downloads: a token bucket topped up by elapsed time, so no
/// timer is needed. Thread-safe.
final class SharedLimiter {
    private let lock = NSLock()
    private var tokens = 0.0
    private var last = Date()
    private var _limit = 0
    /// Bytes per second; 0 means no limit.
    var limit: Int {
        get { lock.lock(); defer { lock.unlock() }; return _limit }
        set { lock.lock(); _limit = max(0, newValue); tokens = min(tokens, Double(_limit)); lock.unlock() }
    }

    /// Takes `n` bytes; returns how long to hold off before reading more.
    func take(_ n: Int) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard _limit > 0 else { return 0 }
        let now = Date()
        tokens = min(Double(_limit), tokens + now.timeIntervalSince(last) * Double(_limit))
        last = now
        tokens -= Double(n)
        return tokens >= 0 ? 0 : -tokens / Double(_limit)
    }
}

/// A fast HTTP(S) download. Several connections each fetch a byte range; whenever one
/// finishes, the biggest range still left is split in two and the free connection takes the
/// back half (dynamic segmentation), so every connection stays busy to the end. Each
/// connection has a URLSession of its own, so they really are separate TCP connections.
/// Pausing keeps every range's progress, which survives relaunches; on resume, `If-Range`
/// makes sure the file on the server is still the same one.
final class HTTPTransfer: NSObject, URLSessionDataDelegate {
    struct Segment: Codable, Equatable {
        var start: Int64
        var pos: Int64
        var end: Int64  // exclusive; Int64.max while the size is unknown
        var done: Bool { pos >= end }
    }

    /// Everything needed to carry on later.
    struct State: Codable {
        var url: URL
        var total: Int64 = -1
        var segments: [Segment] = []
        var etag: String?
        var lastModified: String?
        var acceptsRanges = false
        var partPath: String?
        var destination: String?
        var headers: [String: String] = [:]
        var method = "GET"
    }

    enum Status: Equatable { case idle, running, paused, finished, failed(String) }

    private(set) var state: State
    private(set) var status = Status.idle
    var maxConnections: Int
    let limiter: SharedLimiter?
    /// The server's first answer arrived: say where the file goes (only asked when no
    /// destination is known yet). Called on the main thread; nil cancels.
    var decideDestination: ((HTTPURLResponse, String) -> URL?)?
    /// Progress and the end, on the main thread.
    var onProgress: ((Int64, Int64) -> Void)?
    var onFinish: ((Result<URL, Error>) -> Void)?

    private let queue = DispatchQueue(label: "tuff.http", qos: .userInitiated)
    private lazy var delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.underlyingQueue = queue
        return q
    }()

    private final class Worker {
        let session: URLSession
        let task: URLSessionDataTask
        var segment: Int
        var validated = false
        var finishedEarly = false
        /// The server refused one connection too many: not an error, just fewer connections.
        var refused = false
        init(session: URLSession, task: URLSessionDataTask, segment: Int) {
            self.session = session
            self.task = task
            self.segment = segment
        }
    }

    private var workers: [Int: Worker] = [:]  // by task identifier ^ session hash
    private var retries: [Int: Int] = [:]  // by segment
    private var fd: Int32 = -1
    private var lastReport = Date.distantPast
    private var deciding = false
    private static let minSplit: Int64 = 1 << 20

    init(state: State, connections: Int, limiter: SharedLimiter?) {
        self.state = state
        maxConnections = max(1, min(connections, 32))
        self.limiter = limiter
    }

    var received: Int64 { state.segments.reduce(0) { $0 + ($1.pos - $1.start) } }
    var activeConnections: Int { queue.sync { workers.count } }
    /// Each range as (start, downloaded so far, end), for the downloads page.
    var segmentMap: [[Int64]] { queue.sync { state.segments.map { [$0.start, $0.pos, $0.end == .max ? -1 : $0.end] } } }

    func snapshot() -> State { queue.sync { state } }

    // MARK: Control

    func start() {
        queue.async { [self] in
            guard status != .running, status != .finished else { return }
            status = .running
            if state.segments.isEmpty { state.segments = [Segment(start: 0, pos: 0, end: .max)] }
            if let path = state.partPath, !openFile(path) { return }
            // Resume what's unfinished, then fill the free connections by splitting.
            for i in state.segments.indices where !state.segments[i].done && workers.count < maxConnections {
                if state.segments[i].end == .max || state.acceptsRanges || state.segments[i].pos == 0 { spawn(i) }
            }
            if state.acceptsRanges { fillConnections() }
            if state.segments.allSatisfy(\.done), state.total >= 0 { complete() }
        }
    }

    func pause() {
        queue.sync {
            guard status == .running else { return }
            status = .paused
            stopWorkers()
            if fd >= 0 { fsync(fd); close(fd); fd = -1 }
        }
    }

    /// Stops for good and removes the partial file.
    func cancel() {
        queue.sync {
            status = .failed("Cancelled")
            stopWorkers()
            if fd >= 0 { close(fd); fd = -1 }
            if let path = state.partPath { unlink(path) }
        }
    }

    private func stopWorkers() {
        for (_, w) in workers {
            w.task.cancel()
            w.session.invalidateAndCancel()
        }
        workers.removeAll()
    }

    // MARK: Workers

    private func key(_ task: URLSessionTask, _ session: URLSession) -> Int { task.taskIdentifier ^ ObjectIdentifier(session).hashValue }

    private func spawn(_ index: Int) {
        let segment = state.segments[index]
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        var request = URLRequest(url: state.url)
        request.httpMethod = state.method
        for (k, v) in state.headers { request.setValue(v, forHTTPHeaderField: k) }
        // Compressed bodies can't be fetched by range.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if segment.pos > 0 || segment.end != .max {
            request.setValue("bytes=\(segment.pos)-" + (segment.end == .max ? "" : String(segment.end - 1)), forHTTPHeaderField: "Range")
            if let validator = state.etag.flatMap({ $0.hasPrefix("W/") ? nil : $0 }) ?? state.lastModified {
                request.setValue(validator, forHTTPHeaderField: "If-Range")
            }
        } else if state.acceptsRanges || state.segments.count == 1 {
            // Ask for a range even from the start: a 206 tells us the server can split.
            request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: request)
        workers[key(task, session)] = Worker(session: session, task: task, segment: index)
        task.resume()
    }

    /// Gives every idle connection the back half of the biggest range still downloading.
    private func fillConnections() {
        guard state.acceptsRanges, state.total > 0 else { return }
        while workers.count < maxConnections {
            let busy = Set(workers.values.map(\.segment))
            // A range nobody is working on (after a pause) first, then splitting.
            if let idle = state.segments.indices.first(where: { !state.segments[$0].done && !busy.contains($0) }) {
                spawn(idle)
                continue
            }
            guard let biggest = state.segments.indices.filter({ !state.segments[$0].done }).max(by: {
                state.segments[$0].end - state.segments[$0].pos < state.segments[$1].end - state.segments[$1].pos
            }) else { return }
            let s = state.segments[biggest]
            let left = s.end - s.pos
            guard left >= Self.minSplit * 2 else { return }
            let mid = s.pos + left / 2
            state.segments[biggest].end = mid
            state.segments.append(Segment(start: mid, pos: mid, end: s.end))
            spawn(state.segments.count - 1)
        }
    }

    private func openFile(_ path: String) -> Bool {
        if fd >= 0 { return true }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fd = open(path, O_RDWR | O_CREAT, 0o644)
        if fd < 0 { fail("Couldn’t write the file: \(String(cString: strerror(errno)))"); return false }
        return true
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard status == .running, let worker = workers[key(dataTask, session)], let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        let seg = state.segments[worker.segment]
        switch http.statusCode {
        case 206:
            guard let range = http.value(forHTTPHeaderField: "Content-Range"), let parsed = Self.contentRange(range), parsed.start == seg.pos else {
                completionHandler(.cancel)
                return
            }
            if parsed.total > 0 {
                if state.total > 0, parsed.total != state.total { restartFromScratch(); completionHandler(.cancel); return }
                state.total = parsed.total
                if state.segments[worker.segment].end == .max { state.segments[worker.segment].end = parsed.total }
            }
            state.acceptsRanges = true
        case 200:
            // No ranges (or the file changed): only a fresh single stream works.
            if seg.pos > 0 || state.segments.count > 1 {
                if state.acceptsRanges && state.segments.contains(where: { $0.pos > $0.start }) {
                    restartFromScratch()
                    completionHandler(.cancel)
                    return
                }
            }
            state.acceptsRanges = false
            state.total = http.expectedContentLength
            state.segments = [Segment(start: 0, pos: 0, end: state.total >= 0 ? state.total : .max)]
            worker.segment = 0
            for (k, w) in workers where w !== worker { w.task.cancel(); w.session.invalidateAndCancel(); workers[k] = nil }
        case 416 where state.total > 0 && seg.pos >= state.total:
            state.segments[worker.segment].pos = seg.end
            completionHandler(.cancel)
            return
        default:
            completionHandler(.cancel)
            let code = http.statusCode
            // Busy or limiting connections (429, 503, 5xx): keep the connections it accepted,
            // or, for the first one, try again shortly.
            if code == 429 || code == 408 || code >= 500 {
                if workers.values.contains(where: { $0 !== worker && $0.validated }) {
                    worker.refused = true
                    maxConnections = max(1, workers.values.filter(\.validated).count)
                }
                return
            }
            fail(code == 404 ? "The file isn’t there any more (404)" : code == 403 ? "The server refused it (403)" : "The server said \(code)")
            return
        }
        if state.etag == nil { state.etag = http.value(forHTTPHeaderField: "ETag") }
        if state.lastModified == nil { state.lastModified = http.value(forHTTPHeaderField: "Last-Modified") }
        worker.validated = true

        guard state.partPath == nil else {
            completionHandler(.allow)
            if state.acceptsRanges { fillConnections() }
            return
        }
        // First answer of a download added by address: decide its name and place now.
        guard !deciding else { completionHandler(.cancel); return }
        deciding = true
        let suggested = Self.filename(from: http, url: state.url)
        DispatchQueue.main.async { [self] in
            let destination = decideDestination?(http, suggested)
            queue.async { [self] in
                deciding = false
                guard let destination, status == .running else { completionHandler(.cancel); if destination == nil { fail("Cancelled") }; return }
                state.destination = destination.path
                state.partPath = destination.path + ".tuffpart"
                guard openFile(state.partPath!) else { completionHandler(.cancel); return }
                completionHandler(.allow)
                if state.acceptsRanges { fillConnections() }
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard status == .running, let worker = workers[key(dataTask, session)], worker.validated, fd >= 0 else { return }
        var seg = state.segments[worker.segment]
        let room = seg.end == .max ? Int64(data.count) : max(0, seg.end - seg.pos)
        let n = Int(min(Int64(data.count), room))
        if n > 0 {
            let written = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, n, off_t(seg.pos)) }
            if written != n { fail("Couldn’t write the file: \(String(cString: strerror(errno)))"); return }
            seg.pos += Int64(n)
            state.segments[worker.segment] = seg
        }
        // Another connection took the rest of this range: this one is done.
        if seg.end != .max, seg.pos >= seg.end {
            worker.finishedEarly = true
            dataTask.cancel()
        }
        if let limiter {
            let wait = limiter.take(n)
            if wait > 0.01 {
                dataTask.suspend()
                queue.asyncAfter(deadline: .now() + min(wait, 2)) { if dataTask.state == .suspended { dataTask.resume() } }
            }
        }
        report()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let k = key(task, session)
        guard let worker = workers.removeValue(forKey: k) else { return }
        session.finishTasksAndInvalidate()
        guard status == .running else { return }
        if worker.refused { fillConnections(); return }
        let index = worker.segment
        var seg = state.segments[index]
        if error == nil || worker.finishedEarly {
            // A stream of unknown length ends when the server stops sending.
            if seg.end == .max, error == nil { seg.end = seg.pos; state.segments[index] = seg; state.total = seg.pos }
            if seg.done || worker.finishedEarly {
                retries[index] = nil
                if state.segments.allSatisfy(\.done) { complete(); return }
                fillConnections()
                return
            }
        }
        // Failed or cut short: try that range again, backing off, a few times.
        let tries = (retries[index] ?? 0) + 1
        retries[index] = tries
        guard tries <= 8 else {
            if workers.isEmpty { fail((error as NSError?)?.localizedDescription ?? "The connection dropped") }
            return
        }
        if !state.acceptsRanges && seg.pos > 0 {
            // Can't carry on mid-file without ranges.
            fail("The server can’t resume this download")
            return
        }
        queue.asyncAfter(deadline: .now() + min(pow(2, Double(tries - 1)), 15)) { [self] in
            guard status == .running, !state.segments[index].done, !workers.values.contains(where: { $0.segment == index }) else { return }
            spawn(index)
        }
    }

    private func restartFromScratch() {
        for (_, w) in workers { w.task.cancel(); w.session.invalidateAndCancel() }
        workers.removeAll()
        state.segments = [Segment(start: 0, pos: 0, end: .max)]
        state.total = -1
        state.etag = nil
        state.lastModified = nil
        if fd >= 0 { ftruncate(fd, 0) }
        spawn(0)
    }

    private func report(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) > 0.25 else { return }
        lastReport = now
        let got = received, total = state.total
        DispatchQueue.main.async { self.onProgress?(got, total) }
    }

    private func complete() {
        guard status == .running else { return }
        status = .finished
        stopWorkers()
        if fd >= 0 {
            if state.total >= 0 { ftruncate(fd, off_t(state.total)) }
            fsync(fd)
            close(fd)
            fd = -1
        }
        report(force: true)
        guard let part = state.partPath, let destination = state.destination else { fail("Nowhere to save"); return }
        let to = URL(fileURLWithPath: destination)
        do {
            if FileManager.default.fileExists(atPath: destination) {
                _ = try FileManager.default.replaceItemAt(to, withItemAt: URL(fileURLWithPath: part))
            } else {
                try FileManager.default.moveItem(atPath: part, toPath: destination)
            }
            DispatchQueue.main.async { self.onFinish?(.success(to)) }
        } catch {
            status = .failed(error.localizedDescription)
            DispatchQueue.main.async { self.onFinish?(.failure(error)) }
        }
    }

    private func fail(_ why: String) {
        guard status == .running else { return }
        status = .failed(why)
        stopWorkers()
        if fd >= 0 { fsync(fd); close(fd); fd = -1 }
        let error = TorrentError.invalid(why)
        DispatchQueue.main.async { self.onFinish?(.failure(error)) }
    }

    // MARK: Helpers

    static func contentRange(_ header: String) -> (start: Int64, end: Int64, total: Int64)? {
        // "bytes 100-199/1000" or "bytes 100-199/*"
        let parts = header.replacingOccurrences(of: "bytes", with: "").trimmingCharacters(in: .whitespaces).split(separator: "/")
        guard parts.count == 2 else { return nil }
        let range = parts[0].split(separator: "-")
        guard range.count == 2, let a = Int64(range[0]), let b = Int64(range[1]) else { return nil }
        return (a, b, Int64(parts[1]) ?? -1)
    }

    /// The name the server suggests (Content-Disposition), else the address's last part.
    static func filename(from response: HTTPURLResponse, url: URL) -> String {
        if let disposition = response.value(forHTTPHeaderField: "Content-Disposition") {
            for part in disposition.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if part.lowercased().hasPrefix("filename*="), let value = part.split(separator: "'", maxSplits: 2).last?.removingPercentEncoding, !value.isEmpty { return value }
            }
            for part in disposition.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where part.lowercased().hasPrefix("filename=") {
                let value = part.dropFirst(9).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                if !value.isEmpty { return value }
            }
        }
        if let suggested = response.suggestedFilename, !suggested.isEmpty, suggested != "Unknown" { return suggested }
        let last = url.lastPathComponent
        return last.isEmpty || last == "/" ? (url.host ?? "Download") : last
    }
}
