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

/// The view model protocol for previewing a room before joining.
///
/// ``RoomPreviewViewModelProtocol`` defines the observable state and actions needed by
/// ``RoomPreviewView`` to display a read-only preview of a room's metadata and
/// (when available) its message timeline. Used for rooms that support preview-before-join
/// (typically public rooms with world-readable history).
@MainActor
public protocol RoomPreviewViewModelProtocol: AnyObject, Observable {
    /// The display name of the room, if available.
    var roomName: String? { get }

    /// The room's topic description, if set.
    var roomTopic: String? { get }

    /// The `mxc://` URL of the room's avatar, if set.
    var roomAvatarURL: String? { get }

    /// The number of members currently joined to the room.
    var memberCount: UInt64 { get }

    /// The canonical alias for the room (e.g. `"#room:matrix.org"`), if available.
    var canonicalAlias: String? { get }

    /// Read-only messages loaded from the room's preview timeline.
    ///
    /// Empty if the room does not support world-readable history or if
    /// the timeline has not finished loading.
    var messages: [TimelineMessage] { get }

    /// Whether the preview is currently loading room info or timeline messages.
    var isLoading: Bool { get }

    /// The Matrix room ID being previewed.
    var roomId: String { get }

    /// Loads the room preview metadata and, if available, the timeline.
    func loadPreview() async
}
