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

/// A room discovered through the public room directory search.
///
/// ``DirectoryRoom`` represents a room listing returned by
/// ``MatrixServiceProtocol/searchDirectory(query:)``. It contains only the metadata
/// visible in directory search results, not the full room state.
public struct DirectoryRoom: Identifiable, Hashable, Sendable {
    /// The stable identifier for this room, derived from ``roomId``.
    public var id: String { roomId }

    /// The Matrix room identifier (e.g. `"!abc123:matrix.org"`).
    public let roomId: String

    /// The display name of the room, if set by the room administrators.
    public let name: String?

    /// The room's topic description, if set.
    public let topic: String?

    /// The canonical alias for the room (e.g. `"#design:matrix.org"`), if one exists.
    public let alias: String?

    /// The `mxc://` URL of the room's avatar image, if set.
    public let avatarURL: String?

    /// The number of members currently joined to this room.
    public let memberCount: UInt64

    /// Whether the room's history is world-readable (visible without joining).
    ///
    /// When `true`, the room supports preview-before-join, allowing users to
    /// browse the timeline without committing to membership.
    public let isWorldReadable: Bool

    /// Whether this entry is a space rather than a regular room.
    ///
    /// Spaces use rounded-rectangle avatars while rooms use circular avatars.
    public let isSpace: Bool

    /// Creates a new ``DirectoryRoom`` value.
    ///
    /// - Parameters:
    ///   - roomId: The Matrix room identifier.
    ///   - name: The room display name.
    ///   - topic: The room topic description.
    ///   - alias: The canonical alias for the room.
    ///   - avatarURL: The `mxc://` URL for the room avatar.
    ///   - memberCount: The number of joined members.
    ///   - isWorldReadable: Whether the room has world-readable history.
    ///   - isSpace: Whether this entry is a space.
    nonisolated public init(
        roomId: String,
        name: String? = nil,
        topic: String? = nil,
        alias: String? = nil,
        avatarURL: String? = nil,
        memberCount: UInt64 = 0,
        isWorldReadable: Bool = false,
        isSpace: Bool = false
    ) {
        self.roomId = roomId
        self.name = name
        self.topic = topic
        self.alias = alias
        self.avatarURL = avatarURL
        self.memberCount = memberCount
        self.isWorldReadable = isWorldReadable
        self.isSpace = isSpace
    }
}
