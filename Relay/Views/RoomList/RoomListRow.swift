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

    /// Whether the trailing unread badge should be visible.
    private var showBadge: Bool {
        guard !room.isMuted else { return false }
        return room.notificationCount > 0
    }

    /// The color of the unread notification badge.
    ///
    /// - Red: highlights (mentions/keywords) or any notifications in a DM
    /// - Accent (blue): plain notifications in group rooms
    private var badgeColor: Color {
        if room.highlightCount > 0 || room.isDirect {
            return .red
        }
        return .accentColor
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
            .overlay(alignment: .topTrailing) {
                if showBadge {
                    Circle()
                        .fill(badgeColor)
                        .frame(width: 12, height: 12)
                        .padding(1)
                        .background(.background, in: .circle)
                }
                muteIndicator
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .opacity(room.isArchived ? 0.5 : 1)
            .help(room.name)
    }

    private var fullBody: some View {
        HStack(spacing: 10) {
            AvatarView(name: room.name, mxcURL: room.avatarURL, size: 48)
                .overlay(alignment: .topTrailing) {
                    muteIndicator
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

                    notificationBadge
                }
            }
            .padding(4)
            .transition(.opacity)
        }
        .padding(.vertical, 8)
        .opacity(room.isArchived ? 0.5 : 1)
    }

    /// A mute icon overlay on the avatar for muted rooms.
    @ViewBuilder
    private var muteIndicator: some View {
        if room.isMuted {
            Image(systemName: "bell.slash.fill")
                .font(.system(size: 8))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(.gray, in: .circle)
        }
    }

    /// A numeric badge at the trailing edge of the row showing the notification count.
    @ViewBuilder
    private var notificationBadge: some View {
        if showBadge {
            Text(room.notificationCount, format: .number)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(badgeColor, in: .capsule)
        }
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

#Preview("Highlights") {
    RoomListRow(room: PreviewFixtures.rooms[0])
        .frame(width: 300)
}

#Preview("Muted Room") {
    RoomListRow(room: PreviewFixtures.rooms[2])
        .frame(width: 300)
}

#Preview("Mentions Only — No Highlights") {
    RoomListRow(room: RoomRowData(
        roomId: "!dev:example.com",
        name: "Development",
        lastMessage: "Merged the refactor PR",
        lastMessageAuthor: "Alice",
        lastMessageTimestamp: .now.addingTimeInterval(-600),
        notificationCount: 5
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

