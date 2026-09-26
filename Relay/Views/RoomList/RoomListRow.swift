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

import SwiftUI

/// A single room row in the sidebar list, showing the avatar, name, last message preview,
/// unread indicator, and notification mode state.
struct RoomListRow: View {
    let room: RoomRowData

    @Environment(\.hasSpaceRail) private var hasSpaceRail
    @AppStorage("appearance.showUnreadCounts") private var showUnreadCounts = true
    @State private var rowWidth: CGFloat = 0

    private static let compactThreshold: CGFloat = 100

    private var isCompact: Bool {
        let effectiveWidth = hasSpaceRail ? rowWidth : rowWidth - SpaceRail.width
        return effectiveWidth < Self.compactThreshold
    }

    /// Whether the room name should appear bold (has notification-worthy unread activity).
    private var hasVisibleUnread: Bool {
        guard !room.isMuted else { return false }
        return room.notificationCount > 0
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
            .badge(at: .topTrailing) {
                avatarStatusBadge
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .opacity(room.isArchived ? 0.5 : 1)
            .help(room.name)
    }

    private var fullBody: some View {
        HStack(spacing: 10) {
            AvatarView(name: room.name, mxcURL: room.avatarURL, size: 48)
                .badge(at: .topTrailing) {
                    avatarStatusBadge
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(room.name)
                        .font(.headline)
                        .fontWeight(hasVisibleUnread ? .semibold : .regular)
                        .lineLimit(1)

                    Spacer()

                    // swiftlint:disable:next identifier_name
                    if let ts = room.lastMessageTimestamp {
                        Text(Self.formatTimestamp(ts))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    if let msg = room.lastMessage {
                        let author = RoomListRow.formatAuthor(room.lastMessageAuthor)
                        Text(author + AttributedString(msg))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer()

                    unreadIndicator
                }
            }
            .padding(4)
            .transition(.opacity)
        }
        .padding(.vertical, 8)
        .opacity(room.isArchived ? 0.5 : 1)
    }

    /// The avatar's top-trailing badge: a mute icon when the room is
    /// muted, plus the compact row's unread dot, since a narrow row has
    /// no trailing edge to carry the indicator.
    @ViewBuilder
    private var avatarStatusBadge: some View {
        if room.isMuted {
            muteIndicator
        } else if isCompact, hasVisibleUnread {
            unreadDot
        }
    }

    /// A mute icon on the avatar for muted rooms.
    private var muteIndicator: some View {
        Image(systemName: "bell.slash.fill")
            .font(.system(size: 8))
            .foregroundStyle(.white)
            .badgeIcon(fill: Color(.systemGray), diameter: 14)
    }

    /// The compact row's unread dot, in both styles: too narrow for a
    /// count, so it is a large ringed circle — red for attention, blue for
    /// plain unreads.
    private var unreadDot: some View {
        AvatarBadge.dot(color: unreadColor, diameter: 12)
            .padding(1)
            .background(.background, in: .circle)
    }

    /// The full row's trailing unread indicator: the total count when
    /// counts are shown, a bare dot otherwise. Both take their color from
    /// the unread tier.
    @ViewBuilder
    private var unreadIndicator: some View {
        if hasVisibleUnread {
            if showUnreadCounts {
                AvatarBadge.count(room.notificationCount, color: unreadColor)
            } else {
                AvatarBadge.dot(color: unreadColor)
            }
        }
    }

    /// Red for mentions, keyword highlights, or any unread in a DM;
    /// blue for plain unreads in group rooms.
    private var unreadColor: Color {
        room.needsAttention ? Color(.systemRed) : Color(.systemBlue)
    }
}

// MARK: - Helpers
extension RoomListRow {
    /// Formats a message timestamp for display in the room list.
    ///
    /// - Today: "11:54 AM"
    /// - Yesterday: "Yesterday"
    /// - Within the last week: "Wednesday"
    /// - Older: "Apr 3"
    static func formatTimestamp(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else if let daysAgo = calendar.dateComponents([.day], from: date, to: .now).day, daysAgo < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        } else {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
    
    /// Formats an author for preview in the roomlist, always adds a ": " at the end of the name, for easier concatination with the message
    static func formatAuthor(_ author: String?) -> AttributedString {
        let authorName = author ?? "Unknown Sender"
        if let markdown = try? AttributedString(markdown: "**\(authorName)**: ",
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return markdown
        }
        return AttributedString("\(authorName): ")
    }
}

// MARK: - AttributedString Extension

extension AttributedString {
    /// Returns a copy of the attributed string where links are stripped of their
    /// interaction but keep their accent color.
    func visualizeLinksOnly() -> AttributedString {
        var result = self
        var linkRanges: [Range<AttributedString.Index>] = []
        
        for run in result.runs {
            if run.attributes.link != nil {
                linkRanges.append(run.range)
            }
        }
        
        for range in linkRanges {
            result[range].link = nil
        }
        
        return result
    }
}

// MARK: - Previews

#Preview("Plain Unread") {
    RoomListRow(room: PreviewFixtures.rooms[0])
        .frame(width: 300)
}

#Preview("Muted Room") {
    RoomListRow(room: PreviewFixtures.rooms[2])
        .frame(width: 300)
}

#Preview("Unread and Mentions") {
    RoomListRow(room: PreviewFixtures.rooms[4])
        .frame(width: 300)
}

#Preview("Mention Only") {
    RoomListRow(room: RoomRowData(
        roomId: "!ops:example.com",
        name: "Operations",
        lastMessage: "@relay the deploy is blocked",
        lastMessageAuthor: "Bob",
        lastMessageTimestamp: .now.addingTimeInterval(-900),
        notificationCount: 2,
        highlightCount: 2
    ))
    .frame(width: 300)
}

#Preview("Notifications") {
    RoomListRow(room: RoomRowData(
        roomId: "!general:example.com",
        name: "General",
        lastMessage: "Has anyone tried the new build?",
        lastMessageAuthor: "Charlie",
        lastMessageTimestamp: .now.addingTimeInterval(-1800),
        notificationCount: 7
    ))
    .frame(width: 300)
}

#Preview("Unread DM") {
    RoomListRow(room: PreviewFixtures.rooms[1])
        .frame(width: 300)
}

#Preview("No Unread") {
    RoomListRow(room: RoomRowData(
        roomId: "!alice:example.com",
        name: "Alice",
        lastMessage: "Sounds good, talk soon!",
        lastMessageAuthor: "Alice",
        lastMessageTimestamp: .now.addingTimeInterval(-7200),
        isDirect: true
    ))
    .frame(width: 300)
}

#Preview("Compact") {
    HStack(spacing: 0) {
        RoomListRow(room: PreviewFixtures.rooms[0])

        RoomListRow(room: PreviewFixtures.rooms[2])

        RoomListRow(room: RoomRowData(
            roomId: "!dev:example.com",
            name: "Development"
        ))
    }
    .frame(width: 240)
}

