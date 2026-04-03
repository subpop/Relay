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
import RelayInterface
import os
import Synchronization

private let logger = Logger(subsystem: "RelayKit", category: "DirectorySearch")

/// Searches the public room directory on the Matrix homeserver.
///
/// ``DirectorySearchService`` wraps the SDK's `RoomDirectorySearch` API, collecting
/// results via a thread-safe collector and returning them as ``DirectoryRoom`` models.
@MainActor
final class DirectorySearchService {

    /// Searches the public room directory for rooms matching the query.
    ///
    /// - Parameters:
    ///   - query: The search string to match against room names and aliases.
    ///   - client: The authenticated Matrix SDK client.
    /// - Returns: A list of matching ``DirectoryRoom`` results.
    func search(query: String, client: Client) async throws -> [DirectoryRoom] {
        let search = client.roomDirectorySearch()
        let collector = DirectorySearchCollector()

        let listener = SDKListener<[RoomDirectorySearchEntryUpdate]> { updates in
            collector.apply(updates)
        }

        let handle = await search.results(listener: listener)
        try await search.search(filter: query, batchSize: 20, viaServerName: nil)
        try await Task.sleep(for: .milliseconds(500))

        let descriptions = collector.snapshot()
        withExtendedLifetime(handle) {}
        return descriptions.map { desc in
            DirectoryRoom(
                roomId: desc.roomId,
                name: desc.name,
                topic: desc.topic,
                alias: desc.alias,
                avatarURL: desc.avatarUrl,
                memberCount: desc.joinedMembers,
                isWorldReadable: desc.isWorldReadable
            )
        }
    }
}

// MARK: - Directory Search Collector

/// Thread-safe collector that accumulates room directory search results from SDK callbacks.
nonisolated private final class DirectorySearchCollector: Sendable {
    private let storage = Mutex<[RoomDescription]>([])

    nonisolated func apply(_ updates: [RoomDirectorySearchEntryUpdate]) {
        storage.withLock { results in
            for update in updates {
                switch update {
                case .append(let values):
                    results.append(contentsOf: values)
                case .clear:
                    results.removeAll()
                case .pushBack(let value):
                    results.append(value)
                case .pushFront(let value):
                    results.insert(value, at: 0)
                case .insert(let index, let value):
                    results.insert(value, at: Int(index))
                case .set(let index, let value):
                    results[Int(index)] = value
                case .remove(let index):
                    results.remove(at: Int(index))
                case .popFront:
                    if !results.isEmpty { results.removeFirst() }
                case .popBack:
                    if !results.isEmpty { results.removeLast() }
                case .reset(let values):
                    results = values
                case .truncate(let length):
                    results = Array(results.prefix(Int(length)))
                }
            }
        }
    }

    nonisolated func snapshot() -> [RoomDescription] {
        storage.withLock { $0 }
    }
}
