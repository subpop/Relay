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

/// A store-backed snapshot of one room for the UI layer.
///
/// Replaces `ObservableRoom`: instead of a live observable graph owned
/// by MatrixKit, room state lives in the normalized SwiftData store and
/// `RelayClient` rebuilds these value snapshots from it after each sync
/// delta. Views render from the snapshot without holding store
/// references; `@Observable` invalidation on `RelayClient` refreshes
/// them when the cache rebuilds.
struct RelayRoom: Identifiable, Hashable, Sendable {
    var id: String { roomId.value }
    var roomId: RoomId
    var displayName: String
    var name: String?
    var topic: String?
    var avatarURL: MXCURI?
    var canonicalAlias: String?
    var altAliases: [String] = []
    var membership: Membership = .join
    /// Display unread count: the writer-precomputed effective (client-
    /// estimated) unread, matching the old live `unreadCount` semantics.
    var unreadCount = 0
    var highlightCount = 0
    var effectiveUnread = 0
    var firstUnreadEventId: EventId?
    var prevBatch: BatchToken?
    var fullyReadEventId: EventId?
    var memberDetails: [UserId: MemberContent] = [:]
    var memberCount = 0
    var isSpace = false
    var isFavourite = false
    var isEncrypted = false
    var isDirect = false
    var successorRoomId: String?
    var inviterId: UserId?
    var pinnedEventIds: [String] = []
    /// Newest message-like event, for list previews and read markers.
    var latestMessage: MessageEvent?
    /// Newest stored event ID of any type, for optimistic-read checks.
    var newestEventId: String?
    var parentSpaceIds: Set<RoomId> = []
    var localUserId: UserId?

    /// Spec `m.direct`, or the Relay DM-like display heuristic (see
    /// `RoomPresentation`).
    var presentsAsDirect: Bool {
        RoomPresentation.presentsAsDirect(
            isDirect: isDirect,
            isSpace: isSpace,
            canonicalAlias: canonicalAlias,
            joinedMemberCount: memberDetails.values.filter { $0.membership == .join }.count)
    }

    /// Avatar for list rows: the room avatar, falling back to the other
    /// joined member's avatar when the room presents as a direct chat
    /// (DMs carry no room avatar).
    var presentingAvatarURL: MXCURI? {
        if let avatarURL { return avatarURL }
        guard presentsAsDirect else { return nil }
        return memberDetails
            .first { $0.key != localUserId && $0.value.membership == .join }?
            .value.avatarUrl
            .flatMap { try? MXCURI($0) }
    }

    /// Display name of the invite sender, if known.
    var inviterName: String? {
        guard let inviterId else { return nil }
        return memberDetails[inviterId]?.displayname ?? inviterId.value
    }

    /// Avatar of the invite sender, if known.
    var inviterAvatarURL: MXCURI? {
        guard let inviterId else { return nil }
        return memberDetails[inviterId]?.avatarUrl.flatMap { try? MXCURI($0) }
    }
}
