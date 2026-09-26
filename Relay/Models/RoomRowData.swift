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
import MatrixKit

/// Display-ready room row data for the sidebar.
///
/// A plain value type mapped from ``ObservableRoom`` so room rows render
/// (and preview) without holding observable graph references.
struct RoomRowData: Identifiable, Hashable, Sendable {
    var id: String { roomId }
    var roomId: String
    var name: String
    var topic: String? = nil
    var avatarURL: String? = nil
    var canonicalAlias: String? = nil
    var parentSpaceIds: Set<String> = []
    var lastMessage: String? = nil
    var lastMessageAuthor: String? = nil
    var lastMessageTimestamp: Date? = nil
    var notificationCount: Int = 0
    var highlightCount: Int = 0
    var isDirect: Bool = false
    var isMuted: Bool = false
    var isFavourite: Bool = false
    var isSpace: Bool = false
    var isArchived: Bool = false

    /// Unread activity that specifically needs attention: a mention, `@room`
    /// ping, or keyword highlight, or any notification in a DM.
    var needsAttention: Bool {
        highlightCount > 0 || (isDirect && notificationCount > 0)
    }

    /// Map a live room, resolving the mention preview and mute state.
    /// Callers pass the effective notification mode (defaults are cheap
    /// to compute once per refresh, not per row render). Passing `client`
    /// applies its optimistic unread clear so badges drop immediately
    /// after marking read, instead of lingering on the stale synced
    /// server count.
    static func from(room: ObservableRoom, isMuted: Bool, client: RelayClient? = nil) -> RoomRowData {
        let latest = room.latestMessage
        let sender = latest.map(\.sender)
        return RoomRowData(
            roomId: room.roomId.value,
            name: room.displayName,
            topic: room.topic,
            avatarURL: room.presentingAvatarURL?.value,
            canonicalAlias: room.canonicalAlias,
            parentSpaceIds: Set(room.parentSpaceIds.map(\.value)),
            lastMessage: latest?.messageContent.map(preview),
            lastMessageAuthor: sender.map { room.memberDetails[$0]?.displayname ?? $0.value },
            lastMessageTimestamp: latest?.timestamp,
            notificationCount: client?.displayUnreadCount(for: room) ?? room.unreadCount,
            highlightCount: client?.displayHighlightCount(for: room) ?? room.highlightCount,
            isDirect: room.presentsAsDirect,
            isMuted: isMuted,
            isFavourite: room.isFavourite,
            isSpace: room.isSpace,
            isArchived: room.successorRoomId != nil)
    }

    /// Room-list preview text for a message. Media bodies hold the
    /// caption-or-filename, so describe them instead of showing it.
    private static func preview(for content: MessageContent) -> String {
        switch content.msgtype {
        case .image: "Sent an image"
        case .video: "Sent a video"
        case .audio: "Sent an audio message"
        case .file: "Sent a file"
        case .location: "Sent a location"
        case .emote, .notice, .text: content.body.strippingInlineMarkdown
        }
    }
}

/// Display-ready invite row data for the sidebar.
struct InviteRowData: Identifiable, Hashable, Sendable {
    var id: String { roomId }
    var roomId: String
    var name: String
    var topic: String? = nil
    var avatarURL: String? = nil
    var inviterName: String? = nil
    var inviterAvatarURL: String? = nil
    var isSpace: Bool = false

    static func from(room: ObservableRoom) -> InviteRowData {
        InviteRowData(
            roomId: room.roomId.value,
            name: room.displayName,
            topic: room.topic,
            avatarURL: room.avatarURL?.value,
            inviterName: room.inviterName,
            inviterAvatarURL: room.inviterAvatarURL?.value,
            isSpace: room.isSpace)
    }
}
