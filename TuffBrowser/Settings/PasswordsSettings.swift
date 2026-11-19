import AppKit
import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Passwords: the switch, every saved sign-in (searchable, editable), the sites
/// never to save for, and CSV import / export. Showing, copying, editing or exporting a
/// password asks for Touch ID or the Mac's password first, then stays unlocked for five minutes.
struct PasswordsPage: View {
    @Environment(BrowserState.self) private var state
    @Environment(AppSettings.self) private var settings
    @State private var store = PasswordStore.shared
    @State private var query = ""
    @State private var profileID: UUID?
    @State private var revealed: Set<UUID> = []

    /// Until when the passwords stay unlocked.
    private static var unlockedUntil: Date?

    var body: some View {
        @Bindable var settings = settings
        let profiles = state.profiles
        let profile = profileID ?? state.bookmarksProfileID ?? profiles.first?.id
        SettingsPage(title: "Passwords", subtitle: "Sign-ins Tuff saves and fills in for you.") {
            SettingsGroup(footer: "Turn this off if a password manager extension such as 1Password saves and fills your passwords.") {
                SwitchRow(
                    title: "Save and fill passwords",
                    detail: "Offer to save a password when you sign in, and suggest saved ones in sign-in forms.",
                    isOn: $settings.privacy.passwords
                )
                if profiles.count > 1, let profile {
                    SettingsRow(title: "Profile", detail: "Each profile keeps its own passwords.") {
                        TuffMenu(
                            selection: Binding(get: { profile }, set: { profileID = $0; revealed = [] }),
                            options: profiles.map(\.id),
                            label: { id in profiles.first { $0.id == id }?.name ?? "Profile" }
                        )
                    }
                }
            }

            if let profile {
                savedGroup(profile: profile)
                neverGroup
                transferGroup(profile: profile)
            }
        }
    }

    // MARK: Saved

    private func savedGroup(profile: UUID) -> some View {
        let all = store.logins.filter { $0.profile == profile }
            .sorted { ($0.displayName, $0.username) < ($1.displayName, $1.username) }
        let q = query.trimmed.lowercased()
        let shown = q.isEmpty ? all : all.filter { $0.displayName.lowercased().contains(q) || $0.username.lowercased().contains(q) }
        return SettingsGroup(
            title: "Saved passwords",
            footer: "Passwords are encrypted on this Mac. Showing, copying, editing or exporting one asks for Touch ID or your Mac’s password."
        ) {
            HStack(spacing: 8) {
                TuffTextField(placeholder: all.count == 1 ? "Search 1 password" : "Search \(all.count) passwords", text: $query, width: nil)
                Button("Add…") { add(profile: profile) }
                    .buttonStyle(TuffButtonStyle())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            if shown.isEmpty {
                SettingsRow(title: all.isEmpty ? "No saved passwords yet" : "No passwords match")
            }
            ForEach(shown.prefix(300)) { login in
                row(login)
            }
            if shown.count > 300 {
                SettingsRow(title: "\(shown.count - 300) more — search to find them.")
            }
        }
    }

    private func row(_ login: SavedLogin) -> some View {
        let isRevealed = revealed.contains(login.id)
        return HStack(spacing: 10) {
            Image(systemName: login.origin.hasPrefix("http://") ? "lock.open.fill" : "key.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.55))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(login.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(login.username.isEmpty ? "No username" : login.username)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(isRevealed ? login.password : "••••••••")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 170, alignment: .trailing)
                .textSelection(.enabled)
            IconButton(symbol: isRevealed ? "eye.slash" : "eye", size: 11, side: 24, help: isRevealed ? "Hide" : "Show Password") {
                if isRevealed {
                    revealed.remove(login.id)
                } else {
                    unlock { revealed.insert(login.id) }
                }
            }
            IconButton(symbol: "doc.on.doc", size: 11, side: 24, help: "Copy Password") {
                unlock { Self.copy(login.password) }
            }
            IconButton(symbol: "pencil", size: 11, side: 24, help: "Edit") {
                unlock { edit(login) }
            }
            IconButton(symbol: "trash", size: 11, side: 24, help: "Delete") {
                delete(login)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(minHeight: 44)
    }

    // MARK: Never

    @ViewBuilder
    private var neverGroup: some View {
        if !store.never.isEmpty {
            SettingsGroup(title: "Never saved", footer: "Sites where you chose never to save passwords.") {
                ForEach(store.never, id: \.self) { origin in
                    SettingsRow(title: SitePermissions.displayName(origin), symbol: "nosign") {
                        IconButton(symbol: "xmark", size: 10, side: 24, help: "Ask Again") {
                            withAnimation(Motion.snappy) { store.removeNever(origin) }
                        }
                    }
                }
            }
        }
    }

    // MARK: Import and export

    private func transferGroup(profile: UUID) -> some View {
        SettingsGroup(title: "Import and export", footer: "CSV files from Chrome, Safari, Firefox, 1Password and Bitwarden can be imported.") {
            SettingsRow(title: "Import passwords", detail: "From a CSV file another browser or password manager exported.", symbol: "square.and.arrow.down") {
                Button("Import…") { importCSV(profile: profile) }
                    .buttonStyle(TuffButtonStyle())
            }
            SettingsRow(title: "Export passwords", detail: "To a CSV file. Anyone who can open the file can read them.", symbol: "square.and.arrow.up") {
                Button("Export…") { unlock { exportCSV(profile: profile) } }
                    .buttonStyle(TuffButtonStyle())
                    .disabled(!store.logins.contains { $0.profile == profile })
            }
        }
    }

    // MARK: Actions

    /// Asks for Touch ID or the Mac's password (the system's own sheet), unless that was done in
    /// the last five minutes. A Mac with no password set can't protect them, so it just goes ahead.
    private func unlock(then action: @escaping () -> Void) {
        if let until = Self.unlockedUntil, until > Date() {
            action()
            return
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            action()
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "use your saved passwords") { success, _ in
            DispatchQueue.main.async {
                guard success else { return }
                Self.unlockedUntil = Date().addingTimeInterval(5 * 60)
                action()
            }
        }
    }

    /// Copies a password, marked so clipboard history apps leave it out.
    static func copy(_ password: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        board.setString(password, forType: .string)
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }

    private func add(profile: UUID) {
        Task { @MainActor in
            let result = await PromptPresenter.ask(Prompt(
                host: .settings, symbol: "key.fill",
                title: "Add a password",
                message: "Tuff suggests it when you sign in to this site.",
                confirmTitle: "Add",
                fields: [
                    Prompt.Field(placeholder: "Website (example.com)"),
                    Prompt.Field(placeholder: "Username"),
                    Prompt.Field(placeholder: "Password", secure: true),
                ]
            ))
            guard result.confirmed, result.fields.count == 3 else { return }
            let address = result.fields[0].trimmed
            let url = URL(string: address.contains("://") ? address : "https://" + address)
            guard let origin = SitePermissions.origin(of: url), !result.fields[2].isEmpty else {
                await PromptPresenter.present(Prompt(
                    host: .settings, symbol: "exclamationmark.triangle.fill", symbolColor: .systemOrange,
                    title: "Couldn’t add that password",
                    message: "Enter the site’s address (such as example.com) and a password.",
                    confirmTitle: "OK", cancelTitle: nil
                ))
                return
            }
            withAnimation(Motion.snappy) {
                _ = store.save(origin: origin, username: result.fields[1].trimmed, password: result.fields[2], profile: profile)
            }
        }
    }

    private func edit(_ login: SavedLogin) {
        Task { @MainActor in
            let result = await PromptPresenter.ask(Prompt(
                host: .settings, symbol: "key.fill",
                title: "Edit password for \(login.displayName)",
                confirmTitle: "Save",
                fields: [
                    Prompt.Field(placeholder: "Username", text: login.username),
                    Prompt.Field(placeholder: "Password", text: login.password),
                ]
            ))
            guard result.confirmed, result.fields.count == 2, !result.fields[1].isEmpty else { return }
            store.update(login.id, username: result.fields[0].trimmed, password: result.fields[1])
        }
    }

    private func delete(_ login: SavedLogin) {
        Task { @MainActor in
            let confirmed = await PromptPresenter.present(Prompt(
                host: .settings, symbol: "trash.fill", symbolColor: .red,
                title: "Delete the password for \(login.displayName)?",
                message: login.username.isEmpty ? "It can’t be brought back." : "The password for \(login.username) can’t be brought back.",
                confirmTitle: "Delete", destructive: true
            ))
            guard confirmed else { return }
            withAnimation(Motion.snappy) {
                revealed.remove(login.id)
                store.remove(login.id)
            }
        }
    }

    private func importCSV(profile: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.message = "Choose a CSV file of passwords"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let count = withAnimation(Motion.snappy) { store.importCSV(text, profile: profile) }
        Task { @MainActor in
            await PromptPresenter.present(Prompt(
                host: .settings, symbol: count > 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                symbolColor: count > 0 ? .systemGreen : .systemOrange,
                title: count > 0 ? "Imported \(count) password\(count == 1 ? "" : "s")" : "No passwords imported",
                message: count > 0
                    ? "You can delete the CSV file now: anyone who can open it can read the passwords."
                    : "The file had no new passwords, or its columns weren’t recognised (it needs url, username and password).",
                confirmTitle: "OK", cancelTitle: nil
            ))
        }
    }

    private func exportCSV(profile: UUID) {
        Task { @MainActor in
            let confirmed = await PromptPresenter.present(Prompt(
                host: .settings, symbol: "exclamationmark.lock.fill", symbolColor: .systemOrange,
                title: "Export passwords?",
                message: "The file isn’t encrypted: anyone or any app that can open it can read every password in it. Delete it once you’ve used it.",
                confirmTitle: "Export…"
            ))
            guard confirmed else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "Tuff Passwords.csv"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try store.exportCSV(profile: profile).write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                await PromptPresenter.present(Prompt(
                    host: .settings, symbol: "exclamationmark.triangle.fill", symbolColor: .systemOrange,
                    title: "Couldn’t export passwords", message: error.localizedDescription,
                    confirmTitle: "OK", cancelTitle: nil
                ))
            }
        }
    }
}
