import CryptoKit
import Foundation

enum TorrentError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let why) = self { return why }; return nil }
}

func sha1(_ data: Data) -> Data { Data(Insecure.SHA1.hash(data: data)) }
func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

/// A file inside a torrent, at its place in the torrent's byte stream.
struct TorrentFile {
    let path: [String]
    let length: Int64
    let offset: Int64
    /// BEP 47 padding (or v2 alignment): never written to disk, reads as zeros.
    let isPad: Bool
    var executable = false
    var hidden = false
    /// BEP 47 symlink: made once the torrent finishes, pointing inside the torrent.
    var symlink: [String]?
    /// BEP 52: the file's merkle root (v2 and hybrid torrents).
    var root: Data?
}

/// BEP 52 merkle trees: SHA-256 over 16 KiB blocks, padded with zero leaves to a power of two.
enum Merkle {
    static let blockSize = 16 * 1024
    static let zero = Data(count: 32)

    static func pair(_ a: Data, _ b: Data) -> Data {
        var h = SHA256()
        h.update(data: a)
        h.update(data: b)
        return Data(h.finalize())
    }

    /// The root of `2^levels` zero leaves.
    static func zeroRoot(levels: Int) -> Data {
        var node = zero
        for _ in 0..<levels { node = pair(node, node) }
        return node
    }

    static func root(_ nodes: [Data], width: Int, pad: Data) -> Data {
        var layer = nodes
        if layer.count < width { layer += [Data](repeating: pad, count: width - layer.count) }
        var padNode = pad
        while layer.count > 1 {
            if layer.count % 2 == 1 { layer.append(padNode) }
            layer = stride(from: 0, to: layer.count, by: 2).map { pair(layer[$0], layer[$0 + 1]) }
            padNode = pair(padNode, padNode)
        }
        return layer.first ?? pad
    }

    static func nextPow2(_ n: Int) -> Int { n <= 1 ? 1 : 1 << (Int.bitWidth - (n - 1).leadingZeroBitCount) }
    static func log2(_ n: Int) -> Int { Int.bitWidth - 1 - n.leadingZeroBitCount }

    static func leaves(_ data: Data) -> [Data] {
        stride(from: 0, to: data.count, by: blockSize).map { sha256(data.subdata(in: data.startIndex + $0..<data.startIndex + min($0 + blockSize, data.count))) }
    }
}

/// A torrent's info dictionary: what the info hash covers.
final class TorrentInfo {
    static let maximumTotalLength: Int64 = 1 << 50
    static let maximumPieceCount = 1_000_000
    static let maximumFileCount = 100_000
    private static let maximumMetadataBytes = 128 * 1024 * 1024

    private static func adding(_ length: Int64, to offset: Int64) throws -> Int64 {
        let (total, overflow) = offset.addingReportingOverflow(length)
        guard !overflow, total <= maximumTotalLength else { throw TorrentError.invalid("The torrent is too large") }
        return total
    }

    private static func pieces(for total: Int64, pieceLength: Int64) throws -> Int64 {
        guard total > 0 else { throw TorrentError.invalid("The torrent is empty") }
        let count = (total - 1) / pieceLength + 1
        guard count <= Int64(maximumPieceCount) else { throw TorrentError.invalid("The torrent has too many pieces") }
        return count
    }

    /// The hash peers, trackers and the DHT know the torrent by: SHA-1 for v1 and hybrid,
    /// SHA-256 cut to 20 bytes for v2-only torrents.
    let infoHash: Data
    let infoHashV1: Data?
    let infoHashV2: Data?
    let raw: Data
    let name: String
    let pieceLength: Int
    let hashes: Data
    let files: [TorrentFile]
    let totalLength: Int64
    let isPrivate: Bool
    let pieceCount: Int
    let isSingleFile: Bool
    var hasV1: Bool { infoHashV1 != nil }
    var hasV2: Bool { infoHashV2 != nil }
    /// BEP 52 piece layers, by file root: each piece's subtree root, end to end. From the
    /// .torrent file or fetched from peers (magnets).
    var pieceLayers: [Data: Data] = [:]
    var comment: String?
    var createdBy: String?
    var creationDate: Date?

    init(raw: Data) throws {
        guard raw.count <= Self.maximumMetadataBytes else { throw TorrentError.invalid("The torrent’s metadata is too large") }
        guard let info = try? BDecoder.decode(raw).0, info.dict != nil else { throw TorrentError.invalid("The torrent’s info isn’t readable") }
        self.raw = raw
        guard let pieceLength = info["piece length"]?.int, pieceLength >= 1024, pieceLength <= 1 << 28 else {
            throw TorrentError.invalid("The torrent has no piece length")
        }
        self.pieceLength = Int(pieceLength)
        let v2 = info["meta version"]?.int == 2 && info["file tree"]?.dict != nil
        if v2 {
            guard pieceLength >= Int64(Merkle.blockSize), pieceLength & (pieceLength - 1) == 0 else {
                throw TorrentError.invalid("The v2 torrent has an invalid piece length")
            }
        }
        let v1Hashes = info["pieces"]?.data
        guard v2 || v1Hashes != nil else { throw TorrentError.invalid("The torrent has no pieces") }
        infoHashV1 = v1Hashes != nil ? sha1(raw) : nil
        infoHashV2 = v2 ? sha256(raw) : nil
        infoHash = infoHashV1 ?? infoHashV2!.prefix(20)
        hashes = v1Hashes ?? Data()
        let rawName = (info["name.utf-8"] ?? info["name"])?.string ?? ""
        name = TorrentInfo.clean(rawName).isEmpty ? infoHash.tHex : TorrentInfo.clean(rawName)
        isPrivate = info["private"]?.int == 1

        // v2 file tree: path → root, in tree order (keys sorted bytewise).
        var tree: [(path: [String], length: Int64, root: Data?, attr: String)] = []
        if v2, let ft = info["file tree"] {
            func walk(_ node: BValue, _ path: [String], depth: Int) throws {
                guard depth < 64, let d = node.dict else { throw TorrentError.invalid("Bad file tree") }
                if let leaf = d[Data()], let length = leaf["length"]?.int, length >= 0 {
                    guard tree.count < Self.maximumFileCount else { throw TorrentError.invalid("Too many files") }
                    tree.append((path, length, leaf["pieces root"]?.data, leaf["attr"]?.string ?? ""))
                    return
                }
                for key in d.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                    let part = TorrentInfo.clean(String(data: key, encoding: .utf8) ?? "")
                    guard !part.isEmpty, let child = d[key] else { throw TorrentError.invalid("A file in the torrent has no name") }
                    try walk(child, path + [part], depth: depth + 1)
                }
            }
            try walk(ft, [], depth: 0)
        }

        var files: [TorrentFile] = []
        var offset: Int64 = 0
        if v1Hashes != nil {
            if let list = info["files"]?.list {
                guard list.count <= Self.maximumFileCount else { throw TorrentError.invalid("Too many files") }
                isSingleFile = false
                for entry in list {
                    guard let length = entry["length"]?.int, length >= 0 else { throw TorrentError.invalid("A file in the torrent has no size") }
                    let parts = ((entry["path.utf-8"] ?? entry["path"])?.list ?? []).compactMap { $0.string }.map(TorrentInfo.clean).filter { !$0.isEmpty }
                    let attr = entry["attr"]?.string ?? ""
                    let pad = attr.contains("p") || (parts.first == ".pad" && parts.count == 2)
                    if !pad, parts.isEmpty { throw TorrentError.invalid("A file in the torrent has no name") }
                    var file = TorrentFile(path: parts, length: length, offset: offset, isPad: pad)
                    file.executable = attr.contains("x")
                    file.hidden = attr.contains("h")
                    if attr.contains("l") { file.symlink = (entry["symlink path"]?.list ?? []).compactMap { $0.string }.map(TorrentInfo.clean).filter { !$0.isEmpty } }
                    files.append(file)
                    offset = try Self.adding(length, to: offset)
                }
            } else if let length = info["length"]?.int, length >= 0 {
                isSingleFile = true
                files = [TorrentFile(path: [name], length: length, offset: 0, isPad: false)]
                offset = try Self.adding(length, to: 0)
            } else {
                throw TorrentError.invalid("The torrent lists no files")
            }
            // Hybrid: give each real file its v2 root (same order, pads aside).
            if !tree.isEmpty {
                var roots = tree.makeIterator()
                for i in files.indices where !files[i].isPad {
                    guard let entry = roots.next() else { break }
                    if entry.length == files[i].length { files[i].root = entry.root }
                }
            }
            let expected = try Self.pieces(for: offset, pieceLength: pieceLength)
            guard Int64(hashes.count / 20) == expected, hashes.count % 20 == 0 else { throw TorrentError.invalid("The torrent’s pieces don’t match its files") }
            pieceCount = Int(expected)
        } else {
            // v2 only: every file starts on a piece boundary; the gaps act as padding.
            isSingleFile = tree.count == 1 && tree[0].path.count == 1 && info["file tree"]?.dict?.count == 1
            for (i, entry) in tree.enumerated() {
                guard files.count < Self.maximumFileCount * 2 else { throw TorrentError.invalid("Too many files") }
                var file = TorrentFile(path: isSingleFile ? [name] : entry.path, length: entry.length, offset: offset, isPad: false)
                file.root = entry.root
                file.executable = entry.attr.contains("x")
                file.hidden = entry.attr.contains("h")
                if entry.length > 0, entry.root?.count != 32 { throw TorrentError.invalid("A file in the torrent has no hash") }
                files.append(file)
                offset = try Self.adding(entry.length, to: offset)
                let gap = (pieceLength - offset % pieceLength) % pieceLength
                if gap > 0, i < tree.count - 1 {
                    files.append(TorrentFile(path: [".pad", String(gap)], length: gap, offset: offset, isPad: true))
                    offset = try Self.adding(gap, to: offset)
                }
            }
            pieceCount = Int(try Self.pieces(for: offset, pieceLength: pieceLength))
        }
        self.files = files
        totalLength = offset
    }

    /// A safe single path component: no separators, no "." / "..", no control characters.
    static func clean(_ s: String) -> String {
        var out = String(s.unicodeScalars.filter { $0.value >= 32 && $0 != "/" && $0 != "\\" && $0 != ":" }.map(Character.init))
        out = out.trimmingCharacters(in: .whitespaces)
        if out.allSatisfy({ $0 == "." }) { return "" }
        // Keep within the 255-byte name limit, cutting on a character boundary.
        while out.utf8.count > 240 { out.removeLast() }
        return out
    }

    func pieceSize(_ index: Int) -> Int {
        index == pieceCount - 1 ? Int(totalLength - Int64(index) * Int64(pieceLength)) : pieceLength
    }

    func hash(_ index: Int) -> Data { hashes.subdata(in: index * 20..<index * 20 + 20) }

    /// Pieces that hold some of file `i` (nil for a zero-length file).
    func pieces(ofFile i: Int) -> ClosedRange<Int>? {
        let f = files[i]
        guard f.length > 0 else { return nil }
        return Int(f.offset / Int64(pieceLength))...Int((f.offset + f.length - 1) / Int64(pieceLength))
    }

    /// The real file a piece starts in (v2 pieces never span files).
    func file(atPiece piece: Int) -> Int? {
        let at = Int64(piece) * Int64(pieceLength)
        return files.indices.first { !files[$0].isPad && files[$0].offset <= at && at < files[$0].offset + files[$0].length }
    }

    /// Files whose piece layer we still need (v2 files bigger than one piece).
    var missingLayers: [Int] {
        guard hasV2 else { return [] }
        return files.indices.filter { files[$0].length > Int64(pieceLength) && files[$0].root != nil && pieceLayers[files[$0].root!] == nil }
    }

    /// Checks a piece layer against its file's root and keeps it.
    @discardableResult
    func accept(layer: Data, forFile i: Int) -> Bool {
        guard files.indices.contains(i) else { return false }
        let f = files[i]
        guard let root = f.root, f.length > 0 else { return false }
        let count64 = (f.length - 1) / Int64(pieceLength) + 1
        guard count64 <= Int64(Self.maximumPieceCount) else { return false }
        let count = Int(count64)
        let (byteCount, overflow) = count.multipliedReportingOverflow(by: 32)
        guard !overflow, layer.count == byteCount else { return false }
        let nodes = stride(from: 0, to: layer.count, by: 32).map { layer.subdata(in: $0..<$0 + 32) }
        let pad = Merkle.zeroRoot(levels: Merkle.log2(pieceLength / Merkle.blockSize))
        guard Merkle.root(nodes, width: Merkle.nextPow2(count), pad: pad) == root else { return false }
        pieceLayers[root] = layer
        return true
    }

    /// Checks a whole piece, by SHA-1 (v1), by its merkle subtree (v2), or both (hybrid).
    func verify(_ piece: Int, _ data: Data) -> Bool {
        if hasV1, sha1(data) != hash(piece) { return false }
        guard hasV2, let fi = file(atPiece: piece), let root = files[fi].root else { return hasV1 }
        let f = files[fi]
        let start = Int64(piece) * Int64(pieceLength)
        let length = Int(min(Int64(pieceLength), f.offset + f.length - start))
        let leaves = Merkle.leaves(data.prefix(length))
        if f.length <= Int64(pieceLength) {
            return Merkle.root(leaves, width: Merkle.nextPow2(leaves.count), pad: Merkle.zero) == root
        }
        guard let layer = pieceLayers[root] else { return hasV1 }
        let local = Int((start - f.offset) / Int64(pieceLength))
        guard (local + 1) * 32 <= layer.count else { return false }
        let expected = layer.subdata(in: local * 32..<local * 32 + 32)
        return Merkle.root(leaves, width: pieceLength / Merkle.blockSize, pad: Merkle.zero) == expected
    }

    /// The .torrent file for this info (with piece layers), for saving and "Export .torrent".
    func torrentFile(trackers: [[String]] = [], webSeeds: [String] = []) -> Data {
        var d = Data("d".utf8)
        func key(_ k: String) { BValue.s(k).encode(into: &d) }
        if let first = trackers.first?.first { key("announce"); BValue.s(first).encode(into: &d) }
        if trackers.count > 1 || (trackers.first?.count ?? 0) > 1 {
            key("announce-list")
            BValue.list(trackers.map { .list($0.map(BValue.s)) }).encode(into: &d)
        }
        if let comment { key("comment"); BValue.s(comment).encode(into: &d) }
        key("created by"); BValue.s(createdBy ?? "Tuff").encode(into: &d)
        if let creationDate { key("creation date"); BValue.int(Int64(creationDate.timeIntervalSince1970)).encode(into: &d) }
        key("info")
        d.append(raw)
        if !pieceLayers.isEmpty {
            key("piece layers")
            BValue.dict(pieceLayers.mapValues(BValue.bytes)).encode(into: &d)
        }
        if !webSeeds.isEmpty { key("url-list"); BValue.list(webSeeds.map(BValue.s)).encode(into: &d) }
        d.append(UInt8(ascii: "e"))
        return d
    }
}

/// Something to download: a .torrent file or a magnet link.
struct TorrentSource {
    var infoHash: Data
    /// The full SHA-256 info hash, for v2 magnets (metadata is checked against it).
    var infoHashV2: Data?
    var info: TorrentInfo?
    var name: String
    var trackers: [[String]] = []
    var webSeeds: [String] = []
    var httpSeeds: [String] = []
    var peers: [String] = []
    /// `xs`: where to fetch the .torrent itself.
    var exactSource: String?
    /// `so`: the only files to download, by index.
    var selectOnly: [Int]?

    static func load(torrent data: Data) throws -> TorrentSource {
        guard let (root, _, range) = try? BDecoder.decode(data, allowTrailing: true), let range else {
            throw TorrentError.invalid("This isn’t a torrent file")
        }
        let info = try TorrentInfo(raw: data.subdata(in: range))
        info.comment = root["comment"]?.string
        info.createdBy = root["created by"]?.string
        info.creationDate = root["creation date"]?.int.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        if let layers = root["piece layers"]?.dict {
            for (i, f) in info.files.enumerated() where f.root != nil { if let layer = layers[f.root!]?.data { info.accept(layer: layer, forFile: i) } }
        }
        var source = TorrentSource(infoHash: info.infoHash, infoHashV2: info.infoHashV2, info: info, name: info.name)
        if let tiers = root["announce-list"]?.list {
            source.trackers = tiers.compactMap { $0.list?.compactMap { $0.string }.filter(Self.isTracker) }.filter { !$0.isEmpty }
        }
        if source.trackers.isEmpty, let one = root["announce"]?.string, Self.isTracker(one) { source.trackers = [[one]] }
        func urls(_ v: BValue?) -> [String] { (v?.list?.compactMap { $0.string } ?? v?.string.map { [$0] } ?? []).filter { $0.lowercased().hasPrefix("http") } }
        source.webSeeds = urls(root["url-list"])
        source.httpSeeds = urls(root["httpseeds"])
        return source
    }

    static func load(magnet: String) throws -> TorrentSource {
        guard let parts = URLComponents(string: magnet), parts.scheme?.lowercased() == "magnet" else {
            throw TorrentError.invalid("This isn’t a magnet link")
        }
        var v1: Data?, v2: Data?
        var trackers: [String] = [], seeds: [String] = [], peers: [String] = []
        var name: String?, exact: String?, select: [Int]?
        for item in parts.queryItems ?? [] {
            guard let value = item.value else { continue }
            let key = item.name.lowercased()
            switch key.split(separator: ".").first.map(String.init) ?? key {  // xt.1, tr.2 …
            case "xt":
                let lower = value.lowercased()
                if lower.hasPrefix("urn:btih:") {
                    let hash = String(value.dropFirst(9))
                    v1 = hash.count == 40 ? Data(tHex: hash) : (hash.count == 32 ? base32(hash) : nil)
                } else if lower.hasPrefix("urn:btmh:1220"), value.count == 13 + 64 {
                    v2 = Data(tHex: String(value.dropFirst(13)))
                }
            case "tr": if isTracker(value) { trackers.append(value) }
            case "ws": if value.lowercased().hasPrefix("http") { seeds.append(value) }
            case "xs", "as": if value.lowercased().hasPrefix("http") { exact = value }
            case "x":
                if key == "x.pe" { peers.append(value) }
            case "dn": name = value
            case "so":
                select = value.split(separator: ",").flatMap { part -> [Int] in
                    let ends = part.split(separator: "-").compactMap { Int($0) }
                    if ends.count == 2, ends[0] <= ends[1], ends[1] - ends[0] < 100_000 { return Array(ends[0]...ends[1]) }
                    return ends.count == 1 ? ends : []
                }
            default: break
            }
        }
        guard let hash = v1 ?? v2?.prefix(20) else {
            throw TorrentError.invalid("The magnet link has no info hash")
        }
        var source = TorrentSource(infoHash: Data(hash), infoHashV2: v2, name: Data(hash).tHex)
        if let name, !TorrentInfo.clean(name).isEmpty { source.name = TorrentInfo.clean(name) }
        source.trackers = trackers.map { [$0] }
        source.webSeeds = seeds
        source.peers = peers
        source.exactSource = exact
        source.selectOnly = select
        return source
    }

    static func isTracker(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("udp://")
    }

    private static func base32(_ s: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var out = Data()
        for c in s.uppercased() {
            guard let v = alphabet.firstIndex(of: c) else { return nil }
            value = (value << 5 | v) & 0xffff
            bits += 5
            if bits >= 8 { out.append(UInt8(value >> (bits - 8) & 0xff)); bits -= 8 }
        }
        return out.count == 20 ? out : nil
    }

    /// A magnet link for sharing.
    static func magnet(hash: Data, v2: Data?, name: String, trackers: [String]) -> String {
        var parts = URLComponents()
        parts.scheme = "magnet"
        var items: [URLQueryItem] = []
        if hash.count == 20, v2 == nil || v2!.prefix(20) != hash { items.append(URLQueryItem(name: "xt", value: "urn:btih:" + hash.tHex)) }
        if let v2 { items.append(URLQueryItem(name: "xt", value: "urn:btmh:1220" + v2.tHex)) }
        items.append(URLQueryItem(name: "dn", value: name))
        parts.queryItems = items + trackers.map { URLQueryItem(name: "tr", value: $0) }
        return parts.string ?? "magnet:?xt=urn:btih:" + hash.tHex
    }
}
