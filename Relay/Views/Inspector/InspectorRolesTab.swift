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

/// The Roles & Permissions tab of the timeline inspector, showing members grouped
/// by role with the ability to promote or demote members.
struct InspectorRolesTab: View {
    let viewModel: TimelineInspectorViewModel

    @State private var memberToPromote: RoomMemberDetails?
    @State private var selectedRole: RoomMemberDetails.Role = .user
    @Environment(\.errorReporter) private var errorReporter

    private var administrators: [RoomMemberDetails] {
        viewModel.allMembers.filter { $0.role == .administrator }
    }

    private var moderators: [RoomMemberDetails] {
        viewModel.allMembers.filter { $0.role == .moderator }
    }

    private var users: [RoomMemberDetails] {
        viewModel.allMembers.filter { $0.role == .user }
    }

    private var canEditRoles: Bool {
        guard let currentUserId = viewModel.currentUserId else { return false }
        return viewModel.allMembers.first { $0.userId == currentUserId }?.role == .administrator
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !administrators.isEmpty {
                    roleGroup(
                        title: "Administrators",
                        icon: "crown",
                        color: .orange,
                        members: administrators,
                        powerLevelLabel: "100"
                    )
                }

                if !moderators.isEmpty {
                    roleGroup(
                        title: "Moderators",
                        icon: "shield.fill",
                        color: .blue,
                        members: moderators,
                        powerLevelLabel: "50"
                    )
                }

                if !users.isEmpty {
                    roleGroup(
                        title: "Members",
                        icon: "person",
                        color: .secondary,
                        members: users,
                        powerLevelLabel: "0"
                    )
                }

                if viewModel.allMembers.isEmpty && !viewModel.isLoadingMembers {
                    ContentUnavailableView(
                        "No Members",
                        systemImage: "person.2.slash",
                        description: Text("Member information is not available.")
                    )
                }
            }
            .padding(.vertical)
        }
        .task {
            await viewModel.loadAllMembers()
        }
        .confirmationDialog(
            "Change Role",
            isPresented: Binding(
                get: { memberToPromote != nil },
                set: { if !$0 { memberToPromote = nil } }
            ),
            presenting: memberToPromote
        ) { member in
            Button("Administrator (100)") {
                changeRole(member: member, powerLevel: 100)
            }
            Button("Moderator (50)") {
                changeRole(member: member, powerLevel: 50)
            }
            Button("Member (0)") {
                changeRole(member: member, powerLevel: 0)
            }
            Button("Cancel", role: .cancel) {}
        } message: { member in
            Text("Change role for \(member.displayName ?? member.userId)")
        }
    }

    // MARK: - Role Group

    private func roleGroup(
        title: String,
        icon: String,
        color: Color,
        members: [RoomMemberDetails],
        powerLevelLabel: String
    ) -> some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(
                    members.enumerated(), id: \.element.id
                ) { index, member in
                    if index > 0 {
                        Divider().padding(.vertical, 4)
                    }
                    roleRow(member: member)
                }
            }
            .padding(.vertical, 2)
        } label: {
            HStack {
                Label("\(title) (\(members.count))", systemImage: icon)
                    .font(.caption)
                    .foregroundStyle(color)
                Spacer()
                Text("PL \(powerLevelLabel)")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Role Row

    private func roleRow(member: RoomMemberDetails) -> some View {
        HStack(spacing: 8) {
            AvatarView(
                name: member.displayName ?? member.userId,
                mxcURL: member.avatarURL,
                size: 24
            )

            VStack(alignment: .leading, spacing: 0) {
                Text(member.displayName ?? member.userId)
                    .font(.callout)
                    .lineLimit(1)

                Text("\(member.powerLevel)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if canEditRoles, member.userId != viewModel.currentUserId {
                Button("Change", systemImage: "arrow.up.arrow.down") {
                    memberToPromote = member
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .help("Change Role")
            }
        }
    }

    // MARK: - Actions

    private func changeRole(member: RoomMemberDetails, powerLevel: Int64) {
        Task {
            do {
                try await viewModel.setMemberPowerLevel(
                    userId: member.userId,
                    powerLevel: powerLevel
                )
            } catch {
                errorReporter.report(.notificationSettingsFailed(error.localizedDescription))
            }
        }
    }
}

#Preview {
    InspectorRolesTab(viewModel: .preview())
        .environment(\.matrixService, PreviewMatrixService())
        .environment(\.errorReporter, ErrorReporter())
        .frame(width: 280, height: 600)
}
