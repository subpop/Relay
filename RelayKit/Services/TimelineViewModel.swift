// swiftlint:disable file_length
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
import RelayInterface
import OSLog
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "RelayKit", category: "Timeline")

/// Concrete implementation of ``TimelineViewModelProtocol`` backed by the Matrix Rust SDK.
///
/// ``TimelineViewModel`` manages a single room's message timeline. It subscribes to live
/// timeline diffs from the SDK using ``SDKListener``, converts them into ``TimelineMessage``
/// models, handles backward pagination via ``subscribeToBackPaginationStatus``, computes the
/// unread marker position, and observes typing notifications.
@Observable
// swiftlint:disable:next type_body_length
public final class TimelineViewModel: TimelineViewModelProtocol {
    public private(set) var messages: [TimelineMessage] = []
    public private(set) var messagesVersion: UInt = 0
    public private(set) var isLoading = true
    public private(set) var isLoadingMore = false
    public private(set) var hasReachedStart = false
    public private(set) var hasReachedEnd = true
    public var firstUnreadMessageId: String?
    public private(set) var typingUserDisplayNames: [String] = []
    public private(set) var timelineFocus: TimelineFocusState = .live

    private let room: Room
    private let roomId: String
    private let currentUserId: String?
    private let unreadCount: Int
    /// The SDK timeline, exposed for use by ``MatrixService/pinnedMessages(roomId:)``.
    private(set) var sdkTimeline: Timeline?
    private var timelineItems: [TimelineItem] = []
    /// Pre-extracted event/transaction IDs for each item in ``timelineItems``,
    /// maintained in parallel during ``applyDiffs``. Used to avoid FFI calls
    /// during incremental cache lookups in the mapper.  `nil` entries
    /// represent non-event items (e.g. date dividers) that have no ID.
    private var timelineItemIDs: [String?] = []
    private var observationTask: Task<Void, Never>?
    private var paginationTask: Task<Void, Never>?
    private var typingTask: Task<Void, Never>?
    private let messageMapper: TimelineMessageMapper
    private let errorReporter: ErrorReporter
    private var hasComputedUnreadMarker = false
    private var isSendingFullyReadReceipt = false
    private var fetchedReplyEventIds: Set<String> = []

    /// Tracks which indices in ``timelineItems`` were modified by the latest
    /// batch of diffs. `nil` means a full remap is required (e.g. after a
    /// reset or clear). An empty set means nothing changed.
    private var pendingChangedIndices: IndexSet?

    /// Previously mapped messages keyed by event/transaction ID for O(1) reuse
    /// during incremental rebuilds. Updated after each ``rebuildMessages()``
    /// call so unchanged items are never re-mapped.
    private var messageCache: [String: TimelineMessage] = [:]

    /// Monotonically increasing counter used to discard stale results from
    /// background mapping tasks that were superseded by a newer rebuild.
    private var rebuildGeneration: UInt = 0

    /// Continuation that is resumed once the first batch of timeline diffs has
    /// been received and applied.  Both the pagination-status observer (live
    /// timelines) and ``focusOnEvent`` (focused timelines) await this before
    /// clearing ``isLoading`` so the view never transiently shows an empty state.
    private var initialDiffsContinuation: AsyncStream<Void>.Continuation?
    private var initialDiffsStream: AsyncStream<Void>?

    @ObservationIgnored private var timelineHandle: TaskHandle?
    @ObservationIgnored private var paginationHandle: TaskHandle?
    @ObservationIgnored private var typingHandle: TaskHandle?

    /// Creates a new view model for the given room.
    ///
    /// - Parameters:
    ///   - room: The Matrix Rust SDK `Room` object.
    ///   - currentUserId: The Matrix user ID of the signed-in user, used for highlight detection.
    ///   - unreadCount: The number of unread messages, used to position the "New" divider.
    ///   - notificationKeywords: User-defined keywords that trigger message highlighting.
    public init(
        room: Room,
        currentUserId: String?,
        unreadCount: Int = 0,
        notificationKeywords: [String] = [],
        errorReporter: ErrorReporter
    ) {
        self.room = room
        self.roomId = room.id()
        self.currentUserId = currentUserId
        self.unreadCount = unreadCount
        self.messageMapper = TimelineMessageMapper(
            currentUserId: currentUserId,
            notificationKeywords: notificationKeywords
        )
        self.errorReporter = errorReporter
    }

    deinit {
        let tasks = MainActor.assumeIsolated { (observationTask, paginationTask, typingTask) }
        tasks.0?.cancel()
        tasks.1?.cancel()
        tasks.2?.cancel()
    }

    // MARK: - Public

    public func loadTimeline(focusedOnEventId fullyReadEventId: String? = nil) async {
        guard sdkTimeline == nil else { return }

        isLoading = true
        do {
            if let fullyReadEventId {
                // Load timeline focused on the fully-read marker
                try await setupTimeline(focus: .event(
                    eventId: fullyReadEventId,
                    numContextEvents: 50,
                    threadMode: .automatic(hideThreadedEvents: true)
                ))
                timelineFocus = .focusedOnEvent(fullyReadEventId)
                hasReachedEnd = false
            } else {
                try await setupTimeline(focus: .live(hideThreadedEvents: true))
                timelineFocus = .live
                hasReachedEnd = true
            }
            observeTypingNotifications()
        } catch {
            logger.error("Failed to load timeline: \(error)")
            errorReporter.report(.messageLoadFailed(error.localizedDescription))
            isLoading = false
        }
    }

    public func loadMoreHistory() async {
        guard let sdkTimeline, !isLoadingMore, !hasReachedStart else { return }
        do {
            _ = try await sdkTimeline.paginateBackwards(numEvents: 100)
        } catch {
            logger.error("Failed to load earlier messages: \(error)")
            errorReporter.report(.messageLoadFailed(error.localizedDescription))
        }
    }

    public func loadMoreFuture() async {
        guard let sdkTimeline, !hasReachedEnd else { return }
        do {
            let hitEnd = try await sdkTimeline.paginateForwards(numEvents: 40)
            if hitEnd {
                hasReachedEnd = true
                // Auto-transition to live: the user has scrolled to the newest messages
                if case .focusedOnEvent = timelineFocus {
                    timelineFocus = .live
                }
            }
        } catch {
            logger.error("Failed to load newer messages: \(error)")
        }
    }

    public func sendFullyReadReceipt(upTo eventId: String) async {
        guard let sdkTimeline else { return }
        // Transaction IDs (pending local echoes) don't have the leading "$"
        // sigil that the server requires for event IDs. Skip them; the receipt
        // will be sent once the echo is confirmed and the row re-appears with
        // a real event ID.
        guard eventId.hasPrefix("$") else { return }
        // Serialize calls so we don't fire concurrent requests to the same
        // endpoint, which the SDK rejects with ConcurrentRequestFailed.
        guard !isSendingFullyReadReceipt else { return }
        isSendingFullyReadReceipt = true
        defer { isSendingFullyReadReceipt = false }
        do {
            try await sdkTimeline.sendReadReceipt(receiptType: .fullyRead, eventId: eventId)
        } catch {
            logger.error("Failed to send fully-read receipt: \(error)")
        }
    }

    public func focusOnEvent(eventId: String) async {
        isLoading = true
        teardownTimeline()

        do {
            try await setupTimeline(focus: .event(
                eventId: eventId,
                numContextEvents: 50,
                threadMode: .automatic(hideThreadedEvents: true)
            ))
            timelineFocus = .focusedOnEvent(eventId)
            hasReachedEnd = false
        } catch {
            logger.error("Failed to focus on event \(eventId): \(error)")
            errorReporter.report(.messageLoadFailed(error.localizedDescription))
            // Attempt to recover by returning to live
            do {
                try await setupTimeline(focus: .live(hideThreadedEvents: true))
                timelineFocus = .live
            } catch {
                logger.error("Failed to recover live timeline: \(error)")
            }
        }

        // Wait for the diff observer to deliver initial content so
        // `timelineItems` is populated before we clear the loading flag.
        // Focused timelines don't use the pagination-status observer,
        // so this is the only gate that prevents an empty flash.
        if let diffStream = initialDiffsStream {
            for await _ in diffStream { break }
        }
        await rebuildMessages()
        isLoading = false
    }

    public func returnToLive() async {
        isLoading = true
        teardownTimeline()

        do {
            try await setupTimeline(focus: .live(hideThreadedEvents: true))
            timelineFocus = .live
        } catch {
            logger.error("Failed to return to live timeline: \(error)")
            errorReporter.report(.messageLoadFailed(error.localizedDescription))
            isLoading = false
        }
    }

    public func send(text: String, inReplyTo eventId: String? = nil, mentionedUserIds: [String] = []) async {
        guard let sdkTimeline else { return }
        // The spec recommends always including m.mentions on every event, even
        // when empty, to prevent legacy push rules (e.g. .m.rule.contains_display_name)
        // from triggering unintentional notifications.
        let msg = messageEventContentFromMarkdown(md: text)
            .withMentions(mentions: Mentions(userIds: mentionedUserIds, room: false))
        do {
            if let eventId {
                try await sdkTimeline.sendReply(msg: msg, eventId: eventId)
            } else {
                _ = try await sdkTimeline.send(msg: msg)
            }
        } catch {
            logger.error("Failed to send message: \(error)")
            errorReporter.report(.messageSendFailed(error.localizedDescription))
        }
    }

    public func edit(messageId: String, newText: String, mentionedUserIds: [String] = []) async {
        guard let sdkTimeline else { return }
        let itemId: EventOrTransactionId = if messageId.hasPrefix("$") {
            .eventId(eventId: messageId)
        } else {
            .transactionId(transactionId: messageId)
        }
        let content = messageEventContentFromMarkdown(md: newText)
            .withMentions(mentions: Mentions(userIds: mentionedUserIds, room: false))
        let editedContent = EditedContent.roomMessage(content: content)
        do {
            try await sdkTimeline.edit(eventOrTransactionId: itemId, newContent: editedContent)
        } catch {
            logger.error("Failed to edit message: \(error)")
            errorReporter.report(.editFailed(error.localizedDescription))
        }
    }

    public func toggleReaction(messageId: String, key: String) async {
        guard let sdkTimeline else { return }
        let itemId: EventOrTransactionId = if messageId.hasPrefix("$") {
            .eventId(eventId: messageId)
        } else {
            .transactionId(transactionId: messageId)
        }
        do {
            _ = try await sdkTimeline.toggleReaction(itemId: itemId, key: key)
        } catch {
            logger.error("Failed to toggle reaction: \(error)")
            errorReporter.report(.reactionFailed(error.localizedDescription))
        }
    }

    public func redact(messageId: String, reason: String? = nil) async {
        guard let sdkTimeline else { return }
        let itemId: EventOrTransactionId = if messageId.hasPrefix("$") {
            .eventId(eventId: messageId)
        } else {
            .transactionId(transactionId: messageId)
        }
        do {
            try await sdkTimeline.redactEvent(eventOrTransactionId: itemId, reason: reason)
        } catch {
            logger.error("Failed to delete message: \(error)")
            errorReporter.report(.redactFailed(error.localizedDescription))
        }
    }

    public func pin(eventId: String) async {
        guard let sdkTimeline else { return }
        do {
            _ = try await sdkTimeline.pinEvent(eventId: eventId)
        } catch {
            logger.error("Failed to pin message: \(error)")
            errorReporter.report(.pinFailed(error.localizedDescription))
        }
    }

    public func unpin(eventId: String) async {
        guard let sdkTimeline else { return }
        do {
            _ = try await sdkTimeline.unpinEvent(eventId: eventId)
        } catch {
            logger.error("Failed to unpin message: \(error)")
            errorReporter.report(.pinFailed(error.localizedDescription))
        }
    }

    // swiftlint:disable:next function_body_length
    public func sendAttachment(url: URL, caption: String? = nil) async {
        guard let sdkTimeline else { return }

        let filename = url.lastPathComponent
        let utType = UTType(filenameExtension: url.pathExtension) ?? .data
        let mime = utType.preferredMIMEType

        // Convert a plain-text caption to simple HTML for formattedCaption
        let formattedCaption: String? = caption.map { "<p>\($0)</p>" }

        do {
            let handle: SendAttachmentJoinHandle

            if utType.conforms(to: .image),
               let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                let data: Data
                do {
                    data = try Data(contentsOf: url)
                } catch {
                    logger.error("Failed to read attachment \(filename): \(error)")
                    errorReporter.report(.fileCopyFailed(filename: filename, reason: error.localizedDescription))
                    return
                }
                let fileSize = UInt64(data.count)
                let width = UInt64(cgImage.width)
                let height = UInt64(cgImage.height)
                let hash = blurHash(from: cgImage) ?? "000000"

                let params = UploadParameters(
                    source: .data(bytes: data, filename: filename),
                    caption: caption,
                    formattedCaption: formattedCaption.map { .init(format: .html, body: $0) },
                    mentions: nil,
                    inReplyTo: nil
                )
                handle = try sdkTimeline.sendImage(
                    params: params,
                    thumbnailSource: nil,
                    imageInfo: ImageInfo(
                        height: height, width: width, mimetype: mime, size: fileSize,
                        thumbnailInfo: nil, thumbnailSource: nil, blurhash: hash, isAnimated: nil
                    )
                )
            } else if utType.conforms(to: .movie) || utType.conforms(to: .video) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = UInt64((attrs?[.size] as? UInt64) ?? 0)

                let asset = AVURLAsset(url: url)
                let videoWidth: UInt64
                let videoHeight: UInt64
                if let track = try? await asset.loadTracks(withMediaType: .video).first {
                    let size = try? await track.load(.naturalSize)
                    videoWidth = UInt64(size?.width ?? 0)
                    videoHeight = UInt64(size?.height ?? 0)
                } else {
                    videoWidth = 0
                    videoHeight = 0
                }
                let cmDuration = try? await asset.load(.duration)
                let duration = cmDuration.map { CMTimeGetSeconds($0) } ?? 0

                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 32, height: 32)
                let hash: String
                if let cgImage = try? await generator.image(at: .zero).image {
                    hash = blurHash(from: cgImage) ?? "000000"
                } else {
                    hash = "000000"
                }

                let params = UploadParameters(
                    source: .file(filename: url.path),
                    caption: caption,
                    formattedCaption: formattedCaption.map { .init(format: .html, body: $0) },
                    mentions: nil,
                    inReplyTo: nil
                )
                handle = try sdkTimeline.sendVideo(
                    params: params,
                    thumbnailSource: nil,
                    videoInfo: VideoInfo(
                        duration: duration, height: videoHeight, width: videoWidth,
                        mimetype: mime, size: fileSize,
                        thumbnailInfo: nil, thumbnailSource: nil, blurhash: hash
                    )
                )
            } else if utType.conforms(to: .audio) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = UInt64((attrs?[.size] as? UInt64) ?? 0)

                let asset = AVURLAsset(url: url)
                let cmDuration = try? await asset.load(.duration)
                let duration = cmDuration.map { CMTimeGetSeconds($0) } ?? 0

                let params = UploadParameters(
                    source: .file(filename: url.path),
                    caption: caption,
                    formattedCaption: formattedCaption.map { .init(format: .html, body: $0) },
                    mentions: nil,
                    inReplyTo: nil
                )
                handle = try sdkTimeline.sendAudio(
                    params: params,
                    audioInfo: AudioInfo(
                        duration: duration, size: fileSize, mimetype: mime
                    )
                )
            } else {
                let data: Data
                do {
                    data = try Data(contentsOf: url)
                } catch {
                    logger.error("Failed to read attachment \(filename): \(error)")
                    errorReporter.report(.fileCopyFailed(filename: filename, reason: error.localizedDescription))
                    return
                }
                let fileSize = UInt64(data.count)
                let params = UploadParameters(
                    source: .data(bytes: data, filename: filename),
                    caption: caption,
                    formattedCaption: formattedCaption.map { .init(format: .html, body: $0) },
                    mentions: nil,
                    inReplyTo: nil
                )
                handle = try sdkTimeline.sendFile(
                    params: params,
                    fileInfo: FileInfo(
                        mimetype: mime, size: fileSize,
                        thumbnailInfo: nil, thumbnailSource: nil
                    )
                )
            }

            try await handle.join()
        } catch {
            logger.error("Failed to send attachment \(filename): \(error)")
            errorReporter.report(.attachmentSendFailed(filename: filename, reason: error.localizedDescription))
        }

        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Timeline Lifecycle

    /// Tears down the current timeline: cancels observation tasks, releases SDK handles,
    /// and clears the in-memory timeline items and messages.
    private func teardownTimeline() {
        observationTask?.cancel()
        observationTask = nil
        paginationTask?.cancel()
        paginationTask = nil
        timelineHandle = nil
        paginationHandle = nil
        sdkTimeline = nil
        timelineItems = []
        messages = []
        hasReachedStart = false
        hasReachedEnd = true
        isLoadingMore = false
        fetchedReplyEventIds = []
        pendingChangedIndices = IndexSet()
        messageCache = [:]
        rebuildGeneration &+= 1
        initialDiffsContinuation?.finish()
        initialDiffsContinuation = nil
        initialDiffsStream = nil
    }

    /// Creates a new SDK timeline with the given focus, subscribes to diffs and pagination status.
    private func setupTimeline(focus: TimelineFocus) async throws {
        // Create a one-shot stream that the diff observer signals once the
        // first batch of diffs has been applied. Consumers (pagination status
        // observer, focusOnEvent) await this so they never clear `isLoading`
        // before any timeline content is available.
        let (diffStream, diffContinuation) = AsyncStream<Void>.makeStream()
        initialDiffsStream = diffStream
        initialDiffsContinuation = diffContinuation

        let config = TimelineConfiguration(
            focus: focus,
            filter: .all,
            internalIdPrefix: nil,
            dateDividerMode: .daily,
            trackReadReceipts: .allEvents,
            reportUtds: false
        )
        // swiftlint:disable:next identifier_name
        let tl = try await room.timelineWithConfiguration(configuration: config)
        sdkTimeline = tl
        observeTimeline(tl)

        // Back-pagination status subscriptions are only supported on live
        // timelines. The SDK throws on focused (event-based) timelines, so
        // skip the subscription in that case.
        if case .live = focus {
            do {
                try await observePaginationStatus(tl)
            } catch {
                logger.error("Failed to subscribe to pagination status: \(error)")
            }
        }
    }

    // MARK: - Private

    /// How long to wait for additional diffs before rebuilding again after
    /// a burst. Only applies when more diffs arrive while a rebuild is
    /// already in progress — the first diff always triggers an immediate
    /// rebuild with no delay.
    private static let diffCoalesceInterval: Duration = .milliseconds(200)

    // swiftlint:disable:next identifier_name
    private func observeTimeline(_ tl: Timeline) {
        let (stream, continuation) = AsyncStream<[TimelineDiff]>.makeStream()
        let listener = SDKListener<[TimelineDiff]> { diffs in
            continuation.yield(diffs)
        }

        observationTask = Task { [weak self] in
            guard let self else { return }

            self.timelineHandle = await tl.addListener(listener: listener)

            // Adaptive diff processing: diffs are applied to `timelineItems`
            // immediately (cheap array mutations). The first diff triggers an
            // immediate `rebuildMessages()` call with no delay. If more diffs
            // arrive while a rebuild is running on the background thread, they
            // are batched and a short coalesce timer groups them into a single
            // follow-up rebuild. This gives instant response for isolated
            // events (incoming message, reaction) while still batching rapid
            // bursts (initial load, back-pagination).
            var needsRebuild = false
            var isRebuilding = false
            var coalesceTask: Task<Void, Never>?
            var hasSignaledInitialDiffs = false

            for await diffs in stream {
                self.applyDiffs(diffs)

                // Signal that the first batch of diffs has been applied so
                // consumers waiting on `initialDiffsStream` can proceed.
                if !hasSignaledInitialDiffs {
                    hasSignaledInitialDiffs = true
                    self.initialDiffsContinuation?.yield()
                    self.initialDiffsContinuation?.finish()
                    self.initialDiffsContinuation = nil
                }

                needsRebuild = true

                // If no rebuild is in progress and no coalesce timer is
                // pending, rebuild immediately.
                if !isRebuilding && coalesceTask == nil {
                    isRebuilding = true
                    needsRebuild = false
                    await self.rebuildMessages()
                    isRebuilding = false

                    // After the rebuild, if more diffs arrived during the
                    // background mapping pass, start a short coalesce timer
                    // to batch any further rapid-fire diffs before the next
                    // rebuild.
                    if needsRebuild && coalesceTask == nil {
                        coalesceTask = Task { [weak self] in
                            try? await Task.sleep(for: Self.diffCoalesceInterval)
                            guard !Task.isCancelled, let self else { return }
                            while needsRebuild {
                                needsRebuild = false
                                await self.rebuildMessages()
                            }
                            coalesceTask = nil
                        }
                    }
                }
            }

            // Flush any remaining diffs when the stream ends.
            coalesceTask?.cancel()
            if needsRebuild {
                await self.rebuildMessages()
            }
        }
    }

    // swiftlint:disable:next identifier_name
    private func observePaginationStatus(_ tl: Timeline) async throws {
        let (stream, continuation) = AsyncStream<PaginationStatus>.makeStream()
        let listener = SDKListener<PaginationStatus> { status in
            continuation.yield(status)
        }
        paginationHandle = try await tl.subscribeToBackPaginationStatus(listener: listener)

        paginationTask = Task { [weak self] in
            for await status in stream {
                guard let self else { break }

                switch status {
                case .idle(let hitStart):
                    self.isLoadingMore = false
                    self.hasReachedStart = hitStart

                    // Auto-paginate if we have few items and haven't hit start,
                    // ensuring enough content to fill the viewport so the user
                    // doesn't immediately see the pagination trigger.
                    if !hitStart && self.timelineItems.count < 20 {
                        try? await Task.sleep(for: .milliseconds(500))
                        _ = try? await tl.paginateBackwards(numEvents: 100)
                    } else if self.isLoading {
                        // The initial auto-pagination loop has settled — either
                        // we have enough items or hit the room start.  Wait for
                        // the diff observer to deliver at least one batch so
                        // `timelineItems` is populated, then rebuild messages
                        // before clearing the loading flag.
                        if let diffStream = self.initialDiffsStream {
                            for await _ in diffStream { break }
                        }
                        await self.rebuildMessages()
                        self.isLoading = false
                    }
                case .paginating:
                    self.isLoadingMore = true
                }
            }
        }
    }

    private func observeTypingNotifications() {
        let (stream, continuation) = AsyncStream<[String]>.makeStream()
        let listener = SDKListener<[String]> { userIds in
            continuation.yield(userIds)
        }
        typingHandle = room.subscribeToTypingNotifications(listener: listener)

        typingTask = Task { [weak self] in
            for await userIds in stream {
                guard let self else { break }
                let filtered = userIds.filter { $0 != self.currentUserId }
                var names: [String] = []
                for userId in filtered {
                    if let name = try? await self.room.memberDisplayName(userId: userId), !name.isEmpty {
                        names.append(name)
                    } else {
                        names.append(userId)
                    }
                }
                self.typingUserDisplayNames = names
            }
        }
    }

    /// Extracts the event or transaction ID from a timeline item without
    /// crossing the FFI bridge during incremental mapping. This is called
    /// once per item during `applyDiffs` (when we already have the item)
    /// so the mapper can reuse cached messages by index lookup alone.
    private static func extractItemID(_ item: TimelineItem) -> String? {
        guard let event = item.asEvent() else { return nil }
        switch event.eventOrTransactionId {
        case .eventId(let id): return id
        case .transactionId(let id): return id
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func applyDiffs(_ diffs: [TimelineDiff]) {
        let itemCountBefore = timelineItems.count
        let state = PerformanceSignposts.timeline.beginInterval(
            PerformanceSignposts.TimelineName.applyDiffs,
            "\(diffs.count) diffs, \(itemCountBefore) items"
        )
        for diff in diffs {
            switch diff {
            case .reset(let values):
                timelineItemIDs = values.map(Self.extractItemID)
                timelineItems = values
                // Full remap required — discard incremental tracking.
                pendingChangedIndices = nil

            case .append(let values):
                let start = timelineItems.count
                timelineItemIDs.append(contentsOf: values.map(Self.extractItemID))
                timelineItems.append(contentsOf: values)
                markIndicesChanged(start ..< timelineItems.count)

            case .pushBack(let value):
                let idx = timelineItems.count
                timelineItemIDs.append(Self.extractItemID(value))
                timelineItems.append(value)
                markIndexChanged(idx)

            case .pushFront(let value):
                // Inserting at 0 shifts every existing index up by 1.
                shiftPendingIndices(by: 1, from: 0)
                timelineItemIDs.insert(Self.extractItemID(value), at: 0)
                timelineItems.insert(value, at: 0)
                markIndexChanged(0)

            // swiftlint:disable identifier_name
            case .insert(let index, let value):
                let i = Int(index)
                if i <= timelineItems.count {
                    shiftPendingIndices(by: 1, from: i)
                    timelineItemIDs.insert(Self.extractItemID(value), at: i)
                    timelineItems.insert(value, at: i)
                    markIndexChanged(i)
                }

            case .set(let index, let value):
                let i = Int(index)
                if i < timelineItems.count {
                    timelineItemIDs[i] = Self.extractItemID(value)
                    timelineItems[i] = value
                    markIndexChanged(i)
                }

            case .remove(let index):
                let i = Int(index)
                if i < timelineItems.count {
                    timelineItemIDs.remove(at: i)
                    timelineItems.remove(at: i)
                    // Remove this index and shift everything above it down.
                    pendingChangedIndices?.remove(i)
                    shiftPendingIndices(by: -1, from: i + 1)
                    // Mark the new occupant of this index as changed, since
                    // it may now pair with a different neighbor for grouping.
                    if i < timelineItems.count {
                        markIndexChanged(i)
                    }
                }
            // swiftlint:enable identifier_name

            case .clear:
                timelineItemIDs.removeAll()
                timelineItems.removeAll()
                pendingChangedIndices = nil

            case .popBack:
                if !timelineItems.isEmpty {
                    timelineItemIDs.removeLast()
                    timelineItems.removeLast()
                    // No index to mark — the item is gone. Cache will be
                    // pruned naturally when it's absent from the next rebuild.
                }

            case .popFront:
                if !timelineItems.isEmpty {
                    timelineItemIDs.removeFirst()
                    timelineItems.removeFirst()
                    pendingChangedIndices?.remove(0)
                    shiftPendingIndices(by: -1, from: 1)
                    if !timelineItems.isEmpty {
                        markIndexChanged(0)
                    }
                }

            case .truncate(let length):
                let len = Int(length)
                timelineItemIDs = Array(timelineItemIDs.prefix(len))
                timelineItems = Array(timelineItems.prefix(len))
                // Discard any tracked indices beyond the new length.
                if var indices = pendingChangedIndices {
                    indices = indices.filteredIndexSet { $0 < len }
                    pendingChangedIndices = indices
                }
            }
        }
        let itemCountAfter = timelineItems.count
        PerformanceSignposts.timeline.endInterval(
            PerformanceSignposts.TimelineName.applyDiffs,
            state,
            "\(itemCountAfter) items after"
        )
    }

    // MARK: - Index Tracking Helpers

    /// Records a single index as changed, initializing the set if needed.
    private func markIndexChanged(_ index: Int) {
        if pendingChangedIndices == nil {
            // nil means "full remap" — no point tracking individual indices.
            return
        }
        pendingChangedIndices?.insert(index)
    }

    /// Records a range of indices as changed.
    private func markIndicesChanged(_ range: Range<Int>) {
        if pendingChangedIndices == nil { return }
        pendingChangedIndices?.insert(integersIn: range)
    }

    /// Shifts all tracked indices >= `from` by `delta` (positive = right, negative = left).
    private func shiftPendingIndices(by delta: Int, from start: Int) {
        guard var indices = pendingChangedIndices else { return }
        let affected = indices.filteredIndexSet { $0 >= start }
        indices.subtract(affected)
        for idx in affected {
            let shifted = idx + delta
            if shifted >= 0 {
                indices.insert(shifted)
            }
        }
        pendingChangedIndices = indices
    }

    /// Performs an incremental rebuild of messages, mapping only changed items
    /// on a background thread and reusing cached messages for unchanged items.
    ///
    /// This method is `async` so callers that need to wait for the result
    /// (e.g. the initial load path) can `await` it. The throttled diff path
    /// wraps the call in an unstructured `Task` to fire-and-forget.
    private func rebuildMessages() async {
        let itemCount = timelineItems.count
        let changedCount = pendingChangedIndices?.count ?? -1
        let rebuildState = PerformanceSignposts.timeline.beginInterval(
            PerformanceSignposts.TimelineName.rebuildMessages,
            "\(itemCount) items, changed: \(changedCount)"
        )

        // Capture the current state for the background mapping pass.
        let items = timelineItems
        let itemIDs = timelineItemIDs
        let changedIndices = pendingChangedIndices
        let cache = messageCache
        let mapper = messageMapper

        // Bump the generation so we can discard stale results from
        // a superseded background task.
        rebuildGeneration &+= 1
        let generation = rebuildGeneration

        // Reset the pending set to empty (not nil) so subsequent diffs
        // accumulate into a fresh set while the background work runs.
        pendingChangedIndices = IndexSet()

        let mapping = await mapper.mapItemsIncrementally(
            items,
            itemIDs: itemIDs,
            changedIndices: changedIndices,
            existingMessages: cache
        )

        // Discard the result if a newer rebuild was started while we
        // were mapping on the background thread.
        guard generation == rebuildGeneration else {
            PerformanceSignposts.timeline.endInterval(
                PerformanceSignposts.TimelineName.rebuildMessages,
                rebuildState,
                "discarded (stale generation)"
            )
            return
        }

        // Back on MainActor — apply the result.
        applyMappingResult(mapping)
        PerformanceSignposts.timeline.endInterval(
            PerformanceSignposts.TimelineName.rebuildMessages,
            rebuildState,
            "\(mapping.messages.count) messages"
        )
    }

    /// Applies a mapping result to the view model's published state.
    private func applyMappingResult(_ mapping: TimelineMessageMapper.MappingResult) {
        let applyState = PerformanceSignposts.timeline.beginInterval(
            PerformanceSignposts.TimelineName.applyMappingResult,
            "\(mapping.messages.count) messages"
        )

        // Update the cache with the freshly mapped messages.
        var newCache: [String: TimelineMessage] = [:]
        newCache.reserveCapacity(mapping.messages.count)
        for message in mapping.messages {
            newCache[message.id] = message
        }
        messageCache = newCache

        // Suppress the @Observable notification when the mapped messages
        // haven't actually changed. Without this guard, every diff batch
        // replaces the array reference, causing a full SwiftUI body
        // re-evaluation + messageRows rebuild + table update even when
        // no visible data changed (e.g. a .set diff that only touches
        // a read receipt or delivery status).
        let currentCount = messages.count
        let eqState = PerformanceSignposts.timeline.beginInterval(
            PerformanceSignposts.TimelineName.equalityCheck,
            "\(mapping.messages.count) vs \(currentCount)"
        )
        let changed = mapping.messages != messages
        PerformanceSignposts.timeline.endInterval(
            PerformanceSignposts.TimelineName.equalityCheck,
            eqState,
            "changed: \(changed)"
        )

        if changed {
            messages = mapping.messages
            messagesVersion &+= 1
        }

        computeUnreadMarkerIfNeeded(mapping.messages)
        resolveUnfetchedReplies(mapping.unresolvedReplyEventIds)

        PerformanceSignposts.timeline.endInterval(
            PerformanceSignposts.TimelineName.applyMappingResult,
            applyState
        )
    }

    private func computeUnreadMarkerIfNeeded(_ result: [TimelineMessage]) {
        guard !hasComputedUnreadMarker, unreadCount > 0, !result.isEmpty else { return }
        hasComputedUnreadMarker = true
        let incomingMessages = result.filter { !$0.isOutgoing }
        if unreadCount <= incomingMessages.count {
            let markerIndex = incomingMessages.count - unreadCount
            firstUnreadMessageId = incomingMessages[markerIndex].id
        }
    }

    private func resolveUnfetchedReplies(_ pendingIds: Set<String>) {
        let newFetchIds = pendingIds.subtracting(fetchedReplyEventIds)
        // swiftlint:disable:next identifier_name
        guard !newFetchIds.isEmpty, let tl = sdkTimeline else { return }
        fetchedReplyEventIds.formUnion(newFetchIds)
        Task {
            for eventId in newFetchIds {
                try? await tl.fetchDetailsForEvent(eventId: eventId)
            }
        }
    }
}
