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

import Foundation

/// A summary of a Matrix room for display in the room list sidebar.
///
/// ``RoomSummary`` contains just enough information to render a room row in the
/// sidebar -- the room name, avatar, last message preview, unread counts, and
/// whether it is a direct message conversation. The full room state is available
/// via ``RoomDetails``.
///
/// This is an observable reference type so that individual room properties (such as
/// unread counts) can be updated reactively without replacing the entire room list.
@Observable
public final class RoomSummary: Identifiable {
    /// The Matrix room identifier (e.g. `"!abc123:matrix.org"`).
    public let id: String

    /// The display name of the room.
    public var name: String

    /// The room's topic description, if set.
    public var topic: String?

    /// The `mxc://` URL of the room's avatar image, if set.
    public var avatarURL: String?

    /// The room's most recent author, if available
    public var lastAuthor: String?
    
    /// A rich text preview of the most recent message in the room.
    ///
    /// The attributed string preserves inline Markdown formatting (bold, italic, code,
    /// strikethrough, links) so the sidebar can render a styled single-line preview.
    public var lastMessage: AttributedString?

    /// The timestamp of the most recent message, used for sorting the room list.
    public var lastMessageTimestamp: Date?

    /// The number of unread messages in this room.
    public var unreadMessages: UInt

    /// The number of unread messages that mention the current user.
    public var unreadMentions: UInt

    /// Whether this room is a direct message (one-to-one) conversation.
    public var isDirect: Bool

    /// The canonical alias for the room (e.g. `"#swift:matrix.org"`), if one exists.
    public var canonicalAlias: String?

    /// The event IDs of messages currently pinned in this room.
    public var pinnedEventIds: [String]

    /// Whether this room has any pinned messages.
    public var hasPinnedMessages: Bool { !pinnedEventIds.isEmpty }

    /// The user-defined notification mode for this room, or `nil` if using the default.
    ///
    /// This value comes from the server-side push rules. When `nil`, the effective
    /// notification mode is determined by the global default for this room type
    /// (direct message vs group).
    public var notificationMode: RoomNotificationMode?

    /// Whether this room's effective notification mode is mute.
    ///
    /// A convenience accessor that checks whether the user has explicitly muted this room.
    /// When `true`, the room should not display unread indicators in the sidebar.
    public var isMuted: Bool { notificationMode == .mute }

    /// Creates a new ``RoomSummary`` instance.
    ///
    /// - Parameters:
    ///   - id: The Matrix room identifier.
    ///   - name: The room display name.
    ///   - topic: The room topic description.
    ///   - avatarURL: The `mxc://` URL for the room avatar.
    ///   - lastMessage: A rich text preview of the most recent message.
    ///   - lastMessageTimestamp: The timestamp of the most recent message.
    ///   - unreadCount: The number of unread messages.
    ///   - unreadMentions: The number of unread mentions.
    ///   - isDirect: Whether this is a direct message conversation.
    ///   - canonicalAlias: The canonical alias for the room.
    ///   - pinnedEventIds: The event IDs of pinned messages in this room.
    ///   - notificationMode: The user-defined notification mode, or `nil` for default.
    public init(
        id: String,
        name: String,
        topic: String? = nil,
        avatarURL: String? = nil,
        lastAuthor: String? = nil,
        lastMessage: AttributedString? = nil,
        lastMessageTimestamp: Date? = nil,
        unreadCount: UInt = 0,
        unreadMentions: UInt = 0,
        isDirect: Bool = false,
        canonicalAlias: String? = nil,
        pinnedEventIds: [String] = [],
        notificationMode: RoomNotificationMode? = nil
    ) {
        self.id = id
        self.name = name
        self.topic = topic
        self.avatarURL = avatarURL
        self.lastAuthor = lastAuthor
        self.lastMessage = lastMessage
        self.lastMessageTimestamp = lastMessageTimestamp
        self.unreadMessages = unreadCount
        self.unreadMentions = unreadMentions
        self.isDirect = isDirect
        self.canonicalAlias = canonicalAlias
        self.pinnedEventIds = pinnedEventIds
        self.notificationMode = notificationMode
    }
}
