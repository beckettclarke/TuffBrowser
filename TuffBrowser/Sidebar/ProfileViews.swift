import SwiftUI

// MARK: - Extension links

/// Menu items choosing where an extension runs: everywhere, or only in some profiles / spaces.
struct ExtensionLinkMenuItems: View {
    @Environment(BrowserState.self) private var state
    @Environment(ExtensionManager.self) private var extensions
    let id: String

    var body: some View {
        let record = extensions.records.first { $0.id == id }
        let links = record.map { extensions.liveLinks($0) } ?? []
        Toggle(isOn: Binding(get: { links.isEmpty }, set: { if $0 { extensions.setLinks(nil, id: id) } })) {
            Text("All Spaces")
        }
        Section("Profiles") {
            ForEach(state.profiles) { profile in
                Toggle(isOn: Binding(get: { links.contains(profile.id) }, set: { _ in extensions.toggleLink(profile.id, id: id) })) {
                    Label(profile.name, systemImage: profile.icon)
                }
            }
        }
        Section("Spaces") {
            ForEach(state.spaces) { space in
                Toggle(isOn: Binding(get: { links.contains(space.id) }, set: { _ in extensions.toggleLink(space.id, id: id) })) {
                    Label(space.name, systemImage: space.icon)
                }
            }
        }
    }
}

// MARK: - Profile picker

/// Picks the profile a space belongs to, with a shortcut for making a new one.
struct SpaceProfilePicker: View {
    @Environment(BrowserState.self) private var state
    let space: Space
    @State private var renaming = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let profile = state.profile(for: space)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Menu {
                    Picker("", selection: Binding(
                        get: { space.profileID },
                        set: { id in
                            if let p = state.profiles.first(where: { $0.id == id }) { state.setProfile(p, for: space) }
                            renaming = false
                        }
                    )) {
                        ForEach(state.profiles) { p in
                            Label(p.name, systemImage: p.icon).tag(p.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Divider()
                    Button("New Profile…") {
                        let new = state.addProfile()
                        state.setProfile(new, for: space)
                        renaming = true
                        DispatchQueue.main.async { nameFocused = true }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: profile.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 16)
                        Text(profile.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.primary.opacity(0.45))
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.07)))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)

                Button {
                    renaming.toggle()
                    if renaming { DispatchQueue.main.async { nameFocused = true } }
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(renaming ? 0.16 : 0.07)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(SquishButtonStyle())
                .help("Rename Profile")
            }
            if renaming {
                TextField("Profile name", text: Binding(get: { profile.name }, set: { profile.name = $0; state.profileDidChange(profile) }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .focused($nameFocused)
                    .onSubmit { renaming = false }
            }
            Text(footnote(for: profile))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func footnote(for profile: Profile) -> String {
        let others = state.spaces(in: profile).filter { $0 !== space }.map(\.name)
        if others.isEmpty { return "Has its own cookies and sign-ins. Favourites and linked extensions follow the profile." }
        return "Shares cookies, sign-ins and favourites with " + others.joined(separator: ", ") + "."
    }
}

// MARK: - Settings: profiles

struct ProfileSettingsRow: View {
    @Environment(BrowserState.self) private var state
    @Bindable var profile: Profile
    @State private var editingIcon = false

    private let iconColumns = Array(repeating: GridItem(.fixed(30), spacing: 6), count: 6)

    var body: some View {
        let spaceCount = state.spaces(in: profile).count
        HStack(spacing: 12) {
            Button { editingIcon = true } label: {
                Image(systemName: profile.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.75))
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.primary.opacity(0.18), lineWidth: 0.5))
            }
            .buttonStyle(SquishButtonStyle())
            .help("Change icon")
            .popover(isPresented: $editingIcon, arrowEdge: .bottom) {
                LazyVGrid(columns: iconColumns, spacing: 6) {
                    ForEach(Profile.icons, id: \.self) { icon in
                        Button {
                            withAnimation(Motion.snappy) { profile.icon = icon }
                            state.profileDidChange(profile)
                        } label: {
                            Image(systemName: icon)
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 30, height: 30)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(profile.icon == icon ? 0.16 : 0.05)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(SquishButtonStyle())
                    }
                }
                .padding(16)
            }

            TuffTextField(placeholder: "Profile name", text: $profile.name, width: 200)

            if state.currentProfile === profile {
                Text("Showing")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.5))
                    .padding(.horizontal, 7)
                    .frame(height: 19)
                    .background(Capsule().fill(.primary.opacity(0.08)))
                    .fixedSize()
            }

            Spacer(minLength: 8)

            Text("\(spaceCount) \(spaceCount == 1 ? "space" : "spaces") · \(profile.favorites.count) \(profile.favorites.count == 1 ? "favourite" : "favourites")")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.42))

            IconButton(symbol: "trash", size: 11, side: 24, help: "Delete Profile…", disabled: state.profiles.count < 2) {
                confirmDelete()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: profile.name) { _, _ in state.scheduleSave() }
        .onChange(of: profile.icon) { _, _ in state.scheduleSave() }
    }

    /// Deleting signs out of every site on the profile, so it asks first.
    private func confirmDelete() {
        let fallback = state.profiles.first { $0 !== profile }?.name ?? "another profile"
        let spaces = state.spaces(in: profile).map(\.name)
        var message = "Its favourites are closed, and its cookies and site data are deleted, which signs you out of every site on it."
        if !spaces.isEmpty { message += " \(spaces.joined(separator: ", ")) will move to \(fallback)." }
        if profile.usesSharedStore {
            message = "Its favourites are closed. Its sign-ins stay, since this profile uses Tuff’s original website data."
                + (spaces.isEmpty ? "" : " \(spaces.joined(separator: ", ")) will move to \(fallback).")
        }
        let profile = profile
        Task { @MainActor in
            let confirmed = await PromptPresenter.present(Prompt(
                host: .settings, symbol: "trash.fill", symbolColor: .systemRed,
                title: "Delete “\(profile.name)”?", message: message,
                confirmTitle: "Delete Profile", destructive: true
            ))
            if confirmed { state.delete(profile) }
        }
    }
}
