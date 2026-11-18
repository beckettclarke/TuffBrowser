import Foundation

/// Makes a .torrent from a file or folder: v1, v2 or hybrid (BEP 3 / 52), with trackers,
/// web seeds, a comment, a source tag and the private flag.
struct TorrentCreator {
    enum Format: Int { case v1 = 1, v2 = 2, hybrid = 3 }

    var path: URL
    var format = Format.hybrid
    var pieceLength = 0  // 0: chosen from the size
    var isPrivate = false
    var trackers: [[String]] = []
    var webSeeds: [String] = []
    var comment = ""
    var source = ""

    /// Picks a piece size giving roughly 1,000–2,000 pieces, between 16 KiB and 16 MiB.
    static func autoPieceLength(total: Int64) -> Int {
        var size = 16 * 1024
        while size < 16 << 20, total / Int64(size) > 2000 { size *= 2 }
        return size
    }

    private struct Entry { let url: URL; let path: [String]; let length: Int64; let executable: Bool }

    /// Builds the torrent; `progress` gets 0…1, `cancelled` is polled. Runs on the calling thread.
    func create(progress: (Double) -> Void, cancelled: () -> Bool) throws -> Data {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path.path, isDirectory: &isDir) else { throw TorrentError.invalid("The file isn’t there") }
        var entries: [Entry] = []
        if isDir.boolValue {
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isHiddenKey]
            guard let walker = fm.enumerator(at: path, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { throw TorrentError.invalid("Couldn’t read the folder") }
            for case let url as URL in walker {
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true else { continue }
                // Relative to the folder, comparing resolved paths (/var vs /private/var).
                let root = path.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                let full = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                guard full.count > root.count, Array(full.prefix(root.count)) == root else { continue }
                let rel = Array(full.dropFirst(root.count))
                entries.append(Entry(url: url, path: rel, length: Int64(values.fileSize ?? 0), executable: fm.isExecutableFile(atPath: url.path)))
            }
            // v2 file trees and hybrid torrents need files in byte order of their paths.
            entries.sort { $0.path.joined(separator: "/").utf8.lexicographicallyPrecedes($1.path.joined(separator: "/").utf8) }
        } else {
            let size = (try fm.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.int64Value ?? 0
            entries = [Entry(url: path, path: [path.lastPathComponent], length: size, executable: false)]
        }
        let total = entries.reduce(0) { $0 + $1.length }
        guard total > 0 else { throw TorrentError.invalid("There’s nothing to share in it") }
        let pieceLength = self.pieceLength > 0 ? self.pieceLength : Self.autoPieceLength(total: total)
        let v1 = format != .v2, v2 = format != .v1
        let aligned = v2  // hybrid: pad files line every file up with a piece
        let leavesPerPiece = pieceLength / Merkle.blockSize

        var v1Hashes = Data()
        var current = Data()  // the v1 piece being filled
        var fileList: [BValue] = []
        var tree: [String: Any] = [:]
        var layers: [Data: Data] = [:]
        var done: Int64 = 0

        func addV1(_ data: Data) {
            var rest = data[...]
            while !rest.isEmpty {
                let take = min(pieceLength - current.count, rest.count)
                current.append(rest.prefix(take))
                rest = rest.dropFirst(take)
                if current.count == pieceLength { v1Hashes.append(sha1(current)); current.removeAll(keepingCapacity: true) }
            }
        }

        for (n, entry) in entries.enumerated() {
            guard let handle = FileHandle(forReadingAtPath: entry.url.path) else { throw TorrentError.invalid("Couldn’t read \(entry.url.lastPathComponent)") }
            defer { try? handle.close() }
            var pieceRoots: [Data] = []
            var leaves: [Data] = []
            var remaining = entry.length
            while remaining > 0 {
                if cancelled() { throw TorrentError.invalid("Cancelled") }
                let chunk = try handle.read(upToCount: Int(min(Int64(pieceLength), remaining))) ?? Data()
                guard !chunk.isEmpty else { throw TorrentError.invalid("\(entry.url.lastPathComponent) changed while reading") }
                remaining -= Int64(chunk.count)
                done += Int64(chunk.count)
                if v1 { addV1(chunk) }
                if v2 {
                    let l = Merkle.leaves(chunk)
                    leaves += l
                    pieceRoots.append(Merkle.root(l, width: leavesPerPiece, pad: Merkle.zero))
                }
                progress(Double(done) / Double(total))
            }
            var fileDict: [String: BValue] = ["length": .int(entry.length)]
            if v2, entry.length > 0 {
                let root: Data
                if entry.length <= Int64(pieceLength) {
                    root = Merkle.root(leaves, width: Merkle.nextPow2(leaves.count), pad: Merkle.zero)
                } else {
                    root = Merkle.root(pieceRoots, width: Merkle.nextPow2(pieceRoots.count), pad: Merkle.zeroRoot(levels: Merkle.log2(leavesPerPiece)))
                    layers[root] = pieceRoots.reduce(Data(), +)
                }
                fileDict["pieces root"] = .bytes(root)
                var node = tree
                insert(&node, entry.path, .d(fileDict))
                tree = node
            } else if v2 {
                var node = tree
                insert(&node, entry.path, .d(fileDict))
                tree = node
            }
            if v1 {
                var item: [String: BValue] = ["length": .int(entry.length), "path": .list(entry.path.map(BValue.s))]
                if entry.executable { item["attr"] = .s("x") }
                fileList.append(.d(item))
                let gap = (pieceLength - current.count) % pieceLength
                if aligned, n < entries.count - 1, gap > 0, !current.isEmpty {
                    fileList.append(.d(["length": .int(Int64(gap)), "path": .list([.s(".pad"), .s(String(gap))]), "attr": .s("p")]))
                    addV1(Data(count: gap))
                }
            }
        }
        if v1, !current.isEmpty { v1Hashes.append(sha1(current)) }

        var info: [String: BValue] = ["name": .s(isDir.boolValue ? path.lastPathComponent : entries[0].path[0]), "piece length": .int(Int64(pieceLength))]
        if v1 {
            info["pieces"] = .bytes(v1Hashes)
            if isDir.boolValue { info["files"] = .list(fileList) } else { info["length"] = .int(entries[0].length) }
        }
        if v2 {
            info["meta version"] = .int(2)
            info["file tree"] = Self.bencode(tree)
        }
        if isPrivate { info["private"] = .int(1) }
        if !source.isEmpty { info["source"] = .s(source) }
        let parsed = try TorrentInfo(raw: BValue.d(info).encoded)
        parsed.pieceLayers = layers
        parsed.comment = comment.isEmpty ? nil : comment
        parsed.createdBy = "Tuff"
        parsed.creationDate = Date()
        return parsed.torrentFile(trackers: trackers, webSeeds: webSeeds)
    }

    private func insert(_ node: inout [String: Any], _ path: [String], _ leaf: BValue) {
        guard let first = path.first else { return }
        if path.count == 1 { node[first] = ["": leaf] as [String: Any]; return }
        var child = node[first] as? [String: Any] ?? [:]
        insert(&child, Array(path.dropFirst()), leaf)
        node[first] = child
    }

    private static func bencode(_ node: [String: Any]) -> BValue {
        .d(node.mapValues { value in (value as? BValue) ?? bencode(value as? [String: Any] ?? [:]) })
    }
}
