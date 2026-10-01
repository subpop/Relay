// Copyright 2026 Link Dupont
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import SwiftUI
import UniformTypeIdentifiers

/// The Account tab of the Settings window, displaying the user's profile avatar,
/// display name, user ID, account info, room directories, and logout/cache actions.
struct SettingsAccountTab: View {
    @Environment(RelayClient.self) private var client
    @Environment(\.errorReporter) private var errorReporter

    @State private var displayName = ""
    @State private var savedDisplayName = ""
    @State private var avatarURL: String?
    @State private var isEditingDisplayName = false
    @State private var editedDisplayName = ""
    @State private var showImagePicker = false
    @State private var showLogoutConfirmation = false
    @State private var showClearCacheConfirmation = false

    @State private var deviceId: String?

    @State private var directoryServers: [RoomDirectoryServer] = RoomDirectoryStore.load()
    @State private var selectedDirectoryIDs: Set<RoomDirectoryServer.ID> = []
    @State private var focusDirectoryID: RoomDirectoryServer.ID?
    @State private var directoryInputError: String?

    private var userId: String? { client.userId() }

    private var resolvedDisplayName: String {
        displayName.isEmpty ? (userId ?? "?") : displayName
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    AvatarView(
                        name: resolvedDisplayName,
                        mxcURL: avatarURL,
                        size: 80,
                        colorID: userId
                    )
                    .badge(at: .bottomTrailing) {
                        Button { showImagePicker = true } label: {
                            Image(systemName: "camera.fill")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .badgeIcon(fill: .tint, diameter: 22)
                        }
                        .buttonStyle(.plain)
                        .help("Change photo")
                    }
                    .badge(at: .bottomLeading) {
                        if avatarURL != nil {
                            Button {
                                Task { await removeAvatar() }
                            } label: {
                                Image(systemName: "trash.fill")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.white)
                                    .badgeIcon(fill: .red, diameter: 22)
                            }
                            .buttonStyle(.plain)
                            .help("Remove photo")
                        }
                    }

                    VStack(spacing: 2) {
                        Text(displayName.isEmpty ? "Not set" : displayName)
                            .font(.title2)
                            .bold()

                        if let userId {
                            Text(userId)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section("Account Info") {
                LabeledContent("Display Name") {
                    if isEditingDisplayName {
                        HStack(spacing: 6) {
                            TextField("Display Name", text: $editedDisplayName)
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                                .onSubmit { saveDisplayName() }

                            Button("Save Display Name", systemImage: "checkmark.circle.fill") {
                                saveDisplayName()
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tint)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Text(displayName.isEmpty ? "Not set" : displayName)
                                .foregroundStyle(displayName.isEmpty ? .secondary : .primary)

                            Button("Edit Display Name", systemImage: "pencil") {
                                editedDisplayName = displayName
                                isEditingDisplayName = true
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                if let userId {
                    CopyableLabeledContent("User ID", value: userId)
                }
                if let homeserver = client.homeserver()?.absoluteString {
                    CopyableLabeledContent("Homeserver", value: homeserver)
                }
                if let deviceId {
                    CopyableLabeledContent("Device ID", value: deviceId)
                }
            }

            Section {
                if let homeServerName = client.homeServerName() {
                    LabeledContent(content: {
                        Text(homeServerName)
                    }, label: {
                        Text("Homeserver")
                    })
                }
                VStack(spacing: 0) {
                    Table($directoryServers, selection: $selectedDirectoryIDs) {
                        TableColumn("Enable") { server in
                            Toggle(
                                "Show \(server.wrappedValue.serverName) in Browse Rooms",
                                isOn: server.isEnabled
                            )
                            .labelsHidden()
                            .onChange(of: server.wrappedValue.isEnabled) { _, _ in
                                persistDirectories()
                            }
                        }
                        .width(40)

                        TableColumn("Server") { server in
                            DirectoryNameCell(
                                server: server,
                                existingNames: directoryNamesExcluding(server.wrappedValue.id),
                                autofocus: server.wrappedValue.id == focusDirectoryID,
                                onError: { directoryInputError = $0 },
                                onPersist: persistDirectories,
                                onRemove: { removeDirectory(id: server.wrappedValue.id) }
                            )
                        }
                    }
                    .frame(height: directoryListHeight)

                    Divider()

                    HStack(spacing: 6) {
                        Button("Add directory", systemImage: "plus") {
                            let server = RoomDirectoryServer(serverName: "")
                            directoryServers.append(server)
                            selectedDirectoryIDs = [server.id]
                            focusDirectoryID = server.id
                            directoryInputError = nil
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .help("Add directory")

                        Divider()
                            .frame(height: 14)

                        Button("Remove directory", systemImage: "minus") {
                            removeSelectedDirectories()
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .disabled(selectedDirectoryIDs.isEmpty)
                        .help("Remove directory")

                        Spacer()

                        Button("Restore Defaults") {
                            directoryServers = [
                                RoomDirectoryServer(serverName: RoomDirectoryStore.defaultServerName)
                            ]
                            selectedDirectoryIDs = []
                            persistDirectories()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }
                .clipShape(.rect(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(.separator)
                }

                if let directoryInputError {
                    Text(directoryInputError)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Public Rooms")
                Text("In addition to your homeserver, search these servers for public rooms.")
            }

            Section("Advanced") {
                HStack {
                    Button("Clear Cache…") {
                        showClearCacheConfirmation = true
                    }
                    Spacer()
                    Button("Log Out…", role: .destructive) {
                        showLogoutConfirmation = true
                    }
                    .tint(.red)
                }

            }
        }
        .formStyle(.grouped)
        .task(id: client.syncState) {
            guard client.syncState == .running else { return }
            let name = await client.userDisplayName() ?? ""
            displayName = name
            savedDisplayName = name
            avatarURL = await client.userAvatarURL()
            deviceId = await client.deviceId()
        }
        .fileImporter(
            isPresented: $showImagePicker,
            allowedContentTypes: [.png, .jpeg, .gif],
            allowsMultipleSelection: false
        ) { result in
            handleImageSelection(result)
        }
        .alert("Log Out", isPresented: $showLogoutConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Log Out", role: .destructive) {
                Task { await client.logout(reason: "settings sign-out") }
            }
        } message: {
            Text("Are you sure you want to log out? You will need to sign in again.")
        }
        .alert("Clear Cache", isPresented: $showClearCacheConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Cache", role: .destructive) {
                Task { await client.clearLocalData() }
            }
        } message: {
            Text(
                "This will delete all locally cached data and resync from the server. You will remain logged in."
            )
        }
    }

    // MARK: - Actions

    /// Table height: header plus one row per server, scrolling past five.
    private var directoryListHeight: CGFloat {
        min(28 + CGFloat(max(directoryServers.count, 1)) * 30, 208)
    }

    /// Server names already taken by the homeserver and every directory
    /// except the given one, for rename validation.
    private func directoryNamesExcluding(_ id: RoomDirectoryServer.ID) -> Set<String> {
        var names = Set(directoryServers.filter { $0.id != id }.map(\.serverName))
        if let home = client.homeServerName() {
            names.insert(home)
        }
        return names
    }

    private func removeDirectory(id: RoomDirectoryServer.ID) {
        directoryServers.removeAll { $0.id == id }
        selectedDirectoryIDs.remove(id)
        if focusDirectoryID == id {
            focusDirectoryID = nil
        }
        persistDirectories()
    }

    private func removeSelectedDirectories() {
        directoryServers.removeAll { selectedDirectoryIDs.contains($0.id) }
        selectedDirectoryIDs = []
        persistDirectories()
    }

    private func persistDirectories() {
        RoomDirectoryStore.save(directoryServers)
    }

    private func saveDisplayName() {
        let trimmed = editedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != savedDisplayName else {
            isEditingDisplayName = false
            return
        }
        Task {
            do {
                try await client.setDisplayName(trimmed)
                displayName = trimmed
                savedDisplayName = trimmed
            } catch {
                errorReporter.report(.displayNameUpdateFailed(error.localizedDescription))
            }
            isEditingDisplayName = false
        }
    }

    private func handleImageSelection(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else { return }
        let ext = url.pathExtension.lowercased()
        let mimeType: String = switch ext {
        case "png": "image/png"
        case "gif": "image/gif"
        default: "image/jpeg"
        }
        Task {
            do {
                try await client.uploadUserAvatar(mimeType: mimeType, data: data)
                avatarURL = await client.userAvatarURL()
            } catch {
                errorReporter.report(.avatarUpdateFailed(error.localizedDescription))
            }
        }
    }

    private func removeAvatar() async {
        do {
            try await client.removeUserAvatar()
            avatarURL = nil
        } catch {
            errorReporter.report(.avatarUpdateFailed(error.localizedDescription))
        }
    }
}

// MARK: - Directory Name Cell

/// The editable server-name cell of the directories table. The name
/// commits on Return or focus loss (normalized, duplicate-checked);
/// committing an empty name on a new row removes it.
private struct DirectoryNameCell: View {
    @Binding var server: RoomDirectoryServer
    var existingNames: Set<String>
    var autofocus: Bool = false
    var onError: (String?) -> Void = { _ in }
    var onPersist: () -> Void = {}
    var onRemove: () -> Void = {}

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onSubmit { commit() }
            .onAppear {
                draft = server.serverName
                if autofocus {
                    Task { isFocused = true }
                }
            }
            .onChange(of: server.serverName) { _, newValue in
                if !isFocused {
                    draft = newValue
                }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    commit()
                }
            }
    }

    private func commit() {
        guard draft != server.serverName else {
            onError(nil)
            return
        }
        guard let normalized = RoomDirectoryStore.normalize(draft) else {
            if server.serverName.isEmpty {
                onRemove()
            } else {
                draft = server.serverName
            }
            onError(nil)
            return
        }
        guard !existingNames.contains(normalized) else {
            draft = server.serverName
            onError("\(normalized) is already listed.")
            return
        }
        server.serverName = normalized
        draft = normalized
        onError(nil)
        onPersist()
    }
}

// MARK: - Copyable Labeled Content

/// A read-only labeled row with a copy button, used for account info fields.
private struct CopyableLabeledContent: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(value)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Copy \(label)", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    TabView {
        SettingsAccountTab()
            .tabItem { Label("Account", systemImage: "person.crop.circle") }
    }
    .environment(PreviewFixtures.previewClient())
    .frame(width: 480)
}
