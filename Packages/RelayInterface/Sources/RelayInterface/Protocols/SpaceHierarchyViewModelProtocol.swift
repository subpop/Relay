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

/// The view model protocol for browsing the room hierarchy within a Matrix space.
///
/// ``SpaceHierarchyViewModelProtocol`` defines the observable state and actions
/// needed by ``SpaceDetailView`` to display a space's metadata, list its children
/// (rooms and sub-spaces), paginate through the hierarchy, and join unjoined rooms.
///
/// Concrete implementations include ``SpaceHierarchyViewModel`` (backed by the
/// Matrix Rust SDK's `SpaceRoomList`) and ``PreviewSpaceHierarchyViewModel``
/// (for SwiftUI previews).
@MainActor
public protocol SpaceHierarchyViewModelProtocol: AnyObject, Observable {
    /// The display name of the space.
    var spaceName: String { get }

    /// The topic of the space, if set.
    var spaceTopic: String? { get }

    /// The `mxc://` avatar URL of the space, if set.
    var spaceAvatarURL: String? { get }

    /// The number of members joined to the space.
    var spaceMemberCount: UInt64 { get }

    /// Whether the current user has joined this space.
    var isJoined: Bool { get }

    /// Whether the current user has permission to add or remove children
    /// in this space (i.e. can send `m.space.child` state events).
    var canManageChildren: Bool { get }

    /// The current list of children (rooms and sub-spaces) in the hierarchy.
    var children: [SpaceChild] { get }

    /// Whether the initial load or a pagination request is in progress.
    var isLoading: Bool { get }

    /// Whether all pages of the hierarchy have been fetched.
    var isAtEnd: Bool { get }

    /// Loads the space metadata and fetches the first page of children.
    ///
    /// This should be called once when the view appears. Subsequent pages
    /// are loaded via ``loadMore()``.
    func load() async

    /// Fetches the next page of children from the hierarchy.
    ///
    /// Does nothing if ``isAtEnd`` is `true` or a load is already in progress.
    func loadMore() async

    /// Joins the room with the given identifier.
    ///
    /// After joining, the room's ``SpaceChild/isJoined`` state will be updated
    /// reactively via the room list subscription.
    ///
    /// - Parameter roomId: The Matrix room ID to join.
    func joinRoom(roomId: String) async throws
}
