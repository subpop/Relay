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
import MatrixKit
import Observation

/// View model for the public room directory.
///
/// Loads popular rooms on demand and searches by name or alias, paging
/// through the homeserver directory via ``RelayClient``.
@Observable
final class RoomDirectoryViewModel {
    /// The current page of directory entries.
    var rooms: [PublicRoomEntry] = []

    /// Whether a search request is in flight.
    var isSearching = false

    /// Whether the server reported the end of the list.
    var isAtEnd = false

    var errorReporter: ErrorReporter?

    var client: RelayClient?

    private var nextBatch: String?
    private var currentFilter: String?

    init(client: RelayClient? = nil) {
        self.client = client
    }

    /// Search the directory (nil query lists popular rooms).
    @MainActor
    func search(query: String?) async {
        guard let client else { return }
        isSearching = true
        defer { isSearching = false }
        currentFilter = query
        do {
            let page = try await client.publicRooms(filter: query)
            rooms = page.rooms
            nextBatch = page.nextBatch
            isAtEnd = page.nextBatch == nil
        } catch {
            errorReporter?.report(.directorySearchFailed(error.localizedDescription))
        }
    }

    /// Load the next page, if any.
    @MainActor
    func loadMore() async {
        guard let client, !isAtEnd, let nextBatch else { return }
        do {
            let page = try await client.publicRooms(
                filter: currentFilter, since: nextBatch)
            rooms += page.rooms
            self.nextBatch = page.nextBatch
            isAtEnd = page.nextBatch == nil
        } catch {
            errorReporter?.report(.directorySearchFailed(error.localizedDescription))
        }
    }
}
