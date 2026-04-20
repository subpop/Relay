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

/// A space where the current user has permission to manage children.
///
/// ``EditableSpace`` is a lightweight summary of a space returned by
/// ``MatrixServiceProtocol/editableSpaces()``. It contains enough
/// information to display the space in a picker and identify it by ID.
public struct EditableSpace: Identifiable, Hashable, Sendable {
    /// The stable identifier for this entry, derived from ``roomId``.
    public var id: String { roomId }

    /// The Matrix room ID of the space.
    public let roomId: String

    /// The display name of the space.
    public let name: String

    /// The `mxc://` URL of the space's avatar, if set.
    public let avatarURL: String?

    /// Creates a new ``EditableSpace`` value.
    nonisolated public init(roomId: String, name: String, avatarURL: String? = nil) {
        self.roomId = roomId
        self.name = name
        self.avatarURL = avatarURL
    }
}
