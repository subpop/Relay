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

/// A single room row in the sidebar list, showing the avatar, name, last message preview,
/// unread indicator, and notification mode state.
struct RoomListRow: View {
    let room: RoomSummary

    /// Whether the room name should appear bold (has notification-worthy unread activity).
    private var hasVisibleUnread: Bool {
        switch room.notificationMode {
        case .mute:
            return false
        case .mentionsAndKeywordsOnly:
            return room.unreadMentions > 0
        case .allMessages, nil:
            return room.unreadMessages > 0 || room.unreadMentions > 0
        }
    }

    /// The color of the unread indicator dot.
    ///
    /// - Red: unread mentions, keyword matches, or any unread messages in a DM
    /// - Accent (blue): unread messages in group rooms
    private var dotColor: Color {
        if room.unreadMentions > 0 || room.isDirect || room.hasKeywordHighlight {
            return .red
        }
        return .accentColor
    }

    /// Whether any dot should be visible.
    private var showDot: Bool {
        guard !room.isMuted else { return false }
        return room.unreadMessages > 0 || room.unreadMentions > 0
    }

    var body: some View {
        HStack(spacing: 10) {
            if room.isMuted {
                Image(systemName: "bell.slash.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                    .opacity(showDot ? 1 : 0)
            }

            AvatarView(name: room.name, mxcURL: room.avatarURL, size: 48)

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

                if let msg = room.lastMessage {
                    let author = RoomListRow.formatAuthor(room.lastAuthor)
                    Text(author + msg.visualizeLinksOnly())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(4)
        }
        .padding(.vertical, 8)
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
            result[range].foregroundColor = .accentColor
        }
        
        return result
    }
}

// MARK: - Previews

#Preview("Unread Mentions") {
    RoomListRow(room: RoomSummary(
        id: "!design:matrix.org",
        name: "Design Team",
        lastAuthor: "Alice",
        lastMessage: AttributedString("Let's finalize the mockups tomorrow"),
        lastMessageTimestamp: .now.addingTimeInterval(-300),
        unreadCount: 3,
        unreadMentions: 1
    ))
    .frame(width: 300)
}

#Preview("Muted Room") {
    RoomListRow(room: RoomSummary(
        id: "!hq:matrix.org",
        name: "Matrix HQ",
        lastAuthor: "Bob",
        lastMessage: AttributedString("General discussion"),
        lastMessageTimestamp: .now.addingTimeInterval(-7200),
        unreadCount: 42,
        notificationMode: .mute
    ))
    .frame(width: 300)
}

#Preview("Mentions Only — Activity") {
    RoomListRow(room: RoomSummary(
        id: "!dev:matrix.org",
        name: "Development",
        lastAuthor: "Alice",
        lastMessage: AttributedString("Merged the refactor PR"),
        lastMessageTimestamp: .now.addingTimeInterval(-600),
        unreadCount: 5,
        notificationMode: .mentionsAndKeywordsOnly
    ))
    .frame(width: 300)
}

#Preview("No Unread") {
    RoomListRow(room: RoomSummary(
        id: "!alice:matrix.org",
        name: "Alice",
        lastAuthor: "Alice",
        lastMessage: AttributedString("Sounds good, talk soon!"),
        lastMessageTimestamp: .now.addingTimeInterval(-7200),
        isDirect: true
    ))
    .frame(width: 300)
}
