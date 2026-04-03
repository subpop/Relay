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

// RoomSummary.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A lightweight, `Identifiable` summary of a room for display in a list.
///
/// `RoomSummary` is a plain Swift struct built from the SDK's `RoomInfo`
/// and latest event data. It contains all the information needed to
/// render a room list row: name, avatar, unread counts, last message, etc.
///
/// ## Topics
///
/// ### Identity
/// - ``id``
/// - ``name``
/// - ``avatarURL``
///
/// ### State
/// - ``isDirect``
/// - ``isEncrypted``
/// - ``isFavourite``
/// - ``isLowPriority``
/// - ``membership``
///
/// ### Unread Counts
/// - ``notificationCount``
/// - ``highlightCount``
/// - ``unreadMessages``
public struct RoomSummary: Identifiable, Sendable {
    /// The Matrix room ID.
    public let id: String

    /// The computed display name of the room.
    public let name: String?

    /// The room's avatar URL, if set.
    public let avatarURL: URL?

    /// Whether this is a direct message room.
    public let isDirect: Bool

    /// Whether end-to-end encryption is enabled.
    public let isEncrypted: Bool

    /// Whether the user has marked this room as a favourite.
    public let isFavourite: Bool

    /// Whether the user has marked this room as low priority.
    public let isLowPriority: Bool

    /// Whether this room is a Matrix space.
    public let isSpace: Bool

    /// The user's current membership state.
    public let membership: Membership

    /// The number of unread notification events.
    public let notificationCount: UInt64

    /// The number of highlighted (mentioned) unread events.
    public let highlightCount: UInt64

    /// The number of unread messages.
    public let unreadMessages: UInt64

    /// The room's heroes (used for display name/avatar computation).
    public let heroes: [RoomHero]

    /// The room's join rule.
    public let joinRule: JoinRule?

    /// The room's canonical alias, if set.
    public let canonicalAlias: String?

    /// Whether the room has an active call.
    public let hasRoomCall: Bool

    /// The number of active (joined + invited) members.
    public let activeMembersCount: UInt64

    /// The IDs of pinned events in this room.
    public let pinnedEventIDs: [String]

    /// Creates a room summary from a `RoomInfo`.
    ///
    /// - Parameter roomInfo: The SDK room info record.
    public init(roomInfo: RoomInfo) {
        self.id = roomInfo.id
        self.name = roomInfo.displayName
        self.avatarURL = roomInfo.avatarUrl.matrixURL
        self.isDirect = roomInfo.isDirect
        self.isEncrypted = roomInfo.encryptionState != .notEncrypted
        self.isFavourite = roomInfo.isFavourite
        self.isLowPriority = roomInfo.isLowPriority
        self.isSpace = roomInfo.isSpace
        self.membership = roomInfo.membership
        self.notificationCount = roomInfo.notificationCount
        self.highlightCount = roomInfo.highlightCount
        self.unreadMessages = roomInfo.numUnreadMessages
        self.heroes = roomInfo.heroes
        self.joinRule = roomInfo.joinRule
        self.canonicalAlias = roomInfo.canonicalAlias
        self.hasRoomCall = roomInfo.hasRoomCall
        self.activeMembersCount = roomInfo.activeMembersCount
        self.pinnedEventIDs = roomInfo.pinnedEventIds
    }
}
