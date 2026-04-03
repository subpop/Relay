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

// RoomInfoProxy.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A snapshot of a room's metadata at a point in time.
///
/// Wraps the SDK's `RoomInfo` record with Swift-typed computed
/// properties (e.g., `String` -> `URL` conversions). Created from
/// room info listener updates and used to populate the observable
/// properties on ``JoinedRoomProxy``.
///
/// ## Topics
///
/// ### Identity
/// - ``id``
/// - ``displayName``
/// - ``avatarURL``
///
/// ### State
/// - ``isDirect``
/// - ``isEncrypted``
/// - ``isSpace``
/// - ``membership``
///
/// ### Members
/// - ``activeMembersCount``
/// - ``joinedMembersCount``
/// - ``invitedMembersCount``
public struct RoomInfoProxy: Sendable {
    /// The underlying SDK room info.
    public let roomInfo: RoomInfo

    /// Creates a room info proxy from an SDK `RoomInfo`.
    ///
    /// - Parameter roomInfo: The SDK room info record.
    public init(roomInfo: RoomInfo) {
        self.roomInfo = roomInfo
    }

    /// The Matrix room ID.
    public var id: String { roomInfo.id }

    /// The computed display name of the room.
    public var displayName: String? { roomInfo.displayName }

    /// The room's raw (non-computed) name, if set.
    public var rawName: String? { roomInfo.rawName }

    /// The room's topic, if set.
    public var topic: String? { roomInfo.topic }

    /// The room's avatar URL, if set.
    public var avatarURL: URL? { roomInfo.avatarUrl.matrixURL }

    /// Whether this is a direct message room.
    public var isDirect: Bool { roomInfo.isDirect }

    /// Whether the room is publicly joinable.
    public var isPublic: Bool { roomInfo.isPublic ?? false }

    /// Whether this room is a Matrix space.
    public var isSpace: Bool { roomInfo.isSpace }

    /// Whether end-to-end encryption is enabled.
    public var isEncrypted: Bool { roomInfo.encryptionState != .notEncrypted }

    /// The encryption state of the room.
    public var encryptionState: EncryptionState { roomInfo.encryptionState }

    /// Whether the user has marked this room as a favourite.
    public var isFavourite: Bool { roomInfo.isFavourite }

    /// Whether the user has marked this room as low priority.
    public var isLowPriority: Bool { roomInfo.isLowPriority }

    /// The user's current membership state.
    public var membership: Membership { roomInfo.membership }

    /// The member who invited the user, if applicable.
    public var inviter: RoomMember? { roomInfo.inviter }

    /// The room's heroes.
    public var heroes: [RoomHero] { roomInfo.heroes }

    /// The number of active (joined + invited) members.
    public var activeMembersCount: UInt64 { roomInfo.activeMembersCount }

    /// The number of invited members.
    public var invitedMembersCount: UInt64 { roomInfo.invitedMembersCount }

    /// The number of joined members.
    public var joinedMembersCount: UInt64 { roomInfo.joinedMembersCount }

    /// The number of highlighted (mentioned) unread events.
    public var highlightCount: UInt64 { roomInfo.highlightCount }

    /// The number of unread notification events.
    public var notificationCount: UInt64 { roomInfo.notificationCount }

    /// The number of unread messages.
    public var numUnreadMessages: UInt64 { roomInfo.numUnreadMessages }

    /// The IDs of pinned events.
    public var pinnedEventIDs: [String] { roomInfo.pinnedEventIds }

    /// The room's join rule.
    public var joinRule: JoinRule? { roomInfo.joinRule }

    /// The room's history visibility.
    public var historyVisibility: RoomHistoryVisibility { roomInfo.historyVisibility }

    /// The room's canonical alias, if set.
    public var canonicalAlias: String? { roomInfo.canonicalAlias }

    /// Whether the room has an active call.
    public var hasRoomCall: Bool { roomInfo.hasRoomCall }

    /// Whether the room is marked as unread.
    public var isMarkedUnread: Bool { roomInfo.isMarkedUnread }

    /// The room's power levels, if available.
    public var powerLevels: RoomPowerLevels? { roomInfo.powerLevels }
}
