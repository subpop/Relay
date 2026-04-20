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

/// The Security & Privacy tab of the timeline inspector, showing room access settings,
/// encryption status, and history visibility.
///
/// When the current user is an admin, the join rule, history visibility, and directory
/// visibility become editable. Non-admins see read-only displays.
struct InspectorSecurityTab: View {
    let viewModel: TimelineInspectorViewModel

    @State private var isSaving = false

    private var canEdit: Bool { viewModel.isCurrentUserAdmin }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let details = viewModel.details {
                    encryptionSection(details)
                    visibilitySection(details)
                    joinRuleSection(details)
                    historySection(details)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                }
            }
            .padding(.vertical)
            .disabled(isSaving)
        }
    }

    // MARK: - Encryption

    private func encryptionSection(_ details: RoomDetails) -> some View {
        GroupBox {
            SecurityStatusRow(
                icon: details.isEncrypted ? "lock.fill" : "lock.open",
                color: details.isEncrypted ? .green : .orange,
                title: details.isEncrypted ? "End-to-End Encrypted" : "Not Encrypted",
                detail: details.isEncrypted
                    ? "Messages are secured with end-to-end encryption."
                    : "Messages are not encrypted and may be visible to the server."
            )
            .padding(.vertical, 2)
        } label: {
            Label("Encryption", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    // MARK: - Directory Visibility

    private func visibilitySection(_ details: RoomDetails) -> some View {
        GroupBox {
            if canEdit {
                Toggle(isOn: Binding(
                    get: { details.isPublic },
                    set: { newValue in
                        performUpdate { try await viewModel.updateRoomVisibility(isPublic: newValue) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Listed in Room Directory")
                            .font(.callout)
                        Text(details.isPublic
                             ? "This room appears in the public directory."
                             : "This room is hidden from the public directory.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 2)
            } else {
                SecurityStatusRow(
                    icon: details.isPublic ? "globe" : "eye.slash",
                    color: details.isPublic ? .blue : .secondary,
                    title: details.isPublic ? "Public Directory" : "Private",
                    detail: details.isPublic
                        ? "This room appears in the public directory."
                        : "This room is hidden from the public directory."
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

    // MARK: - Join Rule

    private func joinRuleSection(_ details: RoomDetails) -> some View {
        GroupBox {
            if canEdit {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Join Rule", selection: Binding(
                        get: { details.joinRule ?? "invite" },
                        set: { newValue in
                            performUpdate { try await viewModel.updateJoinRule(newValue) }
                        }
                    )) {
                        Label("Anyone Can Join", systemImage: "globe").tag("public")
                        Label("Invite Only", systemImage: "envelope").tag("invite")
                        Label("Request to Join", systemImage: "hand.raised").tag("knock")
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)

                    Text(joinRuleDescription(details.joinRule))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 24)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
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

    // MARK: - History Visibility

    private func historySection(_ details: RoomDetails) -> some View {
        GroupBox {
            if canEdit {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("History Visibility", selection: Binding(
                        get: { details.historyVisibility ?? "shared" },
                        set: { newValue in
                            performUpdate { try await viewModel.updateHistoryVisibility(newValue) }
                        }
                    )) {
                        Label("Since Joined", systemImage: "person.badge.key").tag("joined")
                        Label("Since Invited", systemImage: "envelope").tag("invited")
                        Label("Full History", systemImage: "person.2").tag("shared")
                        Label("Anyone (World Readable)", systemImage: "globe").tag("world_readable")
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)

                    Text(historyDescription(details.historyVisibility))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 24)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
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

    // MARK: - Actions

    private func performUpdate(_ action: @escaping () async throws -> Void) {
        isSaving = true
        Task {
            defer { isSaving = false }
            try? await action()
        }
    }

    // MARK: - Label Helpers

    private func joinRuleLabel(_ rule: String?) -> String {
        switch rule {
        case "public": "Anyone Can Join"
        case "invite": "Invite Only"
        case "knock": "Request to Join"
        case "restricted": "Restricted"
        case "knock_restricted": "Knock (Restricted)"
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
        case "public": "Anyone can join this room without an invitation."
        case "invite": "Users must receive an invitation to join this room."
        case "knock": "Users can request to join. Admins must approve each request."
        case "restricted": "Users can join if they meet specific conditions."
        default: "The join rule for this room is not configured."
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
        case "world_readable": "Anyone can read the room history, even without joining."
        case "shared": "Members can see the full room history from before they joined."
        case "invited": "Members can see history from the point they were invited."
        case "joined": "Members can only see history from the point they joined."
        default: "History visibility is not configured."
        }
    }
}

// MARK: - Security Status Row

/// A read-only row displaying a status icon, title, and detail description.
/// Used in the Security and Settings inspector tabs to show non-editable state.
struct SecurityStatusRow: View {
    let icon: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }
}

#Preview("Read Only") {
    InspectorSecurityTab(viewModel: .preview())
        .environment(\.matrixService, PreviewMatrixService())
        .frame(width: 280, height: 600)
}
#Preview("Admin") {
    InspectorSecurityTab(viewModel: .preview(asAdmin: true))
        .environment(\.matrixService, PreviewMatrixService())
        .frame(width: 280, height: 600)
}

