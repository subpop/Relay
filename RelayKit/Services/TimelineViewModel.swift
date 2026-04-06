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
    private var observationTask: Task<Void, Never>?
    private var paginationTask: Task<Void, Never>?
    private var typingTask: Task<Void, Never>?
    private let messageMapper: TimelineMessageMapper
    private let errorReporter: ErrorReporter
    private var hasComputedUnreadMarker = false
    private var fetchedReplyEventIds: Set<String> = []

    @ObservationIgnored private var timelineHandle: TaskHandle?
    @ObservationIgnored private var paginationHandle: TaskHandle?
    @ObservationIgnored private var typingHandle: TaskHandle?

    /// Creates a new view model for the given room.
    ///
    /// - Parameters:
    ///   - room: The Matrix Rust SDK `Room` object.
    ///   - currentUserId: The Matrix user ID of the signed-in user, used for highlight detection.
    ///   - unreadCount: The number of unread messages, used to position the "New" divider.
    public init(room: Room, currentUserId: String?, unreadCount: Int = 0, errorReporter: ErrorReporter) {
        self.room = room
        self.roomId = room.id()
        self.currentUserId = currentUserId
        self.unreadCount = unreadCount
        self.messageMapper = TimelineMessageMapper(currentUserId: currentUserId)
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
    }

    /// Creates a new SDK timeline with the given focus, subscribes to diffs and pagination status.
    private func setupTimeline(focus: TimelineFocus) async throws {
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

        do {
            try await observePaginationStatus(tl)
        } catch {
            logger.error("Failed to subscribe to pagination status: \(error)")
        }
    }

    // MARK: - Private

    /// How long to accumulate diffs before applying them. This prevents
    /// `rebuildMessages()` from running on every individual SDK callback
    /// during rapid bursts (initial load, back-pagination, reset diffs).
    /// Matches the 500ms throttle used by Mactrix.
    private static let diffThrottleInterval: Duration = .milliseconds(500)

    // swiftlint:disable:next identifier_name
    private func observeTimeline(_ tl: Timeline) {
        let (stream, continuation) = AsyncStream<[TimelineDiff]>.makeStream()
        let listener = SDKListener<[TimelineDiff]> { diffs in
            continuation.yield(diffs)
        }

        observationTask = Task { [weak self] in
            guard let self else { return }

            self.timelineHandle = await tl.addListener(listener: listener)

            // Throttled diff processing: diffs are applied to `timelineItems`
            // immediately (cheap array mutations), but `rebuildMessages()` is
            // called at most once per throttle interval to avoid mapping all
            // items to TimelineMessage on every SDK callback.
            //
            // While `isLoading` is true the scroll view is hidden behind the
            // loading overlay, so rebuilds are skipped entirely — the single
            // rebuild happens when `isLoading` is cleared by the pagination
            // status observer.
            var needsRebuild = false
            var throttleTask: Task<Void, Never>?

            for await diffs in stream {
                self.applyDiffs(diffs)

                // Skip rebuilds while the loading overlay is up.
                guard !self.isLoading else { continue }

                needsRebuild = true

                // If no throttle timer is running, start one. When it fires,
                // it flushes accumulated diffs into a single rebuild.
                if throttleTask == nil {
                    throttleTask = Task { [weak self] in
                        try? await Task.sleep(for: Self.diffThrottleInterval)
                        guard !Task.isCancelled, let self else { return }
                        if needsRebuild {
                            needsRebuild = false
                            self.rebuildMessages()
                        }
                        throttleTask = nil
                    }
                }
            }

            // Flush any remaining diffs when the stream ends.
            if needsRebuild {
                self.rebuildMessages()
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
                        // we have enough items or hit the room start. Rebuild
                        // messages once with the full content, then clear the
                        // loading overlay so the scroll view renders in a
                        // single pass with no scroll jumps.
                        self.rebuildMessages()
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

    // swiftlint:disable:next cyclomatic_complexity
    private func applyDiffs(_ diffs: [TimelineDiff]) {
        for diff in diffs {
            switch diff {
            case .reset(let values):
                timelineItems = values
            case .append(let values):
                timelineItems.append(contentsOf: values)
            case .pushBack(let value):
                timelineItems.append(value)
            case .pushFront(let value):
                timelineItems.insert(value, at: 0)
            // swiftlint:disable identifier_name
            case .insert(let index, let value):
                let i = Int(index)
                if i <= timelineItems.count {
                    timelineItems.insert(value, at: i)
                }
            case .set(let index, let value):
                let i = Int(index)
                if i < timelineItems.count {
                    timelineItems[i] = value
                }
            case .remove(let index):
                let i = Int(index)
                if i < timelineItems.count {
                    timelineItems.remove(at: i)
                }
            // swiftlint:enable identifier_name
            case .clear:
                timelineItems.removeAll()
            case .popBack:
                if !timelineItems.isEmpty { timelineItems.removeLast() }
            case .popFront:
                if !timelineItems.isEmpty { timelineItems.removeFirst() }
            case .truncate(let length):
                timelineItems = Array(timelineItems.prefix(Int(length)))
            }
        }
    }

    private func rebuildMessages() {
        let mapping = messageMapper.mapItems(timelineItems)
        messages = mapping.messages

        computeUnreadMarkerIfNeeded(mapping.messages)
        resolveUnfetchedReplies(mapping.unresolvedReplyEventIds)
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
