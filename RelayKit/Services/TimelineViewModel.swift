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
import UniformTypeIdentifiers
import os

/// Concrete implementation of ``TimelineViewModelProtocol`` backed by the Matrix Rust SDK.
///
/// ``TimelineViewModel`` manages a single room's message timeline. It coordinates
/// several collaborators:
/// - ``TimelineDiffProcessor`` applies SDK diffs to the raw item arrays.
/// - ``TimelineMessageRebuilder`` incrementally maps items into ``TimelineMessage`` models.
/// - ``TimelinePaginator`` handles backward/forward pagination and auto-fill.
/// - ``TypingNotificationObserver`` resolves typing indicators.
@Observable
public final class TimelineViewModel: TimelineViewModelProtocol {
    public private(set) var messages: [TimelineMessage] = []
    public private(set) var messagesVersion: UInt = 0
    public private(set) var messageRows: [MessageRow] = []
    public private(set) var messageRowsVersion: UInt = 0
    public private(set) var isLoading = true
    public private(set) var isLoadingMore = false
    public private(set) var hasReachedStart = false
    public private(set) var hasReachedEnd = true
    public var firstUnreadMessageId: String?
    public private(set) var typingUsers: [TypingUser] = []
    public private(set) var timelineFocus: TimelineFocusState = .live

    private let room: Room
    private let roomId: String
    /// A human-readable label for this room used in activity log entries.
    /// Prefers the canonical alias (e.g. ``"#design:matrix.org"``) over the
    /// display name, falling back to the room ID.
    private let roomLabel: String
    private let currentUserId: String?
    private weak var activityLog: ActivityLog?
    /// The SDK timeline, exposed for use by ``MatrixService/pinnedMessages(roomId:)``.
    private(set) var sdkTimeline: Timeline?
    private var observationTask: Task<Void, Never>?
    private let messageMapper: TimelineMessageMapper
    private let errorReporter: ErrorReporter
    private var isSendingFullyReadReceipt = false

    // MARK: - Collaborators

    private var diffProcessor = TimelineDiffProcessor()
    private let paginator: TimelinePaginator
    private let rebuilder: TimelineMessageRebuilder
    private let typingObserver: TypingNotificationObserver

    /// Continuation that is resumed once the first batch of timeline diffs has
    /// been received and applied.  Both the pagination-status observer (live
    /// timelines) and ``focusOnEvent`` (focused timelines) await this before
    /// clearing ``isLoading`` so the view never transiently shows an empty state.
    private var initialDiffsContinuation: AsyncStream<Void>.Continuation?
    private var initialDiffsStream: AsyncStream<Void>?

    @ObservationIgnored private var timelineHandle: TaskHandle?

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
        errorReporter: ErrorReporter,
        activityLog: ActivityLog? = nil
    ) {
        let roomId = room.id()
        let roomLabel = room.canonicalAlias() ?? room.displayName() ?? roomId

        self.room = room
        self.roomId = roomId
        self.roomLabel = roomLabel
        self.currentUserId = currentUserId
        self.messageMapper = TimelineMessageMapper(
            currentUserId: currentUserId,
            notificationKeywords: notificationKeywords
        )
        self.errorReporter = errorReporter
        self.activityLog = activityLog
        self.paginator = TimelinePaginator(roomLabel: roomLabel, roomId: roomId, activityLog: activityLog)
        self.rebuilder = TimelineMessageRebuilder(
            unreadCount: unreadCount,
            roomLabel: roomLabel,
            roomId: roomId,
            activityLog: activityLog
        )
        self.typingObserver = TypingNotificationObserver(currentUserId: currentUserId)

        wireCollaborators()
    }

    deinit {
        let task = MainActor.assumeIsolated { observationTask }
        task?.cancel()
    }

    // MARK: - Collaborator Wiring

    private func wireCollaborators() {
        // Paginator → VM
        paginator.onLoadingMoreChanged = { [weak self] loading in
            self?.isLoadingMore = loading
        }
        paginator.onHasReachedStartChanged = { [weak self] hitStart in
            self?.hasReachedStart = hitStart
            self?.rebuilder.hasReachedStart = hitStart
        }
        paginator.msgLikeItemCount = { [weak self] in
            self?.diffProcessor.countMsgLikeItems() ?? 0
        }
        paginator.onInitialLoadSettled = { [weak self] in
            guard let self, self.isLoading else { return }
            if let diffStream = self.initialDiffsStream {
                for await _ in diffStream { break }
            }
            await self.performRebuild()
            self.isLoading = false
        }

        // Rebuilder → VM
        rebuilder.onMessagesUpdated = { [weak self] messages, version in
            guard let self else { return }
            self.messages = messages
            self.messagesVersion = version
        }
        rebuilder.onMessageRowsUpdated = { [weak self] rows, version in
            guard let self else { return }
            self.messageRows = rows
            self.messageRowsVersion = version
        }
        rebuilder.onUnreadMarkerComputed = { [weak self] messageId in
            self?.firstUnreadMessageId = messageId
        }

        // Typing observer → VM
        typingObserver.onTypingUsersChanged = { [weak self] users in
            self?.typingUsers = users
        }
    }

    // MARK: - Public

    public func loadTimeline() async {
        if isSuspended {
            await resume()
            return
        }
        guard sdkTimeline == nil else { return }

        isLoading = true
        do {
            try await setupTimeline(focus: .live(hideThreadedEvents: false))
            timelineFocus = .live
            hasReachedEnd = true
            typingObserver.observe(room: room)
        } catch {
            activityLog?.log(
                category: .timeline, severity: .error, source: "TimelineViewModel",
                summary: "Failed to load timeline in \(roomLabel)",
                detail: error.localizedDescription, roomId: roomId
            )
            errorReporter.report(.messageLoadFailed(error.localizedDescription))
            isLoading = false
        }
    }

    public func loadThreadTimeline(rootEventId: String) async {
        guard sdkTimeline == nil else { return }

        isLoading = true
        do {
            try await setupTimeline(focus: .thread(rootEventId: rootEventId))
            timelineFocus = .live
            hasReachedEnd = true

            // Thread timelines don't deliver initial diffs automatically —
            // we must paginate to fetch the thread content from the server.
            guard let sdkTimeline else { return }
            let hitStart = try await sdkTimeline.paginateBackwards(numEvents: 100)
            hasReachedStart = hitStart
            rebuilder.hasReachedStart = hitStart

            // Wait for the diff observer to process the paginated items,
            // then rebuild messages and clear the loading flag.
            if let diffStream = initialDiffsStream {
                for await _ in diffStream { break }
            }
            await performRebuild()
            isLoading = false
        } catch {
            activityLog?.log(
                category: .timeline, severity: .error, source: "TimelineViewModel",
                summary: "Failed to load thread timeline in \(roomLabel)",
                detail: error.localizedDescription, roomId: roomId
            )
            errorReporter.report(.messageLoadFailed(error.localizedDescription))
            isLoading = false
        }
    }

    public func loadMoreHistory() async {
        guard let sdkTimeline, !isLoadingMore, !hasReachedStart else { return }
        do {
            _ = try await sdkTimeline.paginateBackwards(numEvents: 100)
        } catch {
            activityLog?.log(
                category: .timeline, severity: .error, source: "TimelineViewModel",
                summary: "Failed to load earlier messages in \(roomLabel)",
                detail: error.localizedDescription, roomId: roomId
            )
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
            activityLog?.log(
                category: .timeline, severity: .error, source: "TimelineViewModel",
                summary: "Failed to load newer messages in \(roomLabel)",
                detail: error.localizedDescription, roomId: roomId
            )
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
            activityLog?.log(
                category: .timeline, severity: .error, source: "TimelineViewModel",
                summary: "Failed to send fully-read receipt in \(roomLabel)",
                detail: error.localizedDescription, roomId: roomId
            )
        }
    }

    public func focusOnEvent(eventId: String) async {
        isLoading = true
        teardownTimeline()

        do {
            try await setupTimeline(focus: .event(
                eventId: eventId,
                numContextEvents: 50,
                threadMode: .automatic(hideThreadedEvents: false)
            ))
            timelineFocus = .focusedOnEvent(eventId)
            hasReachedEnd = false
        } catch {
            activityLog?.log(
                category: .timeline, severity: .error, source: "TimelineViewModel",
                summary: "Failed to focus on event in \(roomLabel)",
                detail: "\(eventId): \(error.localizedDescription)", roomId: roomId
            )
            errorReporter.report(.messageLoadFailed(error.localizedDescription))
            // Attempt to recover by returning to live
            do {
                try await setupTimeline(focus: .live(hideThreadedEvents: false))
                timelineFocus = .live
            } catch {
                activityLog?.log(
                    category: .timeline, severity: .error, source: "TimelineViewModel",
                    summary: "Failed to recover live timeline in \(roomLabel)",
                    detail: error.localizedDescription, roomId: roomId
                )
            }
        }

        // Wait for the diff observer to deliver initial content so
        // the items are populated before we clear the loading flag.
        // Focused timelines don't use the pagination-status observer,
        // so this is the only gate that prevents an empty flash.
        if let diffStream = initialDiffsStream {
            for await _ in diffStream { break }
        }
        await performRebuild()
        isLoading = false
    }

    public func returnToLive() async {
        isLoading = true
        teardownTimeline()

        do {
            try await setupTimeline(focus: .live(hideThreadedEvents: false))
            timelineFocus = .live
        } catch {
            activityLog?.log(
                category: .timeline, severity: .error, source: "TimelineViewModel",
                summary: "Failed to return to live timeline in \(roomLabel)",
                detail: error.localizedDescription, roomId: roomId
            )
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
            activityLog?.log(
                category: .timeline, severity: .error, source: "TimelineViewModel",
                summary: "Failed to send message in \(roomLabel)",
                detail: error.localizedDescription, roomId: roomId
            )
            errorReporter.report(.messageSendFailed(error.localizedDescription))
        }
    }

    public func edit(messageId: String, newText: String, mentionedUserIds: [String] = []) async {
        guard let sdkTimeline else { return }
        let itemId = eventOrTransactionId(from: messageId)
        let content = messageEventContentFromMarkdown(md: newText)
            .withMentions(mentions: Mentions(userIds: mentionedUserIds, room: false))
        let editedContent = EditedContent.roomMessage(content: content)
        do {
            try await sdkTimeline.edit(eventOrTransactionId: itemId, newContent: editedContent)
        } catch {
            activityLog?.log(
                category: .timeline, severity: .error, source: "TimelineViewModel",
                summary: "Failed to edit message in \(roomLabel)",
                detail: error.localizedDescription, roomId: roomId
            )
            errorReporter.report(.editFailed(error.localizedDescription))
        }
    }

    public func toggleReaction(messageId: String, key: String) async {
        guard let sdkTimeline else { return }
        let itemId = eventOrTransactionId(from: messageId)
        do {
            _ = try await sdkTimeline.toggleReaction(itemId: itemId, key: key)
        } catch {
            activityLog?.log(
                category: .timeline, severity: .error, source: "TimelineViewModel",
                summary: "Failed to toggle reaction in \(roomLabel)",
                detail: error.localizedDescription, roomId: roomId
            )
            errorReporter.report(.reactionFailed(error.localizedDescription))
        }
    }

    public func redact(messageId: String, reason: String? = nil) async {
        guard let sdkTimeline else { return }
        let itemId = eventOrTransactionId(from: messageId)
        do {
            try await sdkTimeline.redactEvent(eventOrTransactionId: itemId, reason: reason)
        } catch {
            activityLog?.log(
                category: .timeline, severity: .error, source: "TimelineViewModel",
                summary: "Failed to delete message in \(roomLabel)",
                detail: error.localizedDescription, roomId: roomId
            )
            errorReporter.report(.redactFailed(error.localizedDescription))
        }
    }

    public func pin(eventId: String) async {
        guard let sdkTimeline else { return }
        do {
            _ = try await sdkTimeline.pinEvent(eventId: eventId)
        } catch {
            activityLog?.log(
                category: .timeline, severity: .error, source: "TimelineViewModel",
                summary: "Failed to pin message in \(roomLabel)",
                detail: error.localizedDescription, roomId: roomId
            )
            errorReporter.report(.pinFailed(error.localizedDescription))
        }
    }

    public func unpin(eventId: String) async {
        guard let sdkTimeline else { return }
        do {
            _ = try await sdkTimeline.unpinEvent(eventId: eventId)
        } catch {
            activityLog?.log(
                category: .timeline, severity: .error, source: "TimelineViewModel",
                summary: "Failed to unpin message in \(roomLabel)",
                detail: error.localizedDescription, roomId: roomId
            )
            errorReporter.report(.pinFailed(error.localizedDescription))
        }
    }

    // swiftlint:disable:next function_body_length
    public func sendAttachment(url: URL, caption: String? = nil, inReplyTo: String? = nil) async {
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
                    activityLog?.log(
                        category: .timeline, severity: .error, source: "TimelineViewModel",
                        summary: "Failed to read attachment \(filename) in \(roomLabel)",
                        detail: error.localizedDescription, roomId: roomId
                    )
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
                    inReplyTo: inReplyTo
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
                    inReplyTo: inReplyTo
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
                    inReplyTo: inReplyTo
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
                    activityLog?.log(
                        category: .timeline, severity: .error, source: "TimelineViewModel",
                        summary: "Failed to read attachment \(filename) in \(roomLabel)",
                        detail: error.localizedDescription, roomId: roomId
                    )
                    errorReporter.report(.fileCopyFailed(filename: filename, reason: error.localizedDescription))
                    return
                }
                let fileSize = UInt64(data.count)
                let params = UploadParameters(
                    source: .data(bytes: data, filename: filename),
                    caption: caption,
                    formattedCaption: formattedCaption.map { .init(format: .html, body: $0) },
                    mentions: nil,
                    inReplyTo: inReplyTo
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
            activityLog?.log(
                category: .timeline, severity: .error, source: "TimelineViewModel",
                summary: "Failed to send attachment \(filename) in \(roomLabel)",
                detail: error.localizedDescription, roomId: roomId
            )
            errorReporter.report(.attachmentSendFailed(filename: filename, reason: error.localizedDescription))
        }

        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Filtering

    /// Updates the event-filtering preferences and triggers a row rebuild.
    ///
    /// Call this when the user toggles membership or state event visibility.
    /// The rebuilder will filter messages and rebuild rows without re-mapping
    /// from SDK items.
    public func updateEventFiltering(showMembership: Bool, showState: Bool) {
        rebuilder.updateFilterPreferences(showMembership: showMembership, showState: showState)
    }

    // MARK: - Timeline Lifecycle

    /// Whether the timeline has been suspended to save resources while off-screen.
    ///
    /// When `true`, the timeline's observation tasks and SDK handles have been
    /// released but the cached ``messages`` array is preserved for instant display
    /// if the user returns to this room.
    private(set) var isSuspended = false

    /// Suspends background timeline observation to save resources while off-screen.
    ///
    /// Cancels observation, pagination, and typing tasks and releases SDK handles,
    /// but preserves the current ``messages`` array so the view can display cached
    /// content immediately if the user returns. Call ``resume()`` to re-establish
    /// live timeline observation.
    func suspend() {
        guard !isSuspended, sdkTimeline != nil else { return }
        activityLog?.log(
            category: .timeline, severity: .info, source: "TimelineViewModel",
            summary: "Suspending timeline for \(roomLabel)",
            roomId: roomId
        )
        isSuspended = true

        observationTask?.cancel()
        observationTask = nil
        paginator.teardown()
        typingObserver.teardown()
        timelineHandle = nil
        sdkTimeline = nil

        // Clear raw SDK items but keep the mapped messages for instant display.
        diffProcessor.clear()
        rebuilder.invalidateGeneration()
        initialDiffsContinuation?.finish()
        initialDiffsContinuation = nil
        initialDiffsStream = nil
        typingUsers = []
    }

    /// Resumes live timeline observation after a ``suspend()``.
    ///
    /// Re-creates the SDK timeline and re-subscribes to diffs, pagination status,
    /// and typing notifications. Unlike the initial ``loadTimeline()`` call, a
    /// resume does not show a loading spinner — the existing ``messages`` remain
    /// visible until fresh data arrives via the normal diff pipeline.
    func resume() async {
        guard isSuspended else { return }
        let label = roomLabel
        let resumeState = PerformanceSignposts.roomSwitch.beginInterval(
            PerformanceSignposts.RoomSwitchName.resume,
            "\(label)"
        )
        activityLog?.log(
            category: .timeline, severity: .info, source: "TimelineViewModel",
            summary: "Resuming timeline for \(roomLabel)",
            roomId: roomId
        )
        isSuspended = false

        do {
            try await setupTimeline(focus: .live(hideThreadedEvents: false))
            timelineFocus = .live
            hasReachedEnd = true
            typingObserver.observe(room: room)
            PerformanceSignposts.roomSwitch.endInterval(
                PerformanceSignposts.RoomSwitchName.resume,
                resumeState,
                "success"
            )
        } catch {
            PerformanceSignposts.roomSwitch.endInterval(
                PerformanceSignposts.RoomSwitchName.resume,
                resumeState,
                "failed"
            )
            activityLog?.log(
                category: .timeline, severity: .error, source: "TimelineViewModel",
                summary: "Failed to resume timeline for \(roomLabel)",
                detail: error.localizedDescription, roomId: roomId
            )
        }
    }

    /// Tears down the current timeline: cancels observation tasks, releases SDK handles,
    /// and clears the in-memory timeline items and messages.
    private func teardownTimeline() {
        observationTask?.cancel()
        observationTask = nil
        paginator.teardown()
        timelineHandle = nil
        sdkTimeline = nil
        diffProcessor.clear()
        messages = []
        rebuilder.hasReachedStart = false
        hasReachedStart = false
        hasReachedEnd = true
        isLoadingMore = false
        rebuilder.reset()
        initialDiffsContinuation?.finish()
        initialDiffsContinuation = nil
        initialDiffsStream = nil
    }

    /// Creates a new SDK timeline with the given focus, subscribes to diffs and pagination status.
    private func setupTimeline(focus: TimelineFocus) async throws {
        let label = roomLabel
        let setupState = PerformanceSignposts.roomSwitch.beginInterval(
            PerformanceSignposts.RoomSwitchName.setupTimeline,
            "\(label)"
        )

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

        let createState = PerformanceSignposts.roomSwitch.beginInterval(
            PerformanceSignposts.RoomSwitchName.sdkTimelineCreate,
            "\(label)"
        )
        // swiftlint:disable:next identifier_name
        let tl = try await room.timelineWithConfiguration(configuration: config)
        PerformanceSignposts.roomSwitch.endInterval(
            PerformanceSignposts.RoomSwitchName.sdkTimelineCreate,
            createState
        )

        sdkTimeline = tl

        // Wire reply resolution to the SDK timeline.
        rebuilder.fetchReplyDetails = { [weak tl] eventId in
            try await tl?.fetchDetailsForEvent(eventId: eventId)
        }

        observeTimeline(tl)

        // Subscribe to back-pagination status. This is supported on live
        // timelines but may throw on event-focused timelines.
        switch focus {
        case .live:
            do {
                let paginateSubState = PerformanceSignposts.roomSwitch.beginInterval(
                    PerformanceSignposts.RoomSwitchName.paginationSubscribe,
                    "\(label)"
                )
                try await paginator.observePaginationStatus(tl)
                PerformanceSignposts.roomSwitch.endInterval(
                    PerformanceSignposts.RoomSwitchName.paginationSubscribe,
                    paginateSubState
                )
            } catch {
                activityLog?.log(
                    category: .timeline, severity: .error, source: "TimelineViewModel",
                    summary: "Failed to subscribe to pagination status in \(roomLabel)",
                    detail: error.localizedDescription, roomId: roomId
                )
            }
        default:
            break
        }

        PerformanceSignposts.roomSwitch.endInterval(
            PerformanceSignposts.RoomSwitchName.setupTimeline,
            setupState
        )
    }

    // MARK: - Diff Observation

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
        let label = roomLabel

        observationTask = Task { [weak self] in
            guard let self else { return }

            let addListenerState = PerformanceSignposts.roomSwitch.beginInterval(
                PerformanceSignposts.RoomSwitchName.addListener,
                "\(label)"
            )
            self.timelineHandle = await tl.addListener(listener: listener)
            PerformanceSignposts.roomSwitch.endInterval(
                PerformanceSignposts.RoomSwitchName.addListener,
                addListenerState
            )

            let firstDiffState = PerformanceSignposts.roomSwitch.beginInterval(
                PerformanceSignposts.RoomSwitchName.firstDiffDelivery,
                "\(label)"
            )

            // Adaptive diff processing: diffs are applied immediately (cheap
            // array mutations). The first diff triggers an immediate rebuild.
            // Subsequent diffs during a rebuild are coalesced with a short timer.
            var needsRebuild = false
            var isRebuilding = false
            var coalesceTask: Task<Void, Never>?
            var hasSignaledInitialDiffs = false

            for await diffs in stream {
                self.diffProcessor.applyDiffs(
                    diffs,
                    roomLabel: self.roomLabel,
                    roomId: self.roomId,
                    activityLog: self.activityLog
                )

                // Signal that the first batch of diffs has been applied.
                if !hasSignaledInitialDiffs {
                    hasSignaledInitialDiffs = true
                    PerformanceSignposts.roomSwitch.endInterval(
                        PerformanceSignposts.RoomSwitchName.firstDiffDelivery,
                        firstDiffState,
                        "\(diffs.count) diffs, \(self.diffProcessor.timelineItems.count) items"
                    )
                    self.initialDiffsContinuation?.yield()
                    self.initialDiffsContinuation?.finish()
                    self.initialDiffsContinuation = nil
                }

                needsRebuild = true

                if !isRebuilding && coalesceTask == nil {
                    if self.diffProcessor.timelineItems.isEmpty && !self.messages.isEmpty {
                        // Destructive diff with no replacement content yet.
                        coalesceTask = Task { [weak self] in
                            try? await Task.sleep(for: Self.diffCoalesceInterval)
                            guard !Task.isCancelled, let self else { return }
                            while needsRebuild {
                                needsRebuild = false
                                await self.performRebuild()
                            }
                            coalesceTask = nil
                        }
                    } else {
                        isRebuilding = true
                        needsRebuild = false
                        await self.performRebuild()
                        isRebuilding = false

                        if needsRebuild && coalesceTask == nil {
                            if self.isLoading || self.messages.count < 20 {
                                needsRebuild = false
                                await self.performRebuild()
                            }
                            if needsRebuild && coalesceTask == nil {
                                coalesceTask = Task { [weak self] in
                                    try? await Task.sleep(for: Self.diffCoalesceInterval)
                                    guard !Task.isCancelled, let self else { return }
                                    while needsRebuild {
                                        needsRebuild = false
                                        await self.performRebuild()
                                    }
                                    coalesceTask = nil
                                }
                            }
                        }
                    }
                }
            }

            // Flush any remaining diffs when the stream ends.
            coalesceTask?.cancel()
            if needsRebuild {
                await self.performRebuild()
            }
        }
    }

    // MARK: - Private Helpers

    /// Delegates a rebuild to the ``TimelineMessageRebuilder``, passing it the
    /// current snapshot from the ``TimelineDiffProcessor``.
    private func performRebuild() async {
        await rebuilder.rebuild(
            items: diffProcessor.timelineItems,
            itemIDs: diffProcessor.timelineItemIDs,
            changedIndices: diffProcessor.pendingChangedIndices,
            mapper: messageMapper,
            pendingIndicesResetter: { [self] in
                diffProcessor.resetPendingChangedIndices()
            }
        )
    }

    /// Converts a message ID string into the SDK's ``EventOrTransactionId`` enum.
    ///
    /// Event IDs start with `$`; anything else is treated as a transaction ID
    /// (local echo that hasn't been confirmed by the server yet).
    private func eventOrTransactionId(from messageId: String) -> EventOrTransactionId {
        messageId.hasPrefix("$") ? .eventId(eventId: messageId) : .transactionId(transactionId: messageId)
    }
}
