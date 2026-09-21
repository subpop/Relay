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

import MatrixKit
import SwiftUI

/// The Security & Privacy tab of the timeline inspector, showing room access settings,
/// encryption status, and history visibility.
///
/// When the current user has sufficient power level, the join rule, history visibility,
/// and directory visibility become editable. Each section is gated by the corresponding
/// fine-grained permission from ``RoomPermissions``.
struct InspectorSecurityTab: View {
    let viewModel: TimelineInspectorViewModel

    @State private var isSaving = false

    /// Directory visibility is a server-side setting that requires admin privileges.
    private var canEditVisibility: Bool { viewModel.isCurrentUserAdmin }
    private var canEditJoinRules: Bool { viewModel.canEditJoinRules }
    private var canEditHistoryVisibility: Bool { viewModel.canEditHistoryVisibility }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let details = viewModel.details {
                    encryptionSection(details)
                    visibilitySection(details)
                    joinRuleSection(details)
                    historySection(details)
                } else if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    ContentUnavailableView {
                        Label("Couldn't Load Room", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(viewModel.loadError ?? "Room details are unavailable.")
                    } actions: {
                        Button("Retry") {
                            Task { await viewModel.retryLoading() }
                        }
                        .buttonStyle(.bordered)
                    }
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
            if canEditVisibility {
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
            if canEditJoinRules {
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

                    Text(RoomAccessLabels.joinRuleDescription(details.joinRule))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 24)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            } else {
                SecurityStatusRow(
                    icon: RoomAccessLabels.joinRuleIcon(details.joinRule),
                    color: .secondary,
                    title: RoomAccessLabels.joinRuleLabel(details.joinRule),
                    detail: RoomAccessLabels.joinRuleDescription(details.joinRule)
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
            if canEditHistoryVisibility {
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

                    Text(RoomAccessLabels.historyDescription(details.historyVisibility))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 24)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            } else {
                SecurityStatusRow(
                    icon: RoomAccessLabels.historyIcon(details.historyVisibility),
                    color: RoomAccessLabels.historyColor(details.historyVisibility),
                    title: RoomAccessLabels.historyLabel(details.historyVisibility),
                    detail: RoomAccessLabels.historyDescription(details.historyVisibility)
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
        .frame(width: 280, height: 600)
}
#Preview("Admin") {
    InspectorSecurityTab(viewModel: .preview(asAdmin: true))
        .frame(width: 280, height: 600)
}

