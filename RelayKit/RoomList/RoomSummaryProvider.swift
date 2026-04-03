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

// RoomSummaryProvider.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Observation

/// An `@Observable` provider that maintains a live list of ``RoomSummary`` values.
///
/// Subscribes to room list entry diffs from the SDK and applies them
/// using ``DiffEngine`` to maintain an up-to-date array of room summaries.
/// Supports dynamic filtering and pagination.
///
/// ```swift
/// struct RoomListView: View {
///     let provider: RoomSummaryProvider
///
///     var body: some View {
///         List(provider.rooms) { room in
///             RoomRow(summary: room)
///         }
///         .task {
///             await provider.observeUpdates()
///         }
///     }
/// }
/// ```
@Observable
public final class RoomSummaryProvider: RoomSummaryProviderProtocol, @unchecked Sendable {
    private let roomListService: RoomListService
    private var entriesResult: RoomListEntriesWithDynamicAdaptersResult?
    private var loadingStateResult: RoomListLoadingStateResult?
    private var roomList: RoomList?

    /// Maps Room ID -> Room for building summaries.
    private var roomMap: [String: Room] = [:]

    /// The current list of room summaries.
    public private(set) var rooms: [RoomSummary] = []

    /// The loading state of the room list.
    public private(set) var loadingState: RoomListLoadingState = .notLoaded

    /// Continuation for the internal diff stream.
    private let diffContinuation: AsyncStream<[RoomListEntriesUpdate]>.Continuation
    private let diffStream: AsyncStream<[RoomListEntriesUpdate]>

    /// Creates a room summary provider.
    ///
    /// - Parameters:
    ///   - roomListService: The SDK room list service.
    ///   - pageSize: The number of rooms per page (default: 20).
    public init(roomListService: RoomListService, pageSize: UInt32 = 20) {
        self.roomListService = roomListService

        let (stream, continuation) = AsyncStream<[RoomListEntriesUpdate]>.makeStream(
            bufferingPolicy: .bufferingNewest(100)
        )
        self.diffStream = stream
        self.diffContinuation = continuation
    }

    /// Sets up the room list and begins listening for updates.
    ///
    /// - Parameter pageSize: The number of rooms per page.
    /// - Throws: If the room list cannot be loaded.
    public func configure(pageSize: UInt32 = 20) async throws {
        let list = try await roomListService.allRooms()
        self.roomList = list

        entriesResult = list.entriesWithDynamicAdapters(
            pageSize: pageSize,
            listener: SDKListener { [weak self] updates in
                self?.diffContinuation.yield(updates)
            }
        )

        loadingStateResult = try list.loadingState(
            listener: SDKListener { [weak self] state in
                Task { @MainActor in self?.loadingState = state }
            }
        )
        self.loadingState = loadingStateResult?.state ?? .notLoaded
    }

    /// Observes room list diffs and maintains the ``rooms`` array.
    ///
    /// This method runs indefinitely until the task is cancelled.
    public func observeUpdates() async {
        for await updates in diffStream {
            let operations = updates.map { update -> DiffOperation<Room> in
                roomListEntryUpdateToOperation(update)
            }
            let currentRooms = roomMap.values.map { $0 }
            let updatedRoomList = DiffEngine.applyBatch(operations, to: Array(currentRooms))

            // Rebuild room map and summaries
            var newMap: [String: Room] = [:]
            var newSummaries: [RoomSummary] = []
            for room in updatedRoomList {
                let id = room.id()
                newMap[id] = room
                if let info = try? await room.roomInfo() {
                    newSummaries.append(RoomSummary(roomInfo: info))
                }
            }
            roomMap = newMap
            rooms = newSummaries
        }
    }

    // MARK: - RoomSummaryProviderProtocol

    @discardableResult
    public func setFilter(_ kind: RoomListEntriesDynamicFilterKind) -> Bool {
        entriesResult?.controller().setFilter(kind: kind) ?? false
    }

    public func loadNextPage() {
        entriesResult?.controller().addOnePage()
    }

    public func subscribeToVisibleRooms(ids: [String]) async throws {
        try await roomListService.subscribeToRooms(roomIds: ids)
    }

    deinit {
        diffContinuation.finish()
    }
}

/// Converts a `RoomListEntriesUpdate` to a ``DiffOperation``.
private func roomListEntryUpdateToOperation(_ update: RoomListEntriesUpdate) -> DiffOperation<Room> {
    switch update {
    case .append(let values):
        return .append(values)
    case .clear:
        return .clear
    case .pushFront(let value):
        return .pushFront(value)
    case .pushBack(let value):
        return .pushBack(value)
    case .popFront:
        return .popFront
    case .popBack:
        return .popBack
    case .insert(let index, let value):
        return .insert(Int(index), value)
    case .set(let index, let value):
        return .set(Int(index), value)
    case .remove(let index):
        return .remove(Int(index))
    case .truncate(let length):
        return .truncate(Int(length))
    case .reset(let values):
        return .reset(values)
    }
}
