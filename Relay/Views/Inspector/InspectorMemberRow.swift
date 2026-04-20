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

/// A reusable row displaying a room member's avatar, name, user ID, and role badge.
struct InspectorMemberRow: View {
    let member: RoomMemberDetails

    var body: some View {
        HStack(spacing: 8) {
            AvatarView(
                name: member.displayName ?? member.userId,
                mxcURL: member.avatarURL,
                size: 28
            )

            VStack(alignment: .leading, spacing: 0) {
                Text(member.displayName ?? member.userId)
                    .font(.callout)
                    .lineLimit(1)

                if member.displayName != nil {
                    Text(member.userId)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if member.role != .user {
                MemberRoleBadge(role: member.role)
            }
        }
    }
}

/// A colored capsule badge showing a member's role (Administrator or Moderator).
struct MemberRoleBadge: View {
    let role: RoomMemberDetails.Role

    private var color: Color {
        role == .administrator ? .orange : .blue
    }

    var body: some View {
        Text(role.rawValue.capitalized)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1), in: Capsule())
    }
}
