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
/// by zero or more characters. It filters the room's member list by display name using
/// `localizedStandardContains` for user-input filtering.
///
/// Keyboard navigation is supported via the compose view model: the parent view updates
/// the selected index in response to Up/Down arrow keys, and reads it back to confirm
/// a selection on Tab or Return.
struct MentionSuggestionView: View {
    @Bindable var compose: ComposeViewModel

    /// Called when a member is selected from the suggestion list.
    let onSelect: (RoomMemberDetails) -> Void

    /// The maximum number of visible suggestions before scrolling.
    private let maxVisible = 6

    /// Estimated height of a single row (vertical padding + avatar + subtitle).
    private let rowHeight: CGFloat = 40

    /// Vertical padding inside the scroll content VStack (top + bottom).
    private let contentPadding: CGFloat = 8

    @State private var scrollPosition = ScrollPosition()

    var body: some View {
        let matches = compose.filteredMentionMembers
        if !matches.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches.enumerated(), id: \.element.id) { index, member in
                        MentionRow(
                            member: member,
                            isSelected: index == compose.mentionSelectedIndex
                        ) {
                            onSelect(member)
                        }
                        .id(member.id)
                        .onHover { hovering in
                            if hovering {
                                compose.mentionSelectedIndex = index
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollPosition($scrollPosition)
            .frame(
                height: CGFloat(min(matches.count, maxVisible)) * rowHeight + contentPadding
            )
            .onChange(of: compose.mentionSelectedIndex) { _, newIndex in
                let clamped = max(0, min(newIndex, matches.count - 1))
                if clamped != newIndex { compose.mentionSelectedIndex = clamped }
                if clamped < matches.count {
                    withAnimation(.easeOut(duration: 0.1)) {
                        scrollPosition.scrollTo(id: matches[clamped].id)
                    }
                }
            }
            .background(
                .ultraThinMaterial, in: .rect(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.15), radius: 12, y: -4)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

/// A single row in the mention suggestion list.
private struct MentionRow: View {
    let member: RoomMemberDetails
    let isSelected: Bool
    var onSelect: () -> Void

    var body: some View {
        Button {
            onSelect()
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
                        .bold()
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
                        .bold()
                        .foregroundStyle(member.role == .administrator ? .orange : .blue)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            (member.role == .administrator ? Color.orange : Color.blue)
                                .opacity(0.1),
                            in: .capsule
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
            compose: {
                let vm = ComposeViewModel()
                vm.members = [
                    RoomMemberDetails(
                        userId: "@alice:matrix.org", displayName: "Alice Smith",
                        role: .administrator
                    ),
                    RoomMemberDetails(
                        userId: "@bob:matrix.org", displayName: "Bob Chen", role: .moderator
                    ),
                    RoomMemberDetails(
                        userId: "@charlie:matrix.org", displayName: "Charlie Davis"
                    ),
                    RoomMemberDetails(
                        userId: "@diana:matrix.org", displayName: "Diana Evans"
                    ),
                ]
                vm.mentionQuery = ""
                return vm
            }(),
            onSelect: { _ in }
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
            compose: {
                let vm = ComposeViewModel()
                vm.members = [
                    RoomMemberDetails(
                        userId: "@alice:matrix.org", displayName: "Alice Smith",
                        role: .administrator
                    ),
                    RoomMemberDetails(
                        userId: "@bob:matrix.org", displayName: "Bob Chen", role: .moderator
                    ),
                    RoomMemberDetails(
                        userId: "@charlie:matrix.org", displayName: "Charlie Davis"
                    ),
                ]
                vm.mentionQuery = "ali"
                return vm
            }(),
            onSelect: { _ in }
        )
        .padding()
    }
    .frame(width: 400, height: 300)
    .environment(\.matrixService, PreviewMatrixService())
}
