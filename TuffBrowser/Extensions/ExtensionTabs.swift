import Foundation

/// Firefox tab extensions (`tabs.hide`, `tabs.show`, `tabs.moveInSuccession`) and
/// `cookies.getPartitionKey`.
final class ExtensionTabs {
    static let shared = ExtensionTabs()

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// extensionID -> tab UUIDs hidden by that extension, so unloading restores them.
    private var hiddenBy: [String: Set<UUID>] = [:]

    private var browser: BrowserState { .shared }

    // MARK: tabs.hide / tabs.show

    /// Hides the tabs at `indexes` that are eligible (never the active tab, pinned/favourite tabs,
    /// tabs sharing camera/mic, or the visible split partner). Returns the indexes actually hidden.
    func hide(indexes: [Int], extensionID: String) -> [Int] {
        let all = browser.allTabs
        var hiddenIndexes: [Int] = []
        var seen = Set<Int>()
        for index in indexes where seen.insert(index).inserted {
            guard all.indices.contains(index) else { continue }
            let tab = all[index]
            guard canHide(tab) else { continue }
            tab.isHidden = true
            hiddenBy[extensionID, default: []].insert(tab.id)
            hiddenIndexes.append(index)
        }
        return hiddenIndexes
    }

    /// Shows the tabs at `indexes`.
    func show(indexes: [Int]) {
        let all = browser.allTabs
        for index in indexes where all.indices.contains(index) {
            unhide(all[index])
        }
    }

    func unhide(_ tab: Tab) {
        if tab.isHidden { tab.isHidden = false }
        for key in hiddenBy.keys {
            hiddenBy[key]?.remove(tab.id)
        }
    }

    func hiddenFlags() -> [Bool] {
        browser.allTabs.map(\.isHidden)
    }

    func extensionUnloaded(_ extensionID: String) {
        guard let ids = hiddenBy.removeValue(forKey: extensionID), !ids.isEmpty else { return }
        let stillHeld = hiddenBy.values.reduce(into: Set<UUID>()) { $0.formUnion($1) }
        for tab in browser.allTabs where ids.contains(tab.id) && !stillHeld.contains(tab.id) {
            tab.isHidden = false
        }
    }

    private func canHide(_ tab: Tab) -> Bool {
        guard browser.section(of: tab) == .tabs else { return false }
        if browser.isOnScreen(tab) { return false }
        if tab.cameraInUse || tab.microphoneInUse { return false }
        return true
    }

    // MARK: tabs.moveInSuccession

    func moveInSuccession(tabIndexes: [Int], targetIndex: Int?, append: Bool, insert: Bool) throws {
        let all = browser.allTabs
        let tabs: [Tab] = try tabIndexes.map { index in
            guard all.indices.contains(index) else { throw Failure("Invalid tab id.") }
            return all[index]
        }
        let target: Tab?
        if let targetIndex {
            guard all.indices.contains(targetIndex) else { throw Failure("Invalid target tab id.") }
            target = all[targetIndex]
        } else {
            target = nil
        }
        Self.moveInSuccession(tabs: tabs, target: target, allTabs: all, append: append, insert: insert)
    }

    /// Firefox's `tabs.moveInSuccession` algorithm on concrete `Tab` objects.
    static func moveInSuccession(tabs rawTabs: [Tab], target: Tab?, allTabs: [Tab], append: Bool, insert: Bool) {
        var seen = Set<ObjectIdentifier>()
        var tabs: [Tab] = []
        for tab in rawTabs {
            if let target, tab === target { continue }
            if seen.insert(ObjectIdentifier(tab)).inserted { tabs.append(tab) }
        }
        guard !tabs.isEmpty else { return }
        let movingIDs = Set(tabs.map(ObjectIdentifier.init))
        let first = tabs[0]
        let last = tabs[tabs.count - 1]

        if append, let target {
            let oldSuccessor = target.successorTab.flatMap { movingIDs.contains(ObjectIdentifier($0)) ? nil : $0 }
            target.successorTab = first
            for i in 0..<(tabs.count - 1) {
                tabs[i].successorTab = tabs[i + 1]
            }
            last.successorTab = insert ? oldSuccessor : nil
        } else {
            if insert, let target {
                for other in allTabs where !movingIDs.contains(ObjectIdentifier(other)) && other.successorTab === target {
                    other.successorTab = first
                }
            }
            for i in 0..<(tabs.count - 1) {
                tabs[i].successorTab = tabs[i + 1]
            }
            last.successorTab = target
        }
    }
}

// MARK: - cookies.getPartitionKey

enum ExtensionCookies {
    /// Common two-part public suffixes so `a.b.co.uk` yields `b.co.uk` instead of `co.uk`.
    private static let twoPartSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "net.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
        "co.nz", "net.nz", "org.nz", "govt.nz",
        "co.kr", "or.kr", "ne.kr",
        "co.in", "net.in", "org.in", "gov.in", "ac.in",
        "com.br", "net.br", "org.br", "gov.br",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
        "com.tw", "org.tw", "edu.tw", "gov.tw",
        "com.hk", "org.hk", "edu.hk", "gov.hk",
        "com.sg", "org.sg", "edu.sg", "gov.sg",
        "com.mx", "org.mx", "gob.mx",
        "co.za", "org.za", "gov.za",
        "co.il", "org.il", "ac.il",
        "com.tr", "org.tr", "gov.tr",
        "com.ar", "org.ar", "gov.ar",
        "com.pl", "net.pl", "org.pl",
        "com.ua", "org.ua", "net.ua",
        "com.es", "org.es", "nom.es",
        "co.id", "or.id", "ac.id", "go.id",
        "com.my", "org.my", "edu.my", "gov.my",
        "com.ph", "org.ph", "gov.ph",
        "com.vn", "org.vn", "gov.vn",
        "com.sa", "org.sa", "gov.sa",
        "com.eg", "org.eg", "gov.eg",
        "com.ng", "org.ng", "gov.ng",
        "com.pk", "org.pk", "gov.pk",
        "com.co", "org.co", "gov.co",
        "com.pe", "org.pe", "gob.pe",
        "com.ve", "org.ve",
        "com.bd", "org.bd",
        "co.th", "or.th", "ac.th", "go.th",
        "github.io", "gitlab.io", "pages.dev", "vercel.app", "netlify.app", "herokuapp.com",
    ]

    /// Registrable domain (eTLD+1) of `host`, or the host itself for IP addresses / single labels.
    static func registrableDomain(of rawHost: String) -> String {
        var host = rawHost.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty || host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) {
            return host
        }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return host }
        let lastTwo = "\(labels[labels.count - 2]).\(labels[labels.count - 1])"
        if twoPartSuffixes.contains(lastTwo), labels.count >= 3 {
            return "\(labels[labels.count - 3]).\(lastTwo)"
        }
        return lastTwo
    }

    /// Chrome's `cookies.getPartitionKey` response `{ partitionKey: { topLevelSite?, hasCrossSiteAncestor? } }`.
    static func partitionKey(for url: URL?, frameID: Int? = nil) -> [String: Any] {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), !host.isEmpty else {
            return ["partitionKey": [String: Any]()]
        }
        let site = registrableDomain(of: host)
        let key: [String: Any] = [
            "topLevelSite": "\(scheme)://\(site)",
            "hasCrossSiteAncestor": (frameID ?? 0) != 0,
        ]
        return ["partitionKey": key]
    }
}
