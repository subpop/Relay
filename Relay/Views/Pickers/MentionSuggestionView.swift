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
/// substring match) and lets the user select a member to insert a mention pill.
///
/// Keyboard navigation is supported via the `selectedIndex` binding: the parent view updates
/// the index in response to Up/Down arrow keys, and reads it back to confirm a selection
/// on Tab or Return.
struct MentionSuggestionView: View {
    /// The room members available for mention.
    let members: [RoomMemberDetails]

    /// The current query string (characters typed after `@`). Empty string shows all members.
    let query: String

    /// The index of the currently highlighted row, managed by the parent view.
    @Binding var selectedIndex: Int

    /// Called when a member is selected from the suggestion list.
    let onSelect: (RoomMemberDetails) -> Void

    /// Called when the user dismisses the suggestion list (Escape key or click outside).
    let onDismiss: () -> Void

    /// The maximum number of visible suggestions before scrolling.
    private let maxVisible = 6

    /// Estimated height of a single row (vertical padding + avatar + subtitle).
    private let rowHeight: CGFloat = 40

    /// Vertical padding inside the scroll content VStack (top + bottom).
    private let contentPadding: CGFloat = 8

    /// The filtered member list matching the current query.
    var filteredMembers: [RoomMemberDetails] {
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
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, member in
                            memberRow(member, isSelected: index == selectedIndex)
                                .id(member.id)
                                .onHover { hovering in
                                    if hovering {
                                        selectedIndex = index
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: CGFloat(min(matches.count, maxVisible)) * rowHeight + contentPadding)
                .onChange(of: selectedIndex) { _, newIndex in
                    let clamped = max(0, min(newIndex, matches.count - 1))
                    if clamped != newIndex { selectedIndex = clamped }
                    if clamped < matches.count {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(matches[clamped].id, anchor: nil)
                        }
                    }
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.15), radius: 12, y: -4)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func memberRow(_ member: RoomMemberDetails, isSelected: Bool) -> some View {
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
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(MentionRowButtonStyle(isSelected: isSelected))
    }
}

/// A button style for mention suggestion rows with hover and keyboard-selection highlighting.
private struct MentionRowButtonStyle: ButtonStyle {
    let isSelected: Bool
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fillColor(isPressed: configuration.isPressed))
                    .padding(.horizontal, 4)
            )
    }

    private func fillColor(isPressed: Bool) -> Color {
        if isPressed {
            return Color.accentColor.opacity(0.15)
        }
        if isSelected {
            return Color.accentColor.opacity(0.12)
        }
        return Color.clear
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
            selectedIndex: .constant(0),
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
            selectedIndex: .constant(0),
            onSelect: { _ in },
            onDismiss: {}
        )
        .padding()
    }
    .frame(width: 400, height: 300)
    .environment(\.matrixService, PreviewMatrixService())
}
