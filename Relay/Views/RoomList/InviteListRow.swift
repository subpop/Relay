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

    @State private var isAccepting = false
    @Environment(\.hasSpaceRail) private var hasSpaceRail
    @State private var rowWidth: CGFloat = 0

    private static let compactThreshold: CGFloat = 140

    private var isCompact: Bool {
        let effectiveWidth = hasSpaceRail ? rowWidth : rowWidth - SpaceRail.width
        return effectiveWidth < Self.compactThreshold
    }

    var body: some View {
        Group {
            if isCompact {
                compactBody
            } else {
                fullBody
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newValue in
            rowWidth = newValue
        }
        .animation(.default, value: isCompact)
    }

    private var compactBody: some View {
        AvatarView(name: room.name, mxcURL: room.avatarURL, size: 60)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.white)
                    .frame(width: 14, height: 14)
                    .background(.accent, in: .circle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .help(room.name)
    }

    private var fullBody: some View {
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
            .transition(.opacity)

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
        onDecline: {}
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
        onDecline: {}
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
        onDecline: {}
    )
    .frame(width: 300)
}
#Preview("Compact") {
    HStack(spacing: 0) {
        InviteListRow(
            room: RoomSummary(
                id: "!invite:matrix.org",
                name: "Design Team",
                membership: .invited,
                inviterName: "Alice"
            ),
            onAccept: {},
            onDecline: {}
        )

        InviteListRow(
            room: RoomSummary(
                id: "!dm-invite:matrix.org",
                name: "Bob",
                isDirect: true,
                membership: .invited,
                inviterName: "Bob"
            ),
            onAccept: {},
            onDecline: {}
        )
    }
    .frame(width: 200)
}

