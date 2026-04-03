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

// RoomPreviewProxy.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A preview of a room the user has not yet joined.
///
/// Provides read-only information about a room including its name,
/// topic, member count, and join rule. Used for displaying room
/// previews before joining.
public struct RoomPreviewProxy: Sendable {
    private let preview: RoomPreview

    /// Creates a room preview proxy.
    ///
    /// - Parameter preview: The SDK room preview instance.
    public init(preview: RoomPreview) {
        self.preview = preview
    }

    /// Returns the room preview metadata.
    public func info() -> RoomPreviewInfo {
        preview.info()
    }

    /// The room ID being previewed.
    public var roomId: String {
        preview.info().roomId
    }

    /// The display name of the room, if set.
    public var name: String? {
        preview.info().name
    }

    /// The room's topic, if set.
    public var topic: String? {
        preview.info().topic
    }

    /// The `mxc://` URL of the room's avatar, if set.
    public var avatarURL: String? {
        preview.info().avatarUrl
    }

    /// The number of joined members.
    public var memberCount: UInt64 {
        preview.info().numJoinedMembers
    }

    /// The canonical alias for the room, if set.
    public var canonicalAlias: String? {
        preview.info().canonicalAlias
    }

    /// Whether the room's history is world-readable.
    public var isHistoryWorldReadable: Bool {
        preview.info().isHistoryWorldReadable ?? false
    }

    /// The join rule for this room.
    public var joinRule: JoinRule? {
        preview.info().joinRule
    }
}
