import SwiftUI

// MARK: - Mods

/// Optional extras that change how Tuff behaves. Each mod is a group: a header with its switch,
/// and its own options under it while it is on.
struct ModsPage: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        SettingsPage(title: "Mods", subtitle: "Small extras that change how Tuff works. Switch off any you don’t want.") {
            BangsMod(isOn: $settings.mods.bangs)
        }
    }
}

/// The header row of a mod: an icon tile, what it does, and its switch.
private struct ModHeader<Icon: View>: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    @ViewBuilder var icon: Icon
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accent.opacity(isOn ? 0.22 : 0.1)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(accent.opacity(isOn ? 0.45 : 0.15), lineWidth: 0.75))
                .saturation(isOn ? 1 : 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.92))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary.opacity(0.48))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            TuffSwitch(isOn: $isOn)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .settingsAnchor(title)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Motion.snappy) { isOn.toggle() } }
    }
}

// MARK: Bangs

private struct BangsMod: View {
    @Binding var isOn: Bool
    @Environment(\.accent) private var accent
    @State private var lookup = ""
    private let store = BangStore.shared

    private static let examples = ["g", "yt", "w", "gh", "r", "a"]

    var body: some View {
        SettingsGroup(
            footer: isOn
                ? "Bangs go straight to the site, without a stop at DuckDuckGo. Tuff downloads DuckDuckGo’s list of bangs once a week. Press ⌫ at the start of the bar to take a bang back out."
                : nil
        ) {
            ModHeader(
                title: "DuckDuckGo Bangs",
                detail: "Type !yt, !w, !gh… before or after a search to search that site directly.",
                isOn: $isOn
            ) {
                Text("!")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(accent)
            }

            if isOn {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Try it")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.92))
                        Text("Type one of these in the command bar, then a space.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.primary.opacity(0.48))
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .leading), count: 3), alignment: .leading, spacing: 8) {
                        ForEach(Self.examples, id: \.self) { trigger in
                            if let bang = store.bang(for: trigger) {
                                HStack(spacing: 6) {
                                    KeyCap(text: "!" + trigger)
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.primary.opacity(0.35))
                                    BangChip(bang: bang, compact: true, animated: false)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                SettingsRow(title: "Look up a bang", detail: lookupDetail) {
                    TuffTextField(placeholder: "!imdb", text: $lookup, width: 150, monospaced: true)
                }

                SettingsRow(title: "Bang list", detail: listDetail) {
                    Button(store.isUpdating ? "Updating…" : "Update Now") { store.update() }
                        .buttonStyle(TuffButtonStyle())
                        .disabled(store.isUpdating)
                }
            }
        }
        .animation(Motion.snappy, value: isOn)
        .onAppear { if isOn { store.prepare() } }
        .onChange(of: isOn) { _, on in if on { store.prepare() } }
    }

    private var lookupDetail: String {
        let trigger = lookup.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "!"))
        guard !trigger.isEmpty else { return "See where a bang goes." }
        guard let bang = store.bang(for: trigger) else { return "No bang called !\(trigger)." }
        return "!\(bang.trigger) searches \(bang.name) (\(bang.domain))."
    }

    private var listDetail: String {
        if let error = store.lastError { return "Couldn’t update: \(error)" }
        let count = store.count.formatted()
        guard let updated = store.updated else {
            return store.isUpdating ? "Downloading DuckDuckGo’s list…" : "\(count) built in. DuckDuckGo’s full list hasn’t been downloaded yet."
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "\(count) bangs from DuckDuckGo, updated \(formatter.localizedString(for: updated, relativeTo: Date()))."
    }
}
