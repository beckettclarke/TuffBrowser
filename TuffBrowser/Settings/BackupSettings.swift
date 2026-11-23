import SwiftUI
import UniformTypeIdentifiers

/// Settings › Backup & Restore: everything Tuff keeps, in one file you choose the contents of.
struct BackupPage: View {
    @State private var selected: Set<BackupItem> = Set(BackupItem.allCases)
    @State private var protect = true
    @State private var phase: Phase = .idle

    @State private var opened: OpenedBackup?
    @State private var openedName = ""
    @State private var restoreItems: Set<BackupItem> = []
    @State private var restoreError: String?

    private enum Phase: Equatable {
        case idle
        case working
        case done(URL)
        case failed(String)
    }

    private static let fileType = UTType(filenameExtension: "tuffbackup") ?? .data

    var body: some View {
        SettingsPage(title: "Backup & Restore", subtitle: "Save your tabs, spaces, profiles, extensions, passwords and more to one file, or bring them back.") {
            SettingsGroup(
                title: "Back up",
                footer: "Not included: downloaded files, what extensions keep inside pages (a password manager’s vault, say), site storage other than cookies, and your Sync sign-in."
            ) {
                SettingsRow(title: "Include", detail: "\(selected.count) of \(BackupItem.allCases.count) selected") {
                    Button("All") { withAnimation(Motion.snappy) { selected = Set(BackupItem.allCases) } }
                        .buttonStyle(TuffButtonStyle())
                    Button("None") { withAnimation(Motion.snappy) { selected = [] } }
                        .buttonStyle(TuffButtonStyle())
                }
                ForEach(BackupItem.allCases) { item in
                    let blocked = item.requires.map { !selected.contains($0) } ?? false
                    SwitchRow(
                        title: item.title,
                        detail: item.isSensitive ? item.detail + " Keep the file safe." : item.detail,
                        symbol: item.symbol,
                        isOn: Binding(
                            get: { selected.contains(item) && !blocked },
                            set: { on in
                                if on { selected.insert(item) } else { selected.remove(item) }
                                // Open tabs go with their spaces.
                                if !selected.contains(.spaces) { selected.remove(.tabs) }
                                if phase != .working { phase = .idle }
                            }
                        )
                    )
                    .disabled(blocked)
                    .opacity(blocked ? 0.5 : 1)
                }
                SwitchRow(
                    title: "Protect with a password",
                    detail: selected.contains(where: \.isSensitive) && !protect
                        ? "Passwords and cookies would be readable by anyone who gets the file."
                        : "Encrypts the file. Without the password it can’t be opened.",
                    symbol: "lock",
                    isOn: $protect
                )
                backupRow
            }

            SettingsGroup(
                title: "Restore",
                footer: opened == nil
                    ? "Restoring replaces what you pick with what is in the backup, then restarts Tuff."
                    : restoreError
            ) {
                if let opened {
                    restoreRows(opened)
                } else {
                    SettingsRow(title: "Restore from a backup", detail: "Choose a .tuffbackup file.", symbol: "arrow.counterclockwise") {
                        Button("Choose File…", action: chooseBackup).buttonStyle(TuffButtonStyle())
                    }
                }
            }
        }
        .onDisappear {
            opened?.discard()
            opened = nil
        }
    }

    // MARK: Back up

    @ViewBuilder
    private var backupRow: some View {
        switch phase {
        case .idle:
            SettingsRow(title: "Ready to back up", detail: selected.isEmpty ? "Turn on something to back up." : nil) {
                Button("Back Up…", action: createBackup)
                    .buttonStyle(TuffButtonStyle(kind: .prominent))
                    .disabled(selected.isEmpty)
            }
        case .working:
            SettingsRow(title: "Backing up…", detail: "Packing everything into one file.") {
                ProgressView().controlSize(.small)
            }
        case .done(let url):
            SettingsRow(title: "Backup saved", detail: url.lastPathComponent, symbol: "checkmark.circle.fill") {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(TuffButtonStyle())
                Button("Back Up Again") { phase = .idle }
                    .buttonStyle(TuffButtonStyle())
            }
        case .failed(let text):
            SettingsRow(title: "Couldn’t back up", detail: text, symbol: "exclamationmark.triangle.fill") {
                Button("Try Again") { phase = .idle }
                    .buttonStyle(TuffButtonStyle(kind: .prominent))
            }
        }
    }

    private func createBackup() {
        let panel = NSSavePanel()
        let day = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "Tuff Backup \(day).tuffbackup"
        panel.allowedContentTypes = [Self.fileType]
        panel.prompt = "Back Up"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let items = selected
        let protect = protect
        Task { @MainActor in
            var password: String?
            if protect {
                guard let chosen = await askNewPassword() else { return }
                password = chosen
            }
            withAnimation(Motion.smooth) { phase = .working }
            do {
                try await BackupBuilder.create(items: items, to: url, password: password)
                withAnimation(Motion.smooth) { phase = .done(url) }
            } catch {
                withAnimation(Motion.smooth) { phase = .failed(error.localizedDescription) }
            }
        }
    }

    private func askNewPassword() async -> String? {
        var note: String?
        while true {
            let result = await PromptPresenter.ask(Prompt(
                host: .settings,
                symbol: "lock.fill",
                title: "Protect the backup",
                message: "Choose a password for the file. Tuff can’t recover it: without it, nobody can open the backup.",
                note: note,
                confirmTitle: "Protect",
                fields: [
                    .init(placeholder: "Password", secure: true),
                    .init(placeholder: "Repeat password", secure: true),
                ]
            ))
            guard result.confirmed else { return nil }
            if result.fields[0].isEmpty {
                note = "Type a password."
            } else if result.fields[0] != result.fields[1] {
                note = "The two passwords don’t match."
            } else {
                return result.fields[0]
            }
        }
    }

    // MARK: Restore

    @ViewBuilder
    private func restoreRows(_ backup: OpenedBackup) -> some View {
        SettingsRow(
            title: openedName,
            detail: "Made \(backup.manifest.created.formatted(date: .abbreviated, time: .shortened))"
                + (backup.manifest.appVersion.isEmpty ? "" : " with Tuff \(backup.manifest.appVersion)"),
            symbol: "archivebox"
        ) {
            Button("Close") {
                backup.discard()
                withAnimation(Motion.smooth) { opened = nil; restoreError = nil }
            }
            .buttonStyle(TuffButtonStyle())
        }
        ForEach(BackupItem.allCases.filter(backup.manifest.items.contains)) { item in
            let blocked = item.requires.map { !restoreItems.contains($0) } ?? false
            SwitchRow(
                title: item.title,
                detail: backup.manifest.summaries[item.rawValue] ?? item.detail,
                symbol: item.symbol,
                isOn: Binding(
                    get: { restoreItems.contains(item) && !blocked },
                    set: { on in
                        if on { restoreItems.insert(item) } else { restoreItems.remove(item) }
                        if !restoreItems.contains(.spaces) { restoreItems.remove(.tabs) }
                    }
                )
            )
            .disabled(blocked)
            .opacity(blocked ? 0.5 : 1)
        }
        let missing = BackupRestore.missingProfiles(in: backup, restoring: restoreItems)
        if !missing.isEmpty {
            SettingsRow(
                title: "Profiles missing",
                detail: "\(missing.joined(separator: ", ")) \(missing.count == 1 ? "isn’t" : "aren’t") in this Tuff, so their bookmarks, history, passwords and cookies wouldn’t show up. Turn on “Spaces, profiles & pinned tabs” too.",
                symbol: "exclamationmark.triangle.fill"
            )
        }
        SettingsRow(title: "Ready to restore", detail: restoreItems.isEmpty ? "Turn on something to restore." : nil) {
            Button("Restore…") { confirmRestore(backup) }
                .buttonStyle(TuffButtonStyle(kind: .destructive))
                .disabled(restoreItems.isEmpty)
        }
    }

    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.fileType, .zip]
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            var password: String?
            var note: String?
            while true {
                if BackupReader.isProtected(url) && password == nil || note != nil {
                    let result = await PromptPresenter.ask(Prompt(
                        host: .settings,
                        symbol: "lock.fill",
                        title: "Enter the password",
                        subtitle: url.lastPathComponent,
                        note: note,
                        confirmTitle: "Open",
                        fields: [.init(placeholder: "Password", secure: true)]
                    ))
                    guard result.confirmed else { return }
                    password = result.fields[0]
                }
                do {
                    let backup = try await BackupReader.open(url, password: password)
                    opened?.discard()
                    withAnimation(Motion.smooth) {
                        opened = backup
                        openedName = url.deletingPathExtension().lastPathComponent
                        restoreItems = Set(backup.manifest.items)
                        restoreError = nil
                    }
                    return
                } catch BackupError.wrongPassword {
                    note = "That password is wrong."
                } catch {
                    withAnimation(Motion.smooth) { restoreError = error.localizedDescription }
                    return
                }
            }
        }
    }

    private func confirmRestore(_ backup: OpenedBackup) {
        let items = restoreItems
        Task { @MainActor in
            let chosen = BackupItem.allCases.filter(items.contains)
            let prompt = Prompt(
                host: .settings,
                symbol: "arrow.counterclockwise",
                symbolColor: .systemOrange,
                title: "Restore from this backup?",
                subtitle: openedName,
                message: "Tuff replaces the following with what is in the backup, then restarts. Files it replaces are kept in a “Before Restore” folder in Tuff’s data folder until your next restore.",
                itemsHeading: "Replaced",
                items: chosen.map { .init(symbol: $0.symbol, text: $0.title) },
                note: items.contains(.cookies) ? "Your current cookies are replaced and can’t be brought back." : nil,
                confirmTitle: "Restore & Restart",
                destructive: true
            )
            guard await PromptPresenter.present(prompt) else { return }
            do {
                try BackupRestore.stage(backup, items: items)
                backup.discard()
                opened = nil
                BackupRestore.relaunch()
            } catch {
                withAnimation(Motion.smooth) { restoreError = "Couldn’t prepare the restore: \(error.localizedDescription)" }
            }
        }
    }
}
