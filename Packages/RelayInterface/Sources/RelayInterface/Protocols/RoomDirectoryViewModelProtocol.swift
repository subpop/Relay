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

/// The view model protocol for browsing and searching the public room directory.
///
/// ``RoomDirectoryViewModelProtocol`` defines the observable state and actions needed by
/// ``RoomDirectoryView`` to display popular rooms, search by query, and paginate through
/// results. Concrete implementations include ``RoomDirectoryViewModel`` (backed by the
/// Matrix Rust SDK) and ``PreviewRoomDirectoryViewModel`` (for SwiftUI previews).
@MainActor
public protocol RoomDirectoryViewModelProtocol: AnyObject, Observable {
    /// The current list of rooms from the directory search.
    var rooms: [DirectoryRoom] { get }

    /// Whether a search or initial load is currently in progress.
    var isSearching: Bool { get }

    /// Whether all available pages of results have been loaded.
    var isAtEnd: Bool { get }

    /// A user-facing error message from the most recent failed operation, if any.
    var errorMessage: String? { get set }

    /// Searches the room directory with the given query.
    ///
    /// Pass `nil` or an empty string to load the default popular rooms listing.
    /// Each call replaces the previous results.
    ///
    /// - Parameter query: The search string to filter rooms by name or alias.
    func search(query: String?) async

    /// Loads the next page of results from the current search.
    ///
    /// Does nothing if ``isAtEnd`` is `true` or no search has been performed.
    func loadMore() async
}
