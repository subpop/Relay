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

/// A lightweight, serialisable snapshot of a room for the share extension's room picker.
///
/// The main app periodically writes an array of ``ShareableRoom`` to the app group
/// container. The share extension reads this cache on launch to display the room list
/// without needing to initialise the Matrix SDK.
public struct ShareableRoom: Codable, Sendable, Identifiable {
    /// The Matrix room ID.
    public let id: String

    /// The room's display name.
    public let name: String

    /// Whether this is a direct message room.
    public let isDirect: Bool

    /// PNG-encoded avatar image data, or `nil` if no avatar is available.
    public let avatarData: Data?

    /// Timestamp of the room's last activity, used for sorting.
    public let lastActivityTimestamp: Date?

    public init(
        id: String,
        name: String,
        isDirect: Bool,
        avatarData: Data? = nil,
        lastActivityTimestamp: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.isDirect = isDirect
        self.avatarData = avatarData
        self.lastActivityTimestamp = lastActivityTimestamp
    }
}
