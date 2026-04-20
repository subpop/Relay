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

/// Detailed metadata about a Matrix room, including its full member list.
///
/// ``RoomDetails`` is a snapshot of a room's current state, typically fetched
/// via ``MatrixServiceProtocol/roomDetails(roomId:)`` for display in the
/// room info inspector panel.
public struct RoomDetails: Sendable {
    /// The Matrix room identifier (e.g. `"!abc123:matrix.org"`).
    public let id: String

    /// The display name of the room.
    public let name: String

    /// The room's topic description, if set.
    public let topic: String?

    /// The `mxc://` URL of the room's avatar image, if set.
    public let avatarURL: String?

    /// Whether end-to-end encryption is enabled in this room.
    public let isEncrypted: Bool

    /// Whether the room is publicly joinable without an invitation.
    public let isPublic: Bool

    /// Whether this room is a direct message (one-to-one) conversation.
    public let isDirect: Bool

    /// The canonical alias for the room (e.g. `"#design:matrix.org"`), if one exists.
    public let canonicalAlias: String?

    /// The total number of members joined to this room.
    public let memberCount: UInt64

    /// The list of currently joined room members with their profile details and roles.
    public let members: [RoomMemberDetails]

    /// The event IDs of messages currently pinned in this room.
    public let pinnedEventIds: [String]

    /// The room's join rule (e.g. `"public"`, `"invite"`, `"knock"`, `"restricted"`).
    public let joinRule: String?

    /// Who can read the room's history (e.g. `"joined"`, `"invited"`, `"shared"`, `"world_readable"`).
    public let historyVisibility: String?

    /// Creates a new ``RoomDetails`` value.
    ///
    /// - Parameters:
    ///   - id: The Matrix room identifier.
    ///   - name: The room display name.
    ///   - topic: The room topic description.
    ///   - avatarURL: The `mxc://` URL for the room avatar.
    ///   - isEncrypted: Whether encryption is enabled.
    ///   - isPublic: Whether the room is publicly joinable.
    ///   - isDirect: Whether this is a direct message conversation.
    ///   - canonicalAlias: The room's canonical alias.
    ///   - memberCount: The total number of joined members.
    ///   - members: The detailed member list.
    ///   - pinnedEventIds: The event IDs of pinned messages.
    ///   - joinRule: The room's join rule string.
    ///   - historyVisibility: The room's history visibility string.
    nonisolated public init(
        id: String,
        name: String,
        topic: String? = nil,
        avatarURL: String? = nil,
        isEncrypted: Bool = false,
        isPublic: Bool = false,
        isDirect: Bool = false,
        canonicalAlias: String? = nil,
        memberCount: UInt64 = 0,
        members: [RoomMemberDetails] = [],
        pinnedEventIds: [String] = [],
        joinRule: String? = nil,
        historyVisibility: String? = nil
    ) {
        self.id = id
        self.name = name
        self.topic = topic
        self.avatarURL = avatarURL
        self.isEncrypted = isEncrypted
        self.isPublic = isPublic
        self.isDirect = isDirect
        self.canonicalAlias = canonicalAlias
        self.memberCount = memberCount
        self.members = members
        self.pinnedEventIds = pinnedEventIds
        self.joinRule = joinRule
        self.historyVisibility = historyVisibility
    }
}

/// Profile and role information for a single member of a Matrix room.
public struct RoomMemberDetails: Identifiable, Sendable {
    /// The stable identifier for this member, derived from ``userId``.
    nonisolated public var id: String { userId }

    /// The Matrix user identifier (e.g. `"@alice:matrix.org"`).
    public let userId: String

    /// The member's display name within the room, if set.
    public let displayName: String?

    /// The `mxc://` URL of the member's avatar image, if set.
    public let avatarURL: String?

    /// The member's power-level role within this room.
    public let role: Role

    /// The member's raw power level within this room (e.g. 100 for admin, 50 for moderator, 0 for user).
    public let powerLevel: Int64

    /// The power-level role a member holds within a room.
    public enum Role: String, Sendable {
        /// Full administrative privileges (power level 100).
        case administrator
        /// Moderation privileges such as kick and ban (power level 50).
        case moderator
        /// Standard participant with no elevated privileges.
        case user
    }

    /// Creates a new ``RoomMemberDetails`` value.
    ///
    /// - Parameters:
    ///   - userId: The Matrix user identifier.
    ///   - displayName: The member's display name.
    ///   - avatarURL: The `mxc://` URL for the member's avatar.
    ///   - role: The member's power-level role. Defaults to `.user`.
    ///   - powerLevel: The member's raw power level. Defaults to `0`.
    nonisolated public init(
        userId: String,
        displayName: String? = nil,
        avatarURL: String? = nil,
        role: Role = .user,
        powerLevel: Int64 = 0
    ) {
        self.userId = userId
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.role = role
        self.powerLevel = powerLevel
    }
}
