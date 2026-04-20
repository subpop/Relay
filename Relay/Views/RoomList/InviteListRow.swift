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

/// A sidebar row for a room the user has been invited to but not yet joined.
///
/// ``InviteListRow`` is visually distinct from ``RoomListRow``, showing the room
/// avatar, name, inviter information, and an inline Join button. A swipe action
/// reveals a Decline button for rejecting the invitation.
struct InviteListRow: View {
    let room: RoomSummary
    let onAccept: () -> Void
    let onDecline: () -> Void
    let onTap: () -> Void

    @State private var isAccepting = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                AvatarView(name: room.name, mxcURL: room.avatarURL, size: 48)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        if room.isSpace {
                            Image(systemName: "square.stack.3d.up")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(room.name)
                            .font(.headline)
                            .bold()
                            .lineLimit(1)
                    }

                    if let inviterName = room.inviterName {
                        Text("Invited by **\(inviterName)**")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Pending invitation")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(4)

                Spacer()

                if isAccepting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Join") {
                        isAccepting = true
                        onAccept()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Previews

#Preview("Invite Row") {
    InviteListRow(
        room: RoomSummary(
            id: "!invite:matrix.org",
            name: "Design Team",
            membership: .invited,
            inviterName: "Alice"
        ),
        onAccept: {},
        onDecline: {},
        onTap: {}
    )
    .frame(width: 300)
}

#Preview("Invite Row - No Inviter") {
    InviteListRow(
        room: RoomSummary(
            id: "!invite2:matrix.org",
            name: "Engineering",
            membership: .invited
        ),
        onAccept: {},
        onDecline: {},
        onTap: {}
    )
    .frame(width: 300)
}

#Preview("Invite Row - DM") {
    InviteListRow(
        room: RoomSummary(
            id: "!dm-invite:matrix.org",
            name: "Bob",
            isDirect: true,
            membership: .invited,
            inviterName: "Bob"
        ),
        onAccept: {},
        onDecline: {},
        onTap: {}
    )
    .frame(width: 300)
}
