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

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import MatrixKit
import MatrixKitSwiftData
import OSLog
import UniformTypeIdentifiers

private nonisolated let timelineSignposter = OSSignposter(
    subsystem: "app.subpop.Relay.performance", category: "Timeline")

/// Whether the timeline shows live messages, unread context, a focused
/// event window, or a thread.
enum TimelineFocus: Hashable, Sendable {
    /// Live messages anchored at the newest edge.
    case live
    /// Unread context backed by a SwiftData event window.
    case unread(EventId)
    /// Context window around one event.
    case focused(EventId)
    /// Thread rooted at one event.
    case thread(EventId)
}

/// Which window the timeline shows.
private enum TimelineWindow: Equatable {
    /// Live messages anchored at the newest edge.
    case live
    /// Store-backed event window around the unread anchor.
    case unreadContext(EventId)
    /// Context window around one event.
    case focused(EventId)
    /// Thread rooted at one event.
    case thread(EventId)

    var logName: String {
        switch self {
        case .live: "live"
        case .unreadContext: "focused-unread"
        case .focused: "focused-event"
        case .thread: "thread"
        }
    }
}

/// View model driving `TimelineView` from the normalized store.
///
/// Live and unread-context windows render stored events through
/// `ObservableTimelineEvent.render`; sync deltas refresh them via the
/// room's revision counter on `RelayClient`. Explicit event focus and
/// thread modes page detached windows. Sends go through `RelayClient`'s
/// store-backed pipeline.
@Observable
final class TimelineViewModel {
    /// Maximum number of stored events rendered in a non-thread window.
    private static let liveLimit = 100
    private static let contextPageSize = 50
    /// Initial store-backed slice size around the unread/read anchor.
    private static let anchoredOlderLimit = contextPageSize - 1
    private static let anchoredNewerLimit = contextPageSize

    private let roomID: RoomId
    @ObservationIgnored private let client: RelayClient
    private let errorReporter: ErrorReporter
    private var highlights: [String]

    /// Whether the initial load is in flight.
    var isLoading = true
    /// First unread event ID for the "New" divider. The initial window
    /// falls back to its first row when the stored marker is outside it;
    /// subsequent pages only display the divider when its event is present.
    var firstUnreadMessageId: String?
    /// Whether membership events render.
    var showMembershipEvents = true
    /// Whether other state events render.
    var showStateEvents = true

    /// Rendered events, oldest first.
    private var renderedEvents: [ObservableTimelineEvent] = []
    /// Failure details for undecryptable events in the rendered window.
    private var decryptionFailures: [EventId: RoomCrypto.DecryptionFailure] = [:]

    /// Raw snapshot behind ``renderedEvents`` (for thread roots).
    private var snapshot: [MessageEvent] = []
    /// Member map behind ``renderedEvents``.
    private var members: [UserId: MemberContent] = [:]
    /// Local delivery states for staged echoes.
    private var sendStates: [EventId: SendState] = [:]

    /// Cursor toward older history (`GET /messages` `dir=b`).
    private var historyCursor: BatchToken?
    /// Oldest event kept by a retention trim, when the stored cursor
    /// can't reach the trimmed range. Back-pagination resumes before it
    /// via `/context` and then continues from the cursor that returns.
    private var historyGapEventId: EventId?
    private(set) var timelineGaps: [StoredTimelineGap] = []
    private(set) var loadingGapId: String?
    private(set) var gapLoadError: String?
    private(set) var failedGapId: String?
    private var hasOlderLiveEvents = false
    private var hasNewerLiveEvents = false
    var shouldShowUnanchoredGap: Bool { !hasOlderLiveEvents }
    /// Whether older history may exist. True until a page comes back
    /// cursorless.
    private var hasMoreHistory = true
    /// Whether a pagination request is in flight.
    private var isPaginating = false
    private var topLoadingOperations: Set<String> = []
    /// Whether the unread context's Matrix pagination cursors were loaded.
    private var unreadContextReady = false
    /// Whether an unread context page request is in flight.
    private var isLoadingUnreadContext = false
    /// Older/newer Matrix cursors around the unread anchor.
    private var unreadOlderCursor: BatchToken?
    private var unreadNewerCursor: BatchToken?
    /// Whether adjacent locally stored events remain outside the rendered slice.
    private var hasOlderUnreadEvents = false
    private var hasNewerUnreadEvents = false
    /// The first event in the sliding unread window; the unread marker remains
    /// the identity of the context mode even after it leaves the window.
    private var unreadWindowAnchor: EventId?
    @ObservationIgnored private var unreadContextTask: Task<Bool, Never>?
    @ObservationIgnored private var unreadContextTaskGeneration = 0

    /// Detached focus window, when focusing an event.
    @ObservationIgnored private var focused: FocusedTimeline?
    private var focusedWindowStart = 0
    private var focusReachedStart = false
    /// Detached thread window, when viewing a thread.
    @ObservationIgnored private var thread: ThreadTimeline?
    /// Whether the focus window reached the live edge.
    private var focusReachedEnd = true

    enum LivePage { case older, newer }

    /// Retain the requested edge of an overlapping store window. The other
    /// edge stays in SwiftData and can be loaded again in either direction.
    static func liveSlice<T>(_ events: [T], keeping page: LivePage, limit: Int = liveLimit) -> [T] {
        switch page {
        case .older: Array(events.prefix(limit))
        case .newer: Array(events.suffix(limit))
        }
    }

    static func focusedSlice<T>(_ events: [T], start: Int) -> [T] {
        Array(events.dropFirst(start).prefix(liveLimit))
    }

    /// Observation loop over the room's revision counter.
    @ObservationIgnored private var observeTask: Task<Void, Never>?
    /// Pending coalesced live refresh.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAfterPagination = false
    /// Monotonic refresh generation; stale fetch completions drop.
    private var refreshGeneration = 0

    /// In-flight attachment upload fractions by upload ID. Powers the
    /// thin progress bar overlaid on the sending attachment's bubble;
    /// empty when idle.
    private var uploadFractions: [UUID: Double] = [:]

    /// Overall upload fraction across in-flight attachments (the
    /// maximum), or nil when no upload is active.
    var uploadProgress: Double? { uploadFractions.values.max() }

    /// The room ID.
    var roomId: String { roomID.value }
    /// The current user ID for outgoing detection.
    var currentUserId: String? { client.localUserId?.value }

    /// Rendered events, oldest first.
    var events: [ObservableTimelineEvent] {
        renderedEvents
    }

    /// View-facing alias for ``events``.
    var messages: [ObservableTimelineEvent] { events }

    /// Whether the room is a direct chat (drives media auto-reveal).
    var isDirectRoom: Bool { client.storedRoom(roomID)?.presentsAsDirect ?? false }

    /// The ID of the room that replaces this one, if tombstoned.
    var successorRoomId: String? { client.storedRoom(roomID)?.successorRoomId }

    /// Whether an event is currently pinned.
    func isPinned(eventId: String) -> Bool {
        client.storedRoom(roomID)?.pinnedEventIds.contains(eventId) ?? false
    }

    /// Members with role details, for mentions and profile taps.
    /// Reads the current store snapshot off the main actor. The full
    /// `/members` refresh runs separately and updates this snapshot later.
    func roomMembers() async -> [RoomMemberDetails] {
        await client.roomMemberDetails(roomId: roomID)
    }

    /// Refresh the full roster off the main actor, then read its updated
    /// store snapshot for autocomplete and the inspector.
    func refreshRoomMembers() async -> [RoomMemberDetails] {
        await client.refreshRoomMembers(roomId: roomID)
        return await client.roomMemberDetails(roomId: roomID)
    }

    /// The local user's room permissions.
    func roomPermissions() async -> RoomPermissions? {
        await client.roomPermissions(roomId: roomID)
    }

    /// Send (or stop) a typing notification.
    func setTyping(_ typing: Bool) async {
        await client.messageSender?.sendTyping(roomID, typing: typing)
    }

    /// Pre-computed rows with grouping metadata.
    var messageRows: [MessageRow] {
        let state = timelineSignposter.beginInterval(
            "buildTimelineRows", id: timelineSignposter.makeSignpostID())
        let events = filteredEvents
        let rows = MessageRowBuilder.buildRows(
            for: events,
            localUserId: client.localUserId,
            hasReachedStart: hasReachedStart,
            decryptionFailures: decryptionFailures)
        timelineSignposter.endInterval(
            "buildTimelineRows", state,
            "events \(events.count), rows \(rows.count)")
        return rows
    }

    /// Whether older messages are being fetched.
    var isLoadingMore: Bool { isPaginating || isLoadingUnreadContext }

    var loadingMoreDescription: String {
        let operations = topLoadingOperations.sorted().joined(separator: ", ")
        return operations.isEmpty ? "none" : operations
    }

    /// Whether backward pagination reached the room start.
    var hasReachedStart: Bool {
        switch window {
        case .live:
            return !hasOlderLiveEvents && !hasMoreHistory
        case .unreadContext:
            return unreadContextReady && !hasOlderUnreadEvents && unreadOlderCursor == nil
        case .focused:
            return focusReachedStart
        case .thread:
            return false
        }
    }

    /// Whether forward pagination reached the live edge.
    var hasReachedEnd: Bool {
        switch window {
        case .live:
            return !hasNewerLiveEvents
        case .thread:
            return true
        case .unreadContext:
            return !hasNewerUnreadEvents
                && (!unreadContextReady || unreadNewerCursor == nil)
        case .focused:
            return focusReachedEnd
        }
    }

    /// Users currently typing, with display names. Refreshed from the
    /// SDK tracker on typing revisions (see `handleRevisionChange`);
    /// rendering never blocks on it.
    var typingUsers: [TypingUser] {
        typingUsersList
    }

    /// Cached typing list backing `typingUsers`.
    private var typingUsersList: [TypingUser] = []

    /// Refresh the cached typing list from the SDK tracker.
    private func refreshTypingUsers() async {
        guard !Task.isCancelled else { return }
        let typing = await client.typingTrackerUsers(in: roomID)
        guard !Task.isCancelled else { return }
        let members = await client.roomMembersMap(roomId: roomID)
        typingUsersList = typing.map { userId in
            let details = members[userId]
            return TypingUser(
                id: userId.value,
                displayName: details?.displayname ?? userId.value,
                avatarURL: details?.avatarUrl)
        }
        typingTick += 1
    }

    /// Whether the timeline shows live messages or a focused event.
    var timelineFocus: TimelineFocus {
        switch window {
        case .live: return .live
        case .unreadContext(let eventId): return .unread(eventId)
        case .focused(let eventId): return .focused(eventId)
        case .thread(let rootId): return .thread(rootId)
        }
    }

    var timelineFocusDescription: String {
        window.logName
    }

    /// Whether the current window is at the latest stored/synced event.
    var isAtLatestEdge: Bool {
        switch window {
        case .live:
            return !hasNewerLiveEvents
        case .unreadContext:
            return hasReachedEnd
        case .focused:
            return focusReachedEnd
        case .thread:
            return false
        }
    }

    nonisolated static func shouldMarkReadAtLatest(
        latestRowVisible: Bool,
        timelineReachedLatest: Bool
    ) -> Bool {
        latestRowVisible && timelineReachedLatest
    }

    /// Which window the timeline shows. Mirrors the detached actors
    /// (`focused`/`thread`), which cannot be read synchronously.
    private var window: TimelineWindow = .live

    private func selectWindow(_ next: TimelineWindow, reason: String) {
        guard window != next else { return }
        let previous = window.logName
        window = next
        RelayLog.timeline.info(
            "Timeline focus switched room=\(self.roomId, privacy: .private(mask: .hash)) from=\(previous, privacy: .public) to=\(next.logName, privacy: .public) reason=\(reason, privacy: .public)")
    }

    private func logFocusState(reason: String) {
        RelayLog.timeline.info(
            "Timeline focus state room=\(self.roomId, privacy: .private(mask: .hash)) focus=\(self.window.logName, privacy: .public) reason=\(reason, privacy: .public)")
    }

    private func beginTopLoading(_ operation: String) {
        topLoadingOperations.insert(operation)
        RelayLog.timeline.info(
            "Timeline top loading operation started room=\(self.roomId, privacy: .private(mask: .hash)) operation=\(operation, privacy: .public)")
    }

    private func endTopLoading(_ operation: String) {
        guard topLoadingOperations.remove(operation) != nil else { return }
        RelayLog.timeline.info(
            "Timeline top loading operation finished room=\(self.roomId, privacy: .private(mask: .hash)) operation=\(operation, privacy: .public) remaining=\(self.loadingMoreDescription, privacy: .public)")
    }

    private func beginPagination(_ operation: String) {
        isPaginating = true
        switch window {
        case .live, .unreadContext: refreshTask?.cancel()
        case .focused, .thread: break
        }
        beginTopLoading(operation)
    }

    private func endPagination(_ operation: String) {
        isPaginating = false
        endTopLoading(operation)
        if refreshAfterPagination {
            refreshAfterPagination = false
            requestRefresh()
        }
    }

    init(roomId: String, client: RelayClient, highlights: [String] = [], errorReporter: ErrorReporter) {
        self.roomID = RoomId(unchecked: roomId)
        self.client = client
        self.highlights = highlights
        self.errorReporter = errorReporter
        startObserving()
    }

    deinit {
        observeTask?.cancel()
        refreshTask?.cancel()
        typingTask?.cancel()
    }

    // MARK: - State

    private var filteredEvents: [ObservableTimelineEvent] {
        renderedEvents.filter { event in
            switch event.kind {
            case .state:
                return showStateEvents
            case .profileChange:
                return showMembershipEvents
            default:
                return true
            }
        }
    }

    /// Read the live window and rebuild rendered events. Store I/O
    /// happens off the main actor (`timelinePayload`); rendering stays
    /// here. Stale completions (a newer refresh issued mid-fetch) are
    /// dropped via the generation guard. Unread context uses a separate
    /// anchored refresh.
    private func refreshLiveNow(page: LivePage? = nil) async {
        guard case .live = window else { return }
        let refreshState = timelineSignposter.beginInterval(
            "refreshLiveTimeline", id: timelineSignposter.makeSignpostID(),
            "window limit \(Self.liveLimit)")
        defer { timelineSignposter.endInterval("refreshLiveTimeline", refreshState) }
        refreshGeneration += 1
        let generation = refreshGeneration
        let fetchState = timelineSignposter.beginInterval(
            "fetchTimelinePayload", id: timelineSignposter.makeSignpostID())
        let anchor = switch page {
        case .older, nil: snapshot.first?.eventId
        case .newer: snapshot.last?.eventId
        }
        let useAnchor = page != nil || hasNewerLiveEvents
        let around: TimelinePayload?
        if useAnchor, let anchor {
            let olderLimit: Int
            let newerLimit: Int
            switch page {
            case .older:
                olderLimit = Self.contextPageSize
                newerLimit = Self.liveLimit - 1
            case .newer:
                olderLimit = Self.liveLimit - 1
                newerLimit = Self.contextPageSize
            case nil:
                olderLimit = 0
                newerLimit = Self.liveLimit - 1
            }
            around = await client.timelinePayloadAround(
                roomId: roomID, anchorEventId: anchor.value,
                olderLimit: olderLimit, newerLimit: newerLimit)
        } else {
            around = nil
        }
        let payload: TimelinePayload
        if let around {
            payload = around
        } else {
            payload = await client.timelinePayload(roomId: roomID, limit: Self.liveLimit)
        }
        timelineSignposter.endInterval("fetchTimelinePayload", fetchState)
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        guard case .live = window else { return }
        let nextSnapshot = Self.liveSlice(
            payload.snapshot, keeping: page == .older && around != nil ? .older : .newer)
        let nextMembers = await client.roomMembersMap(roomId: roomID)
        let renderState = timelineSignposter.beginInterval(
            "renderTimelineEvents", id: timelineSignposter.makeSignpostID(),
            "events \(nextSnapshot.count)")
        let nextRenderedEvents = ObservableTimelineEvent.render(
            nextSnapshot,
            members: nextMembers,
            localUser: client.localUserId,
            highlightKeywords: highlights,
            sendStates: payload.sendStates)
        timelineSignposter.endInterval("renderTimelineEvents", renderState)
        let decryptState = timelineSignposter.beginInterval(
            "resolveTimelineDecryptionFailures", id: timelineSignposter.makeSignpostID())
        let nextDecryptionFailures = await decryptionFailureMap(
            for: nextRenderedEvents)
        timelineSignposter.endInterval("resolveTimelineDecryptionFailures", decryptState)
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        guard case .live = window else { return }
        snapshot = nextSnapshot
        members = nextMembers
        sendStates = payload.sendStates
        renderedEvents = nextRenderedEvents
        decryptionFailures = nextDecryptionFailures
        let hasNewer = around != nil && (payload.hasNewerStoredEvents
            || (page == .older && payload.snapshot.count > Self.liveLimit))
        if hasNewer {
            firstUnreadMessageId = payload.firstUnreadEventId.flatMap { id in
                snapshot.contains(where: { $0.eventId.value == id }) ? id : nil
            }
        } else {
            firstUnreadMessageId = Self.windowAnchor(
                snapshot: snapshot, storedAnchor: payload.firstUnreadEventId)
        }
        historyCursor = payload.prevBatch.map { BatchToken($0) }
        historyGapEventId = payload.historyGapEventId.map { EventId(unchecked: $0) }
        timelineGaps = payload.timelineGaps
        hasOlderLiveEvents = payload.hasOlderStoredEvents
            || (page == .newer && payload.snapshot.count > Self.liveLimit)
        hasNewerLiveEvents = hasNewer
        if hasOlderLiveEvents { hasMoreHistory = true }
        if historyGapEventId != nil {
            // A trim can land while the room is open; reopen history.
            hasMoreHistory = true
        }
    }

    /// Render a staged local echo immediately instead of waiting for the
    /// ordinary revision debounce or the homeserver's sync echo.
    private func refreshForLocalEcho() async {
        if isPaginating {
            refreshAfterPagination = true
            return
        }
        refreshTask?.cancel()
        await refreshLiveNow()
    }

    /// Request a window refresh, coalescing bursts: rapid revision bumps
    /// (sync storms, typing) collapse into one fetch ~120ms later.
    private func requestRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            let state = timelineSignposter.beginInterval(
                "timelineRefreshDebounce", id: timelineSignposter.makeSignpostID())
            try? await Task.sleep(for: .milliseconds(120))
            timelineSignposter.endInterval("timelineRefreshDebounce", state)
            guard let self, !Task.isCancelled else { return }
            await self.refreshCurrentNow()
        }
    }

    /// Clamp the stored first-unread anchor to a rendered snapshot.
    /// The stored anchor is the oldest unread in full history; when it
    /// predates the loaded window it matches no rendered row and the
    /// divider would vanish despite unread. Fall back to the window's
    /// first event while a stored anchor exists at all, mirroring the
    /// retired live timeline (nil when fully read). Pure for testing.
    static func windowAnchor(snapshot: [MessageEvent], storedAnchor: String?) -> String? {
        guard let first = snapshot.first else { return nil }
        if let storedAnchor {
            if snapshot.contains(where: { $0.eventId.value == storedAnchor }) {
                return storedAnchor
            }
            return first.eventId.value
        }
        return nil
    }

    /// Candidate event IDs for anchoring the live timeline near the user's
    /// reading position. Prefer the first unread marker so the unread divider
    /// is visible on first paint; fall back to the fully-read marker when they
    /// differ.
    nonisolated static func liveAnchorCandidates(
        fullyReadEventId: String?,
        firstUnreadEventId: String?,
        hasUnread: Bool
    ) -> [String] {
        guard hasUnread else { return [] }
        var candidates: [String] = []
        if let firstUnreadEventId {
            candidates.append(firstUnreadEventId)
        }
        if let fullyReadEventId,
           fullyReadEventId != firstUnreadEventId {
            candidates.append(fullyReadEventId)
        }
        return candidates
    }

    /// Watch the room's revision counters. Timeline revisions refresh
    /// the live window (coalesced); typing revisions only bump an
    /// invalidation counter so the indicator re-reads without a full
    /// re-render.
    private func startObserving() {
        observeTask?.cancel()
        observeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let stream = AsyncStream<Void> { continuation in
                    withObservationTracking {
                        _ = self.client.roomRevisions[self.roomID.value]
                        _ = self.client.typingRevisions[self.roomID.value]
                    } onChange: {
                        continuation.yield()
                        continuation.finish()
                    }
                }
                for await _ in stream {
                    guard !Task.isCancelled else { return }
                    self.handleRevisionChange()
                }
            }
        }
    }

    /// Last-seen revision counters, for telling timeline changes apart
    /// from typing-only traffic.
    private var lastRoomRevision: UInt64 = 0
    private var lastTypingRevision: UInt64 = 0
    /// Bumped on typing-only changes. Tracked (unread by views) so the
    /// typing indicator re-renders without a window refresh.
    private var typingTick: UInt64 = 0

    /// Pending typing-list refresh.
    @ObservationIgnored private var typingTask: Task<Void, Never>?

    private func handleRevisionChange() {
        let roomId = roomID.value
        let roomRev = client.roomRevisions[roomId] ?? 0
        let typingRev = client.typingRevisions[roomId] ?? 0
        if roomRev != lastRoomRevision {
            lastRoomRevision = roomRev
            if !isLoading {
                if isPaginating {
                    refreshAfterPagination = true
                } else {
                    requestRefresh()
                }
            }
        }
        if typingRev != lastTypingRevision {
            lastTypingRevision = typingRev
            // Last-wins: a newer typing event supersedes an in-flight
            // refresh so the list never regresses.
            typingTask?.cancel()
            typingTask = Task { [weak self] in
                await self?.refreshTypingUsers()
            }
        }
    }

    /// Load the live timeline from the store.
    func loadTimeline() async {
        isLoading = true
        clearUnreadContext()
        focused = nil
        thread = nil
        selectWindow(.live, reason: "load newest timeline")
        logFocusState(reason: "load newest timeline")
        hasNewerLiveEvents = false
        if client.localUserId == nil {
            // Without a local user ID every message renders as incoming;
            // log it so the failure is observable instead of silent.
            RelayLog.timeline.warning("Local user ID unavailable; own messages render as incoming")
        }
        await refreshLiveNow()
        await refreshTypingUsers()
        if historyCursor == nil && historyGapEventId == nil && !hasOlderLiveEvents {
            // No back-pagination cursor or trim gap stored: the window
            // is the whole known history.
            hasMoreHistory = false
        }
        isLoading = false
    }

    /// Load the timeline from local SwiftData around the room's unread/read
    /// anchor when available. Returns the selected anchor for first positioning.
    func loadTimelineAnchoredToReadMarker() async -> String? {
        isLoading = true
        clearUnreadContext()
        focused = nil
        thread = nil
        selectWindow(.live, reason: "resolve unread/read anchor")
        logFocusState(reason: "resolve unread/read anchor")
        hasNewerLiveEvents = false
        if client.localUserId == nil {
            RelayLog.timeline.warning("Local user ID unavailable; own messages render as incoming")
        }
        guard let room = client.storedRoom(roomID) else {
            isLoading = false
            return nil
        }
        let hasUnread = room.unreadCount > 0
            || room.highlightCount > 0
            || room.firstUnreadEventId != nil
        let candidates = Self.liveAnchorCandidates(
            fullyReadEventId: room.fullyReadEventId?.value,
            firstUnreadEventId: room.firstUnreadEventId?.value,
            hasUnread: hasUnread)
        RelayLog.timeline.info(
            "Timeline focus decision room=\(self.roomId, privacy: .private(mask: .hash)) unread=\(hasUnread) unreadCount=\(room.unreadCount) highlights=\(room.highlightCount) mode=\(candidates.isEmpty ? "live" : "focused", privacy: .public)")
        for eventId in candidates {
            clearUnreadContext()
            let anchor = EventId(unchecked: eventId)
            selectWindow(.unreadContext(anchor), reason: "open stored context at read anchor")

            var payload = await client.timelinePayloadAround(
                roomId: roomID,
                anchorEventId: eventId,
                olderLimit: Self.anchoredOlderLimit,
                newerLimit: Self.anchoredNewerLimit)
            if payload == nil {
                guard await loadInitialUnreadContext(anchorEventId: anchor) else {
                    selectWindow(.live, reason: "unread anchor context unavailable")
                    continue
                }
                payload = await client.timelinePayloadAround(
                    roomId: roomID,
                    anchorEventId: eventId,
                    olderLimit: Self.anchoredOlderLimit,
                    newerLimit: Self.anchoredNewerLimit)
            }
            guard let payload,
                  await applyUnreadPayload(payload, anchor: anchor)
            else {
                selectWindow(.live, reason: "unread anchor missing from stored context")
                continue
            }
            await refreshTypingUsers()
            isLoading = false
            return eventId
        }
        clearUnreadContext()
        selectWindow(.live, reason: "no stored read anchor available")
        isLoading = false
        return nil
    }

    /// Load the initial context only when the unread anchor is not in SwiftData.
    private func loadInitialUnreadContext(anchorEventId: EventId) async -> Bool {
        guard let messages = client.messageClient else { return false }
        do {
            let context = try await messages.context(
                roomID, eventId: anchorEventId, limit: Self.contextPageSize)
            guard case .unreadContext(let currentAnchor) = window,
                  currentAnchor == anchorEventId
            else { return false }
            await client.insertTimelineHistory(context.events, roomId: roomID)
            unreadOlderCursor = context.start
            unreadNewerCursor = context.end
            unreadContextReady = true
            return context.event != nil
        } catch {
            RelayLog.timeline.warning(
                "Unread context load failed room=\(self.roomId, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    private func applyUnreadPayload(
        _ payload: TimelinePayload,
        anchor: EventId,
        page: LivePage? = nil
    ) async -> Bool {
        let expectedWindow = TimelineWindow.unreadContext(anchor)
        let nextMembers = await client.roomMembersMap(roomId: roomID)
        let windowSnapshot = Self.liveSlice(
            payload.snapshot, keeping: page == .older ? .older : .newer)
        var renderSnapshot: [MessageEvent] = []
        renderSnapshot.reserveCapacity(windowSnapshot.count)
        for event in windowSnapshot {
            guard !Task.isCancelled else { return false }
            renderSnapshot.append(await client.decryptEvent(event, in: roomID) ?? event)
        }
        let nextRenderedEvents = ObservableTimelineEvent.render(
            renderSnapshot,
            members: nextMembers,
            localUser: client.localUserId,
            highlightKeywords: highlights,
            sendStates: payload.sendStates)
        let nextDecryptionFailures = await decryptionFailureMap(for: nextRenderedEvents)
        guard window == expectedWindow, !Task.isCancelled else { return false }
        snapshot = renderSnapshot
        members = nextMembers
        sendStates = payload.sendStates
        renderedEvents = nextRenderedEvents
        decryptionFailures = nextDecryptionFailures
        let isInitialWindow = unreadWindowAnchor == nil
        unreadWindowAnchor = snapshot.first?.eventId
        if isInitialWindow {
            firstUnreadMessageId = Self.windowAnchor(
                snapshot: snapshot, storedAnchor: payload.firstUnreadEventId)
        } else {
            firstUnreadMessageId = payload.firstUnreadEventId.flatMap { id in
                snapshot.contains(where: { $0.eventId.value == id }) ? id : nil
            }
        }
        historyCursor = payload.prevBatch.map { BatchToken($0) }
        historyGapEventId = payload.historyGapEventId.map { EventId(unchecked: $0) }
        hasMoreHistory = historyCursor != nil || historyGapEventId != nil
        hasOlderUnreadEvents = payload.hasOlderStoredEvents
            || (page == .newer && payload.snapshot.count > Self.liveLimit)
        hasNewerUnreadEvents = payload.hasNewerStoredEvents
            || (page == .older && payload.snapshot.count > Self.liveLimit)
        return true
    }

    /// Refresh only the current unread slice; sync updates must not replace it
    /// with the newest-window payload.
    private func refreshUnreadNow(page: LivePage? = nil) async {
        guard case .unreadContext(let anchor) = window else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let edge = page == .newer ? snapshot.last?.eventId : unreadWindowAnchor
        guard let edge,
              let payload = await client.timelinePayloadAround(
                  roomId: roomID,
                  anchorEventId: edge.value,
                  olderLimit: page == .newer ? Self.liveLimit - 1
                      : (page == .older ? Self.contextPageSize : 0),
                  newerLimit: page == .older ? Self.liveLimit - 1
                      : (page == .newer ? Self.contextPageSize : Self.liveLimit - 1))
        else { return }
        guard generation == refreshGeneration,
              case .unreadContext(let currentAnchor) = window,
              currentAnchor == anchor,
              !Task.isCancelled
        else { return }
        _ = await applyUnreadPayload(payload, anchor: anchor, page: page)
    }

    private func refreshCurrentNow() async {
        switch window {
        case .live:
            await refreshLiveNow()
        case .unreadContext:
            await refreshUnreadNow()
        case .focused, .thread:
            break
        }
    }

    private func clearUnreadContext() {
        cancelUnreadContextWarmup()
        unreadContextReady = false
        unreadOlderCursor = nil
        unreadNewerCursor = nil
        hasOlderUnreadEvents = false
        hasNewerUnreadEvents = false
        unreadWindowAnchor = nil
    }

    func cancelUnreadContextWarmup() {
        unreadContextTaskGeneration += 1
        unreadContextTask?.cancel()
        unreadContextTask = nil
        if isLoadingUnreadContext {
            isLoadingUnreadContext = false
            endTopLoading("fetch unread context and refresh stored slice")
        }
    }

    /// Ensure a message event is present in the current live window,
    /// back-paginating older history when needed.
    func ensureEventVisibleInLiveWindow(eventId: String, maxPages: Int = 8) async -> Bool {
        guard case .live = window else {
            await returnToLive()
            return await ensureEventVisibleInLiveWindow(eventId: eventId, maxPages: maxPages)
        }
        if renderedEvents.contains(where: { $0.eventId.value == eventId }) {
            return true
        }

        var pagesLoaded = 0
        while pagesLoaded < maxPages,
              !hasReachedStart,
              !Task.isCancelled
        {
            let previousFirstEventId = snapshot.first?.eventId
            await loadMoreHistory()
            pagesLoaded += 1
            if renderedEvents.contains(where: { $0.eventId.value == eventId }) {
                return true
            }
            if snapshot.first?.eventId == previousFirstEventId {
                break
            }
        }
        return renderedEvents.contains(where: { $0.eventId.value == eventId })
    }

    /// Load a thread-scoped timeline for a thread root.
    func loadThreadTimeline(rootEventId: String) async {
        isLoading = true
        defer { isLoading = false }
        clearUnreadContext()
        selectWindow(.live, reason: "load thread timeline")
        guard let messages = client.messageClient else {
            errorReporter.report(.messageLoadFailed("Not connected."))
            return
        }
        let timeline = ThreadTimeline(
            roomId: roomID, rootEventId: EventId(unchecked: rootEventId),
            messages: messages)
        if let crypto = client.roomCrypto {
            await timeline.setDecryptor { event, roomId in
                await crypto.decryptRoomEvent(event, in: roomId)
            }
        }
        do {
            try await timeline.load(localEvents: snapshot)
            thread = timeline
            focused = nil
            selectWindow(.thread(await timeline.rootEventId), reason: "thread timeline loaded")
            focusReachedEnd = true
            await renderDetached(events: await timeline.events())
        } catch {
            errorReporter.report(.messageLoadFailed(error.localizedDescription))
        }
    }

    /// Paginate backward to older history.
    func loadMoreHistory() async {
        if case .unreadContext(let anchor) = window {
            await loadMoreUnreadHistory(anchor: anchor)
            return
        }
        if case .focused = window, let focused {
            await paginateFocusedBack(focused)
            return
        }
        guard !isPaginating, hasMoreHistory || hasOlderLiveEvents else { return }
        if hasOlderLiveEvents {
            beginPagination("reveal older stored history")
            defer { endPagination("reveal older stored history") }
            await refreshLiveNow(page: .older)
            return
        }
        guard let messages = client.messageClient else { return }
        if let anchor = historyGapEventId,
           await resolveHistoryGap(before: anchor, messages: messages) {
            return
        }
        guard let from = historyCursor else {
            hasMoreHistory = false
            return
        }
        beginPagination("load older live history")
        defer { endPagination("load older live history") }
        do {
            let page = try await messages.paginate(
                roomID, from: from, limit: Self.contextPageSize)
            if !page.chunk.isEmpty, let writer = client.storeWriter {
                try? await writer.prependHistory(
                    page.chunk, roomId: roomID,
                    prevBatch: page.end.map { BatchToken($0) })
            }
            if let end = page.end {
                historyCursor = BatchToken(end)
            } else {
                hasMoreHistory = false
            }
            await refreshLiveNow(page: .older)
        } catch {
            RelayLog.timeline.warning(
                "History pagination failed room=\(self.roomId, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Fill the boundary between two retained sync windows. A page
    /// overlapping only previously fetched gap pages does not close it.
    func loadMissingMessages(at gap: StoredTimelineGap) async {
        guard case .live = window, loadingGapId == nil,
              timelineGaps.contains(gap),
              let messages = client.messageClient,
              let writer = client.storeWriter else { return }
        loadingGapId = gap.newerEventId
        gapLoadError = nil
        failedGapId = nil
        defer { loadingGapId = nil }
        do {
            let page = try await messages.paginate(
                roomID, from: BatchToken(gap.prevBatch), limit: Self.contextPageSize)
            try await writer.fillTimelineGap(
                page.chunk, roomId: roomID, newerEventId: gap.newerEventId,
                end: page.end.map { BatchToken($0) })
            await refreshLiveNow()
            if page.end == nil && timelineGaps.contains(where: {
                $0.newerEventId == gap.newerEventId
            }) {
                gapLoadError = "No earlier messages are available."
                failedGapId = gap.newerEventId
            }
        } catch {
            gapLoadError = error.localizedDescription
            failedGapId = gap.newerEventId
        }
    }

    /// Recover the cursor across a retention-trim gap: `/context` on the
    /// oldest kept event returns the events just before it plus a fresh
    /// back cursor, which the writer adopts (clearing the anchor).
    /// Returns false when the lookup fails, so the caller falls back to
    /// the stored cursor; that page's `prependHistory` also clears the
    /// anchor, so a bad anchor (e.g. a local echo) never sticks.
    private func resolveHistoryGap(before anchor: EventId, messages: MessageClient) async -> Bool {
        beginPagination("recover trimmed history gap")
        defer { endPagination("recover trimmed history gap") }
        do {
            // The server splits `limit` around the focus event, so ~50
            // land before it.
            let context = try await messages.context(roomID, eventId: anchor, limit: 100)
            if let writer = client.storeWriter {
                try await writer.resolveHistoryGap(
                    context.eventsBefore, roomId: roomID, prevBatch: context.start)
            }
            historyGapEventId = nil
            historyCursor = context.start
            if context.start == nil {
                hasMoreHistory = false
            }
            await refreshLiveNow(page: .older)
            return true
        } catch {
            RelayLog.timeline.warning(
                "History gap recovery failed room=\(self.roomId, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    /// Paginate forward toward the live edge (live, focused, or unread context).
    func loadMoreFuture() async {
        if case .live = window {
            guard hasNewerLiveEvents, !isPaginating else { return }
            beginPagination("load newer live history")
            defer { endPagination("load newer live history") }
            await refreshLiveNow(page: .newer)
            return
        }
        if case .unreadContext(let anchor) = window {
            await loadMoreUnreadFuture(anchor: anchor)
            return
        }
        guard let focused, !isPaginating else { return }
        beginPagination("load newer focused context")
        defer { endPagination("load newer focused context") }
        do {
            let count = await focused.events.count
            if focusedWindowStart + Self.liveLimit < count {
                focusedWindowStart += min(
                    Self.contextPageSize, count - focusedWindowStart - Self.liveLimit)
            } else {
                _ = try await focused.paginateForward(limit: Self.contextPageSize)
                focusedWindowStart = max(0, await focused.events.count - Self.liveLimit)
            }
            await renderFocused(focused)
        } catch {
            RelayLog.timeline.warning(
                "Forward pagination failed room=\(self.roomId, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
        }
    }

    private func startUnreadContextWarmup(anchor: EventId) {
        guard !unreadContextReady, unreadContextTask == nil else { return }
        unreadContextTaskGeneration += 1
        let generation = unreadContextTaskGeneration
        unreadContextTask = Task { @MainActor [weak self] in
            guard let self else { return false }
            let result = await self.fetchUnreadContextCursors(anchor: anchor)
            if self.unreadContextTaskGeneration == generation {
                self.unreadContextTask = nil
            }
            return result
        }
    }

    private func loadUnreadContextCursors(anchor: EventId) async -> Bool {
        guard case .unreadContext(let currentAnchor) = window,
              currentAnchor == anchor
        else { return false }
        if unreadContextReady { return true }
        startUnreadContextWarmup(anchor: anchor)
        return await unreadContextTask?.value ?? false
    }

    private func fetchUnreadContextCursors(anchor: EventId) async -> Bool {
        guard case .unreadContext(let currentAnchor) = window,
              currentAnchor == anchor
        else { return false }
        if unreadContextReady { return true }
        guard !isLoadingUnreadContext else { return false }
        isLoadingUnreadContext = true
        beginTopLoading("fetch unread context and refresh stored slice")
        defer {
            isLoadingUnreadContext = false
            endTopLoading("fetch unread context and refresh stored slice")
        }
        guard let messages = client.messageClient else {
            unreadContextReady = true
            return true
        }
        do {
            let context = try await messages.context(
                roomID, eventId: anchor, limit: Self.contextPageSize)
            guard case .unreadContext(let currentAnchor) = window,
                  currentAnchor == anchor
            else { return false }
            await client.insertTimelineHistory(context.events, roomId: roomID)
            unreadOlderCursor = context.start
            unreadNewerCursor = context.end
            unreadContextReady = true
            await refreshUnreadNow()
            return true
        } catch {
            RelayLog.timeline.warning(
                "Unread context cursors failed room=\(self.roomId, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    private func loadMoreUnreadHistory(anchor: EventId) async {
        guard !isPaginating else { return }
        beginPagination("load older unread context")
        defer { endPagination("load older unread context") }
        if hasOlderUnreadEvents {
            await refreshUnreadNow(page: .older)
            return
        }
        guard await loadUnreadContextCursors(anchor: anchor) else { return }
        if hasOlderUnreadEvents {
            await refreshUnreadNow(page: .older)
            return
        }
        guard let from = unreadOlderCursor,
              let messages = client.messageClient
        else {
            unreadOlderCursor = nil
            return
        }
        do {
            let page = try await messages.paginate(
                roomID, from: from, limit: Self.contextPageSize, direction: .backward)
            await client.prependTimelineHistory(
                page.chunk,
                roomId: roomID,
                prevBatch: page.end.map { BatchToken($0) })
            unreadOlderCursor = page.end.map { BatchToken($0) }
            await refreshUnreadNow(page: .older)
        } catch {
            RelayLog.timeline.warning(
                "Unread older-page load failed room=\(self.roomId, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
        }
    }

    private func loadMoreUnreadFuture(anchor: EventId) async {
        guard !isPaginating else { return }
        beginPagination("load newer unread context")
        defer { endPagination("load newer unread context") }
        if hasNewerUnreadEvents {
            await refreshUnreadNow(page: .newer)
            return
        }
        guard await loadUnreadContextCursors(anchor: anchor) else { return }
        if hasNewerUnreadEvents {
            await refreshUnreadNow(page: .newer)
            return
        }
        guard let from = unreadNewerCursor,
              let messages = client.messageClient
        else {
            unreadNewerCursor = nil
            return
        }
        do {
            let page = try await messages.paginate(
                roomID, from: from, limit: Self.contextPageSize, direction: .forward)
            await client.insertTimelineHistory(page.chunk, roomId: roomID)
            unreadNewerCursor = page.end.map { BatchToken($0) }
            await refreshUnreadNow(page: .newer)
        } catch {
            RelayLog.timeline.warning(
                "Unread newer-page load failed room=\(self.roomId, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Focus on one event with context around it.
    func focusOnEvent(eventId: String) async {
        clearUnreadContext()
        selectWindow(.live, reason: "begin explicit event focus")
        guard let messages = client.messageClient else {
            errorReporter.report(.messageLoadFailed("Not connected."))
            return
        }
        let timeline = FocusedTimeline(
            roomId: roomID, focusEventId: EventId(unchecked: eventId),
            messages: messages)
        if let crypto = client.roomCrypto {
            await timeline.setDecryptor { event, roomId in
                await crypto.decryptRoomEvent(event, in: roomId)
            }
        }
        do {
            try await timeline.load()
            focused = timeline
            thread = nil
            selectWindow(.focused(await timeline.focusEventId), reason: "event context loaded")
            focusedWindowStart = 0
            await renderFocused(timeline)
        } catch {
            errorReporter.report(.messageLoadFailed(error.localizedDescription))
        }
    }

    /// Paginate a focus window backward.
    private func paginateFocusedBack(_ timeline: FocusedTimeline) async {
        guard !isPaginating else { return }
        beginPagination("load older focused context")
        defer { endPagination("load older focused context") }
        do {
            if focusedWindowStart > 0 {
                focusedWindowStart = max(0, focusedWindowStart - Self.contextPageSize)
            } else {
                _ = try await timeline.paginateBack(limit: Self.contextPageSize)
            }
            await renderFocused(timeline)
        } catch {
            RelayLog.timeline.warning(
                "Focus pagination failed room=\(self.roomId, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
        }
    }

    private func renderFocused(_ timeline: FocusedTimeline) async {
        let events = await timeline.events
        let start = min(focusedWindowStart, events.count)
        let end = min(events.count, start + Self.liveLimit)
        let canPageBack = await timeline.canPaginateBack()
        let canPageForward = await timeline.canPaginateForward()
        focusReachedStart = start == 0 && !canPageBack
        focusReachedEnd = end == events.count && !canPageForward
        await renderDetached(events: Self.focusedSlice(events, start: start))
    }

    /// Render a detached (focus/thread) window. Marker columns come
    /// from a single indexed row fetch; members resolve from memory.
    private func renderDetached(events snapshot: [MessageEvent]) async {
        let renderingWindow = window
        let nextMembers = await client.roomMembersMap(roomId: roomID)
        let marker = await client.markerSummary(roomId: roomID)
        guard !Task.isCancelled, window == renderingWindow else { return }
        let nextSendStates = sendStatesById(in: snapshot)
        let nextRenderedEvents = ObservableTimelineEvent.render(
            snapshot,
            members: nextMembers,
            localUser: client.localUserId,
            highlightKeywords: highlights,
            sendStates: nextSendStates)
        let nextDecryptionFailures = await decryptionFailureMap(
            for: nextRenderedEvents)
        guard !Task.isCancelled, window == renderingWindow else { return }
        members = nextMembers
        sendStates = nextSendStates
        renderedEvents = nextRenderedEvents
        decryptionFailures = nextDecryptionFailures
        firstUnreadMessageId = Self.windowAnchor(
            snapshot: snapshot, storedAnchor: marker.firstUnreadEventId)
    }

    private func decryptionFailureMap(
        for events: [ObservableTimelineEvent]
    ) async -> [EventId: RoomCrypto.DecryptionFailure] {
        var failures: [EventId: RoomCrypto.DecryptionFailure] = [:]
        for event in events where event.kind == .unableToDecrypt {
            guard !Task.isCancelled else { return failures }
            if let failure = await client.decryptionFailure(
                roomId: roomID, eventId: event.eventId)
            {
                failures[event.eventId] = failure
            }
        }
        return failures
    }

    /// Delivery states for exactly the given events. Detached windows
    /// (focus/thread) render subsets that may omit staged echoes, so
    /// states resolve against the window rather than the live payload.
    private func sendStatesById(in snapshot: [MessageEvent]) -> [EventId: SendState] {
        var states = sendStates
        states = states.filter { id, _ in snapshot.contains(where: { $0.eventId == id }) }
        return states
    }

    /// Whether a context window that paged to the live edge should hand
    /// over to the live timeline because the user is viewing its end.
    nonisolated static func shouldPromoteToLive(
        isFocused: Bool, focusReachedEnd: Bool, isNearEnd: Bool
    ) -> Bool {
        isFocused && focusReachedEnd && isNearEnd
    }

    nonisolated static func shouldPromoteUnreadContextToLive(
        reachedLocalEnd: Bool
    ) -> Bool {
        reachedLocalEnd
    }

    /// Switch an unread-context window to live as soon as its local newest
    /// edge is known. Explicit event-focus windows still require the user
    /// to reach that edge.
    func promoteToLiveIfAtEnd(isNearEnd: Bool) async {
        let shouldPromote = switch window {
        case .unreadContext:
            Self.shouldPromoteUnreadContextToLive(reachedLocalEnd: hasReachedEnd)
        case .focused:
            Self.shouldPromoteToLive(
                isFocused: true,
                focusReachedEnd: hasReachedEnd,
                isNearEnd: isNearEnd)
        case .live, .thread:
            false
        }
        let reachedLiveEdge = hasReachedEnd
        RelayLog.timeline.info(
            "Timeline live-transition check room=\(self.roomId, privacy: .private(mask: .hash)) focus=\(self.window.logName, privacy: .public) reachedLiveEdge=\(reachedLiveEdge) nearEnd=\(isNearEnd) decision=\(shouldPromote ? "switch to live" : "stay focused", privacy: .public)")
        guard shouldPromote else { return }
        await returnToLive()
    }

    /// Return to the live timeline.
    func returnToLive() async {
        clearUnreadContext()
        focused = nil
        thread = nil
        selectWindow(.live, reason: "context reached live edge")
        focusReachedEnd = true
        hasNewerLiveEvents = false
        await refreshLiveNow()
    }

    /// Advance the fully-read marker (synced across devices).
    func sendFullyReadReceipt(upTo eventId: String) async {
        let marker = EventId(unchecked: eventId)
        await client.markFullyReadLocally(roomId: roomID, eventId: marker)
        do {
            try await client.messageSender?.setFullyRead(
                roomID, eventId: marker)
        } catch {
            RelayLog.timeline.warning(
                "Fully-read marker send failed room=\(self.roomId, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Update which system events render (read-only consumers ignore).
    func updateEventFiltering(showMembership: Bool, showState: Bool) {
        showMembershipEvents = showMembership
        showStateEvents = showState
    }

    // MARK: - Actions

    /// Send a text message, optionally as a reply with mentions. Returns
    /// once the local echo is on screen; transport continues in the
    /// background and marks the echo failed on error.
    func send(text: String, inReplyTo eventId: String?, mentionedUserIds: [String]) async {
        let mentions = mentionsParam(mentionedUserIds)
        let relatesTo = eventId.map { RelatesTo.reply(to: EventId(unchecked: $0)) }
        // `/me <action>` is sent as an `m.emote` with the command stripped.
        let emotePrefix = "/me "
        let isEmote = relatesTo == nil && text.hasPrefix(emotePrefix)
            && !text.dropFirst(emotePrefix.count).allSatisfy(\.isWhitespace)
        let body = isEmote ? String(text.dropFirst(emotePrefix.count)) : text
        let (echoStaged, continuation) = AsyncStream<Void>.makeStream()
        Task { @MainActor [client, roomID] in
            await client.messageSender?.sendText(
                roomID, body, relatesTo: relatesTo, mentions: mentions,
                msgtype: isEmote ? .emote : .text,
                onEchoStaged: { continuation.yield() })
            continuation.finish()
        }
        for await _ in echoStaged {
            await refreshForLocalEcho()
            break
        }
    }

    /// The `m.sticker` content for a pack image, replying to `inReplyTo` when set.
    static func stickerContent(
        for image: ImagePackImage, shortcode: String, inReplyTo: String?
    ) -> StickerContent {
        var content = image.stickerContent(shortcode: shortcode)
        content.relatesTo = inReplyTo.map { .reply(to: EventId(unchecked: $0)) }
        return content
    }

    /// Sends an image from an image pack as an `m.sticker`, optionally as a
    /// reply. The local echo appears immediately; sync confirms it in the
    /// background.
    func sendSticker(_ image: ImagePackImage, shortcode: String, inReplyTo: String?) async {
        let (echoStaged, continuation) = AsyncStream<Void>.makeStream()
        let echoRefreshTask = Task { @MainActor in
            for await _ in echoStaged {
                await refreshForLocalEcho()
            }
        }
        await client.messageSender?.sendSticker(
            roomID, Self.stickerContent(for: image, shortcode: shortcode, inReplyTo: inReplyTo),
            onEchoStaged: { continuation.yield() })
        continuation.finish()
        await echoRefreshTask.value
    }

    /// Reads a file and probes its dimensions, duration, and thumbnail.
    /// Reports the failure and returns nil when the file is unreadable.
    private func probeUpload(url: URL, filename: String, caption: String?) async
        -> MessageSender.GalleryUpload?
    {
        let upload = await Self.readUpload(url: url, filename: filename, caption: caption)
        if upload == nil {
            errorReporter.report(.fileCopyFailed(filename: filename, reason: "Unreadable file"))
        }
        return upload
    }

    /// The file read, image decode, and thumbnailing behind ``probeUpload``,
    /// kept off the main actor so large files don't stall the UI.
    private nonisolated static func readUpload(
        url: URL, filename: String, caption: String?
    ) async -> MessageSender.GalleryUpload? {
        let utType = UTType(filenameExtension: url.pathExtension) ?? .data
        let mimeType = utType.preferredMIMEType ?? "application/octet-stream"
        guard let data = try? Data(contentsOf: url) else { return nil }
        var upload = MessageSender.GalleryUpload(
            data: data, filename: filename, mimeType: mimeType, caption: caption)
        if utType.conforms(to: .image),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        {
            upload.width = cgImage.width
            upload.height = cgImage.height
            upload.isAnimated = ImageAnimation.isAnimated(imageData: data)
            upload.thumbnailData = jpegThumbnail(cgImage: cgImage, maxDimension: 800)
            upload.thumbnailMimeType = "image/jpeg"
        } else if utType.conforms(to: .movie) || utType.conforms(to: .video)
            || utType.conforms(to: .audio)
        {
            let asset = AVURLAsset(url: url)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
                let size = try? await track.load(.naturalSize)
            {
                upload.width = Int(size.width)
                upload.height = Int(size.height)
            }
            if let durationSeconds = try? await asset.load(.duration).seconds,
                durationSeconds.isFinite
            {
                upload.duration = Int(durationSeconds * 1000)
            }
        }
        return upload
    }

    /// Runs an upload-and-send, publishing its progress through
    /// ``uploadProgress`` and refreshing the timeline once the local echo
    /// is staged. `send` receives the echo-staged and progress callbacks.
    private func trackingUpload(
        _ send: (
            _ onEchoStaged: @escaping @Sendable () -> Void,
            _ onProgress: @escaping @Sendable (Double) -> Void
        ) async -> Void
    ) async {
        let uploadId = UUID()
        uploadFractions[uploadId] = 0
        defer { uploadFractions.removeValue(forKey: uploadId) }
        // The SDK callback is synchronous and `Sendable`, arriving off
        // the main actor as the channel drains; bridge it through a
        // stream (matching the recovery-progress pattern) so state
        // updates stay on the main actor.
        let (fractions, continuation) = AsyncStream<Double>.makeStream()
        let consumer = Task { @MainActor in
            for await fraction in fractions {
                uploadFractions[uploadId] = fraction
            }
        }
        // `stageEcho` is a local-only store mutation with no sync delta to
        // announce it, so the timeline won't otherwise learn the pending
        // bubble exists until the real event lands after the upload
        // finishes. Bump the revision as soon as it's staged so the
        // placeholder (and its progress bar) appears immediately.
        let (echoStaged, echoStagedContinuation) = AsyncStream<Void>.makeStream()
        let echoStagedConsumer = Task { @MainActor in
            for await _ in echoStaged {
                client.bumpRevision(roomID)
            }
        }
        await send({ echoStagedContinuation.yield() }, { continuation.yield($0) })
        continuation.finish()
        echoStagedContinuation.finish()
        await consumer.value
        await echoStagedConsumer.value
    }

    /// Records the server's upload limit when it rejects `size` bytes.
    private func uploadFailureHandler(size: Int) -> @Sendable (any Error) -> Void {
        { [client] error in
            guard case .serverError(code: "M_TOO_LARGE", _, _) = error as? MatrixError else {
                return
            }
            Task { @MainActor in client.noteUploadTooLarge(size: size) }
        }
    }

    /// Send a file attachment with probed metadata.
    func sendAttachment(url: URL, caption: String?, inReplyTo: String?) async {
        guard let upload = await probeUpload(
            url: url, filename: url.lastPathComponent, caption: caption)
        else { return }
        await trackingUpload { onEchoStaged, onProgress in
            await client.messageSender?.sendAttachment(
                roomID,
                data: upload.data, filename: upload.filename, mimeType: upload.mimeType,
                caption: upload.caption, width: upload.width, height: upload.height,
                duration: upload.duration, isAnimated: upload.isAnimated,
                thumbnailData: upload.thumbnailData, thumbnailMimeType: upload.thumbnailMimeType,
                inReplyTo: inReplyTo.map(EventId.init(unchecked:)),
                onEchoStaged: onEchoStaged,
                onProgress: onProgress,
                onFailure: uploadFailureHandler(size: upload.data.count))
        }
    }

    /// Sends several files as one gallery message (MSC4274). Each entry is
    /// the staged file, its display filename, and its optional caption.
    func sendGallery(
        files: [(url: URL, filename: String, caption: String?)],
        caption: String, inReplyTo: String?
    ) async {
        var uploads: [MessageSender.GalleryUpload] = []
        for file in files {
            guard let upload = await probeUpload(
                url: file.url, filename: file.filename, caption: file.caption)
            else { return }
            uploads.append(upload)
        }
        let totalSize = uploads.reduce(0) { $0 + $1.data.count }
        await trackingUpload { onEchoStaged, onProgress in
            await client.messageSender?.sendGallery(
                roomID, items: uploads, caption: caption,
                inReplyTo: inReplyTo.map(EventId.init(unchecked:)),
                onEchoStaged: onEchoStaged,
                onProgress: onProgress,
                onFailure: uploadFailureHandler(size: totalSize))
        }
    }

    /// A callback for the SDK's `onEchoStaged` that refreshes the timeline
    /// immediately, since a staged echo has no sync delta to announce it.
    private func echoStagedRefresh() -> @Sendable () -> Void {
        { [weak self] in
            Task { @MainActor in await self?.refreshForLocalEcho() }
        }
    }

    /// Toggle an emoji reaction (removes the user's own reaction if present).
    /// The badge updates optimistically; sync confirms in the background.
    func toggleReaction(messageId: String, key: String) async {
        await client.messageSender?.toggleReaction(
            roomID, target: EventId(unchecked: messageId), key: key,
            onEchoStaged: echoStagedRefresh())
    }

    /// Cast, change, or retract (empty `answers`) a vote on a poll.
    /// The count updates optimistically; sync confirms in the background.
    func vote(pollId: String, answers: [String]) async {
        await client.messageSender?.vote(
            roomID, poll: EventId(unchecked: pollId), answers: answers,
            onEchoStaged: echoStagedRefresh())
    }

    /// End a poll created by the local user. Failures surface through
    /// the error reporter; sync confirms the end in the background.
    func endPoll(pollId: String) async {
        do {
            try await client.messageSender?.endPoll(
                roomID, poll: EventId(unchecked: pollId))
        } catch {
            errorReporter.report(.messageSendFailed(error.localizedDescription))
        }
    }

    /// Start a poll from the compose bar's poll composer. The poll card
    /// appears as a local echo; failures mark the echo failed and sync
    /// confirms the event in the background.
    func startPoll(question: String, options: [String], maxSelections: Int, kind: PollKind) async {
        await client.startPoll(
            roomId: roomID, question: question, options: options,
            maxSelections: maxSelections, kind: kind)
    }

    /// Edit own message text.
    func edit(messageId: String, newText: String, mentionedUserIds: [String]) async {
        do {
            try await client.messageSender?.edit(
                roomID,
                eventId: EventId(unchecked: messageId), newBody: newText,
                mentions: mentionsParam(mentionedUserIds),
                onEchoStaged: echoStagedRefresh())
        } catch {
            errorReporter.report(.editFailed(error.localizedDescription))
        }
    }

    /// Redact a message (cancels unsent echoes).
    func redact(messageId: String, reason: String? = nil) async {
        do {
            try await client.messageSender?.redact(
                roomID, eventId: EventId(unchecked: messageId), reason: reason)
        } catch {
            errorReporter.report(.redactFailed(error.localizedDescription))
        }
    }

    /// Pin a message.
    func pin(eventId: String) async {
        do {
            try await client.messageSender?.pin(
                roomID, eventId: EventId(unchecked: eventId))
        } catch {
            errorReporter.report(.pinFailed(error.localizedDescription))
        }
    }

    /// Unpin a message.
    func unpin(eventId: String) async {
        do {
            try await client.messageSender?.unpin(
                roomID, eventId: EventId(unchecked: eventId))
        } catch {
            errorReporter.report(.pinFailed(error.localizedDescription))
        }
    }

    // MARK: - Private

    private func mentionsParam(_ userIds: [String]) -> Mentions? {
        guard !userIds.isEmpty else { return nil }
        return Mentions(userIds: userIds.map(UserId.init(unchecked:)))
    }

    /// Downscaled JPEG thumbnail for image attachments.
    private nonisolated static func jpegThumbnail(cgImage: CGImage, maxDimension: CGFloat) -> Data? {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let scale = min(1, maxDimension / max(width, height))
        let size = CGSize(width: width * scale, height: height * scale)
        guard size.width >= 1, size.height >= 1,
            let context = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        guard let thumbnail = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
