import Foundation
import MatrixRustSDK
import os
import RelayCore
import Synchronization

private let logger = Logger(subsystem: "RelaySDK", category: "DirectorySearch")

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

        let listener = DirectorySearchListenerProxy { updates in
            collector.apply(updates)
        }

        let handle = await search.results(listener: listener)
        try await search.search(filter: query, batchSize: 20, viaServerName: nil)
        try await Task.sleep(for: .milliseconds(500))

        let results = collector.snapshot()
        withExtendedLifetime(handle) {}
        return results
    }
}

// MARK: - Directory Search Collector

/// Thread-safe collector that accumulates room directory search results from SDK callbacks.
nonisolated private final class DirectorySearchCollector: Sendable {
    private let storage = Mutex<[DirectoryRoom]>([])

    nonisolated func apply(_ updates: [RoomDirectorySearchEntryUpdate]) {
        storage.withLock { results in
            for update in updates {
                switch update {
                case .append(let values):
                    results.append(contentsOf: values.map(DirectoryRoom.from))
                case .clear:
                    results.removeAll()
                case .pushBack(let value):
                    results.append(.from(value))
                case .pushFront(let value):
                    results.insert(.from(value), at: 0)
                case .insert(let index, let value):
                    results.insert(.from(value), at: Int(index))
                case .set(let index, let value):
                    results[Int(index)] = .from(value)
                case .remove(let index):
                    results.remove(at: Int(index))
                case .popFront:
                    if !results.isEmpty { results.removeFirst() }
                case .popBack:
                    if !results.isEmpty { results.removeLast() }
                case .reset(let values):
                    results = values.map(DirectoryRoom.from)
                case .truncate(let length):
                    results = Array(results.prefix(Int(length)))
                }
            }
        }
    }

    nonisolated func snapshot() -> [DirectoryRoom] {
        storage.withLock { $0 }
    }
}

// MARK: - Directory Search Listener Bridge

/// Bridges `RoomDirectorySearchEntriesListener` callbacks from the Matrix Rust SDK to a Swift closure.
nonisolated final class DirectorySearchListenerProxy: RoomDirectorySearchEntriesListener, @unchecked Sendable {
    private let handler: @Sendable ([RoomDirectorySearchEntryUpdate]) -> Void

    init(handler: @escaping @Sendable ([RoomDirectorySearchEntryUpdate]) -> Void) {
        self.handler = handler
    }

    func onUpdate(roomEntriesUpdate: [RoomDirectorySearchEntryUpdate]) {
        handler(roomEntriesUpdate)
    }
}

// MARK: - RoomDescription -> DirectoryRoom

extension DirectoryRoom {
    /// Converts a Matrix Rust SDK `RoomDescription` into a ``DirectoryRoom`` model.
    nonisolated static func from(_ desc: RoomDescription) -> DirectoryRoom {
        DirectoryRoom(
            roomId: desc.roomId,
            name: desc.name,
            topic: desc.topic,
            alias: desc.alias,
            avatarURL: desc.avatarUrl,
            memberCount: desc.joinedMembers
        )
    }
}
