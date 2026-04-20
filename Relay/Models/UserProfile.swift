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

import RelayInterface

/// Lightweight user identifier used as a navigation value for the inspector panel.
///
/// ``UserProfile`` can be constructed from a ``RoomMemberDetails`` (tapping a member in
/// room info) or from a ``TimelineMessage`` (double-tapping an avatar in the timeline).
struct UserProfile: Hashable {
    /// The Matrix user ID (e.g. `"@alice:matrix.org"`).
    let userId: String

    /// The user's display name, if known.
    let displayName: String?

    /// The `mxc://` URL of the user's avatar, if available.
    let avatarURL: String?

    /// The user's role within the room context, if applicable.
    let role: RoomMemberDetails.Role?

    /// The user's raw power level within the room context, if applicable.
    let powerLevel: Int64?

    /// Creates a ``UserProfile`` with explicit values.
    init(
        userId: String,
        displayName: String? = nil,
        avatarURL: String? = nil,
        role: RoomMemberDetails.Role? = nil,
        powerLevel: Int64? = nil
    ) {
        self.userId = userId
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.role = role
        self.powerLevel = powerLevel
    }

    /// Creates a ``UserProfile`` from a room member's details.
    init(member: RoomMemberDetails) {
        self.userId = member.userId
        self.displayName = member.displayName
        self.avatarURL = member.avatarURL
        self.role = member.role
        self.powerLevel = member.powerLevel
    }

    /// Creates a ``UserProfile`` from a timeline message's sender information.
    init(message: TimelineMessage) {
        self.userId = message.senderID
        self.displayName = message.senderDisplayName
        self.avatarURL = message.senderAvatarURL
        self.role = nil
        self.powerLevel = nil
    }
}
