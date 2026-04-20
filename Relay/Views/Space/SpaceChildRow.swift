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

/// A single row in the space hierarchy list, styled as a grouped card row
/// with an avatar, name, subtitle, and a trailing chevron or join button.
struct SpaceChildRow: View {
    let child: SpaceChild
    var onJoin: (() -> Void)?
    var onTap: (() -> Void)?

    var body: some View {
        Button(action: { onTap?() }) {
            HStack(spacing: 12) {
                avatar

                VStack(alignment: .leading, spacing: 2) {
                    Text(child.name)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    subtitle
                }

                Spacer()

                trailingContent
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var avatar: some View {
        if child.roomType == .space {
            SpaceRailIcon(name: child.name, mxcURL: child.avatarURL)
        } else {
            AvatarView(name: child.name, mxcURL: child.avatarURL, size: 36)
        }
    }

    private var subtitle: some View {
        Group {
            if child.roomType == .space, child.childrenCount > 0 {
                Text("\(child.childrenCount) rooms")
            } else if let topic = child.topic, !topic.isEmpty {
                Text(topic)
            } else if let alias = child.canonicalAlias {
                Text(alias)
            } else if child.memberCount > 0 {
                Text("\(child.memberCount) members")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private var trailingContent: some View {
        if child.roomType == .space {
            // Sub-spaces: show Join button if not joined, always show chevron for browsing
            HStack(spacing: 8) {
                if let onJoin, !child.isJoined {
                    joinButton(action: onJoin)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
            }
        } else if let onJoin, !child.isJoined {
            // Rooms: show Join button when not joined, with invisible chevron
            // as a spacer so all Join buttons align with sub-space rows
            HStack(spacing: 8) {
                joinButton(action: onJoin)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .hidden()
            }
        } else {
            // Rooms: show chevron when joined
            Image(systemName: "chevron.right")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.tertiary)
        }
    }

    private func joinButton(action: @escaping () -> Void) -> some View {
        Button(child.joinRule == .knock ? "Request" : "Join", action: action)
            .buttonStyle(.bordered)
            .tint(.accentColor)
            .controlSize(.small)
    }
}

// MARK: - Previews

#Preview("Joined Room") {
    SpaceChildRow(
        child: SpaceChild(
            roomId: "!room1:matrix.org",
            name: "General",
            topic: "General discussion for the team",
            memberCount: 42,
            isJoined: true,
            canonicalAlias: "#general:matrix.org"
        ),
        onTap: {}
    )
    .environment(\.matrixService, PreviewMatrixService())
    .padding()
}

#Preview("Unjoined Room") {
    SpaceChildRow(
        child: SpaceChild(
            roomId: "!room2:matrix.org",
            name: "Design",
            topic: "UI/UX design discussion",
            memberCount: 15,
            joinRule: .public
        ),
        onJoin: {}
    )
    .environment(\.matrixService, PreviewMatrixService())
    .padding()
}

#Preview("Sub-Space") {
    SpaceChildRow(
        child: SpaceChild(
            roomId: "!space1:matrix.org",
            name: "Engineering",
            memberCount: 30,
            roomType: .space,
            childrenCount: 5
        ),
        onTap: {}
    )
    .environment(\.matrixService, PreviewMatrixService())
    .padding()
}
