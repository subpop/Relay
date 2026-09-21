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

/// View model for a space hierarchy level.
///
/// Loads the space's children and metadata, tracks join state, and
/// exposes child management for users who can edit the space.
@Observable
final class SpaceHierarchyViewModel {
    /// The children of the current space level (all pages so far).
    /// Render only ``directChildren``; deeper levels resolve through
    /// each child's own detail level.
    var children: [SpaceChild] = []

    /// Direct child IDs of the current level, unioned across pages.
    private var directChildIds = Set<String>()

    /// Child edges of the current level, accumulated across pages.
    private var directChildrenEdges = [SpaceChildEdge]()

    /// Direct children of the current space level, ordered per the spec's
    /// `order` hint (then creation time, then room ID). Children without an
    /// edge trail in server order.
    var directChildren: [SpaceChild] {
        let byId = Dictionary(
            children.map { ($0.roomId.value, $0) },
            uniquingKeysWith: { _, new in new })
        var ordered: [SpaceChild] = []
        var seen = Set<String>()
        for edge in SpacesClient.orderedChildren(directChildrenEdges) {
            if let child = byId[edge.roomId.value] {
                ordered.append(child)
                seen.insert(edge.roomId.value)
            }
        }
        ordered += children.filter {
            directChildIds.contains($0.roomId.value) && !seen.contains($0.roomId.value)
        }
        return ordered
    }

    /// Whether every direct child of the current level has a row in
    /// ``children``. The space's own hierarchy entry lists all direct
    /// children, so this is knowable long before the (recursed, server-
    /// capped at 50 rooms per page) pagination drains. Once true the list
    /// is visually complete; remaining pages only warm deeper levels and
    /// the on-disk cache, so they continue silently (see `loadMore`).
    var isCurrentLevelComplete: Bool {
        !directChildIds.isEmpty
            && directChildIds.allSatisfy { id in
                children.contains { $0.roomId.value == id }
            }
    }
    /// Display metadata for the current space level.
    var spaceName: String?
    var spaceAvatarURL: String?
    var spaceTopic: String?
    var spaceMemberCount: Int?

    /// Whether the local user joined the current space.
    var isJoined = false

    /// Whether the local user can add or remove children.
    var canManageChildren = false

    /// Whether all hierarchy pages loaded.
    var isAtEnd = false

    /// Human-readable load failure; nil while loading or on success.
    /// Distinguishes "couldn't fetch" (e.g. an unjoined private space)
    /// from "fetched, genuinely empty".
    var loadError: String?

    var errorReporter: ErrorReporter?

    private let spaceId: String
    private var client: RelayClient
    private var nextBatch: String?
    /// Serializes hierarchy page fetches (the footer's `onAppear` can
    /// fire while a chained background fetch is in flight).
    private var isPaging = false
    /// Chained background page fetch, so pagination continues silently
    /// once the visible level is complete. Cancelled on `load()`.
    private var pagingTask: Task<Void, Never>?
    /// Bumped on `load()` so stale chained fetches bail instead of
    /// appending another space's pages.
    private var pagingGeneration = 0
    /// Whether the current generation already restarted pagination after
    /// an expired token, so a persistently failing server can't loop.
    private var restartedPagination = false

    init(spaceId: String, client: RelayClient) {
        self.spaceId = spaceId
        self.client = client
    }

    /// Rendered directly from the locally-restored (on-disk) room graph.
    /// True the moment disk content is available; the network refresh merges
    /// in the background.
    var hasLoaded = false

    /// Load the space's direct children.
    ///
    /// Renders the *persisted* room graph and last-fetched hierarchy rows
    /// from disk immediately so the detail pane paints instantly, then
    /// refreshes hierarchy pages, metadata, and editability from the
    /// network and merges the results. When nothing is known locally
    /// (e.g. an unjoined private space), this instead waits for the
    /// network page before showing.
    @MainActor
    func load() async {
        pagingTask?.cancel()
        pagingGeneration += 1
        restartedPagination = false
        loadError = nil
        directChildIds = []
        directChildrenEdges = []
        seedHeaderFromStore()
        let cached = await client.cachedSpaceHierarchy(spaceId: spaceId)
        if renderPersistedHierarchy(cached) || renderPersistedChildren() {
            hasLoaded = true
            Task { await refreshFromNetwork() }
            return
        }
        await refreshFromNetwork()
    }

    /// Best-effort header from the locally-restored room graph, so the
    /// space name and member count paint without waiting for `roomDetails`.
    /// The network refresh in ``refreshMetadata()`` corrects it afterwards.
    @MainActor
    private func seedHeaderFromStore() {
        guard
            let room = client.rooms.first(where: { $0.roomId.value == spaceId })
        else { return }
        spaceName = room.displayName
        spaceAvatarURL = room.avatarURL?.value
        spaceTopic = room.topic
        isJoined = room.membership == .join
        let persistedCount = room.memberDetails.count
        if spaceMemberCount == nil, persistedCount > 0 {
            spaceMemberCount = persistedCount
        }
    }

    /// Best-effort render of ``children`` from the last-fetched hierarchy
    /// rows in the local store, so a previously opened space shows
    /// instantly with server-reported member counts — including children
    /// the user hasn't joined. Join state is overlaid from the live room
    /// list, since membership may have changed since the fetch. Returns
    /// whether any rows were known locally.
    @MainActor
    private func renderPersistedHierarchy(
        _ cached: (
            children: [SpaceChild], directChildren: [SpaceChildEdge],
            nextBatch: String?
        )
    ) -> Bool {
        guard !cached.children.isEmpty else { return false }
        let joinedIds = Set(client.rooms.map(\.roomId))
        children = cached.children.map { child in
            var child = child
            child.isJoined = joinedIds.contains(child.roomId)
            return child
        }
        directChildrenEdges = cached.directChildren
        if cached.directChildren.isEmpty {
            // No ordering edges cached (e.g. the space's own hierarchy
            // entry carried none): show what we know; the network refresh
            // corrects levels and order.
            directChildIds = Set(cached.children.map { $0.roomId.value })
        } else {
            directChildIds = Set(cached.directChildren.map { $0.roomId.value })
        }
        nextBatch = cached.nextBatch
        isAtEnd = cached.nextBatch == nil
        return true
    }

    /// Best-effort render of ``directChildren`` straight from the persisted
    /// room graph, so a joined space's detail shows instantly without a
    /// network round trip. Returns whether any direct children were known
    /// locally. Server ordering and full metadata arrive with the background
    /// refresh.
    @MainActor
    private func renderPersistedChildren() -> Bool {
        let space = RoomId(unchecked: spaceId)
        var direct: [SpaceChild] = []
        for room in client.rooms where room.spaceParents.contains(space) {
            direct.append(SpaceChild(
                roomId: room.roomId,
                name: room.displayName,
                avatarURL: room.avatarURL,
                memberCount: room.members.count,
                roomType: room.isSpace ? .space : .room,
                isJoined: room.membership == .join))
        }
        children = direct
        directChildIds = Set(direct.map { $0.roomId.value })
        directChildrenEdges = direct.map { SpaceChildEdge(roomId: $0.roomId) }
        return !direct.isEmpty
    }

    /// Fetch hierarchy pages, metadata, and editability from the network and
    /// merge into this level. Merges by room ID instead of replacing, so
    /// rows rendered from the disk cache don't flicker and children the
    /// (possibly truncated) first page omits stay visible until pagination
    /// reaches them.
    @MainActor
    private func refreshFromNetwork() async {
        do {
            let page = try await client.spaceHierarchy(spaceId: spaceId)
            let reported = Set(page.children.map(\.roomId))
            children = page.children + children.filter { !reported.contains($0.roomId) }
            directChildIds = page.directChildIds
            directChildrenEdges = page.directChildren
            nextBatch = page.nextBatch
            isAtEnd = page.nextBatch == nil
            await refreshMetadata()
            canManageChildren = ((try? await client.editableSpaces()) ?? [])
                .contains { $0.roomId.value == spaceId }
            hasLoaded = true
            restartedPagination = false
            continuePagingIfNeeded()
        } catch {
            if error is CancellationError
                || (error as? MatrixError)?.isCancellation == true
            {
                return
            }
            loadError = error.localizedDescription
            errorReporter?.report(.spaceHierarchyFailed(error.localizedDescription))
            hasLoaded = true
        }
    }

    /// Load the next hierarchy page, if any. When the visible level is
    /// already complete, further pages are chained silently in the
    /// background (warming deeper levels and the on-disk cache) instead
    /// of behind the footer's spinner. Errors stop the chain without
    /// surfacing: the footer stays put for another attempt.
    @MainActor
    func loadMore() async {
        guard !isAtEnd, !isPaging, let nextBatch else { return }
        let generation = pagingGeneration
        isPaging = true
        defer { isPaging = false }
        do {
            let page = try await client.spaceHierarchy(
                spaceId: spaceId, since: nextBatch)
            // A chained fetch may have been superseded (e.g. a fresh
            // load reset state while this page was in flight): drop it
            // instead of appending another generation's rows.
            guard generation == pagingGeneration else { return }
            let knownIds = Set(children.map(\.roomId))
            children += page.children.filter { !knownIds.contains($0.roomId) }
            directChildIds.formUnion(page.directChildIds)
            directChildrenEdges += page.directChildren
            self.nextBatch = page.nextBatch
            isAtEnd = page.nextBatch == nil
            continuePagingIfNeeded()
        } catch {
            // Our own paging-task management cancels superseded fetches;
            // view teardown cancels the rest. Neither is a failure.
            if error is CancellationError
                || (error as? MatrixError)?.isCancellation == true
            {
                return
            }
            // Hierarchy pagination sessions are server-side and short-
            // lived (Synapse: 5 minutes), so a `since` token restored
            // from disk or outlived by slow pages 400s. Restart from
            // the first page once per generation instead of stalling.
            if !restartedPagination, isExpiredPaginationToken(error) {
                restartedPagination = true
                await restartPagination()
            } else {
                errorReporter?.report(.spaceHierarchyFailed(error.localizedDescription))
            }
        }
    }

    /// A 400 for the page token (not for the request itself).
    private func isExpiredPaginationToken(_ error: Error) -> Bool {
        guard
            case .serverError(let code, let message, _) = error as? MatrixError
        else { return false }
        return code == "M_INVALID_PARAM"
            && message.localizedStandardContains("pagination token")
    }

    /// Re-fetch the first hierarchy page and resume chaining, merging
    /// like the network refresh so visible rows don't flicker.
    @MainActor
    private func restartPagination() async {
        do {
            let page = try await client.spaceHierarchy(spaceId: spaceId)
            let reported = Set(page.children.map(\.roomId))
            children = page.children + children.filter { !reported.contains($0.roomId) }
            directChildIds = page.directChildIds
            directChildrenEdges = page.directChildren
            nextBatch = page.nextBatch
            isAtEnd = page.nextBatch == nil
            continuePagingIfNeeded()
        } catch {
            if error is CancellationError
                || (error as? MatrixError)?.isCancellation == true
            {
                return
            }
            errorReporter?.report(.spaceHierarchyFailed(error.localizedDescription))
        }
    }

    /// Fetch the next page in the background when pagination hasn't
    /// drained. The footer drives fetches while the visible level is
    /// incomplete; once `isCurrentLevelComplete` hides it, this chain
    /// takes over so deep trees (e.g. Fedora) keep warming silently.
    @MainActor
    private func continuePagingIfNeeded() {
        guard !isAtEnd, nextBatch != nil else { return }
        let generation = pagingGeneration
        pagingTask?.cancel()
        pagingTask = Task {
            guard generation == self.pagingGeneration else { return }
            await self.loadMore()
        }
    }

    /// Join a room or sub-space by ID.
    func joinRoom(roomId: String) async throws {
        try await client.joinRoom(idOrAlias: roomId)
    }

    private func refreshMetadata() async {
        if let room = client.rooms.first(where: { $0.roomId.value == spaceId }) {
            spaceName = room.displayName
            spaceAvatarURL = room.avatarURL?.value
            spaceTopic = room.topic
            isJoined = room.membership == .join
        }
        if let details = await client.roomDetails(roomId: spaceId) {
            spaceName = details.name ?? spaceName
            spaceAvatarURL = details.avatarURL?.value ?? spaceAvatarURL
            spaceTopic = details.topic ?? spaceTopic
            spaceMemberCount = details.memberCount
        }
    }
}
