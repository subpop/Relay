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

// RoomListProxyProtocol.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0


/// Wraps a Matrix SDK `RoomList` with access to loading state and the entries controller.
///
/// Provides methods for subscribing to room list entry diffs,
/// monitoring loading state, and controlling dynamic filtering
/// and pagination via the entries controller.
///
/// ## Topics
///
/// ### Loading State
/// - ``loadingState(listener:)``
///
/// ### Dynamic Entries
/// - ``entriesWithDynamicAdapters(pageSize:listener:)``
///
/// ### Room Access
/// - ``room(id:)``
public protocol RoomListProxyProtocol: AnyObject, Sendable {
    /// Subscribes to the loading state of the room list.
    ///
    /// - Parameter listener: The listener to receive loading state updates.
    /// - Returns: The initial loading state and a result containing the stream.
    /// - Throws: If the subscription fails.
    func loadingState(listener: RoomListLoadingStateListener) throws -> RoomListLoadingStateResult

    /// Subscribes to room list entry diffs with dynamic filtering and pagination.
    ///
    /// - Parameters:
    ///   - pageSize: The number of rooms per page.
    ///   - listener: The listener to receive entry updates.
    /// - Returns: A result containing the entries controller.
    func entriesWithDynamicAdapters(pageSize: UInt32, listener: RoomListEntriesListener) -> RoomListEntriesWithDynamicAdaptersResult

    /// Returns a room by its Matrix room ID.
    ///
    /// - Parameter id: The room ID.
    /// - Returns: The room.
    /// - Throws: If the room is not found.
    func room(id: String) throws -> Room
}
