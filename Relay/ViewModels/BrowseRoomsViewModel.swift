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

/// View model for Browse Rooms.
///
/// Browses the logged-in homeserver's directory plus any enabled extra
/// directories (e.g. `matrixrooms.info`) through ``RelayClient``, keeping
/// one independently paginated result page per server so the list can be
/// grouped by server.
@Observable
final class BrowseRoomsViewModel {
    /// One server's directory page.
    struct ServerPage {
        /// Display name of the server (`host[:port]`).
        var serverName: String
        /// Whether this is the logged-in homeserver (queried without a `server` filter).
        var isHome: Bool
        var rooms: [PublicRoomEntry] = []
        var nextBatch: String?
        var isAtEnd = false
        var isLoading = false
        var errorMessage: String?
    }

    /// Pages keyed by server name, in display order (home first).
    var pages: [ServerPage] = []

    var client: RelayClient?

    private var currentFilter: String?

    init(client: RelayClient? = nil) {
        self.client = client
    }

    /// Whether any page is currently loading.
    var isSearching: Bool {
        pages.contains { $0.isLoading }
    }

    /// Whether every page is empty and nothing is loading.
    var isEmpty: Bool {
        !isSearching && pages.allSatisfy { $0.rooms.isEmpty && $0.errorMessage == nil }
    }

    /// (Re)load the first page of every given server concurrently.
    ///
    /// - Parameters:
    ///   - query: Search text, or nil to list popular rooms.
    ///   - homeServer: Display name of the logged-in homeserver, if any.
    ///   - remotes: Enabled extra server names.
    @MainActor
    func search(query: String?, homeServer: String?, remotes: [String]) async {
        guard let client else { return }
        currentFilter = query
        pages = Self.makePages(homeServer: homeServer, remotes: remotes)
        guard !pages.isEmpty else { return }
        for index in pages.indices {
            pages[index].isLoading = true
            pages[index].errorMessage = nil
        }
        let filter = query
        await withTaskGroup(of: (Int, Result<PageResult, Error>).self) { group in
            for index in pages.indices {
                let page = pages[index]
                group.addTask {
                    do {
                        let result = try await client.publicRooms(
                            filter: filter,
                            server: page.isHome ? nil : page.serverName)
                        return (index, .success(PageResult(
                            rooms: result.rooms, nextBatch: result.nextBatch)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            for await (index, result) in group {
                pages[index].isLoading = false
                switch result {
                case .success(let page):
                    pages[index].rooms = page.rooms
                    pages[index].nextBatch = page.nextBatch
                    pages[index].isAtEnd = page.nextBatch == nil
                case .failure(let error):
                    pages[index].errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Load the next page for one server, if any.
    @MainActor
    func loadMore(serverName: String) async {
        guard let client,
            let index = pages.firstIndex(where: { $0.serverName == serverName })
        else { return }
        guard !pages[index].isLoading, !pages[index].isAtEnd,
            let nextBatch = pages[index].nextBatch
        else { return }
        pages[index].isLoading = true
        pages[index].errorMessage = nil
        let page = pages[index]
        do {
            let result = try await client.publicRooms(
                filter: currentFilter, since: nextBatch,
                server: page.isHome ? nil : page.serverName)
            pages[index].rooms += result.rooms
            pages[index].nextBatch = result.nextBatch
            pages[index].isAtEnd = result.nextBatch == nil
        } catch {
            pages[index].errorMessage = error.localizedDescription
        }
        pages[index].isLoading = false
    }

    /// Retry a failed server page.
    @MainActor
    func retry(serverName: String) async {
        guard let index = pages.firstIndex(where: { $0.serverName == serverName }) else { return }
        pages[index].errorMessage = nil
        if pages[index].rooms.isEmpty {
            pages[index].isLoading = true
            guard let client else {
                pages[index].isLoading = false
                return
            }
            let page = pages[index]
            do {
                let result = try await client.publicRooms(
                    filter: currentFilter,
                    server: page.isHome ? nil : page.serverName)
                pages[index].rooms = result.rooms
                pages[index].nextBatch = result.nextBatch
                pages[index].isAtEnd = result.nextBatch == nil
            } catch {
                pages[index].errorMessage = error.localizedDescription
            }
            pages[index].isLoading = false
        } else {
            await loadMore(serverName: serverName)
        }
    }

    private static func makePages(homeServer: String?, remotes: [String]) -> [ServerPage] {
        var pages: [ServerPage] = []
        if let homeServer {
            pages.append(ServerPage(serverName: homeServer, isHome: true))
        }
        for remote in remotes where remote != homeServer {
            pages.append(ServerPage(serverName: remote, isHome: false))
        }
        return pages
    }

    private struct PageResult {
        var rooms: [PublicRoomEntry]
        var nextBatch: String?
    }
}
