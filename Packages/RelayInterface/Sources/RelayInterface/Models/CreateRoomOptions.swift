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

/// Options for creating a new Matrix room.
///
/// ``CreateRoomOptions`` encapsulates all user-configurable parameters for room creation,
/// passed to ``MatrixServiceProtocol/createRoom(options:)``.
public struct CreateRoomOptions: Sendable {
    /// The display name for the room.
    public let name: String

    /// An optional topic description for the room.
    public let topic: String?

    /// An optional local alias for the room (e.g. `"myroom"` for `#myroom:server.org`).
    ///
    /// Only meaningful for public rooms. The homeserver combines this with its domain
    /// to form the canonical alias.
    public let address: String?

    /// Whether the room should be publicly joinable.
    ///
    /// Public rooms appear in the room directory and can be joined without an invitation.
    public let isPublic: Bool

    /// Whether end-to-end encryption should be enabled.
    ///
    /// Defaults to `true` for private rooms and `false` for public rooms when not
    /// explicitly specified by the user.
    public let isEncrypted: Bool

    /// Whether to create a Matrix space instead of a regular room.
    ///
    /// Spaces are containers for organizing rooms and sub-spaces. They do not
    /// support encryption or message timelines.
    public let isSpace: Bool

    /// Creates a new ``CreateRoomOptions`` value.
    ///
    /// - Parameters:
    ///   - name: The room display name.
    ///   - topic: An optional topic description.
    ///   - address: An optional local alias for the room.
    ///   - isPublic: Whether the room is publicly joinable.
    ///   - isEncrypted: Whether E2EE is enabled.
    ///   - isSpace: Whether to create a space instead of a room.
    public init(
        name: String,
        topic: String? = nil,
        address: String? = nil,
        isPublic: Bool = false,
        isEncrypted: Bool = true,
        isSpace: Bool = false
    ) {
        self.name = name
        self.topic = topic
        self.address = address
        self.isPublic = isPublic
        self.isEncrypted = isEncrypted
        self.isSpace = isSpace
    }
}
