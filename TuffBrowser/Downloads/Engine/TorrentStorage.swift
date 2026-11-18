import Foundation

/// Reads and writes a torrent's pieces across its files. Thread-safe: the disk queue writes
/// while hashing threads read. Files are created as data arrives (sparse on APFS), or fully
/// allocated up front when asked. Data that belongs to deselected files goes to a hidden
/// `.parts` file instead, so unwanted files never appear on disk.
final class TorrentStorage {
    let info: TorrentInfo
    private(set) var base: URL
    private let lock = NSRecursiveLock()
    private var fds: [Int: (fd: Int32, writable: Bool)] = [:]
    private var partsFD: Int32 = -1

    /// Renamed files (relative path under the content folder) and a renamed top level.
    var renamed: [Int: [String]] = [:]
    var rootName: String?
    /// Deselected files, whose data goes to the parts file (when `usePartsFile`).
    var skipped = Set<Int>()
    var usePartsFile = true
    /// Files not finished yet carry this suffix (".part") until they are, when it is set.
    var suffix = ""
    var incomplete = Set<Int>()
    var preallocate = false

    init(info: TorrentInfo, base: URL) {
        self.info = info
        self.base = base
    }

    deinit { closeAll() }

    /// Changes settings (skipped files, suffixes…) safely while other threads read and write.
    func locked(_ body: (TorrentStorage) -> Void) {
        lock.lock()
        body(self)
        lock.unlock()
    }

    var contentURL: URL { base.appendingPathComponent(rootName ?? info.name, isDirectory: !info.isSingleFile) }
    var partsURL: URL { base.appendingPathComponent(".\(info.infoHash.tHex).parts") }

    func url(ofFile i: Int, final: Bool = false) -> URL {
        var url = info.isSingleFile ? contentURL : (renamed[i] ?? info.files[i].path).reduce(contentURL) { $0.appendingPathComponent($1) }
        if !final, !suffix.isEmpty, incomplete.contains(i) { url = url.appendingPathExtension(String(suffix.dropFirst())) }
        return url
    }

    func closeAll() {
        lock.lock()
        closeAllLocked()
        lock.unlock()
    }

    private func closeAllLocked() {
        for (_, entry) in fds { close(entry.fd) }
        fds.removeAll()
        if partsFD >= 0 { close(partsFD); partsFD = -1 }
    }

    private func fd(_ i: Int, write: Bool) throws -> Int32? {
        if let entry = fds[i], entry.writable || !write { return entry.fd }
        if let entry = fds.removeValue(forKey: i) { close(entry.fd) }
        if fds.count >= 128 { closeAllLocked() }
        let url = url(ofFile: i)
        var fd: Int32
        if write {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existed = FileManager.default.fileExists(atPath: url.path)
            fd = open(url.path, O_RDWR | O_CREAT, 0o644)
            if fd >= 0, !existed, preallocate { Self.allocate(fd, info.files[i].length) }
        } else {
            fd = open(url.path, O_RDONLY)
            if fd < 0, errno == ENOENT { return nil }
        }
        guard fd >= 0 else { throw Self.error("open \(url.lastPathComponent)") }
        fds[i] = (fd, write)
        return fd
    }

    private func partsFile(write: Bool) throws -> Int32? {
        if partsFD >= 0 { return partsFD }
        guard write || FileManager.default.fileExists(atPath: partsURL.path) else { return nil }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        partsFD = open(partsURL.path, O_RDWR | O_CREAT, 0o644)
        guard partsFD >= 0 else { throw Self.error("open the parts file") }
        return partsFD
    }

    private static func allocate(_ fd: Int32, _ length: Int64) {
        guard length > 0 else { return }
        var store = fstore_t(fst_flags: UInt32(F_ALLOCATEALL), fst_posmode: F_PEOFPOSMODE, fst_offset: 0, fst_length: off_t(length), fst_bytesalloc: 0)
        _ = fcntl(fd, F_PREALLOCATE, &store)
        ftruncate(fd, off_t(length))
    }

    static func error(_ what: String) -> TorrentError {
        let code = errno
        let why = code == ENOSPC ? "The disk is full" : code == EACCES || code == EPERM ? "Tuff isn’t allowed to write there" : String(cString: strerror(code))
        return TorrentError.invalid("Couldn’t \(what): \(why)")
    }

    /// Calls `body(file, offsetInFile, length, offsetInBuffer)` for each file a byte range touches.
    private func spans(_ offset: Int64, _ length: Int, _ body: (Int, Int64, Int, Int) throws -> Void) rethrows {
        var lo = 0, hi = info.files.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if info.files[mid].offset <= offset { lo = mid } else { hi = mid - 1 }
        }
        var done = 0
        var i = lo
        while done < length, i < info.files.count {
            let f = info.files[i]
            let at = offset + Int64(done)
            if f.length > 0, at < f.offset + f.length {
                let n = Int(min(Int64(length - done), f.offset + f.length - at))
                try body(i, at - f.offset, n, done)
                done += n
            }
            i += 1
        }
    }

    /// Where a span of file `i` lives: the file itself, or the parts file for deselected files.
    private func target(_ i: Int, _ at: Int64, write: Bool) throws -> (Int32, Int64)? {
        if info.files[i].isPad || info.files[i].symlink != nil { return nil }
        if usePartsFile, skipped.contains(i) {
            return try partsFile(write: write).map { ($0, info.files[i].offset + at) }
        }
        return try fd(i, write: write).map { ($0, at) }
    }

    func write(_ data: Data, at offset: Int64) throws {
        lock.lock()
        defer { lock.unlock() }
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            try spans(offset, data.count) { file, at, n, from in
                guard let (fd, pos) = try target(file, at, write: true) else { return }
                var written = 0
                while written < n {
                    let r = pwrite(fd, buf.baseAddress! + from + written, n - written, off_t(pos) + off_t(written))
                    if r < 0 { if errno == EINTR { continue }; throw Self.error("write") }
                    written += r
                }
            }
        }
    }

    /// Missing files read as zeros (so their pieces just fail the hash check).
    func read(at offset: Int64, length: Int) throws -> Data {
        var out = Data(count: length)
        lock.lock()
        defer { lock.unlock() }
        try out.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            try spans(offset, length) { file, at, n, into in
                guard let (fd, pos) = try target(file, at, write: false) else { return }
                var got = 0
                while got < n {
                    let r = pread(fd, buf.baseAddress! + into + got, n - got, off_t(pos) + off_t(got))
                    if r < 0 { if errno == EINTR { continue }; throw Self.error("read") }
                    if r == 0 { break }
                    got += r
                }
            }
        }
        return out
    }

    func readPiece(_ piece: Int) -> Data? {
        try? read(at: Int64(piece) * Int64(info.pieceLength), length: info.pieceSize(piece))
    }

    func verify(_ piece: Int) -> Bool {
        guard let data = readPiece(piece) else { return false }
        return info.verify(piece, data)
    }

    /// Whether any of the torrent's files are on disk (to decide if adding it needs a check).
    var anyFileExists: Bool {
        info.files.indices.contains { !info.files[$0].isPad && (FileManager.default.fileExists(atPath: url(ofFile: $0).path) || FileManager.default.fileExists(atPath: url(ofFile: $0, final: true).path)) }
    }

    /// Size and modification time of each file, for a quick check on the next launch.
    func stamps() -> [[Double]] {
        info.files.indices.map { i in
            guard let a = try? FileManager.default.attributesOfItem(atPath: url(ofFile: i).path) else { return [-1, 0] }
            return [Double((a[.size] as? NSNumber)?.int64Value ?? -1), (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0]
        }
    }

    // MARK: Changing files

    func move(to newBase: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        closeAllLocked()
        let fm = FileManager.default
        try fm.createDirectory(at: newBase, withIntermediateDirectories: true)
        let from = contentURL
        let to = newBase.appendingPathComponent(rootName ?? info.name, isDirectory: !info.isSingleFile)
        if fm.fileExists(atPath: from.path) { try fm.moveItem(at: from, to: to) }
        if !suffix.isEmpty, info.isSingleFile, fm.fileExists(atPath: url(ofFile: 0).path) {
            try fm.moveItem(at: url(ofFile: 0), to: to.appendingPathExtension(String(suffix.dropFirst())))
        }
        if fm.fileExists(atPath: partsURL.path) { try? fm.moveItem(at: partsURL, to: newBase.appendingPathComponent(partsURL.lastPathComponent)) }
        base = newBase
    }

    func rename(file: Int?, to name: String) throws {
        lock.lock()
        defer { lock.unlock() }
        closeAllLocked()
        let fm = FileManager.default
        if let file, !info.isSingleFile {
            let old = url(ofFile: file)
            var parts = renamed[file] ?? info.files[file].path
            parts[parts.count - 1] = name
            renamed[file] = parts
            if fm.fileExists(atPath: old.path) { try fm.moveItem(at: old, to: url(ofFile: file)) }
        } else {
            let oldContent = contentURL, oldFile = url(ofFile: 0)
            rootName = name
            if info.isSingleFile {
                if fm.fileExists(atPath: oldFile.path) { try fm.moveItem(at: oldFile, to: url(ofFile: 0)) }
            } else if fm.fileExists(atPath: oldContent.path) {
                try fm.moveItem(at: oldContent, to: contentURL)
            }
        }
    }

    /// A deselected file was picked again: bring its pieces that are already here out of the parts file.
    func unskip(_ i: Int, have: (Int) -> Bool) {
        guard skipped.remove(i) != nil, usePartsFile, let range = info.pieces(ofFile: i) else { return }
        let f = info.files[i]
        for p in range where have(p) {
            let start = max(Int64(p) * Int64(info.pieceLength), f.offset)
            let end = min(Int64(p) * Int64(info.pieceLength) + Int64(info.pieceSize(p)), f.offset + f.length)
            skipped.insert(i)
            let data = try? read(at: start, length: Int(end - start))
            skipped.remove(i)
            if let data { try? write(data, at: start) }
        }
    }

    /// A file has all its pieces: drop the ".part" suffix and apply its attributes.
    func finish(file i: Int) {
        lock.lock()
        defer { lock.unlock() }
        let f = info.files[i]
        if incomplete.remove(i) != nil, !suffix.isEmpty {
            if let entry = fds.removeValue(forKey: i) { fsync(entry.fd); close(entry.fd) }
            let from = url(ofFile: i).appendingPathExtension(String(suffix.dropFirst()))
            try? FileManager.default.moveItem(at: from, to: url(ofFile: i))
        }
        var target = url(ofFile: i)
        if f.executable { chmod(target.path, 0o755) }
        if f.hidden {
            var values = URLResourceValues()
            values.isHidden = true
            try? target.setResourceValues(values)
        }
        if let link = f.symlink, !link.isEmpty, !FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let destination = link.reduce(contentURL) { $0.appendingPathComponent($1) }
            try? FileManager.default.createSymbolicLink(at: target, withDestinationURL: destination)
        }
    }

    func trashFiles() {
        closeAll()
        try? FileManager.default.trashItem(at: contentURL, resultingItemURL: nil)
        if info.isSingleFile, !suffix.isEmpty { try? FileManager.default.trashItem(at: url(ofFile: 0), resultingItemURL: nil) }
        try? FileManager.default.removeItem(at: partsURL)
    }

    /// Makes sure what's written is on disk (when a torrent finishes, stops or Tuff quits).
    func flush() {
        lock.lock()
        for (_, entry) in fds where entry.writable { fsync(entry.fd) }
        closeAllLocked()
        lock.unlock()
    }
}

/// The disk layer: buffers incoming blocks in memory so a finished piece is hashed straight
/// from memory and written in one go, hashes on several cores, keeps recently uploaded pieces
/// in a read cache, and stays inside a memory budget by writing early when it must.
final class DiskIO {
    let queue = DispatchQueue(label: "tuff.torrent.disk", qos: .utility)
    let hashQueue = DispatchQueue(label: "tuff.torrent.hash", qos: .utility, attributes: .concurrent)
    var budget = 64 << 20

    private struct Key: Hashable { let storage: ObjectIdentifier; let piece: Int }
    private struct Buffer { var blocks: [Int: Data] = [:]; var bytes = 0; var spilled = false; var touched = Date() }
    private var buffers: [Key: Buffer] = [:]
    private var buffered = 0
    private var durable: [Key: Set<Int>] = [:]
    private var cache: [Key: Data] = [:]
    private var cacheOrder: [Key] = []
    private var cached = 0

    struct Check {
        let ok: Bool
        /// SHA-1 of each 16 KiB block, when asked for (smart ban) or when the piece failed.
        let blockHashes: [Data]?
    }

    private static func blockHashes(_ data: Data) -> [Data] {
        stride(from: 0, to: data.count, by: 16384).map { sha1(data.subdata(in: data.startIndex + $0..<data.startIndex + min($0 + 16384, data.count))) }
    }

    /// Stores a block. Once the piece's last block is in, checks it, or reports the disk error.
    /// Calls back on the engine queue.
    func write(_ storage: TorrentStorage, piece: Int, offset: Int, data: Data, complete: Bool, wantHashes: Bool = false, done: @escaping (Result<Check, Error>) -> Void) {
        queue.async { [self] in
            let key = Key(storage: ObjectIdentifier(storage), piece: piece)
            var buffer = buffers[key] ?? Buffer()
            if buffer.blocks[offset] == nil {
                buffer.blocks[offset] = data
                buffer.bytes += data.count
                buffered += data.count
            }
            buffer.touched = Date()
            buffers[key] = buffer
            guard complete else {
                if buffered > budget { spill(storage) }
                return
            }
            buffers[key] = nil
            buffered -= buffer.bytes
            let pieceStart = Int64(piece) * Int64(storage.info.pieceLength)
            // Some blocks already went to disk (memory pressure, or a piece resumed after a
            // relaunch): finish writing and check from disk.
            if buffer.spilled || buffer.bytes != storage.info.pieceSize(piece) {
                do {
                    try flush(buffer, storage, pieceStart)
                    durable[key] = nil
                } catch { engineQueue.async { done(.failure(error)) }; return }
                hashQueue.async {
                    let whole = storage.readPiece(piece) ?? Data()
                    let ok = storage.info.verify(piece, whole)
                    let hashes = !ok || wantHashes ? Self.blockHashes(whole) : nil
                    engineQueue.async { done(.success(Check(ok: ok, blockHashes: hashes))) }
                }
                return
            }
            var whole = Data(capacity: storage.info.pieceSize(piece))
            durable[key] = nil
            for o in buffer.blocks.keys.sorted() { whole.append(buffer.blocks[o]!) }
            hashQueue.async { [self] in
                let ok = storage.info.verify(piece, whole)
                let hashes = !ok || wantHashes ? Self.blockHashes(whole) : nil
                guard ok else { engineQueue.async { done(.success(Check(ok: false, blockHashes: hashes))) }; return }
                queue.async {
                    do { try storage.write(whole, at: pieceStart) } catch { engineQueue.async { done(.failure(error)) }; return }
                    engineQueue.async { done(.success(Check(ok: true, blockHashes: hashes))) }
                }
            }
        }
    }

    private func flush(_ buffer: Buffer, _ storage: TorrentStorage, _ pieceStart: Int64) throws {
        let piece = Int(pieceStart / Int64(storage.info.pieceLength))
        let key = Key(storage: ObjectIdentifier(storage), piece: piece)
        for (offset, block) in buffer.blocks {
            try storage.write(block, at: pieceStart + Int64(offset))
            durable[key, default: []].insert(offset / Peer.blockSize)
        }
    }

    func markRestored(_ storage: TorrentStorage, piece: Int, blocks: [Int]) {
        queue.async {
            self.durable[Key(storage: ObjectIdentifier(storage), piece: piece), default: []].formUnion(blocks)
        }
    }

    func durableBlocks(_ storage: TorrentStorage, candidates: [Int: [Int]]) -> [Int: [Int]] {
        queue.sync {
            candidates.reduce(into: [Int: [Int]]()) { result, pair in
                let written = durable[Key(storage: ObjectIdentifier(storage), piece: pair.key)] ?? []
                let blocks = pair.value.filter { written.contains($0) }.sorted()
                if !blocks.isEmpty { result[pair.key] = blocks }
            }
        }
    }

    /// Over budget: write the stalest partial pieces to disk to free memory.
    private func spill(_ storage: TorrentStorage) {
        for (key, var buffer) in buffers.sorted(by: { $0.value.touched < $1.value.touched }) {
            guard buffered > budget * 3 / 4 else { break }
            guard key.storage == ObjectIdentifier(storage) else { continue }
            let start = Int64(key.piece) * Int64(storage.info.pieceLength)
            try? flush(buffer, storage, start)
            buffered -= buffer.bytes
            buffer.blocks.removeAll()
            buffer.bytes = 0
            buffer.spilled = true
            buffers[key] = buffer
        }
    }

    /// Reads a block for uploading, through the read cache. Calls back on the engine queue.
    func read(_ storage: TorrentStorage, piece: Int, offset: Int, length: Int, done: @escaping (Data?) -> Void) {
        queue.async { [self] in
            let key = Key(storage: ObjectIdentifier(storage), piece: piece)
            var whole = cache[key]
            if whole == nil, storage.info.pieceSize(piece) <= 4 << 20 {
                whole = storage.readPiece(piece)
                if let whole {
                    cache[key] = whole
                    cacheOrder.append(key)
                    cached += whole.count
                    while cached > budget / 2, !cacheOrder.isEmpty {
                        let old = cacheOrder.removeFirst()
                        cached -= cache.removeValue(forKey: old)?.count ?? 0
                    }
                }
            }
            let out: Data?
            if let whole, offset + length <= whole.count {
                out = whole.subdata(in: offset..<offset + length)
            } else {
                out = try? storage.read(at: Int64(piece) * Int64(storage.info.pieceLength) + Int64(offset), length: length)
            }
            engineQueue.async { done(out) }
        }
    }

    /// Forgets a torrent's buffered blocks and cached pieces (stopped or removed).
    func drop(_ storage: TorrentStorage) {
        queue.async { [self] in
            let id = ObjectIdentifier(storage)
            for (k, b) in buffers where k.storage == id {
                if b.spilled || b.bytes > 0 { try? flush(b, storage, Int64(k.piece) * Int64(storage.info.pieceLength)) }
                buffered -= b.bytes
                buffers[k] = nil
            }
            for k in cacheOrder where k.storage == id { cached -= cache.removeValue(forKey: k)?.count ?? 0 }
            cacheOrder.removeAll { $0.storage == id }
        }
    }

    /// Hashes every piece on disk, a batch at a time across cores. `progress` and `done` run on the engine queue.
    func check(_ storage: TorrentStorage, cancelled: @escaping () -> Bool, progress: @escaping (Double) -> Void, done: @escaping (Bitfield?) -> Void) {
        hashQueue.async {
            let count = storage.info.pieceCount
            var found = Bitfield(count: count)
            let batch = 256
            var start = 0
            while start < count {
                if cancelled() { engineQueue.async { done(nil) }; return }
                let end = min(count, start + batch)
                var results = [Bool](repeating: false, count: end - start)
                results.withUnsafeMutableBufferPointer { out in
                    DispatchQueue.concurrentPerform(iterations: end - start) { out[$0] = storage.verify(start + $0) }
                }
                for (i, ok) in results.enumerated() where ok { found[start + i] = true }
                start = end
                let fraction = Double(start) / Double(count)
                engineQueue.async { progress(fraction) }
            }
            storage.closeAll()
            engineQueue.async { done(found) }
        }
    }
}
