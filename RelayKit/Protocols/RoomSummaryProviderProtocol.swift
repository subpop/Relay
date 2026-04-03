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

// RoomSummaryProviderProtocol.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0


/// Provides a reactive, filtered, paginated list of ``RoomSummary`` values.
///
/// The provider maintains an observable array of room summaries that
/// updates in response to sync events. Use ``setFilter(_:)`` to apply
/// dynamic filters (favourites, unread, DMs, etc.) and ``loadNextPage()``
/// to paginate through large room lists.
///
/// ```swift
/// struct RoomListView: View {
///     let provider: any RoomSummaryProviderProtocol
///
///     var body: some View {
///         List(provider.rooms) { room in
///             Text(room.name ?? room.id)
///         }
///     }
/// }
/// ```
///
/// ## Topics
///
/// ### Room Data
/// - ``rooms``
/// - ``loadingState``
///
/// ### Filtering
/// - ``setFilter(_:)``
///
/// ### Pagination
/// - ``loadNextPage()``
///
/// ### Subscriptions
/// - ``subscribeToVisibleRooms(ids:)``
public protocol RoomSummaryProviderProtocol: AnyObject, Sendable {
    /// The current list of room summaries.
    var rooms: [RoomSummary] { get }

    /// The loading state of the room list.
    var loadingState: RoomListLoadingState { get }

    /// Applies a dynamic filter to the room list.
    ///
    /// - Parameter kind: The filter to apply.
    /// - Returns: `true` if the filter was applied successfully.
    @discardableResult
    func setFilter(_ kind: RoomListEntriesDynamicFilterKind) -> Bool

    /// Loads the next page of rooms.
    func loadNextPage()

    /// Subscribes to updates for rooms currently visible on screen.
    ///
    /// - Parameter ids: The room IDs to subscribe to.
    /// - Throws: If the subscription fails.
    func subscribeToVisibleRooms(ids: [String]) async throws
}
