import Foundation

/// Everything about how the torrent client behaves. Kept as a flat key → value table so the
/// downloads page can show and change any of it, and so saved settings survive new fields.
struct TorrentSettings {
    // Connections
    var port = 0
    var randomPort = false
    var maxPeers = 500
    var maxPeersPerTorrent = 80
    var maxHalfOpen = 40
    var uploadSlots = 4
    var utp = true
    var tcp = true
    /// 0 off, 1 preferred (try it, accept plaintext), 2 required.
    var encryption = 1
    var bindInterface = ""
    // Discovery
    var dht = true
    var pex = true
    var lsd = true
    var portMapping = true
    var announceToAllTrackers = false
    var announceToAllTiers = true
    // Speed (bytes per second, 0 = no limit)
    var downloadLimit = 0
    var uploadLimit = 0
    var lanUnlimited = true
    var limitUTPOverhead = false
    // Queue
    var maxActiveDownloads = 5
    var maxActiveSeeds = 5
    // Seeding: off by default, so a finished torrent stops.
    var seedAfterDownload = false
    /// Off by default too: nothing is uploaded at all unless asked for. (Peers that reward
    /// sharing may send a little slower; seeds don't care.)
    var uploadWhileDownloading = false
    var ratioLimit = 0.0
    var seedTimeLimit = 0
    var inactiveSeedLimit = 0
    /// 0 fastest upload, 1 round robin, 2 anti-leech.
    var seedStrategy = 0
    // Disk
    var preallocate = false
    var partFile = true
    var incompleteSuffix = false
    var diskCacheMB = 64
    // Proxy: 0 none, 1 SOCKS5, 2 HTTP CONNECT
    var proxyType = 0
    var proxyHost = ""
    var proxyPort = 1080
    var proxyUser = ""
    var proxyPassword = ""
    var proxyPeers = true
    var proxyTrackers = true
    var proxyOnly = false
    // Filtering
    var ipFilterPath = ""
    var ipFilterEnabled = false

    private static let ints: [String: WritableKeyPath<TorrentSettings, Int>] = [
        "port": \.port, "maxPeers": \.maxPeers, "maxPeersPerTorrent": \.maxPeersPerTorrent, "maxHalfOpen": \.maxHalfOpen,
        "uploadSlots": \.uploadSlots, "encryption": \.encryption, "downloadLimit": \.downloadLimit, "uploadLimit": \.uploadLimit,
        "maxActiveDownloads": \.maxActiveDownloads, "maxActiveSeeds": \.maxActiveSeeds, "seedTimeLimit": \.seedTimeLimit,
        "inactiveSeedLimit": \.inactiveSeedLimit, "seedStrategy": \.seedStrategy, "diskCacheMB": \.diskCacheMB,
        "proxyType": \.proxyType, "proxyPort": \.proxyPort,
    ]
    private static let bools: [String: WritableKeyPath<TorrentSettings, Bool>] = [
        "randomPort": \.randomPort, "utp": \.utp, "tcp": \.tcp, "dht": \.dht, "pex": \.pex, "lsd": \.lsd,
        "portMapping": \.portMapping, "announceToAllTrackers": \.announceToAllTrackers, "announceToAllTiers": \.announceToAllTiers,
        "lanUnlimited": \.lanUnlimited, "limitUTPOverhead": \.limitUTPOverhead, "seedAfterDownload": \.seedAfterDownload, "uploadWhileDownloading": \.uploadWhileDownloading,
        "preallocate": \.preallocate, "partFile": \.partFile, "incompleteSuffix": \.incompleteSuffix, "proxyPeers": \.proxyPeers,
        "proxyTrackers": \.proxyTrackers, "proxyOnly": \.proxyOnly, "ipFilterEnabled": \.ipFilterEnabled,
    ]
    private static let strings: [String: WritableKeyPath<TorrentSettings, String>] = [
        "bindInterface": \.bindInterface, "proxyHost": \.proxyHost, "proxyUser": \.proxyUser,
        "proxyPassword": \.proxyPassword, "ipFilterPath": \.ipFilterPath,
    ]

    var dict: [String: Any] {
        var d: [String: Any] = ["ratioLimit": ratioLimit]
        for (k, p) in Self.ints { d[k] = self[keyPath: p] }
        for (k, p) in Self.bools { d[k] = self[keyPath: p] }
        for (k, p) in Self.strings { d[k] = self[keyPath: p] }
        return d
    }

    mutating func set(_ key: String, _ value: Any) {
        if let p = Self.ints[key], let v = (value as? NSNumber)?.intValue ?? (value as? String).flatMap({ Int($0) }) { self[keyPath: p] = max(0, v) }
        if let p = Self.bools[key], let v = value as? Bool ?? (value as? NSNumber)?.boolValue { self[keyPath: p] = v }
        if let p = Self.strings[key], let v = value as? String { self[keyPath: p] = v }
        if key == "ratioLimit", let v = (value as? NSNumber)?.doubleValue { ratioLimit = max(0, v) }
    }

    mutating func apply(_ d: [String: Any]) { for (k, v) in d { set(k, v) } }
}
