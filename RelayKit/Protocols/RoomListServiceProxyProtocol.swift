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

// RoomListServiceProxyProtocol.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0


/// Manages sliding-sync-powered room lists with dynamic filtering and pagination.
///
/// The room list service provides access to one or more ``RoomListProxyProtocol``
/// instances, each representing a filtered, paginated view of the user's rooms.
/// The service state and sync indicator are observable for UI feedback.
///
/// ## Topics
///
/// ### State
/// - ``state``
/// - ``stateUpdates``
/// - ``syncIndicator``
/// - ``syncIndicatorUpdates``
///
/// ### Room Lists
/// - ``allRooms()``
///
/// ### Room Access
/// - ``room(id:)``
///
/// ### Subscriptions
/// - ``subscribeToRooms(roomIds:)``
public protocol RoomListServiceProxyProtocol: AnyObject, Sendable {
    /// The current room list service state.
    var state: RoomListServiceState { get }

    /// The current sync indicator visibility.
    var syncIndicator: RoomListServiceSyncIndicator { get }

    /// An async stream of room list service state transitions.
    var stateUpdates: AsyncStream<RoomListServiceState> { get }

    /// An async stream of sync indicator visibility changes.
    var syncIndicatorUpdates: AsyncStream<RoomListServiceSyncIndicator> { get }

    /// Returns the room list containing all rooms.
    ///
    /// - Returns: The room list.
    /// - Throws: `RoomListError` if the room list cannot be loaded.
    func allRooms() async throws -> RoomList

    /// Returns a room by its Matrix room ID.
    ///
    /// - Parameter id: The Matrix room ID.
    /// - Returns: The room.
    /// - Throws: `RoomListError` if the room is not found.
    func room(id: String) throws -> Room

    /// Subscribes to updates for the specified rooms.
    ///
    /// Call this with the room IDs currently visible on screen to
    /// ensure they receive timely updates from the sliding sync.
    ///
    /// - Parameter roomIds: The room IDs to subscribe to.
    /// - Throws: `RoomListError` if the subscription fails.
    func subscribeToRooms(roomIds: [String]) async throws
}
