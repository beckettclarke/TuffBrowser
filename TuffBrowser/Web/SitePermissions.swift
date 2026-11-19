import AppKit
import Observation
import SwiftUI
import WebKit

enum SitePermissionKind: String, Codable, CaseIterable {
    case camera, microphone, cameraAndMicrophone, location, notifications

    init(_ type: WKMediaCaptureType) {
        switch type {
        case .camera: self = .camera
        case .microphone: self = .microphone
        default: self = .cameraAndMicrophone
        }
    }

    var label: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .cameraAndMicrophone: "Camera & Microphone"
        case .location: "Location"
        case .notifications: "Notifications"
        }
    }

    /// What the card says the site wants, after its name: "wants to use your camera".
    var request: String {
        switch self {
        case .camera: "wants to use your camera"
        case .microphone: "wants to use your microphone"
        case .cameraAndMicrophone: "wants to use your camera and microphone"
        case .location: "wants to know your location"
        case .notifications: "wants to send you notifications"
        }
    }

    /// The chips on the card, one per thing asked for.
    var chips: [(symbol: String, label: String)] {
        switch self {
        case .camera: [("video.fill", "Camera")]
        case .microphone: [("mic.fill", "Microphone")]
        case .cameraAndMicrophone: [("video.fill", "Camera"), ("mic.fill", "Microphone")]
        case .location: [("location.fill", "Location")]
        case .notifications: [("bell.badge.fill", "Notifications")]
        }
    }

    var symbols: [String] { chips.map(\.symbol) }

    /// The permissions a site's settings list, each set on its own. Camera and microphone
    /// requested together are answered for both (`SitePermissions.record`).
    static let perSite: [SitePermissionKind] = [.camera, .microphone, .location, .notifications]

    /// The two answers a camera-and-microphone request is kept as.
    var parts: [SitePermissionKind] { self == .cameraAndMicrophone ? [.camera, .microphone] : [self] }
}

/// What a site may do for one permission: ask each time, or always allow or deny.
enum PermissionSetting: String, CaseIterable, Identifiable {
    case ask, allow, deny
    var id: String { rawValue }

    init(_ granted: Bool?) {
        self = granted.map { $0 ? .allow : .deny } ?? .ask
    }

    var label: String {
        switch self {
        case .ask: "Ask"
        case .allow: "Allow"
        case .deny: "Deny"
        }
    }
}

/// A site's pending request, shown as a card over its tab.
struct PermissionRequest: Identifiable {
    let id = UUID()
    /// What the card names; the answer is kept for the request's origin (`SitePermissions`).
    let host: String
    let kind: SitePermissionKind
    /// `granted` is nil when the request goes away unanswered (tab closed, page navigated).
    let respond: (_ granted: Bool?, _ remember: Bool) -> Void
}

/// Camera, microphone, location and notification answers, per origin (scheme, host and port:
/// allowing https://example.com doesn't allow http://example.com or another port).
/// Remembered ones are saved; the rest last until Tuff quits.
///
/// Incognito keeps its own answers in memory only, dropped when the last Incognito window
/// closes. It inherits "Don't Allow" from normal windows but not "Allow", as in Chrome.
@Observable
final class SitePermissions {
    struct Entry: Codable, Identifiable, Hashable {
        /// `scheme://host[:port]`. Saved under "host": entries from before origins were bare
        /// host names, read back as https on the default port.
        var origin: String
        var kind: SitePermissionKind
        var granted: Bool
        var id: String { "\(origin)|\(kind.rawValue)" }

        /// The host alone for an https origin on the default port, else the whole origin.
        var displayName: String { SitePermissions.displayName(origin) }

        enum CodingKeys: String, CodingKey { case origin = "host", kind, granted }
    }

    static let shared = SitePermissions()

    private(set) var saved: [Entry] = []
    /// Answers given without "Remember", until Tuff quits. Observed, so a site's settings show them.
    private var session: [String: Bool] = [:]
    private var incognitoSession: [String: Bool] = [:]
    @ObservationIgnored private let file = Paths.appSupport.appendingPathComponent("site-permissions.json")

    private init() {
        guard let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        var migrated = false
        for var entry in list {
            if !entry.origin.contains("://") { entry.origin = "https://" + entry.origin.lowercased() }
            // Camera + microphone used to be one answer; each is now set on its own.
            if entry.kind == .cameraAndMicrophone {
                migrated = true
                for part in entry.kind.parts where !list.contains(where: { $0.origin == entry.origin && $0.kind == part }) {
                    saved.append(Entry(origin: entry.origin, kind: part, granted: entry.granted))
                }
                continue
            }
            saved.append(entry)
        }
        if migrated {
            sort()
            save()
        }
    }

    /// The host alone for an https origin on the default port, else the whole origin.
    static func displayName(_ origin: String) -> String {
        origin.hasPrefix("https://") && !origin.dropFirst(8).contains(":") ? String(origin.dropFirst(8)) : origin
    }

    /// The key permissions are kept under for a page's address, or nil for a page that isn't
    /// on the web.
    static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port.flatMap { $0 != (scheme == "https" ? 443 : 80) ? ":\($0)" : nil } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    /// The key permissions are kept under for a page's or frame's origin.
    static func origin(of origin: WKSecurityOrigin) -> String {
        let scheme = origin.protocol.lowercased()
        let host = origin.host.lowercased()
        let defaultPort = scheme == "https" ? 443 : scheme == "http" ? 80 : 0
        let port = origin.port != 0 && origin.port != defaultPort ? ":\(origin.port)" : ""
        return "\(scheme)://\(host)\(port)"
    }

    private func wildcardDecision(
        saved: [Entry], session: [String: Bool], origin: String, kind: SitePermissionKind
    ) -> Bool? {
        var candidates: [(pattern: ContentSettingPattern, granted: Bool, session: Bool)] = []
        for entry in saved where entry.kind == kind {
            guard let pattern = ContentSettingPattern(pattern: entry.origin),
                  (entry.origin.contains("*") || URL(string: entry.origin)?.port != nil), pattern.matches(origin: origin) else { continue }
            candidates.append((pattern, entry.granted, false))
        }
        for (key, granted) in session where key.hasSuffix("|\(kind.rawValue)") {
            let patternKey = String(key.dropLast(kind.rawValue.count + 1))
            guard let pattern = ContentSettingPattern(pattern: patternKey),
                  (patternKey.contains("*") || URL(string: patternKey)?.port != nil), pattern.matches(origin: origin) else { continue }
            candidates.append((pattern, granted, true))
        }
        return candidates.max {
            ($0.pattern.specificity, $0.session ? 1 : 0) < ($1.pattern.specificity, $1.session ? 1 : 0)
        }?.granted
    }

    func decision(origin: String, kind: SitePermissionKind, incognito: Bool) -> Bool? {
        let key = "\(origin)|\(kind.rawValue)"
        if incognito {
            if let answer = incognitoSession[key] { return answer }
            if let answer = wildcardDecision(saved: [], session: incognitoSession, origin: origin, kind: kind) { return answer }
        }
        var answer = session[key] ?? saved.first(where: { $0.id == key })?.granted
        if answer == nil { answer = wildcardDecision(saved: saved, session: session, origin: origin, kind: kind) }
        // A normal window's "Allow" doesn't carry into Incognito; its "Don't Allow" does.
        if incognito, answer == true { answer = nil }
        if let answer { return answer }
        // Camera + microphone: denied if either is, allowed if both are, else the site asks.
        if kind == .cameraAndMicrophone {
            let answers = kind.parts.map { decision(origin: origin, kind: $0, incognito: incognito) }
            if answers.contains(false) { return false }
            if answers.allSatisfy({ $0 == true }) { return true }
        }
        return nil
    }

    func record(origin: String, kind: SitePermissionKind, granted: Bool, remember: Bool, incognito: Bool) {
        guard kind != .cameraAndMicrophone else {
            for part in kind.parts { record(origin: origin, kind: part, granted: granted, remember: remember, incognito: incognito) }
            return
        }
        let entry = Entry(origin: origin, kind: kind, granted: granted)
        if incognito {
            // Nothing from Incognito reaches the disk; "remember" lasts while Incognito is open.
            if remember { incognitoSession[entry.id] = granted }
            return
        }
        if remember {
            // A remembered answer replaces one given for this session only.
            session[entry.id] = nil
            saved.removeAll { $0.id == entry.id }
            saved.append(entry)
            sort()
            save()
        } else {
            session[entry.id] = granted
        }
    }

    // MARK: Per-site settings

    /// What a site's settings show for one permission: the answer kept for exactly this origin
    /// (remembered, or given until Tuff quits), else Ask. Incognito shows its own answers and
    /// the "Deny"s it inherits from normal windows.
    func setting(origin: String, kind: SitePermissionKind, incognito: Bool) -> PermissionSetting {
        let key = "\(origin)|\(kind.rawValue)"
        let normal = session[key] ?? saved.first(where: { $0.id == key })?.granted
        guard incognito else { return PermissionSetting(normal) }
        if let answer = incognitoSession[key] { return PermissionSetting(answer) }
        return normal == false ? .deny : .ask
    }

    /// Sets one permission for a site, from its settings. Ask forgets the answer, so the site
    /// asks again next time. Denying the camera or microphone stops a page of that site
    /// already using it.
    func set(_ setting: PermissionSetting, origin: String, kind: SitePermissionKind, incognito: Bool) {
        for part in kind.parts {
            switch setting {
            case .ask:
                for granted in [true, false] { remove(Entry(origin: origin, kind: part, granted: granted), incognito: incognito) }
            case .allow, .deny:
                record(origin: origin, kind: part, granted: setting == .allow, remember: true, incognito: incognito)
            }
        }
        if setting == .deny, kind != .location, kind != .notifications {
            Self.stopCapture(kind, origin: origin, incognito: incognito)
        }
    }

    /// Every origin with a remembered answer, sorted.
    var origins: [String] {
        var seen = Set<String>()
        return saved.map(\.origin).filter { seen.insert($0).inserted }
    }

    /// Forgets every answer for one site.
    func removeAll(origin: String) {
        saved.removeAll { $0.origin == origin }
        session = session.filter { !$0.key.hasPrefix(origin + "|") }
        save()
    }

    /// Turns off the camera or microphone in open tabs showing `origin`.
    private static func stopCapture(_ kind: SitePermissionKind, origin: String, incognito: Bool) {
        for state in BrowserState.all where state.isPrivate == incognito {
            for tab in state.allTabs where Self.origin(of: tab.url) == origin {
                guard let webView = tab.webView else { continue }
                if kind != .microphone { webView.setCameraCaptureState(.none) }
                if kind != .camera { webView.setMicrophoneCaptureState(.none) }
            }
        }
    }

    /// Called when the last Incognito window closes.
    func forgetIncognito() {
        incognitoSession.removeAll()
    }

    func remove(_ entry: Entry, incognito: Bool = false) {
        if incognito {
            incognitoSession[entry.id] = nil
            return
        }
        saved.removeAll { $0.id == entry.id }
        session[entry.id] = nil
        save()
    }

    func removeAll() {
        saved.removeAll()
        session.removeAll()
        save()
    }

    private func sort() {
        saved.sort { ($0.origin, $0.kind.rawValue) < ($1.origin, $1.kind.rawValue) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

// MARK: - Card

/// Drops in from the top of the page. It doesn't block the window: the page keeps running and
/// the rest of the browser stays usable while the site waits for an answer.
struct PermissionCard: View {
    @Environment(BrowserState.self) private var state
    @Environment(\.accent) private var accent
    let tab: Tab
    let request: PermissionRequest

    @State private var remember = AppSettings.shared.privacy.rememberMediaPermissions
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                siteIcon
                VStack(alignment: .leading, spacing: 3) {
                    hostText
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text(request.kind.request)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.primary.opacity(0.6))
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                ForEach(request.kind.chips, id: \.symbol) { chip in
                    deviceChip(chip.symbol, chip.label)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                TuffSwitch(isOn: $remember)
                Text(state.isPrivate ? "Remember while Incognito is open" : "Remember for this site")
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize()
                    .foregroundStyle(.primary.opacity(0.7))
                    .onTapGesture { withAnimation(Motion.snappy) { remember.toggle() } }
                Spacer(minLength: 8)
                Button("Don’t Allow") { answer(false) }
                    .buttonStyle(TuffButtonStyle(kind: .plain))
                Button("Allow") { answer(true) }
                    .buttonStyle(TuffButtonStyle(kind: .prominent))
            }
        }
        .padding(16)
        .frame(width: 400)
        .background(
            ZStack {
                VisualEffect(material: .hudWindow, blending: .withinWindow)
                Color(nsColor: state.currentTint).opacity(0.6)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.14), lineWidth: 1))
        .modifier(CardShadow(cornerRadius: 16, opacity: 0.35, radius: 26, y: 12, hollow: true))
        .environment(\.colorScheme, AppSettings.shared.chromeScheme(for: state.currentTint))
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var hostText: Text {
        let parts: (prefix: String, domain: String) = URL(string: "https://\(request.host)")?.hostParts ?? (prefix: "", domain: request.host)
        return Text(parts.prefix).foregroundStyle(.primary.opacity(0.5)) + Text(parts.domain).foregroundStyle(.primary)
    }

    private var siteIcon: some View {
        Group {
            if let icon = tab.favicon {
                Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(7)
            } else {
                Image(systemName: "globe").font(.system(size: 17, weight: .medium)).foregroundStyle(.primary.opacity(0.6))
            }
        }
        .frame(width: 38, height: 38)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.1)))
    }

    private func deviceChip(_ symbol: String, _ label: String) -> some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().fill(accent.opacity(pulse ? 0.35 : 0.18)).frame(width: 22, height: 22)
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.primary.opacity(0.9))
            }
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.8))
        }
        .padding(.leading, 4)
        .padding(.trailing, 11)
        .frame(height: 30)
        .background(Capsule().fill(.primary.opacity(0.08)))
    }

    private func answer(_ granted: Bool) {
        withAnimation(Motion.snappy) { tab.resolvePermission(granted: granted, remember: remember) }
    }
}
