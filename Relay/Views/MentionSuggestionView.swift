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

/// A floating suggestion list that displays room members matching the current `@` query.
///
/// ``MentionSuggestionView`` appears above the compose bar when the user types `@` followed
/// by zero or more characters. It filters the room's member list by display name (case-insensitive
/// prefix match) and lets the user select a member to insert a mention pill.
struct MentionSuggestionView: View {
    /// The room members available for mention.
    let members: [RoomMemberDetails]

    /// The current query string (characters typed after `@`). Empty string shows all members.
    let query: String

    /// Called when a member is selected from the suggestion list.
    let onSelect: (RoomMemberDetails) -> Void

    /// Called when the user dismisses the suggestion list (Escape key or click outside).
    let onDismiss: () -> Void

    /// The maximum number of visible suggestions before scrolling.
    private let maxVisible = 6

    private var filteredMembers: [RoomMemberDetails] {
        if query.isEmpty {
            return Array(members.prefix(maxVisible * 2))
        }
        let lowered = query.lowercased()
        return members.filter { member in
            let name = member.displayName ?? member.userId
            return name.lowercased().contains(lowered)
                || member.userId.lowercased().contains(lowered)
        }
    }

    var body: some View {
        let matches = filteredMembers
        if !matches.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { member in
                        memberRow(member)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: CGFloat(min(matches.count, maxVisible)) * 40)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.15), radius: 12, y: -4)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func memberRow(_ member: RoomMemberDetails) -> some View {
        Button {
            onSelect(member)
        } label: {
            HStack(spacing: 8) {
                AvatarView(
                    name: member.displayName ?? member.userId,
                    mxcURL: member.avatarURL,
                    size: 24
                )

                VStack(alignment: .leading, spacing: 0) {
                    Text(member.displayName ?? member.userId)
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    if member.displayName != nil {
                        Text(member.userId)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if member.role != .user {
                    Text(member.role.rawValue.capitalized)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(member.role == .administrator ? .orange : .blue)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            (member.role == .administrator ? Color.orange : Color.blue).opacity(0.1),
                            in: Capsule()
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(MentionRowButtonStyle())
    }
}

/// A button style for mention suggestion rows with subtle hover highlighting.
private struct MentionRowButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed
                        ? Color.accentColor.opacity(0.15)
                        : (isHovering ? Color.primary.opacity(0.05) : Color.clear))
                    .padding(.horizontal, 4)
            )
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

#Preview("Mention Suggestions") {
    VStack {
        Spacer()
        MentionSuggestionView(
            members: [
                RoomMemberDetails(userId: "@alice:matrix.org", displayName: "Alice Smith", role: .administrator),
                RoomMemberDetails(userId: "@bob:matrix.org", displayName: "Bob Chen", role: .moderator),
                RoomMemberDetails(userId: "@charlie:matrix.org", displayName: "Charlie Davis"),
                RoomMemberDetails(userId: "@diana:matrix.org", displayName: "Diana Evans")
            ],
            query: "",
            onSelect: { _ in },
            onDismiss: {}
        )
        .padding()
    }
    .frame(width: 400, height: 300)
    .environment(\.matrixService, PreviewMatrixService())
}

#Preview("Filtered") {
    VStack {
        Spacer()
        MentionSuggestionView(
            members: [
                RoomMemberDetails(userId: "@alice:matrix.org", displayName: "Alice Smith", role: .administrator),
                RoomMemberDetails(userId: "@bob:matrix.org", displayName: "Bob Chen", role: .moderator),
                RoomMemberDetails(userId: "@charlie:matrix.org", displayName: "Charlie Davis")
            ],
            query: "ali",
            onSelect: { _ in },
            onDismiss: {}
        )
        .padding()
    }
    .frame(width: 400, height: 300)
    .environment(\.matrixService, PreviewMatrixService())
}
