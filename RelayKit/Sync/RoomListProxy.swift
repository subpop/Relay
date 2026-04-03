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

// RoomListProxy.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0


/// A proxy that wraps the Matrix SDK `RoomList`.
///
/// Provides access to the loading state, room list entry diffs
/// with dynamic filtering, and individual room lookups.
public final class RoomListProxy: RoomListProxyProtocol, @unchecked Sendable {
    private let roomList: RoomList

    /// Creates a room list proxy.
    ///
    /// - Parameter roomList: The SDK room list instance.
    public init(roomList: RoomList) {
        self.roomList = roomList
    }

    /// Subscribes to the loading state of the room list.
    public func loadingState(listener: RoomListLoadingStateListener) throws -> RoomListLoadingStateResult {
        try roomList.loadingState(listener: listener)
    }

    /// Subscribes to room list entry diffs with dynamic adapters.
    public func entriesWithDynamicAdapters(pageSize: UInt32, listener: RoomListEntriesListener) -> RoomListEntriesWithDynamicAdaptersResult {
        roomList.entriesWithDynamicAdapters(pageSize: pageSize, listener: listener)
    }

    /// Returns a room by its Matrix room ID.
    public func room(id: String) throws -> Room {
        try roomList.room(roomId: id)
    }
}
