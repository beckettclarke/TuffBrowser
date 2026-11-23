import SwiftUI

/// Settings → Sync: signing in to a Mozilla account, what syncs, and the account's other devices.
struct SyncPage: View {
    @Environment(BrowserState.self) private var state
    @State private var sync = SyncManager.shared

    var body: some View {
        SettingsPage(title: "Sync", subtitle: "Your bookmarks, history, passwords, tabs and spaces on all your devices.") {
            if let account = sync.account {
                accountGroup(account)
                kindsGroup
                devicesGroup
            } else {
                signInGroup
                googleGroup
            }
        }
    }

    // MARK: Signed out

    private var signInGroup: some View {
        SettingsGroup(
            title: "Mozilla account",
            footer: "Works with Firefox, Zen and other browsers built on Firefox, and with Tuff on your other Macs. Everything is end-to-end encrypted with your account’s key, so Mozilla can’t read it."
        ) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.orange.gradient))
                VStack(alignment: .leading, spacing: 2) {
                    Text(sync.finishingSignIn ? "Signing in…" : "Sync with Firefox and Zen")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Sign in on Mozilla’s page, in a new tab. Make an account there if you don’t have one.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.primary.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Sign In…") { sync.beginSignIn() }
                    .buttonStyle(TuffButtonStyle(kind: .prominent))
                    .disabled(sync.finishingSignIn)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .settingsAnchor("Sign in to sync")
            if case .failed(let message) = sync.status {
                SettingsRow(title: "Couldn’t sign in", detail: message, symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    private var googleGroup: some View {
        SettingsGroup(
            title: "Google account",
            footer: "Chrome sync only works in Chrome itself: Google doesn’t let other browsers use it. Import brings over Chrome’s bookmarks, history and passwords instead."
        ) {
            SettingsRow(title: "Bring over what’s in Chrome", symbol: "square.and.arrow.down") {
                SettingsLink(title: "Import", tab: .importData)
            }
        }
    }

    // MARK: Signed in

    private func accountGroup(_ account: MozillaAccountState) -> some View {
        SettingsGroup {
            SettingsRow(
                title: account.displayName ?? (account.email.isEmpty ? "Mozilla account" : account.email),
                detail: account.displayName != nil && !account.email.isEmpty ? account.email : "Mozilla account",
                symbol: "person.crop.circle.fill"
            ) {
                Button("Sign Out…") { Task { await signOut() } }
                    .buttonStyle(TuffButtonStyle())
            }
            SettingsRow(title: "Status", detail: status, symbol: statusSymbol) {
                if sync.needsSignIn {
                    Button("Sign In Again…") { sync.beginSignIn() }
                        .buttonStyle(TuffButtonStyle(kind: .prominent))
                } else {
                    Button("Sync Now") { sync.syncNow() }
                        .buttonStyle(TuffButtonStyle())
                        .disabled(sync.status == .syncing || sync.finishingSignIn)
                }
            }
        }
    }

    private var status: String {
        if sync.finishingSignIn { return "Setting up your account…" }
        switch sync.status {
        case .syncing: return "Syncing…"
        case .failed(let message): return message
        case .idle:
            guard let date = sync.lastSynced else { return "Not synced yet." }
            return "Last synced " + date.formatted(.relative(presentation: .named)) + "."
        }
    }

    private var statusSymbol: String {
        if case .failed = sync.status { return "exclamationmark.triangle.fill" }
        return "arrow.triangle.2.circlepath"
    }

    private var kindsGroup: some View {
        let _ = sync.revision
        let profiles = state.profiles
        return SettingsGroup(title: "What to sync", footer: "These are this Mac’s choices; your other devices keep their own.") {
            ForEach(SyncKind.allCases) { kind in
                SwitchRow(
                    title: kind.title, detail: kind.detail, symbol: kind.symbol,
                    isOn: Binding(get: { sync.isEnabled(kind) }, set: { sync.setEnabled(kind, $0) })
                )
                if kind == .spaces, sync.isEnabled(.spaces) {
                    SwitchRow(
                        title: "Include open tabs",
                        detail: "Also sync each space’s open tabs, not just pinned tabs and favorites. In Zen, turn on “Include unpinned tabs” too.",
                        symbol: "square.on.square",
                        isOn: Binding(get: { sync.includesOpenTabs }, set: { sync.includesOpenTabs = $0 })
                    )
                }
            }
            if profiles.count > 1, let current = sync.profileID ?? profiles.first?.id {
                SettingsRow(title: "Profile", detail: "Whose bookmarks, history and passwords sync. Changing it merges that profile’s into your account.") {
                    TuffMenu(
                        selection: Binding(get: { current }, set: { sync.profileID = $0 }),
                        options: profiles.map(\.id),
                        label: { id in profiles.first { $0.id == id }?.name ?? "Profile" }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var devicesGroup: some View {
        if sync.isEnabled(.tabs), !sync.devices.isEmpty {
            SettingsGroup(title: "Your other devices", footer: "Their open tabs are in the History menu, under Tabs from Other Devices.") {
                ForEach(sync.devices) { device in
                    SettingsRow(title: device.name, detail: device.tabs.count == 1 ? "1 tab open" : "\(device.tabs.count) tabs open", symbol: device.symbol)
                }
            }
        }
    }

    @MainActor
    private func signOut() async {
        var prompt = Prompt(
            symbol: "rectangle.portrait.and.arrow.right",
            title: "Sign Out of Sync?",
            message: "Tuff stops syncing with your Mozilla account and leaves its device list. Your bookmarks, history and passwords stay on this Mac.",
            confirmTitle: "Sign Out"
        )
        prompt.host = .settings
        guard await PromptPresenter.present(prompt) else { return }
        sync.signOut()
    }
}
