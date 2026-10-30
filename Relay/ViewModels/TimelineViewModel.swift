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

/// Whether the timeline shows live messages, a focused event window,
/// or a thread.
enum TimelineFocus: Hashable, Sendable {
    /// Live messages anchored at the newest edge.
    case live
    /// Context window around one event.
    case focused(EventId)
    /// Thread rooted at one event.
    case thread(EventId)
}

/// Which window the timeline shows. Mirrors the detached focus/thread
/// actors, which cannot be read synchronously from view bodies.
private enum TimelineWindow: Equatable {
    /// Live messages anchored at the newest edge.
    case live
    /// Context window around one event.
    case focused(EventId)
    /// Thread rooted at one event.
    case thread(EventId)
}

/// View model driving `TimelineView` from the normalized store.
///
/// The live window renders the room's stored events through
/// `ObservableTimelineEvent.render`; sync deltas refresh it via the
/// room's revision counter on `RelayClient` (bumped for every delta
/// touching the room). Focus and thread modes page detached windows
/// (`FocusedTimeline`/`ThreadTimeline`) without touching the live
/// window. Sends go through `RelayClient`'s store-backed pipeline
/// (local echoes, encrypted/plaintext branching).
@Observable
final class TimelineViewModel {
    /// Newest-window size for the live timeline. Older history pages in
    /// through `loadMoreHistory()`. Matches the retired live window's
    /// 500-event cap: the unread divider anchors to the first-unread
    /// event, which only renders when the window reaches it.
    private static let liveLimit = 500
    /// Upper bound for the grown live window (see `windowSize`). Keeps
    /// per-refresh render work bounded for marathon scrollers while
    /// staying far above the base window.
    private static let maxWindowSize = 2000

    private nonisolated let timelineLogger = Logger(
        subsystem: "app.subpop.Relay", category: "Timeline")
    private let roomID: RoomId
    @ObservationIgnored private let client: RelayClient
    private let errorReporter: ErrorReporter
    private var highlights: [String]

    /// Whether the initial load is in flight.
    var isLoading = true
    /// First unread event ID for the "New" divider. The store anchors
    /// to the oldest unread in full history, which can predate the
    /// loaded window and match no rendered row; the anchor is clamped
    /// to the window (window-first fallback) mirroring the retired
    /// live timeline, so the divider renders while anything is unread.
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
    /// Whether older history may exist. True until a page comes back
    /// cursorless.
    private var hasMoreHistory = true
    /// Whether a pagination request is in flight.
    private var isPaginating = false

    /// Detached focus window, when focusing an event.
    @ObservationIgnored private var focused: FocusedTimeline?
    /// Detached thread window, when viewing a thread.
    @ObservationIgnored private var thread: ThreadTimeline?
    /// Whether the focus window reached the live edge.
    private var focusReachedEnd = true

    /// Current live-window size. Starts at `liveLimit` and grows by
    /// each back-pagination page (up to `maxWindowSize`) so paginated
    /// rows stay rendered: the store keeps full history, so refetching
    /// "newest N" with growing N reproduces accumulated-window
    /// semantics. Without this, pages landing outside a fixed window
    /// would vanish on the next refresh.
    private var windowSize = TimelineViewModel.liveLimit

    /// Grow the live window by a fetched page, clamped to
    /// `maxWindowSize`. Pure so the accumulation rule stays unit-tested.
    static func grownWindowSize(current: Int, fetched: Int) -> Int {
        min(maxWindowSize, current + max(fetched, 0))
    }

    /// Observation loop over the room's revision counter.
    @ObservationIgnored private var observeTask: Task<Void, Never>?
    /// Pending coalesced live refresh.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
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
        MessageRowBuilder.buildRows(
            for: filteredEvents,
            localUserId: client.localUserId,
            hasReachedStart: hasReachedStart,
            decryptionFailures: decryptionFailures)
    }

    /// Whether older messages are being fetched.
    var isLoadingMore: Bool { isPaginating }

    /// Whether backward pagination reached the room start.
    var hasReachedStart: Bool {
        guard case .live = window else { return false }
        return !hasMoreHistory
    }

    /// Whether forward pagination reached the live edge (focus mode).
    var hasReachedEnd: Bool {
        guard case .focused = window else { return true }
        return focusReachedEnd
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
        case .focused(let eventId): return .focused(eventId)
        case .thread(let rootId): return .thread(rootId)
        }
    }

    /// Which window the timeline shows. Mirrors the detached actors
    /// (`focused`/`thread`), which cannot be read synchronously.
    private var window: TimelineWindow = .live

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
    /// dropped via the generation guard. No-op while a focus or thread
    /// window is active (those render their detached actors).
    private func refreshLiveNow() async {
        guard case .live = window else { return }
        let refreshState = timelineSignposter.beginInterval(
            "refreshLiveTimeline", id: timelineSignposter.makeSignpostID(),
            "window limit \(self.windowSize)")
        defer { timelineSignposter.endInterval("refreshLiveTimeline", refreshState) }
        refreshGeneration += 1
        let generation = refreshGeneration
        let fetchState = timelineSignposter.beginInterval(
            "fetchTimelinePayload", id: timelineSignposter.makeSignpostID())
        let payload = await client.timelinePayload(roomId: roomID, limit: windowSize)
        timelineSignposter.endInterval("fetchTimelinePayload", fetchState)
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        guard case .live = window else { return }
        let nextSnapshot = payload.snapshot
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
        firstUnreadMessageId = Self.windowAnchor(
            snapshot: snapshot, storedAnchor: payload.firstUnreadEventId)
        historyCursor = payload.prevBatch.map { BatchToken($0) }
        historyGapEventId = payload.historyGapEventId.map { EventId(unchecked: $0) }
        if historyGapEventId != nil {
            // A trim can land while the room is open; reopen history.
            hasMoreHistory = true
        }
    }

    /// Render a staged local echo immediately instead of waiting for the
    /// ordinary revision debounce or the homeserver's sync echo.
    private func refreshForLocalEcho() async {
        refreshTask?.cancel()
        await refreshLiveNow()
    }

    /// Request a live refresh, coalescing bursts: rapid revision bumps
    /// (sync storms, typing) collapse into one fetch ~120ms later.
    private func requestRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            let state = timelineSignposter.beginInterval(
                "timelineRefreshDebounce", id: timelineSignposter.makeSignpostID())
            try? await Task.sleep(for: .milliseconds(120))
            timelineSignposter.endInterval("timelineRefreshDebounce", state)
            guard let self, !Task.isCancelled else { return }
            await self.refreshLiveNow()
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
            requestRefresh()
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
        windowSize = Self.liveLimit
        if client.localUserId == nil {
            // Without a local user ID every message renders as incoming;
            // log it so the failure is observable instead of silent.
            timelineLogger.warning("Local user ID unavailable; own messages render as incoming")
        }
        await refreshLiveNow()
        await refreshTypingUsers()
        if historyCursor == nil && historyGapEventId == nil {
            // No back-pagination cursor or trim gap stored: the window
            // is the whole known history.
            hasMoreHistory = false
        }
        isLoading = false
    }

    /// Load a thread-scoped timeline for a thread root.
    func loadThreadTimeline(rootEventId: String) async {
        isLoading = true
        defer { isLoading = false }
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
            window = .thread(await timeline.rootEventId)
            focusReachedEnd = true
            await renderDetached(events: await timeline.events())
        } catch {
            errorReporter.report(.messageLoadFailed(error.localizedDescription))
        }
    }

    /// Paginate backward to older history.
    func loadMoreHistory() async {
        if case .focused = window, let focused {
            await paginateFocusedBack(focused)
            return
        }
        guard !isPaginating, hasMoreHistory else { return }
        guard let messages = client.messageClient else { return }
        if let anchor = historyGapEventId,
           await resolveHistoryGap(before: anchor, messages: messages) {
            return
        }
        guard let from = historyCursor else {
            hasMoreHistory = false
            return
        }
        isPaginating = true
        defer { isPaginating = false }
        do {
            let page = try await messages.paginate(roomID, from: from, limit: 50)
            if !page.chunk.isEmpty, let writer = client.storeWriter {
                try? await writer.prependHistory(
                    page.chunk, roomId: roomID,
                    prevBatch: page.end.map { BatchToken($0) })
                windowSize = Self.grownWindowSize(current: windowSize, fetched: page.chunk.count)
            }
            if let end = page.end {
                historyCursor = BatchToken(end)
            } else {
                hasMoreHistory = false
            }
            await refreshLiveNow()
        } catch {
            timelineLogger.debug(
                "History pagination failed room=\(self.roomId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Recover the cursor across a retention-trim gap: `/context` on the
    /// oldest kept event returns the events just before it plus a fresh
    /// back cursor, which the writer adopts (clearing the anchor).
    /// Returns false when the lookup fails, so the caller falls back to
    /// the stored cursor; that page's `prependHistory` also clears the
    /// anchor, so a bad anchor (e.g. a local echo) never sticks.
    private func resolveHistoryGap(before anchor: EventId, messages: MessageClient) async -> Bool {
        isPaginating = true
        defer { isPaginating = false }
        do {
            // The server splits `limit` around the focus event, so ~50
            // land before it.
            let context = try await messages.context(roomID, eventId: anchor, limit: 100)
            if let writer = client.storeWriter {
                try await writer.resolveHistoryGap(
                    context.eventsBefore, roomId: roomID, prevBatch: context.start)
                windowSize = Self.grownWindowSize(
                    current: windowSize, fetched: context.eventsBefore.count)
            }
            historyGapEventId = nil
            historyCursor = context.start
            if context.start == nil {
                hasMoreHistory = false
            }
            await refreshLiveNow()
            return true
        } catch {
            timelineLogger.debug(
                "History gap recovery failed room=\(self.roomId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Paginate forward toward the live edge (focus mode).
    func loadMoreFuture() async {
        guard let focused, !isPaginating else { return }
        isPaginating = true
        defer { isPaginating = false }
        do {
            _ = try await focused.paginateForward()
            focusReachedEnd = await !focused.canPaginateForward()
            await renderDetached(events: await focused.events)
        } catch {
            timelineLogger.debug(
                "Forward pagination failed room=\(self.roomId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Focus on one event with context around it.
    func focusOnEvent(eventId: String) async {
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
            window = .focused(await timeline.focusEventId)
            focusReachedEnd = await !timeline.canPaginateForward()
            await renderDetached(events: await timeline.events)
        } catch {
            errorReporter.report(.messageLoadFailed(error.localizedDescription))
        }
    }

    /// Paginate a focus window backward.
    private func paginateFocusedBack(_ timeline: FocusedTimeline) async {
        guard !isPaginating else { return }
        isPaginating = true
        defer { isPaginating = false }
        do {
            _ = try await timeline.paginateBack()
            await renderDetached(events: await timeline.events)
        } catch {
            timelineLogger.debug(
                "Focus pagination failed room=\(self.roomId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
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

    /// Return to the live timeline.
    func returnToLive() async {
        focused = nil
        thread = nil
        window = .live
        focusReachedEnd = true
        windowSize = Self.liveLimit
        await refreshLiveNow()
    }

    /// Advance the fully-read marker (synced across devices).
    func sendFullyReadReceipt(upTo eventId: String) async {
        do {
            try await client.messageSender?.setFullyRead(
                roomID, eventId: EventId(unchecked: eventId))
            // Local-only store mutation: wake the timeline now rather
            // than waiting for the next sync delta.
            client.bumpRevision(roomID)
        } catch {
            timelineLogger.debug(
                "Fully-read marker send failed room=\(self.roomId, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
                mentions: mentionsParam(mentionedUserIds))
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
