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

/// Information about a new notification-worthy event in a room.
public struct RoomNotificationEvent: Sendable {
    /// The room ID that has new unread activity.
    public let roomId: String
    /// The display name of the room.
    public let roomName: String
    /// A plain-text representation of the latest author, if available.
    public let messageAuthor: String?
    /// A plain-text preview of the latest message, if available.
    public let messageBody: String?
    /// Whether the new activity includes a mention of the current user.
    public let isMention: Bool
    /// Whether the new activity is in a direct message room.
    public let isDirect: Bool
    /// The room's per-room notification mode override, or `nil` if using the default.
    public let notificationMode: RelayInterface.RoomNotificationMode?
}

/// Maintains the sorted list of joined rooms using the SDK's reactive `RoomListService`.
///
/// ``RoomListManager`` subscribes to `RoomListService.allRooms().entriesWithDynamicAdapters()`
/// for incremental room list diffs, and each room subscribes to `Room.subscribeToRoomInfoUpdates()`
/// for live unread counts, display names, and latest message previews. This replaces the
/// previous polling approach with event-driven updates from the Matrix Rust SDK.
@Observable
@MainActor
final class RoomListManager {
    /// The current list of room summaries, updated reactively via SDK diffs.
    private(set) var rooms: [RelayInterface.RoomSummary] = []

    /// Whether the initial room list has been loaded.
    private(set) var hasLoadedRooms = false

    /// The current state of the room list service.
    private(set) var roomListServiceState: RoomListServiceState?

    /// The SDK's room list service, exposed for room subscription calls.
    private(set) var roomListService: RoomListService?
    private var entriesHandle: RoomListEntriesWithDynamicAdaptersResult?
    private var serviceStateHandle: TaskHandle?
    private var stateObservationTask: Task<Void, Never>?
    private var entriesTask: Task<Void, Never>?

    /// Internal room entries that wrap SDK `Room` objects and manage `subscribeToRoomInfoUpdates`.
    private var roomEntries: [RoomEntry] = []

    /// Debounce task for re-sorting after room info updates.
    private var resortTask: Task<Void, Never>?

    /// The diagnostic activity log for capturing service-level events.
    var activityLog: ActivityLog?

    /// Callback invoked when a room has new notification-worthy activity.
    ///
    /// The app layer uses this to post system notifications.
    var onNotificationEvent: ((RoomNotificationEvent) -> Void)?

    /// The signed-in user's Matrix ID, used for client-side highlight detection.
    var currentUserId: String?

    /// The user's notification keywords, used for client-side keyword matching.
    ///
    /// Used by room entries to detect keyword matches in new messages for
    /// system notification banners. The server-side `highlightCount` is the
    /// authoritative source for badge display.
    var notificationKeywords: [String] = []

    /// Callback invoked after the room summaries list is rebuilt.
    ///
    /// Used by ``MatrixService`` to re-apply space membership (`parentSpaceIds`)
    /// to newly arrived rooms.
    var onRoomsRebuilt: (() -> Void)?

    /// Starts the reactive room list using the sync service's `RoomListService`.
    ///
    /// This method subscribes to room list entry diffs and applies them incrementally.
    /// Each room entry subscribes to `subscribeToRoomInfoUpdates` for live property changes.
    ///
    /// - Parameter syncService: The active SDK sync service.
    func start(syncService: SyncService) async throws {
        let rls = syncService.roomListService()
        roomListService = rls

        // Observe room list service state
        let (stateStream, stateContinuation) = AsyncStream<RoomListServiceState>.makeStream()
        let stateListener = SDKListener<RoomListServiceState> { state in
            stateContinuation.yield(state)
        }
        serviceStateHandle = rls.state(listener: stateListener)
        stateObservationTask = Task { [weak self] in
            for await state in stateStream {
                guard let self else { break }
                self.roomListServiceState = state
            }
        }

        // Subscribe to room list entries with dynamic adapters
        let (entriesStream, entriesContinuation) = AsyncStream<[RoomListEntriesUpdate]>.makeStream()
        let entriesListener = SDKListener<[RoomListEntriesUpdate]> { updates in
            entriesContinuation.yield(updates)
        }
        let allRooms = try await rls.allRooms()
        let handle = allRooms.entriesWithDynamicAdapters(pageSize: 100, listener: entriesListener)
        _ = handle.controller().setFilter(kind: .all(filters: [.nonLeft, .nonSpace]))
        entriesHandle = handle

        hasLoadedRooms = true

        entriesTask = Task { [weak self] in
            for await updates in entriesStream {
                guard let self else { break }
                self.applyEntryUpdates(updates)
            }
        }
    }

    /// Restarts the room list subscriptions using a new sync service.
    ///
    /// Unlike ``start(syncService:)``, this method preserves existing ``roomEntries``
    /// and ``rooms`` arrays so cached room data remains available. It cancels the
    /// previous subscription handles and re-subscribes to the new `RoomListService`.
    /// The SDK delivers incremental diffs from the new sync position, reconciling
    /// the room list state without requiring a full replacement.
    ///
    /// - Parameter syncService: The newly rebuilt SDK sync service.
    func restart(syncService: SyncService) async throws {
        // Cancel existing subscriptions but preserve room data
        stateObservationTask?.cancel()
        stateObservationTask = nil
        entriesTask?.cancel()
        entriesTask = nil
        entriesHandle = nil
        serviceStateHandle = nil

        let rls = syncService.roomListService()
        roomListService = rls

        // Re-observe room list service state
        let (stateStream, stateContinuation) = AsyncStream<RoomListServiceState>.makeStream()
        let stateListener = SDKListener<RoomListServiceState> { state in
            stateContinuation.yield(state)
        }
        serviceStateHandle = rls.state(listener: stateListener)
        stateObservationTask = Task { [weak self] in
            for await state in stateStream {
                guard let self else { break }
                self.roomListServiceState = state
            }
        }

        // Re-subscribe to room list entries
        let (entriesStream, entriesContinuation) = AsyncStream<[RoomListEntriesUpdate]>.makeStream()
        let entriesListener = SDKListener<[RoomListEntriesUpdate]> { updates in
            entriesContinuation.yield(updates)
        }
        let allRooms = try await rls.allRooms()
        let handle = allRooms.entriesWithDynamicAdapters(pageSize: 100, listener: entriesListener)
        _ = handle.controller().setFilter(kind: .all(filters: [.nonLeft, .nonSpace]))
        entriesHandle = handle

        entriesTask = Task { [weak self] in
            for await updates in entriesStream {
                guard let self else { break }
                self.applyEntryUpdates(updates)
            }
        }

        activityLog?.log(
            category: .roomList, severity: .info, source: "RoomListManager",
            summary: "Room list restarted with new sync service",
            detail: "Preserving \(roomEntries.count) existing room entries"
        )
    }

    /// Stops listening and clears state.
    func reset() {
        stateObservationTask?.cancel()
        stateObservationTask = nil
        entriesTask?.cancel()
        entriesTask = nil
        resortTask?.cancel()
        resortTask = nil
        entriesHandle = nil
        serviceStateHandle = nil
        roomListService = nil
        roomEntries = []
        rooms = []
        hasLoadedRooms = false
        roomListServiceState = nil
        currentUserId = nil
        notificationKeywords = []
    }

    // MARK: - Room Lookup

    /// Returns the SDK `Room` for a given room ID, if known.
    func sdkRoom(id: String) -> Room? {
        roomEntries.first { $0.id == id }?.room
    }

    // MARK: - Private

    /// Called by individual `RoomEntry` instances when their room info updates.
    /// Debounces re-sorting to avoid excessive work when many rooms update at once.
    fileprivate func scheduleResort() {
        resortTask?.cancel()
        resortTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.rebuildRoomSummaries()
        }
    }

    private func makeEntry(room: Room) -> RoomEntry {
        RoomEntry(
            room: room,
            activityLog: activityLog,
            onInfoUpdated: { [weak self] in self?.scheduleResort() },
            onNotificationEvent: { [weak self] event in self?.onNotificationEvent?(event) },
            highlightContextProvider: { [weak self] in
                (userId: self?.currentUserId, keywords: self?.notificationKeywords ?? [])
            }
        )
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func applyEntryUpdates(_ updates: [RoomListEntriesUpdate]) {
        let entryCountBefore = roomEntries.count
        let state = PerformanceSignposts.roomList.beginInterval(
            PerformanceSignposts.RoomListName.applyEntryUpdates,
            "\(updates.count) updates, \(entryCountBefore) entries"
        )

        // Track whether any operation structurally changed the room list
        // (entries added, removed, or replaced with a different room).
        // Pure in-place updates (.set with the same room ID) don't need
        // an immediate rebuild — the debounced scheduleResort() path
        // handles those once the room info and latest event are updated.
        var structurallyChanged = false

        for update in updates {
            switch update {
            case .append(let values):
                let entries = values.map { makeEntry(room: $0) }
                roomEntries.append(contentsOf: entries)
                structurallyChanged = true
            case .clear:
                roomEntries.removeAll()
                structurallyChanged = true
            case .pushFront(let value):
                roomEntries.insert(makeEntry(room: value), at: 0)
                structurallyChanged = true
            case .pushBack(let value):
                roomEntries.append(makeEntry(room: value))
                structurallyChanged = true
            case .popFront:
                if !roomEntries.isEmpty { roomEntries.removeFirst() }
                structurallyChanged = true
            case .popBack:
                if !roomEntries.isEmpty { roomEntries.removeLast() }
                structurallyChanged = true
            case .insert(let index, let value):
                // swiftlint:disable:next identifier_name
                let i = Int(index)
                if i <= roomEntries.count {
                    roomEntries.insert(makeEntry(room: value), at: i)
                    structurallyChanged = true
                }
            case .set(let index, let value):
                // swiftlint:disable:next identifier_name
                let i = Int(index)
                if i < roomEntries.count {
                    let existing = roomEntries[i]
                    if existing.id == value.id() {
                        // Same room — update in place. The room info
                        // subscription will trigger scheduleResort().
                        existing.updateRoom(value)
                    } else {
                        roomEntries[i] = makeEntry(room: value)
                        structurallyChanged = true
                    }
                }
            case .remove(let index):
                // swiftlint:disable:next identifier_name
                let i = Int(index)
                if i < roomEntries.count {
                    roomEntries.remove(at: i)
                    structurallyChanged = true
                }
            case .truncate(let length):
                let len = Int(length)
                if len < roomEntries.count {
                    roomEntries.removeSubrange(len..<roomEntries.count)
                    structurallyChanged = true
                }
            case .reset(let values):
                let existingById = Dictionary(roomEntries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                var hasNewRooms = false
                roomEntries = values.map { room in
                    if let existing = existingById[room.id()] {
                        existing.updateRoom(room)
                        return existing
                    }
                    hasNewRooms = true
                    return makeEntry(room: room)
                }
                // A reset is structural if the count changed or new rooms appeared.
                if hasNewRooms || roomEntries.count != entryCountBefore {
                    structurallyChanged = true
                }
            }
        }

        let entryCountAfter = roomEntries.count
        PerformanceSignposts.roomList.endInterval(
            PerformanceSignposts.RoomListName.applyEntryUpdates,
            state,
            "\(entryCountAfter) entries after"
        )

        // Log the diff batch to the activity log.
        let diffSummary = updates.map { update -> String in
            switch update {
            case .append(let v): "append(\(v.count))"
            case .clear: "clear"
            case .pushFront: "pushFront"
            case .pushBack: "pushBack"
            case .popFront: "popFront"
            case .popBack: "popBack"
            case .insert(let idx, _): "insert(@\(idx))"
            case .set(let idx, _): "set(@\(idx))"
            case .remove(let idx): "remove(@\(idx))"
            case .truncate(let len): "truncate(\(len))"
            case .reset(let v): "reset(\(v.count))"
            }
        }.joined(separator: ", ")
        activityLog?.log(
            category: .roomList, severity: .debug, source: "RoomListManager",
            summary: "\(updates.count) entry update(s): \(entryCountBefore) → \(entryCountAfter) entries",
            detail: diffSummary
        )

        if structurallyChanged {
            rebuildRoomSummaries()
        }
    }

    private func rebuildRoomSummaries() {
        let entryCount = roomEntries.count
        let state = PerformanceSignposts.roomList.beginInterval(
            PerformanceSignposts.RoomListName.rebuildSummaries,
            "\(entryCount) entries"
        )
        // Preserve the SDK's entry order — sliding sync delivers rooms
        // sorted by recency.  The view layer applies its own sort using
        // lastMessageTimestamp when available, but this baseline order
        // ensures rooms without cached event data still appear in a
        // sensible position rather than being pushed to the bottom.
        rooms = roomEntries.map(\.summary)
        let roomCount = rooms.count
        PerformanceSignposts.roomList.endInterval(
            PerformanceSignposts.RoomListName.rebuildSummaries,
            state,
            "\(roomCount) rooms"
        )
        activityLog?.log(
            category: .roomList, severity: .debug, source: "RoomListManager",
            summary: "Room list rebuilt: \(roomCount) rooms sorted"
        )
        onRoomsRebuilt?()
    }

    /// Eagerly removes rooms from the list after a leave operation.
    ///
    /// The SDK will eventually deliver a diff that removes these rooms, but
    /// calling this immediately after `Room.leave()` avoids a visible delay.
    func removeRooms(ids: Set<String>) {
        roomEntries.removeAll { ids.contains($0.summary.id) }
        rebuildRoomSummaries()
    }
}

// MARK: - Room Entry

/// Wraps a Matrix SDK `Room` and subscribes to `subscribeToRoomInfoUpdates` for live property changes.
///
/// Each ``RoomEntry`` owns a ``RoomSummary`` that it updates reactively when the SDK delivers
/// room info updates. This preserves object identity so SwiftUI can efficiently diff the room list.
@Observable
@MainActor
private final class RoomEntry: Identifiable {
    let id: String
    private(set) var room: Room
    let summary: RelayInterface.RoomSummary

    @ObservationIgnored private var roomInfoHandle: TaskHandle?
    @ObservationIgnored private var listenerTask: Task<Void, Never>?
    @ObservationIgnored private var onInfoUpdated: (() -> Void)?
    @ObservationIgnored private weak var activityLog: ActivityLog?

    @ObservationIgnored private var onNotificationEvent: ((RoomNotificationEvent) -> Void)?
    @ObservationIgnored private var highlightContextProvider: (() -> (userId: String?, keywords: [String]))?
    /// The timestamp (ms) of the last event we fired a notification for.
    @ObservationIgnored private var lastNotifiedEventTimestamp: UInt64 = 0
    @ObservationIgnored private var hasReceivedInitialInfo = false

    deinit {
        roomInfoHandle?.cancel()
        listenerTask?.cancel()
    }

    init(
        room: Room,
        activityLog: ActivityLog? = nil,
        onInfoUpdated: (() -> Void)? = nil,
        onNotificationEvent: ((RoomNotificationEvent) -> Void)? = nil,
        highlightContextProvider: (() -> (userId: String?, keywords: [String]))? = nil
    ) {
        self.id = room.id()
        self.room = room
        self.activityLog = activityLog
        self.onInfoUpdated = onInfoUpdated
        self.onNotificationEvent = onNotificationEvent
        self.highlightContextProvider = highlightContextProvider
        self.summary = RelayInterface.RoomSummary(
            id: room.id(),
            name: room.displayName() ?? room.id()
        )

        // Fetch initial room info and start listening
        Task { [weak self] in
            guard let self else { return }
            await self.fetchAndApplyRoomInfo()
            self.listenToRoomInfo()
        }
    }

    /// Updates the underlying room reference in-place without replacing this entry.
    func updateRoom(_ newRoom: Room) {
        assert(id == newRoom.id())
        room = newRoom
        listenerTask?.cancel()
        roomInfoHandle = nil

        // Re-fetch info and re-subscribe on the new room reference
        Task { [weak self] in
            guard let self else { return }
            await self.fetchAndApplyRoomInfo()
            self.listenToRoomInfo()
        }
    }

    private func fetchAndApplyRoomInfo() async {
        guard let info = try? await room.roomInfo() else { return }
        applyRoomInfo(info, isInitialFetch: true)
        // Await the latest event inline so the timestamp and preview are
        // populated before we trigger the first resort.  This avoids the
        // race where the initial rebuildRoomSummaries() runs while all
        // rooms still have nil timestamps, causing incorrect sort order.
        await fetchAndApplyLatestEvent(checkNotification: false)
    }

    private func listenToRoomInfo() {
        let (stream, continuation) = AsyncStream<RoomInfo>.makeStream()
        let listener = SDKListener<RoomInfo> { info in
            continuation.yield(info)
        }
        roomInfoHandle = room.subscribeToRoomInfoUpdates(listener: listener)

        listenerTask = Task { [weak self] in
            for await info in stream {
                guard let self, !Task.isCancelled else { break }
                self.applyRoomInfo(info)
            }
        }
    }

    private func applyRoomInfo(_ info: RoomInfo, isInitialFetch: Bool = false) {
        let previousNotifications = summary.notificationCount
        summary.name = info.displayName ?? room.displayName() ?? id
        summary.topic = info.topic
        // For DM rooms without an explicit room avatar, fall back to the
        // first hero's avatar so the sidebar shows the other user's picture.
        if let explicit = info.avatarUrl {
            summary.avatarURL = explicit
        } else if info.isDirect, let heroAvatar = info.heroes.first?.avatarUrl {
            summary.avatarURL = heroAvatar
        } else {
            summary.avatarURL = nil
        }

        // Use the SDK's client-side unread counts. The server-side
        // notificationCount/highlightCount from /sync are not reliably
        // populated under sliding sync, so we use numUnreadMessages (which
        // counts "interesting" messages independently of push rules) and
        // numUnreadMentions (which counts mention/highlight events).
        //
        // When the room was optimistically marked as read, the SDK may still
        // report stale non-zero counts until it processes the read receipt.
        // Skip overwriting the cleared values in that case.
        let sdkNotifications = UInt(info.numUnreadMessages)
        let sdkHighlights = UInt(info.numUnreadMentions)
        summary.lastKnownUnreadCount = sdkNotifications
        if summary.isOptimisticallyCleared {
            let cooldownElapsed = summary.optimisticClearedAt
                .map { Date.now.timeIntervalSince($0) >= 3 } ?? true
            if sdkNotifications == 0 && sdkHighlights == 0 && cooldownElapsed {
                // Server confirmed and cooldown elapsed — safe to clear the guard.
                summary.isOptimisticallyCleared = false
                summary.optimisticClearedAt = nil
                summary.highlightCount = 0
            } else if sdkNotifications > summary.optimisticClearedBaseline {
                // New messages arrived after the read receipt was sent.
                // Accept the SDK's values and clear the optimistic flag.
                summary.isOptimisticallyCleared = false
                summary.optimisticClearedAt = nil
                summary.notificationCount = sdkNotifications
                summary.highlightCount = sdkHighlights
            }
            // Otherwise keep the optimistically-cleared zeros — the SDK
            // is still echoing stale counts from before the read receipt.
        } else {
            summary.notificationCount = sdkNotifications
            summary.highlightCount = sdkHighlights
        }
        summary.isDirect = info.isDirect
        summary.canonicalAlias = info.canonicalAlias
        summary.pinnedEventIds = info.pinnedEventIds
        summary.isFavourite = info.isFavourite
        summary.successorRoomId = info.successorRoom?.roomId
        summary.hasRoomCall = info.hasRoomCall

        // Map SDK membership to RelayInterface type
        switch info.membership {
        case .invited: summary.membership = .invited
        case .joined: summary.membership = .joined
        case .left: summary.membership = .left
        case .banned: summary.membership = .banned
        case .knocked: summary.membership = .joined
        }

        // Fetch inviter details for invited rooms
        if info.membership == .invited {
            Task { [weak self] in
                guard let self else { return }
                if let inviter = try? await self.room.inviter() {
                    self.summary.inviterName = inviter.displayName ?? inviter.userId
                    self.summary.inviterAvatarURL = inviter.avatarUrl
                }
            }
        }

        // Map SDK notification mode to RelayInterface type
        if let sdkMode = info.cachedUserDefinedNotificationMode {
            switch sdkMode {
            case .allMessages: summary.notificationMode = .allMessages
            case .mentionsAndKeywordsOnly: summary.notificationMode = .mentionsAndKeywordsOnly
            case .mute: summary.notificationMode = .mute
            }
        } else {
            summary.notificationMode = nil
        }

        // Log significant room info changes (notification count transitions).
        if summary.notificationCount != previousNotifications {
            var meta = ["roomName": summary.name]
            if let alias = summary.canonicalAlias {
                meta["roomAlias"] = alias
            }
            activityLog?.log(
                category: .roomList, severity: .debug, source: "RoomEntry",
                summary: "Room info updated: \(summary.canonicalAlias ?? summary.name)",
                detail: "Notifications: \(previousNotifications) → \(summary.notificationCount), highlights: \(summary.highlightCount)",
                roomId: id,
                metadata: meta
            )
        }

        let shouldCheckNotification = hasReceivedInitialInfo
        hasReceivedInitialInfo = true

        // During the initial fetch, fetchAndApplyRoomInfo() awaits the
        // latest event inline so the timestamp is ready before the first
        // resort.  Skip the detached Task here to avoid a duplicate fetch.
        guard !isInitialFetch else { return }

        // Fetch the latest event, update the message preview, and check
        // for new notification-worthy events in a single task.
        //
        // The room info update fires before the SDK's event cache is
        // guaranteed to have the new event available via latestEvent().
        // When the fetched event has the same timestamp as the last one
        // we processed, we yield briefly (up to 2 retries at 50ms) to
        // give the SDK time to flush the event into its cache.
        Task { [weak self] in
            guard let self else { return }
            await self.fetchAndApplyLatestEvent(checkNotification: shouldCheckNotification)
        }
    }

    /// Fetches the room's latest event, updates the message preview, and
    /// optionally checks for notification-worthy activity.
    ///
    /// Called inline during the initial room info fetch (so the timestamp
    /// is available before the first sort) and from a detached Task during
    /// live room info updates.
    private func fetchAndApplyLatestEvent(checkNotification: Bool) async {
        var latest = await room.latestEvent()
        var eventInfo = Self.extractEventInfo(from: latest)

        // Retry if the event looks stale (same timestamp as what we
        // already processed).  Two short retries cover the common
        // case where the event cache lags by a few milliseconds.
        if checkNotification,
           let ts = eventInfo?.timestamp,
           ts <= lastNotifiedEventTimestamp {
            for _ in 0 ..< 2 {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                latest = await room.latestEvent()
                eventInfo = Self.extractEventInfo(from: latest)
                if let newTs = eventInfo?.timestamp, newTs > lastNotifiedEventTimestamp {
                    break
                }
            }
        }
        let preview = Self.extractPreview(from: latest)

        // Update message preview for the room list.
        summary.lastAuthor = eventInfo?.author
        summary.lastMessage = preview.text
        summary.lastMessageTimestamp = preview.date
        onInfoUpdated?()

        guard let eventInfo else { return }

        // On the first info fetch, just record the baseline.
        guard checkNotification else {
            lastNotifiedEventTimestamp = eventInfo.timestamp
            return
        }

        // Only process events we haven't seen before.
        guard eventInfo.timestamp > lastNotifiedEventTimestamp else { return }
        lastNotifiedEventTimestamp = eventInfo.timestamp

        // Only notify for actual messages, not state events
        // (joins, name changes, topic changes, etc.).
        guard eventInfo.body != nil else { return }

        let roomName = summary.name
        let roomId = id
        let isDirect = summary.isDirect
        let mode = summary.notificationMode
        let highlightContext = highlightContextProvider?()

        // Don't notify for our own messages.
        if let userId = highlightContext?.userId,
           eventInfo.senderId == userId {
            return
        }

        // Determine whether this message is a mention or keyword match.
        var isMention = false
        if let mentions = eventInfo.mentions,
           let userId = highlightContext?.userId {
            isMention = mentions.userIds.contains(userId) || mentions.room
        }
        if !isMention {
            isMention = HighlightMatcher.bodyMatchesHighlightRules(
                eventInfo.body ?? "",
                currentUserId: highlightContext?.userId,
                keywords: highlightContext?.keywords ?? []
            )
        }

        onNotificationEvent?(RoomNotificationEvent(
            roomId: roomId,
            roomName: roomName,
            messageAuthor: eventInfo.author,
            messageBody: eventInfo.body,
            isMention: isMention,
            isDirect: isDirect,
            notificationMode: mode
        ))
    }

    /// Information extracted from the latest event for notification purposes.
    struct LatestEventInfo {
        let timestamp: UInt64
        let senderId: String?
        let author: String?
        let body: String?
        let mentions: Mentions?
    }

    /// Preview information extracted from the latest event.
    struct PreviewInfo {
        let text: AttributedString?
        let date: Date?
    }

    /// Extracts notification-relevant information from a latest event snapshot.
    private static func extractEventInfo(from latest: LatestEventValue) -> LatestEventInfo? {
        let timestamp: UInt64
        let senderId: String?
        let profile: ProfileDetails
        let content: TimelineItemContent

        switch latest {
        case .remote(let ts, let s, _, let p, let c):
            timestamp = UInt64(ts)
            senderId = s
            profile = p
            content = c
        case .local(let ts, let s, let p, let c, _):
            timestamp = UInt64(ts)
            senderId = s
            profile = p
            content = c
        case .remoteInvite(let ts, let s, let p):
            let author: String? = if case .ready(let name, _, _) = p { name ?? s } else { s }
            return LatestEventInfo(
                timestamp: UInt64(ts), senderId: s,
                author: author, body: "Invited you to join", mentions: nil
            )
        case .none:
            return nil
        }

        let author: String? = switch profile {
        case .ready(let displayName, _, _): displayName ?? senderId
        default: senderId
        }

        var body: String?
        var mentions: Mentions?
        if case .msgLike(let msgLike) = content,
           case .message(let mc) = msgLike.kind {
            mentions = mc.mentions
            body = switch mc.msgType {
            case .text(let t): t.body
            case .image: "Sent an image"
            case .video: "Sent a video"
            case .audio: "Sent audio"
            case .file: "Sent a file"
            case .emote(let e): "* \(e.body)"
            case .notice(let n): n.body
            case .location: "Shared a location"
            case .gallery: "Sent a gallery"
            case .other: nil
            }
        }

        return LatestEventInfo(
            timestamp: timestamp, senderId: senderId,
            author: author, body: body, mentions: mentions
        )
    }

    /// Extracts a message preview from a latest event snapshot.
    // swiftlint:disable:next identifier_name
    private static func extractPreview(from latest: LatestEventValue) -> PreviewInfo {
        let content: TimelineItemContent
        let timestamp: Timestamp

        switch latest {
        case .remote(let ts, _, _, _, let c):
            content = c
            timestamp = ts
        case .remoteInvite(let ts, _, _):
            let date = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
            return PreviewInfo(text: AttributedString("Invited you to join"), date: date)
        case .local(let ts, _, _, let c, _):
            content = c
            timestamp = ts
        case .none:
            return PreviewInfo(text: nil, date: nil)
        }

        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        let preview = contentPreview(content)
        return PreviewInfo(text: preview, date: date)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func contentPreview(_ content: TimelineItemContent) -> AttributedString? {
        // swiftlint:disable identifier_name
        switch content {
        case .msgLike(let msgLike):
            switch msgLike.kind {
            case .message(let mc):
                switch mc.msgType {
                case .text(let t): return Self.parseMarkdown(t.body)
                case .image: return AttributedString("Sent an image")
                case .video: return AttributedString("Sent a video")
                case .audio: return AttributedString("Sent audio")
                case .file: return AttributedString("Sent a file")
                case .emote(let e): return Self.parseMarkdown("* \(e.body)")
                case .notice(let n): return Self.parseMarkdown(n.body)
                case .location: return AttributedString("Shared a location")
                case .gallery: return AttributedString("Sent a gallery")
                case .other: return nil
                }
            case .sticker: return AttributedString("Sent a sticker")
            case .poll: return AttributedString("Started a poll")
            case .redacted: return AttributedString("Message deleted")
            case .unableToDecrypt: return AttributedString("Encrypted message")
            case .liveLocation: return AttributedString("Sharing live location")
            case .other: return nil
            }
        case .roomMembership(let userId, let userDisplayName, let change, _):
            let name = userDisplayName ?? userId
            return TimelineMessageMapper.membershipDescription(name: name, change: change)
        case .profileChange(let displayName, let prevDisplayName, let avatarUrl, let prevAvatarUrl):
            return TimelineMessageMapper.profileChangeDescription(
                displayName: displayName,
                prevDisplayName: prevDisplayName,
                avatarUrl: avatarUrl,
                prevAvatarUrl: prevAvatarUrl
            )
        case .state(let stateKey, let content):
            let (body, _) = TimelineMessageMapper.describeStateEvent(
                content,
                stateKey: stateKey,
                senderDisplayName: nil,
                senderId: ""
            )
            guard let body else { return nil }
            return AttributedString(body)
        default: return nil
        }
        // swiftlint:enable identifier_name
    }

    /// Parses a raw message body as inline Markdown, falling back to plain text on failure.
    private static func parseMarkdown(_ body: String) -> AttributedString {
        // swiftlint:disable:next identifier_name
        if let md = try? AttributedString(
            markdown: body,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return md
        }
        return AttributedString(body)
    }
}
