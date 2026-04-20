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
import Observation
import RelayInterface
import os

private let logger = Logger(subsystem: "RelayKit", category: "SpaceHierarchyViewModel")

/// The concrete implementation of ``SpaceHierarchyViewModelProtocol`` backed by the
/// Matrix Rust SDK's `SpaceRoomList`.
///
/// ``SpaceHierarchyViewModel`` loads a paginated list of rooms within a space using
/// the `/hierarchy` endpoint. It subscribes to room entry updates and pagination
/// state changes so the UI stays reactive.
@Observable
public final class SpaceHierarchyViewModel: SpaceHierarchyViewModelProtocol {
    public private(set) var spaceName: String
    public private(set) var spaceTopic: String?
    public private(set) var spaceAvatarURL: String?
    public private(set) var spaceMemberCount: UInt64 = 0
    public private(set) var isJoined: Bool = false
    public private(set) var canManageChildren: Bool = false
    public private(set) var children: [SpaceChild] = []
    public private(set) var isLoading = false
    public private(set) var isAtEnd = false

    private let spaceId: String
    private let client: any ClientProxyProtocol
    private let errorReporter: ErrorReporter

    private var spaceRoomList: SpaceRoomList?
    private var spaceRooms: [SpaceRoom] = []
    private var entriesHandle: TaskHandle?
    private var paginationHandle: TaskHandle?
    private var entriesTask: Task<Void, Never>?

    /// Creates a space hierarchy view model.
    ///
    /// - Parameters:
    ///   - spaceId: The Matrix room ID of the space to browse.
    ///   - spaceName: The display name of the space (used immediately before load completes).
    ///   - client: The authenticated client proxy.
    ///   - errorReporter: The error reporter for presenting failures.
    public init(
        spaceId: String,
        spaceName: String,
        client: any ClientProxyProtocol,
        errorReporter: ErrorReporter
    ) {
        self.spaceId = spaceId
        self.spaceName = spaceName
        self.client = client
        self.errorReporter = errorReporter
    }

    deinit {
        MainActor.assumeIsolated {
            entriesTask?.cancel()
        }
    }

    public func load() async {
        guard spaceRoomList == nil else { return }
        isLoading = true

        do {
            let service = await client.spaceService()
            let roomList = try await service.spaceRoomList(spaceId: spaceId)
            spaceRoomList = roomList

            // Populate space metadata from the space itself
            if let space = roomList.space() {
                spaceName = space.displayName
                spaceTopic = space.topic
                spaceAvatarURL = space.avatarUrl
                spaceMemberCount = space.numJoinedMembers
                isJoined = space.state == .joined
            }

            // Check if the user can manage children in this space
            let editable = await service.editableSpaces()
            canManageChildren = editable.contains { $0.roomId == spaceId }

            // Subscribe to room entry updates
            let (entriesStream, entriesContinuation) = AsyncStream<[SpaceListUpdate]>.makeStream()
            let entriesListener = SpaceRoomListEntriesListenerProxy { updates in
                entriesContinuation.yield(updates)
            }
            entriesHandle = roomList.subscribeToRoomUpdate(listener: entriesListener)

            // Subscribe to pagination state
            let (paginationStream, paginationContinuation) = AsyncStream<SpaceRoomListPaginationState>.makeStream()
            let paginationListener = SpaceRoomListPaginationStateListenerProxy { state in
                paginationContinuation.yield(state)
            }
            paginationHandle = roomList.subscribeToPaginationStateUpdates(listener: paginationListener)

            // Observe entries
            entriesTask = Task { [weak self] in
                for await updates in entriesStream {
                    guard let self, !Task.isCancelled else { break }
                    self.applyUpdates(updates)
                }
            }

            // Observe pagination state in a detached task
            Task { [weak self] in
                for await state in paginationStream {
                    guard let self, !Task.isCancelled else { break }
                    switch state {
                    case .idle(let endReached):
                        self.isLoading = false
                        self.isAtEnd = endReached
                    case .loading:
                        self.isLoading = true
                    }
                }
            }

            // Fetch the first page
            try await roomList.paginate()

            // Read initial results
            spaceRooms = roomList.rooms()
            rebuildChildren()
        } catch is CancellationError {
            // Ignore
        } catch {
            logger.error("Failed to load space hierarchy: \(error)")
            errorReporter.report(.roomJoinFailed(error.localizedDescription))
        }

        isLoading = false
    }

    public func loadMore() async {
        guard !isAtEnd, !isLoading, let roomList = spaceRoomList else { return }
        isLoading = true

        do {
            try await roomList.paginate()
            spaceRooms = roomList.rooms()
            rebuildChildren()
        } catch is CancellationError {
            // Ignore
        } catch {
            logger.error("Failed to load more hierarchy results: \(error)")
        }

        isLoading = false
    }

    public func joinRoom(roomId: String) async throws {
        _ = try await client.joinRoom(id: roomId)
        // If the user joined the space itself, update membership state
        if roomId == spaceId {
            isJoined = true
        }
    }

    // MARK: - Private

    // swiftlint:disable:next cyclomatic_complexity
    private func applyUpdates(_ updates: [SpaceListUpdate]) {
        for update in updates {
            switch update {
            case .append(let values):
                spaceRooms.append(contentsOf: values)
            case .clear:
                spaceRooms.removeAll()
            case .pushFront(let value):
                spaceRooms.insert(value, at: 0)
            case .pushBack(let value):
                spaceRooms.append(value)
            case .popFront:
                if !spaceRooms.isEmpty { spaceRooms.removeFirst() }
            case .popBack:
                if !spaceRooms.isEmpty { spaceRooms.removeLast() }
            case .insert(let index, let value):
                let i = Int(index)
                if i <= spaceRooms.count { spaceRooms.insert(value, at: i) }
            case .set(let index, let value):
                let i = Int(index)
                if i < spaceRooms.count { spaceRooms[i] = value }
            case .remove(let index):
                let i = Int(index)
                if i < spaceRooms.count { spaceRooms.remove(at: i) }
            case .truncate(let length):
                let len = Int(length)
                if len < spaceRooms.count { spaceRooms.removeSubrange(len..<spaceRooms.count) }
            case .reset(let values):
                spaceRooms = values
            }
        }
        rebuildChildren()
    }

    private func rebuildChildren() {
        // The /hierarchy endpoint can return duplicate entries for the same room.
        // Deduplicate by roomId, keeping the first occurrence.
        var seen = Set<String>()
        children = spaceRooms
            .filter { $0.roomId != spaceId } // Exclude the space itself
            .filter { seen.insert($0.roomId).inserted }
            .map { room in
                SpaceChild(
                    roomId: room.roomId,
                    name: room.displayName,
                    topic: room.topic,
                    avatarURL: room.avatarUrl,
                    memberCount: room.numJoinedMembers,
                    roomType: room.roomType == .space ? .space : .room,
                    isJoined: room.state == .joined,
                    childrenCount: room.childrenCount,
                    joinRule: mapJoinRule(room.joinRule),
                    canonicalAlias: room.canonicalAlias
                )
            }
    }

    private func mapJoinRule(_ joinRule: JoinRule?) -> SpaceChildJoinRule? {
        switch joinRule {
        case .public: .public
        case .knock, .knockRestricted: .knock
        case .invite: .invite
        case .restricted: .restricted
        case .private: .invite
        default: nil
        }
    }
}
