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

/// View model for sidebar search.
///
/// Provides client-side room filtering and holds server-side message search
/// results. Owned by ``RoomListView``; message selection navigates through
/// ``MainView``.
@Observable
final class SearchViewModel {
    var searchText = ""

    var isActive: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var messageResults: [MessageSearchResult] = []

    var isSearchingMessages = false

    var previousSelectedRoomId: String?

    var errorReporter: ErrorReporter?

    private var searchTask: Task<Void, Never>?

    func filteredRooms(from rooms: [RoomRowData], spaceId: String?) -> [RoomRowData] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return rooms.filter { room in
            if let spaceId {
                guard room.parentSpaceIds.contains(spaceId) else { return false }
            }
            return room.name.localizedStandardContains(query)
                || (room.topic?.localizedStandardContains(query) ?? false)
        }
    }

    /// Run a server-side message search for the current text, debounced.
    func searchMessages(client: RelayClient) {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else {
            messageResults = []
            isSearchingMessages = false
            return
        }
        isSearchingMessages = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            do {
                let page = try await client.searchMessages(term: query)
                guard !Task.isCancelled else { return }
                messageResults = page.results
            } catch {
                errorReporter?.report(.messageSearchFailed(error.localizedDescription))
            }
            isSearchingMessages = false
        }
    }

    func dismiss() {
        searchTask?.cancel()
        searchTask = nil
        searchText = ""
        messageResults = []
        isSearchingMessages = false
    }
}
