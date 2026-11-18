import Foundation

/// Downloads whole pieces over HTTP(S) from a web seed: GetRight-style URLs (BEP 19), where
/// files are fetched by range, or Hoffman-style seeds (BEP 17), which serve pieces directly.
final class WebSeed {
    let url: String
    let hoffman: Bool
    var status = "Idle"
    var failures = 0
    var retryAt = Date()
    var downloaded: Int64 = 0
    private(set) var busy = false
    private var task: URLSessionDataTask?

    init(url: String, hoffman: Bool) {
        self.url = url
        self.hoffman = hoffman
    }

    func cancel() { task?.cancel(); task = nil; busy = false }

    /// Fetches piece `piece`, calling back on the engine queue with its data or nil.
    func fetch(_ piece: Int, info: TorrentInfo, session: URLSession, done: @escaping (Data?) -> Void) {
        busy = true
        status = "Downloading"
        let start = Int64(piece) * Int64(info.pieceLength)
        let length = info.pieceSize(piece)
        if hoffman {
            guard var parts = URLComponents(string: url) else { finish(nil, done); return }
            let hash = info.infoHash.map { String(format: "%%%02X", $0) }.joined()
            parts.percentEncodedQuery = (parts.percentEncodedQuery.map { $0 + "&" } ?? "") + "info_hash=\(hash)&piece=\(piece)&ranges=0-\(length - 1)"
            guard let u = parts.url else { finish(nil, done); return }
            get(URLRequest(url: u), session: session, expect: length) { [weak self] data in self?.finish(data, done) }
            return
        }
        // GetRight: one ranged request per file the piece touches, joined.
        var spans: [(URL?, Int64, Int)] = []
        var at = start
        let end = start + Int64(length)
        for (i, f) in info.files.enumerated() where f.length > 0 && f.offset < end && f.offset + f.length > at {
            let from = max(at, f.offset), to = min(end, f.offset + f.length)
            spans.append((f.isPad ? nil : fileURL(i, info), from - f.offset, Int(to - from)))
            at = to
        }
        var pieces = [Data?](repeating: nil, count: spans.count)
        let group = DispatchGroup()
        var failed = false
        for (n, span) in spans.enumerated() {
            guard let u = span.0 else { pieces[n] = Data(count: span.2); continue }
            var request = URLRequest(url: u, timeoutInterval: 30)
            request.setValue("bytes=\(span.1)-\(span.1 + Int64(span.2) - 1)", forHTTPHeaderField: "Range")
            group.enter()
            get(request, session: session, expect: span.2) { data in
                if let data { pieces[n] = data } else { failed = true }
                group.leave()
            }
        }
        group.notify(queue: engineQueue) { [weak self] in
            self?.finish(failed ? nil : pieces.reduce(into: Data()) { $0.append($1 ?? Data()) }, done)
        }
    }

    private func fileURL(_ i: Int, _ info: TorrentInfo) -> URL? {
        var base = url
        if info.isSingleFile {
            if base.hasSuffix("/") { base += info.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? info.name }
            return URL(string: base)
        }
        if !base.hasSuffix("/") { base += "/" }
        let path = ([info.name] + info.files[i].path).map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }.joined(separator: "/")
        return URL(string: base + path)
    }

    private func get(_ request: URLRequest, session: URLSession, expect: Int, done: @escaping (Data?) -> Void) {
        let task = session.dataTask(with: request) { [weak self] data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            engineQueue.async {
                if code == 503, let data, let wait = Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) {
                    self?.retryAt = Date().addingTimeInterval(TimeInterval(min(wait, 3600)))
                }
                done((code == 200 || code == 206) && data?.count == expect ? data : nil)
            }
        }
        self.task = task
        task.resume()
    }

    private func finish(_ data: Data?, _ done: (Data?) -> Void) {
        busy = false
        task = nil
        if let data {
            failures = 0
            downloaded += Int64(data.count)
            status = "Working"
        } else {
            failures += 1
            status = "Not working"
            retryAt = max(retryAt, Date().addingTimeInterval(min(30 * pow(2, Double(failures)), 1800)))
        }
        done(data)
    }
}
