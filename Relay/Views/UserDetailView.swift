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

/// Lightweight user identifier used as a navigation value for the inspector panel.
///
/// ``UserProfile`` can be constructed from a ``RoomMemberDetails`` (tapping a member in
/// room info) or from a ``TimelineMessage`` (double-tapping an avatar in the timeline).
struct UserProfile: Hashable {
    /// The Matrix user ID (e.g. `"@alice:matrix.org"`).
    let userId: String

    /// The user's display name, if known.
    let displayName: String?

    /// The `mxc://` URL of the user's avatar, if available.
    let avatarURL: String?

    /// The user's role within the room context, if applicable.
    let role: RoomMemberDetails.Role?

    /// Creates a ``UserProfile`` with explicit values.
    init(userId: String, displayName: String? = nil, avatarURL: String? = nil, role: RoomMemberDetails.Role? = nil) {
        self.userId = userId
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.role = role
    }

    /// Creates a ``UserProfile`` from a room member's details.
    init(member: RoomMemberDetails) {
        self.userId = member.userId
        self.displayName = member.displayName
        self.avatarURL = member.avatarURL
        self.role = member.role
    }

    /// Creates a ``UserProfile`` from a timeline message's sender information.
    init(message: TimelineMessage) {
        self.userId = message.senderID
        self.displayName = message.senderDisplayName
        self.avatarURL = message.senderAvatarURL
        self.role = nil
    }
}

/// An inspector panel that displays a user's avatar, display name, Matrix ID, and room role.
struct UserDetailView: View {
    /// The user profile to display.
    let profile: UserProfile

    private var name: String {
        profile.displayName ?? profile.userId
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSection
                infoSection
            }
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 6) {
            AvatarView(name: name, mxcURL: profile.avatarURL, size: 80)
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)

            Text(name)
                .font(.title3)
                .fontWeight(.semibold)

            Text(profile.userId)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let role = profile.role, role != .user {
                roleBadge(role)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16)
    }

    private func roleBadge(_ role: RoomMemberDetails.Role) -> some View {
        HStack(spacing: 3) {
            Image(systemName: role == .administrator ? "crown.fill" : "shield.fill")
            Text(role.rawValue.capitalized)
        }
        .font(.caption2)
        .fontWeight(.medium)
        .foregroundStyle(role == .administrator ? .orange : .blue)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((role == .administrator ? Color.orange : Color.blue).opacity(0.1), in: Capsule())
    }

    // MARK: - Info

    private var infoSection: some View {
        GroupBox {
            VStack(spacing: 0) {
                infoRow(label: "Matrix ID", value: profile.userId)

                if let displayName = profile.displayName {
                    Divider().padding(.vertical, 4)
                    infoRow(label: "Display Name", value: displayName)
                }
            }
            .padding(.vertical, 2)
        } label: {
            Label("Info", systemImage: "person.circle")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(1)
        }
    }

}

#Preview {
    UserDetailView(profile: UserProfile(
        userId: "@alice:matrix.org",
        displayName: "Alice",
        avatarURL: nil,
        role: .administrator
    ))
    .frame(width: 260, height: 500)
}
