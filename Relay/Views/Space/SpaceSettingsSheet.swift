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

import RelayInterface
import SwiftUI
import UniformTypeIdentifiers

/// A sheet for editing the settings of a space (name, topic, avatar,
/// join rules, visibility, and history visibility).
///
/// Only presented when the current user has admin privileges in the space.
/// Changes are saved individually as each field is committed, matching the
/// behavior of the existing room security settings.
struct SpaceSettingsSheet: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.errorReporter) private var errorReporter
    @Environment(\.dismiss) private var dismiss

    let spaceId: String
    let initialDetails: RoomDetails

    @State private var name: String
    @State private var topic: String
    @State private var joinRule: String
    @State private var isPublic: Bool
    @State private var historyVisibility: String
    @State private var isSaving = false
    @State private var showImagePicker = false

    init(spaceId: String, details: RoomDetails) {
        self.spaceId = spaceId
        self.initialDetails = details
        _name = State(initialValue: details.name)
        _topic = State(initialValue: details.topic ?? "")
        _joinRule = State(initialValue: details.joinRule ?? "invite")
        _isPublic = State(initialValue: details.isPublic)
        _historyVisibility = State(initialValue: details.historyVisibility ?? "shared")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            settingsForm
        }
        .frame(width: 460, height: 520)
        .disabled(isSaving)
        .fileImporter(
            isPresented: $showImagePicker,
            allowedContentTypes: [.png, .jpeg, .gif],
            allowsMultipleSelection: false
        ) { result in
            handleImageSelection(result)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Space Settings")
                .font(.headline)

            Spacer()

            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding()
    }

    // MARK: - Form

    private var settingsForm: some View {
        Form {
            Section("Identity") {
                identitySection
            }

            Section("Access") {
                accessSection
            }

            Section("Visibility") {
                visibilitySection
            }

            Section("History") {
                historySection
            }

            Section {
                avatarSection
            } header: {
                Text("Avatar")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Identity

    private var identitySection: some View {
        Group {
            TextField("Space Name", text: $name)
                .onSubmit { saveName() }

            TextField("Topic", text: $topic, axis: .vertical)
                .lineLimit(3...6)
                .onSubmit { saveTopic() }
        }
    }

    // MARK: - Access (Join Rule)

    private var accessSection: some View {
        Picker("Who Can Join", selection: $joinRule) {
            Label("Anyone Can Join", systemImage: "globe").tag("public")
            Label("Invite Only", systemImage: "envelope").tag("invite")
            Label("Request to Join", systemImage: "hand.raised").tag("knock")
        }
        .pickerStyle(.radioGroup)
        .onChange(of: joinRule) {
            saveJoinRule()
        }
    }

    // MARK: - Visibility

    private var visibilitySection: some View {
        Toggle(isOn: $isPublic) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Listed in Room Directory")
                Text(isPublic
                     ? "This space appears in the public directory."
                     : "This space is hidden from the public directory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: isPublic) {
            saveVisibility()
        }
    }

    // MARK: - History Visibility

    private var historySection: some View {
        Picker("Who Can Read History", selection: $historyVisibility) {
            Label("Since Joined", systemImage: "person.badge.key").tag("joined")
            Label("Since Invited", systemImage: "envelope").tag("invited")
            Label("Full History", systemImage: "person.2").tag("shared")
            Label("Anyone (World Readable)", systemImage: "globe").tag("world_readable")
        }
        .pickerStyle(.radioGroup)
        .onChange(of: historyVisibility) {
            saveHistoryVisibility()
        }
    }

    // MARK: - Avatar

    private var avatarSection: some View {
        HStack {
            AvatarView(
                name: name,
                mxcURL: initialDetails.avatarURL,
                size: 48
            )

            VStack(alignment: .leading, spacing: 4) {
                Button("Change Avatar\u{2026}", systemImage: "photo") {
                    showImagePicker = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if initialDetails.avatarURL != nil {
                    Button("Remove Avatar", systemImage: "trash", role: .destructive) {
                        removeAvatar()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Spacer()
        }
    }

    // MARK: - Save Actions

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != initialDetails.name else { return }
        performUpdate { try await matrixService.setRoomName(roomId: spaceId, name: trimmed) }
    }

    private func saveTopic() {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (initialDetails.topic ?? "") else { return }
        performUpdate { try await matrixService.setRoomTopic(roomId: spaceId, topic: trimmed) }
    }

    private func saveJoinRule() {
        performUpdate { try await matrixService.updateJoinRule(roomId: spaceId, rule: joinRule) }
    }

    private func saveVisibility() {
        performUpdate { try await matrixService.updateRoomVisibility(roomId: spaceId, isPublic: isPublic) }
    }

    private func saveHistoryVisibility() {
        performUpdate {
            try await matrixService.updateHistoryVisibility(roomId: spaceId, visibility: historyVisibility)
        }
    }

    private func removeAvatar() {
        performUpdate { try await matrixService.removeRoomAvatar(roomId: spaceId) }
    }

    private func handleImageSelection(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else { return }
        let mimeType = mimeTypeForURL(url)
        performUpdate { try await matrixService.uploadRoomAvatar(roomId: spaceId, mimeType: mimeType, data: data) }
    }

    private func performUpdate(_ action: @escaping () async throws -> Void) {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await action()
            } catch {
                errorReporter.report(.roomJoinFailed(error.localizedDescription))
            }
        }
    }

    private func mimeTypeForURL(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "gif": return "image/gif"
        default: return "image/jpeg"
        }
    }
}

// MARK: - Previews

#Preview {
    SpaceSettingsSheet(
        spaceId: "!space-work:matrix.org",
        details: RoomDetails(
            id: "!space-work:matrix.org",
            name: "Work",
            topic: "Work-related rooms and discussions",
            isPublic: false,
            canonicalAlias: "#work:matrix.org",
            memberCount: 48,
            members: [],
            joinRule: "invite",
            historyVisibility: "shared"
        )
    )
    .environment(\.matrixService, PreviewMatrixService())
}
