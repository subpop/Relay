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
private enum TimelineWindow {
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

    /// Raw snapshot behind ``renderedEvents`` (for thread roots).
    private var snapshot: [MessageEvent] = []
    /// Member map behind ``renderedEvents``.
    private var members: [UserId: MemberContent] = [:]
    /// Local delivery states for staged echoes.
    private var sendStates: [EventId: SendState] = [:]

    /// Cursor toward older history (`GET /messages` `dir=b`).
    private var historyCursor: BatchToken?
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
    /// thin progress bar above the compose bar; empty when idle.
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
    /// Members resolve from memory; roles need one small power-levels
    /// fetch (cached per call site by the view's debounce).
    func roomMembers() async -> [RoomMemberDetails] {
        let members = client.roomMembersMap(roomId: roomID)
        let powerLevels = await client.roomPowerLevels(roomId: roomID)
        return members.map { userId, content in
            let level = powerLevels.map {
                RoomPermissions.powerLevel(of: userId, in: $0)
            } ?? 0
            return RoomMemberDetails(
                userId: userId,
                displayName: content.displayname,
                avatarURL: content.avatarUrl.flatMap { try? MXCURI($0) },
                role: .of(level),
                powerLevel: level)
        }.sorted { $0.resolvedName < $1.resolvedName }
    }

    /// The local user's power-level-derived permissions.
    func roomPermissions() async -> RoomPermissions? {
        guard let localUser = client.localUserId,
              let powerLevels = await client.roomPowerLevels(roomId: roomID)
        else { return nil }
        return RoomPermissions.evaluate(powerLevels: powerLevels, userId: localUser)
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
            hasReachedStart: hasReachedStart)
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
        let members = client.roomMembersMap(roomId: roomID)
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
        refreshGeneration += 1
        let generation = refreshGeneration
        let payload = await client.timelinePayload(roomId: roomID, limit: windowSize)
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        guard case .live = window else { return }
        snapshot = payload.snapshot
        members = client.roomMembersMap(roomId: roomID)
        sendStates = payload.sendStates
        renderedEvents = ObservableTimelineEvent.render(
            snapshot,
            members: members,
            localUser: client.localUserId,
            highlightKeywords: highlights,
            sendStates: sendStates)
        firstUnreadMessageId = Self.windowAnchor(
            snapshot: snapshot, storedAnchor: payload.firstUnreadEventId)
        historyCursor = payload.prevBatch.map { BatchToken($0) }
    }

    /// Request a live refresh, coalescing bursts: rapid revision bumps
    /// (sync storms, typing) collapse into one fetch ~120ms later.
    private func requestRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
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
        if historyCursor == nil {
            // No back-pagination cursor stored: the window is the whole
            // known history.
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
        members = client.roomMembersMap(roomId: roomID)
        let marker = await client.markerSummary(roomId: roomID)
        sendStates = sendStatesById(in: snapshot)
        renderedEvents = ObservableTimelineEvent.render(
            snapshot,
            members: members,
            localUser: client.localUserId,
            highlightKeywords: highlights,
            sendStates: sendStates)
        firstUnreadMessageId = Self.windowAnchor(
            snapshot: snapshot, storedAnchor: marker.firstUnreadEventId)
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

    /// Send a text message, optionally as a reply with mentions.
    func send(text: String, inReplyTo eventId: String?, mentionedUserIds: [String]) async {
        let mentions = mentionsParam(mentionedUserIds)
        if let eventId {
            try? await client.messageSender?.reply(
                roomID, to: EventId(unchecked: eventId), body: text,
                mentions: mentions)
            return
        }
        await client.messageSender?.sendText(roomID, text, mentions: mentions)
    }

    /// Send a file attachment with probed metadata.
    func sendAttachment(url: URL, caption: String?, inReplyTo: String?) async {
        let filename = url.lastPathComponent
        let utType = UTType(filenameExtension: url.pathExtension) ?? .data
        let mimeType = utType.preferredMIMEType ?? "application/octet-stream"
        guard let data = try? Data(contentsOf: url) else {
            errorReporter.report(.fileCopyFailed(filename: filename, reason: "Unreadable file"))
            return
        }
        var width: Int?
        var height: Int?
        var duration: Int?
        var thumbnailData: Data?
        if utType.conforms(to: .image),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        {
            width = cgImage.width
            height = cgImage.height
            thumbnailData = jpegThumbnail(cgImage: cgImage, maxDimension: 800)
        } else if utType.conforms(to: .movie) || utType.conforms(to: .video)
            || utType.conforms(to: .audio)
        {
            let asset = AVURLAsset(url: url)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
                let size = try? await track.load(.naturalSize)
            {
                width = Int(size.width)
                height = Int(size.height)
            }
            if let durationSeconds = try? await asset.load(.duration).seconds,
                durationSeconds.isFinite
            {
                duration = Int(durationSeconds * 1000)
            }
        }
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
        await client.messageSender?.sendAttachment(
            roomID,
            data: data, filename: filename, mimeType: mimeType,
            caption: caption, width: width, height: height, duration: duration,
            thumbnailData: thumbnailData, thumbnailMimeType: "image/jpeg",
            inReplyTo: inReplyTo.map(EventId.init(unchecked:)),
            onProgress: { continuation.yield($0) })
        continuation.finish()
        await consumer.value
    }

    /// Toggle an emoji reaction (removes the user's own reaction if present).
    /// The badge updates optimistically; sync confirms in the background.
    func toggleReaction(messageId: String, key: String) async {
        await client.messageSender?.toggleReaction(
            roomID, target: EventId(unchecked: messageId), key: key)
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
        try? await client.messageSender?.redact(
            roomID, eventId: EventId(unchecked: messageId), reason: reason)
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
    private func jpegThumbnail(cgImage: CGImage, maxDimension: CGFloat) -> Data? {
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
