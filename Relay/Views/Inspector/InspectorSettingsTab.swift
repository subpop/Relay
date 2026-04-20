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

/// The Settings tab of the inspector, shown only for spaces. When the current user
/// is an admin, editable controls are shown for the space's name, topic, avatar,
/// join rule, directory visibility, and history visibility. Non-admins see read-only
/// status rows matching the pattern used by ``InspectorSecurityTab``.
struct InspectorSettingsTab: View {
    let viewModel: TimelineInspectorViewModel

    @State private var name = ""
    @State private var topic = ""
    @State private var joinRule = "invite"
    @State private var isPublic = false
    @State private var historyVisibility = "shared"
    @State private var isSaving = false
    @State private var showImagePicker = false
    @State private var hasPopulated = false

    private var canEdit: Bool { viewModel.isCurrentUserAdmin }

    var body: some View {
        Group {
            if let details = viewModel.details {
                settingsContent(details)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .disabled(isSaving)
        .fileImporter(
            isPresented: $showImagePicker,
            allowedContentTypes: [.png, .jpeg, .gif],
            allowsMultipleSelection: false
        ) { result in
            handleImageSelection(result)
        }
        .onChange(of: viewModel.isLoading) {
            populateFromDetails()
        }
        .onAppear {
            populateFromDetails()
        }
    }

    // MARK: - Content

    private func settingsContent(_ details: RoomDetails) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                identitySection(details)
                if canEdit {
                    avatarSection(details)
                }
                accessSection(details)
                visibilitySection(details)
                historySection(details)
            }
            .padding(.vertical)
        }
    }

    // MARK: - Identity

    private func identitySection(_ details: RoomDetails) -> some View {
        GroupBox {
            if canEdit {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Space Name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout)
                            .onSubmit { saveName(details) }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Topic")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Topic", text: $topic, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout)
                            .lineLimit(2...4)
                            .onSubmit { saveTopic(details) }
                    }
                }
                .padding(.vertical, 2)
            } else {
                VStack(spacing: 0) {
                    InspectorInfoRow(label: "Name", value: details.name)
                    if let topic = details.topic, !topic.isEmpty {
                        Divider().padding(.vertical, 4)
                        InspectorInfoRow(label: "Topic", value: topic)
                    }
                }
                .padding(.vertical, 2)
            }
        } label: {
            Label("Identity", systemImage: "textformat")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    // MARK: - Avatar (admin only)

    private func avatarSection(_ details: RoomDetails) -> some View {
        GroupBox {
            HStack {
                AvatarView(
                    name: name,
                    mxcURL: details.avatarURL,
                    size: 40
                )

                VStack(alignment: .leading, spacing: 4) {
                    Button("Change\u{2026}", systemImage: "photo") {
                        showImagePicker = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if details.avatarURL != nil {
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            removeAvatar()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Spacer()
            }
            .padding(.vertical, 2)
        } label: {
            Label("Avatar", systemImage: "person.crop.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    // MARK: - Access (Join Rule)

    private func accessSection(_ details: RoomDetails) -> some View {
        GroupBox {
            if canEdit {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Join Rule", selection: $joinRule) {
                        Label("Anyone Can Join", systemImage: "globe").tag("public")
                        Label("Invite Only", systemImage: "envelope").tag("invite")
                        Label("Request to Join", systemImage: "hand.raised").tag("knock")
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)

                    Text(joinRuleDescription(joinRule))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 24)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .onChange(of: joinRule) {
                    saveJoinRule()
                }
            } else {
                SecurityStatusRow(
                    icon: joinRuleIcon(details.joinRule),
                    color: .secondary,
                    title: joinRuleLabel(details.joinRule),
                    detail: joinRuleDescription(details.joinRule)
                )
                .padding(.vertical, 2)
            }
        } label: {
            Label("Who Can Join", systemImage: "door.left.hand.open")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    // MARK: - Visibility

    private func visibilitySection(_ details: RoomDetails) -> some View {
        GroupBox {
            if canEdit {
                Toggle(isOn: $isPublic) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Listed in Room Directory")
                            .font(.callout)
                        Text(isPublic
                             ? "This space appears in the public directory."
                             : "This space is hidden from the public directory.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 2)
                .onChange(of: isPublic) {
                    saveVisibility()
                }
            } else {
                SecurityStatusRow(
                    icon: details.isPublic ? "globe" : "eye.slash",
                    color: details.isPublic ? .blue : .secondary,
                    title: details.isPublic ? "Public Directory" : "Private",
                    detail: details.isPublic
                        ? "This space appears in the public directory."
                        : "This space is hidden from the public directory."
                )
                .padding(.vertical, 2)
            }
        } label: {
            Label("Directory Visibility", systemImage: "globe")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    // MARK: - History Visibility

    private func historySection(_ details: RoomDetails) -> some View {
        GroupBox {
            if canEdit {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("History Visibility", selection: $historyVisibility) {
                        Label("Since Joined", systemImage: "person.badge.key").tag("joined")
                        Label("Since Invited", systemImage: "envelope").tag("invited")
                        Label("Full History", systemImage: "person.2").tag("shared")
                        Label("Anyone (World Readable)", systemImage: "globe").tag("world_readable")
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)

                    Text(historyDescription(historyVisibility))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 24)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .onChange(of: historyVisibility) {
                    saveHistoryVisibility()
                }
            } else {
                SecurityStatusRow(
                    icon: historyIcon(details.historyVisibility),
                    color: historyColor(details.historyVisibility),
                    title: historyLabel(details.historyVisibility),
                    detail: historyDescription(details.historyVisibility)
                )
                .padding(.vertical, 2)
            }
        } label: {
            Label("Who Can Read History", systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    // MARK: - Populate

    private func populateFromDetails() {
        guard let details = viewModel.details, !hasPopulated else { return }
        name = details.name
        topic = details.topic ?? ""
        joinRule = details.joinRule ?? "invite"
        isPublic = details.isPublic
        historyVisibility = details.historyVisibility ?? "shared"
        hasPopulated = true
    }

    // MARK: - Save Actions

    private func saveName(_ details: RoomDetails) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != details.name else { return }
        performUpdate { try await viewModel.setRoomName(trimmed) }
    }

    private func saveTopic(_ details: RoomDetails) {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (details.topic ?? "") else { return }
        performUpdate { try await viewModel.setRoomTopic(trimmed) }
    }

    private func saveJoinRule() {
        performUpdate { try await viewModel.updateJoinRule(joinRule) }
    }

    private func saveVisibility() {
        performUpdate { try await viewModel.updateRoomVisibility(isPublic: isPublic) }
    }

    private func saveHistoryVisibility() {
        performUpdate { try await viewModel.updateHistoryVisibility(historyVisibility) }
    }

    private func removeAvatar() {
        performUpdate { try await viewModel.removeRoomAvatar() }
    }

    private func handleImageSelection(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else { return }
        let mimeType = mimeTypeForURL(url)
        performUpdate { try await viewModel.uploadRoomAvatar(mimeType: mimeType, data: data) }
    }

    private func performUpdate(_ action: @escaping () async throws -> Void) {
        isSaving = true
        Task {
            defer { isSaving = false }
            try? await action()
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

    // MARK: - Label Helpers

    private func joinRuleLabel(_ rule: String?) -> String {
        switch rule {
        case "public": "Anyone Can Join"
        case "invite": "Invite Only"
        case "knock": "Request to Join"
        case "restricted": "Restricted"
        default: "Unknown"
        }
    }

    private func joinRuleIcon(_ rule: String?) -> String {
        switch rule {
        case "public": "globe"
        case "invite": "envelope"
        case "knock": "hand.raised"
        default: "questionmark.circle"
        }
    }

    private func joinRuleDescription(_ rule: String?) -> String {
        switch rule {
        case "public": "Anyone can join this space without an invitation."
        case "invite": "Users must receive an invitation to join this space."
        case "knock": "Users can request to join. Admins must approve each request."
        case "restricted": "Users can join if they meet specific conditions."
        default: "The join rule for this space is not configured."
        }
    }

    private func historyLabel(_ visibility: String?) -> String {
        switch visibility {
        case "world_readable": "Anyone (World Readable)"
        case "shared": "Full History"
        case "invited": "Since Invited"
        case "joined": "Since Joined"
        default: "Unknown"
        }
    }

    private func historyIcon(_ visibility: String?) -> String {
        switch visibility {
        case "world_readable": "globe"
        case "shared": "person.2"
        case "invited": "envelope"
        case "joined": "person.badge.key"
        default: "questionmark.circle"
        }
    }

    private func historyColor(_ visibility: String?) -> Color {
        switch visibility {
        case "world_readable": .blue
        case "shared": .green
        case "invited": .orange
        case "joined": .secondary
        default: .secondary
        }
    }

    private func historyDescription(_ visibility: String?) -> String {
        switch visibility {
        case "world_readable": "Anyone can read the history, even without joining."
        case "shared": "Members can see the full history from before they joined."
        case "invited": "Members can see history from the point they were invited."
        case "joined": "Members can only see history from the point they joined."
        default: "History visibility is not configured."
        }
    }
}

#Preview("Admin") {
    InspectorSettingsTab(viewModel: .preview(context: .space, asAdmin: true))
        .environment(\.matrixService, PreviewMatrixService())
        .frame(width: 280, height: 700)
}

#Preview("Read Only") {
    InspectorSettingsTab(viewModel: .preview(context: .space))
        .environment(\.matrixService, PreviewMatrixService())
        .frame(width: 280, height: 700)
}
