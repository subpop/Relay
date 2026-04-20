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

/// A child room or sub-space within a space that may be affected when leaving.
///
/// ``LeaveSpaceChild`` represents a room discovered during
/// ``MatrixServiceProtocol/leaveSpace(spaceId:)``. It contains the metadata
/// needed to present a confirmation UI where the user selects which child rooms
/// to leave alongside the parent space.
public struct LeaveSpaceChild: Identifiable, Hashable, Sendable {
    /// The stable identifier for this room, derived from ``roomId``.
    public var id: String { roomId }

    /// The Matrix room identifier (e.g. `"!abc123:matrix.org"`).
    public let roomId: String

    /// The display name of the room.
    public let name: String

    /// The `mxc://` URL of the room's avatar image, if set.
    public let avatarURL: String?

    /// Whether the current user is the last remaining owner (admin) of this room.
    ///
    /// When `true`, the UI should warn the user that leaving will result in the
    /// room having no owner.
    public let isLastOwner: Bool

    /// The number of members currently joined to this room.
    public let memberCount: UInt64

    /// Whether this child is itself a space rather than a regular room.
    public let isSpace: Bool

    /// Creates a new ``LeaveSpaceChild`` value.
    ///
    /// - Parameters:
    ///   - roomId: The Matrix room identifier.
    ///   - name: The room display name.
    ///   - avatarURL: The `mxc://` URL for the room avatar.
    ///   - isLastOwner: Whether the user is the last owner of this room.
    ///   - memberCount: The number of joined members.
    ///   - isSpace: Whether this child is a space.
    nonisolated public init(
        roomId: String,
        name: String,
        avatarURL: String? = nil,
        isLastOwner: Bool = false,
        memberCount: UInt64 = 0,
        isSpace: Bool = false
    ) {
        self.roomId = roomId
        self.name = name
        self.avatarURL = avatarURL
        self.isLastOwner = isLastOwner
        self.memberCount = memberCount
        self.isSpace = isSpace
    }
}
