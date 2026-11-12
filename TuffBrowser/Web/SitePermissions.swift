import AppKit
import Observation
import SwiftUI
import WebKit

enum SitePermissionKind: String, Codable, CaseIterable {
    case camera, microphone, cameraAndMicrophone

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
        }
    }

    /// What the card asks for, lower-case: "your camera".
    var phrase: String {
        switch self {
        case .camera: "your camera"
        case .microphone: "your microphone"
        case .cameraAndMicrophone: "your camera and microphone"
        }
    }

    var symbols: [String] {
        switch self {
        case .camera: ["video.fill"]
        case .microphone: ["mic.fill"]
        case .cameraAndMicrophone: ["video.fill", "mic.fill"]
        }
    }
}

/// A site's pending request, shown as a card over its tab.
struct PermissionRequest: Identifiable {
    let id = UUID()
    let host: String
    let kind: SitePermissionKind
    /// `granted` is nil when the request goes away unanswered (tab closed, page navigated).
    let respond: (_ granted: Bool?, _ remember: Bool) -> Void
}

/// Camera / microphone answers. Remembered ones are saved; the rest last until Tuff quits.
@Observable
final class SitePermissions {
    struct Entry: Codable, Identifiable, Hashable {
        var host: String
        var kind: SitePermissionKind
        var granted: Bool
        var id: String { "\(host)|\(kind.rawValue)" }
    }

    static let shared = SitePermissions()

    private(set) var saved: [Entry] = []
    @ObservationIgnored private var session: [String: Bool] = [:]
    @ObservationIgnored private let file = Paths.appSupport.appendingPathComponent("site-permissions.json")

    private init() {
        if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([Entry].self, from: data) {
            saved = list
        }
    }

    func decision(host: String, kind: SitePermissionKind) -> Bool? {
        let key = "\(host)|\(kind.rawValue)"
        if let answer = session[key] { return answer }
        if let entry = saved.first(where: { $0.id == key }) { return entry.granted }
        // Camera + microphone is covered when each was answered the same way on its own.
        if kind == .cameraAndMicrophone,
           let camera = decision(host: host, kind: .camera),
           let mic = decision(host: host, kind: .microphone),
           camera == mic {
            return camera
        }
        return nil
    }

    func record(host: String, kind: SitePermissionKind, granted: Bool, remember: Bool) {
        let entry = Entry(host: host, kind: kind, granted: granted)
        if remember {
            saved.removeAll { $0.id == entry.id }
            saved.append(entry)
            saved.sort { ($0.host, $0.kind.rawValue) < ($1.host, $1.kind.rawValue) }
            save()
        } else {
            session[entry.id] = granted
        }
    }

    func remove(_ entry: Entry) {
        saved.removeAll { $0.id == entry.id }
        session[entry.id] = nil
        save()
    }

    func removeAll() {
        saved.removeAll()
        session.removeAll()
        save()
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
                    Text("wants to use \(request.kind.phrase)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.primary.opacity(0.6))
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                ForEach(request.kind.symbols, id: \.self) { symbol in
                    deviceChip(symbol)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                TuffSwitch(isOn: $remember)
                Text("Remember for this site")
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
        .shadow(color: .black.opacity(0.35), radius: 26, y: 12)
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

    private func deviceChip(_ symbol: String) -> some View {
        let isCamera = symbol.hasPrefix("video")
        return HStack(spacing: 7) {
            ZStack {
                Circle().fill(accent.opacity(pulse ? 0.35 : 0.18)).frame(width: 22, height: 22)
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.primary.opacity(0.9))
            }
            Text(isCamera ? "Camera" : "Microphone")
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
