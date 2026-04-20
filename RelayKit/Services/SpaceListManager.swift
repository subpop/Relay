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

private let logger = Logger(subsystem: "RelayKit", category: "SpaceList")

/// Maintains the list of joined spaces and the space-to-room membership graph
/// using the SDK's reactive `SpaceService`.
///
/// ``SpaceListManager`` subscribes to `SpaceService.subscribeToTopLevelJoinedSpaces()`
/// for space list diffs and `SpaceService.subscribeToSpaceFilters()` for the
/// descendant room mapping. The room list manager uses ``spaceDescendants`` to
/// populate each room's `parentSpaceIds`.
@Observable
@MainActor
final class SpaceListManager {
    /// The current list of top-level joined spaces as UI-facing summaries.
    private(set) var spaces: [RelayInterface.RoomSummary] = []

    /// A mapping from space ID to the set of descendant room IDs.
    ///
    /// Built from the SDK's ``SpaceFilter`` data. Top-level spaces (level 0)
    /// contain direct descendants, while level-1 sub-spaces contain all
    /// remaining descendants recursively.
    private(set) var spaceDescendants: [String: Set<String>] = [:]

    /// Callback invoked when ``spaceDescendants`` changes.
    ///
    /// The ``MatrixService`` uses this to re-apply `parentSpaceIds` to rooms
    /// whenever the space-to-room mapping is updated.
    var onDescendantsChanged: (() -> Void)?

    /// Internal space room data received from SDK diffs.
    private var spaceRooms: [SpaceRoom] = []

    /// The space filters received from the SDK, used to build ``spaceDescendants``.
    private var spaceFilters: [SpaceFilter] = []

    private var spaceService: SpaceService?
    private var spacesHandle: TaskHandle?
    private var filtersHandle: TaskHandle?
    private var spacesTask: Task<Void, Never>?
    private var filtersTask: Task<Void, Never>?

    /// Starts observing the space service for joined spaces and space filters.
    ///
    /// - Parameter client: The authenticated SDK client proxy.
    func start(client: ClientProxy) async {
        let service = await client.spaceService()
        spaceService = service

        // Fetch initial data
        let initialSpaces = await service.topLevelJoinedSpaces()
        spaceRooms = initialSpaces

        let initialFilters = await service.spaceFilters()
        spaceFilters = initialFilters

        // Build descendants first, then space summaries (which includes sub-spaces
        // extracted from the filter data)
        rebuildSpaceDescendants()

        // Subscribe to joined spaces updates
        let (spacesStream, spacesContinuation) = AsyncStream<[SpaceListUpdate]>.makeStream()
        let spacesListener = SDKListener<[SpaceListUpdate]> { updates in
            spacesContinuation.yield(updates)
        }
        spacesHandle = await service.subscribeToTopLevelJoinedSpaces(listener: spacesListener)

        spacesTask = Task { [weak self] in
            for await updates in spacesStream {
                guard let self, !Task.isCancelled else { break }
                self.applySpaceUpdates(updates)
            }
        }

        // Subscribe to space filter updates
        let (filtersStream, filtersContinuation) = AsyncStream<[SpaceFilterUpdate]>.makeStream()
        let filtersListener = SDKListener<[SpaceFilterUpdate]> { updates in
            filtersContinuation.yield(updates)
        }
        filtersHandle = await service.subscribeToSpaceFilters(listener: filtersListener)

        filtersTask = Task { [weak self] in
            for await updates in filtersStream {
                guard let self, !Task.isCancelled else { break }
                self.applyFilterUpdates(updates)
            }
        }

        logger.info("Started with \(initialSpaces.count) spaces and \(initialFilters.count) filters, \(self.spaceDescendants.count) descendant entries")
    }

    /// Stops all subscriptions and clears state.
    func reset() {
        spacesTask?.cancel()
        spacesTask = nil
        filtersTask?.cancel()
        filtersTask = nil
        spacesHandle = nil
        filtersHandle = nil
        spaceService = nil
        spaceRooms = []
        spaceFilters = []
        spaces = []
        spaceDescendants = [:]
    }

    // MARK: - Space List Updates

    // swiftlint:disable:next cyclomatic_complexity
    private func applySpaceUpdates(_ updates: [SpaceListUpdate]) {
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
                if i <= spaceRooms.count {
                    spaceRooms.insert(value, at: i)
                }
            case .set(let index, let value):
                let i = Int(index)
                if i < spaceRooms.count {
                    spaceRooms[i] = value
                }
            case .remove(let index):
                let i = Int(index)
                if i < spaceRooms.count {
                    spaceRooms.remove(at: i)
                }
            case .truncate(let length):
                let len = Int(length)
                if len < spaceRooms.count {
                    spaceRooms.removeSubrange(len..<spaceRooms.count)
                }
            case .reset(let values):
                spaceRooms = values
            }
        }

        rebuildSpaceSummaries()
    }

    // MARK: - Space Filter Updates

    // swiftlint:disable:next cyclomatic_complexity
    private func applyFilterUpdates(_ updates: [SpaceFilterUpdate]) {
        for update in updates {
            switch update {
            case .append(let values):
                spaceFilters.append(contentsOf: values)
            case .clear:
                spaceFilters.removeAll()
            case .pushFront(let value):
                spaceFilters.insert(value, at: 0)
            case .pushBack(let value):
                spaceFilters.append(value)
            case .popFront:
                if !spaceFilters.isEmpty { spaceFilters.removeFirst() }
            case .popBack:
                if !spaceFilters.isEmpty { spaceFilters.removeLast() }
            case .insert(let index, let value):
                let i = Int(index)
                if i <= spaceFilters.count {
                    spaceFilters.insert(value, at: i)
                }
            case .set(let index, let value):
                let i = Int(index)
                if i < spaceFilters.count {
                    spaceFilters[i] = value
                }
            case .remove(let index):
                let i = Int(index)
                if i < spaceFilters.count {
                    spaceFilters.remove(at: i)
                }
            case .truncate(let length):
                let len = Int(length)
                if len < spaceFilters.count {
                    spaceFilters.removeSubrange(len..<spaceFilters.count)
                }
            case .reset(let values):
                spaceFilters = values
            }
        }

        rebuildSpaceDescendants()
    }

    // MARK: - Rebuild

    /// Converts the SDK `SpaceRoom` list into UI-facing `RoomSummary` objects.
    private func rebuildSpaceSummaries() {
        // Start with top-level spaces from topLevelJoinedSpaces()
        var seen = Set<String>()
        var allSpaces: [RelayInterface.RoomSummary] = []

        for spaceRoom in spaceRooms {
            if seen.insert(spaceRoom.roomId).inserted {
                allSpaces.append(makeSpaceSummary(from: spaceRoom))
            }
        }

        // Add joined sub-spaces from level-1 space filters
        // (topLevelJoinedSpaces() only returns top-level spaces, not nested ones)
        for filter in spaceFilters where filter.level > 0 {
            let spaceRoom = filter.spaceRoom
            guard spaceRoom.state == .joined else { continue }
            if seen.insert(spaceRoom.roomId).inserted {
                allSpaces.append(makeSpaceSummary(from: spaceRoom))
            }
        }

        spaces = allSpaces
        // Re-apply parentSpaceIds so new spaces get their parent mappings
        onDescendantsChanged?()
    }

    private func makeSpaceSummary(from spaceRoom: SpaceRoom) -> RelayInterface.RoomSummary {
        RelayInterface.RoomSummary(
            id: spaceRoom.roomId,
            name: spaceRoom.displayName,
            avatarURL: spaceRoom.avatarUrl,
            canonicalAlias: spaceRoom.canonicalAlias,
            isSpace: true
        )
    }

    /// Builds the space-ID-to-descendant-room-IDs mapping from space filters.
    ///
    /// The SDK delivers space filters at two levels:
    /// - **Level 0**: Top-level spaces with their direct children (rooms and sub-spaces).
    /// - **Level 1**: Sub-spaces with all their descendants recursively.
    ///
    /// To enable filtering by top-level space, this method merges level-1 descendants
    /// up into their parent top-level space's entry. It does this by checking which
    /// level-1 sub-space IDs appear as direct children (level-0 descendants) of each
    /// top-level space.
    private func rebuildSpaceDescendants() {
        // Separate filters by level
        var topLevel: [String: Set<String>] = [:]     // level 0: spaceId -> direct child IDs
        var subLevel: [String: Set<String>] = [:]     // level 1: subSpaceId -> recursive descendant IDs

        for filter in spaceFilters {
            let spaceId = filter.spaceRoom.roomId
            let descendantSet = Set(filter.descendants)
            if filter.level == 0 {
                topLevel[spaceId, default: []].formUnion(descendantSet)
            } else {
                subLevel[spaceId, default: []].formUnion(descendantSet)
            }
        }

        // For each top-level space, merge in descendants from any sub-spaces
        // that appear as its direct children.
        var merged: [String: Set<String>] = [:]
        for (spaceId, directChildren) in topLevel {
            var allDescendants = directChildren
            for childId in directChildren {
                if let subDescendants = subLevel[childId] {
                    allDescendants.formUnion(subDescendants)
                }
            }
            merged[spaceId] = allDescendants
        }

        // Add each sub-space as its own entry so rooms can be filtered by
        // sub-space ID (when a sub-space is selected in the rail).
        for (subSpaceId, descendants) in subLevel {
            merged[subSpaceId, default: []].formUnion(descendants)
        }

        spaceDescendants = merged
        logger.debug("rebuildSpaceDescendants: \(topLevel.count) top-level, \(subLevel.count) sub-level, \(merged.count) merged entries")

        // Rebuild the full space list since sub-spaces come from filter data
        rebuildSpaceSummaries()
    }
}
