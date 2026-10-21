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

/// View model for local-first event search in the main detail pane.
@Observable
final class SearchViewModel {
    enum Scope: Equatable {
        case room
        case allRooms
    }

    var searchText = ""
    var scope: Scope = .room
    var localResults: [MessageSearchResult] = []
    var serverResults: [MessageSearchResult] = []
    var isSearchingLocal = false
    var isSearchingServer = false
    var localSearchError: String?
    var serverSearchError: String?
    var serverNextBatch: String?
    var hasCompletedServerSearch = false
    var errorReporter: ErrorReporter?

    var isActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSearchMoreOnServer: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
            && !isSearchingServer
            && (!hasCompletedServerSearch || serverNextBatch != nil || serverSearchError != nil)
    }

    var serverSearchButtonTitle: String {
        if serverSearchError != nil { return "Retry Server Search" }
        return hasCompletedServerSearch ? "Load More Results" : "Search on Server"
    }

    var visibleServerResults: [MessageSearchResult] {
        let localIds = Set(localResults.map(Self.resultKey))
        return serverResults.filter { !localIds.contains(Self.resultKey($0)) }
    }

    private var localTask: Task<Void, Never>?
    private var serverTask: Task<Void, Never>?

    func updateSearch(client: RelayClient, roomId: String?) {
        localTask?.cancel()
        resetServerSearch()
        localSearchError = nil
        localResults = []

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            isSearchingLocal = false
            return
        }

        let scopedRoomId: RoomId?
        switch scope {
        case .room:
            guard let roomId else {
                isSearchingLocal = false
                return
            }
            scopedRoomId = RoomId(unchecked: roomId)
        case .allRooms:
            scopedRoomId = nil
        }

        isSearchingLocal = true
        localTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
                guard let self, !Task.isCancelled else { return }
                let results = try await client.searchStoredMessages(
                    term: query, roomId: scopedRoomId)
                guard !Task.isCancelled else { return }
                localResults = results
            } catch {
                guard let self, !Task.isCancelled else { return }
                localSearchError = error.localizedDescription
                errorReporter?.report(.messageSearchFailed(error.localizedDescription))
            }
            guard let self, !Task.isCancelled else { return }
            isSearchingLocal = false
        }
    }

    func selectAllRooms(client: RelayClient, roomId: String?) {
        scope = .allRooms
        updateSearch(client: client, roomId: roomId)
    }

    func selectedRoomChanged(client: RelayClient, roomId: String?) {
        scope = .room
        updateSearch(client: client, roomId: roomId)
    }

    func searchMoreOnServer(client: RelayClient, roomId: String?) {
        guard canSearchMoreOnServer else { return }
        if scope == .room, roomId == nil { return }

        serverTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let cursor = serverNextBatch
        let filter = scope == .room
            ? roomId.map { MessageSearchFilter(roomIds: [RoomId(unchecked: $0)]) }
            : nil
        serverSearchError = nil
        isSearchingServer = true
        serverTask = Task { [weak self] in
            do {
                let page = try await client.searchMessages(
                    term: query, filter: filter, from: cursor)
                guard let self, !Task.isCancelled else { return }
                var seen = Set(serverResults.map(Self.resultKey))
                serverResults.append(contentsOf: page.results.filter {
                    seen.insert(Self.resultKey($0)).inserted
                })
                serverNextBatch = page.nextBatch
                hasCompletedServerSearch = true
            } catch {
                guard let self, !Task.isCancelled else { return }
                serverSearchError = error.localizedDescription
                errorReporter?.report(.messageSearchFailed(error.localizedDescription))
            }
            guard let self, !Task.isCancelled else { return }
            isSearchingServer = false
        }
    }

    func dismiss() {
        localTask?.cancel()
        localTask = nil
        serverTask?.cancel()
        serverTask = nil
        searchText = ""
        scope = .room
        localResults = []
        resetServerSearch()
        localSearchError = nil
        isSearchingLocal = false
    }

    private func resetServerSearch() {
        serverTask?.cancel()
        serverTask = nil
        serverResults = []
        serverNextBatch = nil
        hasCompletedServerSearch = false
        serverSearchError = nil
        isSearchingServer = false
    }

    private static func resultKey(_ result: MessageSearchResult) -> String {
        "\(result.roomId.value)|\(result.eventId.value)"
    }
}
