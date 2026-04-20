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

/// A room or sub-space within a space hierarchy.
///
/// ``SpaceChild`` represents a single entry returned when browsing a space's
/// children via the `/hierarchy` endpoint. It contains the metadata needed to
/// display the entry in a list and determine whether the user can join it.
public struct SpaceChild: Identifiable, Hashable, Sendable {
    /// The stable identifier for this entry, derived from ``roomId``.
    public var id: String { roomId }

    /// The Matrix room identifier (e.g. `"!abc123:matrix.org"`).
    public let roomId: String

    /// The display name of the room or sub-space.
    public let name: String

    /// The room's topic description, if set.
    public let topic: String?

    /// The `mxc://` URL of the avatar image, if set.
    public let avatarURL: String?

    /// The number of members currently joined.
    public let memberCount: UInt64

    /// Whether this entry is a room or a sub-space.
    public let roomType: SpaceChildType

    /// Whether the current user has joined this room.
    public let isJoined: Bool

    /// The number of children this entry has (non-zero only for sub-spaces).
    public let childrenCount: UInt64

    /// The join rule governing access to this room, if known.
    public let joinRule: SpaceChildJoinRule?

    /// The canonical alias for the room (e.g. `"#design:matrix.org"`), if one exists.
    public let canonicalAlias: String?

    /// Creates a new ``SpaceChild`` value.
    nonisolated public init(
        roomId: String,
        name: String,
        topic: String? = nil,
        avatarURL: String? = nil,
        memberCount: UInt64 = 0,
        roomType: SpaceChildType = .room,
        isJoined: Bool = false,
        childrenCount: UInt64 = 0,
        joinRule: SpaceChildJoinRule? = nil,
        canonicalAlias: String? = nil
    ) {
        self.roomId = roomId
        self.name = name
        self.topic = topic
        self.avatarURL = avatarURL
        self.memberCount = memberCount
        self.roomType = roomType
        self.isJoined = isJoined
        self.childrenCount = childrenCount
        self.joinRule = joinRule
        self.canonicalAlias = canonicalAlias
    }
}

/// The type of entry within a space hierarchy.
public enum SpaceChildType: Hashable, Sendable {
    /// A regular chat room.
    case room
    /// A nested sub-space that can contain its own children.
    case space
}

/// The join rule governing access to a room within a space.
public enum SpaceChildJoinRule: Hashable, Sendable {
    /// Anyone can join without an invitation.
    case `public`
    /// Users must request access and be approved.
    case knock
    /// Users must be explicitly invited.
    case invite
    /// Access is restricted to members of specific rooms or spaces.
    case restricted
}
