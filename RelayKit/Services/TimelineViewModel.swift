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
import NaturalLanguage
import RelayInterface
import UniformTypeIdentifiers
import os

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
    public private(set) var typingUsers: [TypingUser] = []
    public private(set) var timelineFocus: TimelineFocusState = .live
    public private(set) var translationsVersion: UInt = 0
    public private(set) var pendingTranslationQueueVersion: UInt = 0
    /// FIFO queue of translation requests waiting for a free slot. Drained
    /// by ``claimNextTranslation()``; size of pool lives in `TimelineView`.
    private var pendingTranslationQueue: [PendingTranslationRequest] = []
    /// MessageIds currently being translated by some slot. Used to dedup
    /// "translate again while it's still running".
    private var inFlightTranslations: Set<String> = []

    private let room: Room
    private let roomId: String
    /// A human-readable label for this room used in activity log entries.
    /// Prefers the canonical alias (e.g. ``"#design:matrix.org"``) over the
    /// display name, falling back to the room ID.
    private let roomLabel: String
    private let currentUserId: String?
    private let unreadCount: Int
    private weak var activityLog: ActivityLog?
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
    /// Set to `true` when backward pagination hits a permanent error (e.g.
    /// corrupted event cache). Prevents the auto-pagination loop from
    /// retrying indefinitely.
    private var paginationPermanentlyFailed = false

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

    // MARK: - Translation

    /// Per-message translation state. `@ObservationIgnored` because the
    /// dictionary churns on every result and observation-tracking it
    /// would re-evaluate every body of every visible row on each tick.
    /// `translationsVersion` is the observed signal SwiftUI listens to.
    @ObservationIgnored
    private var translationStates: [String: MessageTranslationState] = [:]
    @ObservationIgnored
    private lazy var translator = MessageTranslator()

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
        self.room = room
        self.roomId = room.id()
        self.roomLabel = room.canonicalAlias() ?? room.displayName() ?? room.id()
        self.currentUserId = currentUserId
        self.unreadCount = unreadCount
        self.messageMapper = TimelineMessageMapper(
            currentUserId: currentUserId,
            notificationKeywords: notificationKeywords
        )
        self.errorReporter = errorReporter
        self.activityLog = activityLog
    }

    deinit {
        let tasks = MainActor.assumeIsolated { (observationTask, paginationTask, typingTask) }
        tasks.0?.cancel()
        tasks.1?.cancel()
        tasks.2?.cancel()
    }

    // MARK: - Public

    public func loadTimeline(focusedOnEventId fullyReadEventId: String? = nil) async {
        if isSuspended {
            await resume()
            return
        }
        guard sdkTimeline == nil else { return }

        isLoading = true
        do {
            if let fullyReadEventId {
                // Load timeline focused on the fully-read marker
                try await setupTimeline(focus: .event(
                    eventId: fullyReadEventId,
                    numContextEvents: 50,
                    threadMode: .automatic(hideThreadedEvents: false)
                ))
                timelineFocus = .focusedOnEvent(fullyReadEventId)
                hasReachedEnd = false
            } else {
                try await setupTimeline(focus: .live(hideThreadedEvents: false))
                timelineFocus = .live
                hasReachedEnd = true
            }
            observeTypingNotifications()
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

            // Wait for the diff observer to process the paginated items,
            // then rebuild messages and clear the loading flag.
            if let diffStream = initialDiffsStream {
                for await _ in diffStream { break }
            }
            await rebuildMessages()
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
            activityLog?.log(
                category: .timeline, severity: .error, source: "TimelineViewModel",
                summary: "Failed to send attachment \(filename) in \(roomLabel)",
                detail: error.localizedDescription, roomId: roomId
            )
            errorReporter.report(.attachmentSendFailed(filename: filename, reason: error.localizedDescription))
        }

        try? FileManager.default.removeItem(at: url)
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
        paginationTask?.cancel()
        paginationTask = nil
        typingTask?.cancel()
        typingTask = nil
        timelineHandle = nil
        paginationHandle = nil
        typingHandle = nil
        sdkTimeline = nil

        // Clear raw SDK items but keep the mapped messages for instant display.
        timelineItems = []
        timelineItemIDs = []
        pendingChangedIndices = IndexSet()
        rebuildGeneration &+= 1
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
            observeTypingNotifications()
        } catch {
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
        paginationPermanentlyFailed = false
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

        // Subscribe to back-pagination status. This is supported on live
        // timelines but may throw on event-focused timelines.
        switch focus {
        case .live:
            do {
                try await observePaginationStatus(tl)
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
                // pending, rebuild immediately — unless the batch emptied
                // the timeline (e.g. a clear diff). In that case, defer
                // the rebuild to give the SDK time to deliver follow-up
                // content diffs, preventing a momentary empty-state flash.
                if !isRebuilding && coalesceTask == nil {
                    if self.timelineItems.isEmpty && !self.messages.isEmpty {
                        // Destructive diff with no replacement content yet.
                        // Defer the rebuild so we don't flash an empty view.
                        coalesceTask = Task { [weak self] in
                            try? await Task.sleep(for: Self.diffCoalesceInterval)
                            guard !Task.isCancelled, let self else { return }
                            while needsRebuild {
                                needsRebuild = false
                                await self.rebuildMessages()
                            }
                            coalesceTask = nil
                        }
                    } else {
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
            }

            // Flush any remaining diffs when the stream ends.
            coalesceTask?.cancel()
            if needsRebuild {
                await self.rebuildMessages()
            }
        }
    }

    /// Maximum number of retry attempts for auto-pagination when the server
    /// is unreachable. Each attempt uses exponential backoff (1s, 2s, 4s).
    private static let maxPaginationRetries = 3

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
                    self.activityLog?.log(
                        category: .timeline, severity: .debug, source: "TimelineViewModel",
                        summary: "Pagination idle in \(self.roomLabel) (hitStart: \(hitStart))",
                        roomId: self.roomId
                    )

                    // Auto-paginate if we have few message-like events and
                    // haven't hit start, ensuring enough content to fill the
                    // viewport.  We count only msgLike event items (skipping
                    // state events, membership changes, date dividers, etc.)
                    // because a room with many members can easily have 20+
                    // non-message items but zero actual messages.
                    let msgLikeCount = self.countMsgLikeItems()
                    if !hitStart && msgLikeCount < 20 && !self.paginationPermanentlyFailed {
                        // Fetch only enough events to fill the viewport.
                        // The threshold is 20 msgLike items, so request
                        // slightly more to account for non-message events
                        // (state changes, date dividers) that don't count.
                        let needed = UInt16(max(20 - msgLikeCount, 5))
                        let succeeded = await self.paginateBackwardsWithRetry(tl, numEvents: needed)
                        if !succeeded {
                            self.paginationPermanentlyFailed = true
                        }
                    }
                    if self.isLoading && (hitStart || msgLikeCount >= 20 || self.paginationPermanentlyFailed) {
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
                    self.activityLog?.log(
                        category: .timeline, severity: .debug, source: "TimelineViewModel",
                        summary: "Paginating backwards in \(self.roomLabel)",
                        roomId: self.roomId
                    )
                }
            }
        }
    }

    /// Counts the number of message-like (non-state) event items currently
    /// in ``timelineItems``.
    private func countMsgLikeItems() -> Int {
        timelineItems.lazy
            .compactMap { $0.asEvent() }
            .filter {
                if case .msgLike = $0.content { return true }
                return false
            }
            .count
    }

    /// Attempts backward pagination with retry and exponential backoff.
    ///
    /// On transient errors (network unreachable, connection timeout), retries
    /// up to ``maxPaginationRetries`` times with 1s / 2s / 4s delays. On
    /// success or permanent failure, returns without throwing.
    ///
    /// - Returns: `true` if pagination succeeded, `false` if it failed
    ///   permanently (non-transient error or retries exhausted).
    @discardableResult
    private func paginateBackwardsWithRetry(_ timeline: Timeline, numEvents: UInt16 = 100) async -> Bool {
        for attempt in 0 ..< Self.maxPaginationRetries {
            do {
                if attempt > 0 {
                    try await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return false }
                }
                _ = try await timeline.paginateBackwards(numEvents: numEvents)
                return true
            } catch is CancellationError {
                return false
            } catch {
                let isTransient = NetworkErrorClassifier.isOfflineShaped(error)
                    || "\(error)".contains("HostUnreachable")
                if isTransient && attempt < Self.maxPaginationRetries - 1 {
                    let delay = Duration.seconds(1 << attempt) // 1s, 2s, 4s
                    activityLog?.log(
                        category: .timeline, severity: .warning, source: "TimelineViewModel",
                        summary: "Pagination attempt \(attempt + 1) failed (transient) in \(roomLabel), retrying in \(1 << attempt)s",
                        detail: error.localizedDescription, roomId: roomId
                    )
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return false }
                } else {
                    activityLog?.log(
                        category: .timeline, severity: .error, source: "TimelineViewModel",
                        summary: "Pagination failed in \(roomLabel)",
                        detail: "\(error)",
                        roomId: roomId
                    )
                    return false
                }
            }
        }
        return false
    }

    private func observeTypingNotifications() {
        let (stream, continuation) = AsyncStream<[String]>.makeStream()
        let listener = SDKListener<[String]> { userIds in
            continuation.yield(userIds)
        }
        typingHandle = room.subscribeToTypingNotifications(listener: listener)

        typingTask = Task { [weak self] in
            // A child task that resolves display names and avatar URLs.
            // Cancelled and replaced each time a new typing notification
            // arrives, so stale resolutions never block clearing the
            // indicator when the SDK sends an empty user list.
            var resolveTask: Task<Void, Never>?

            for await userIds in stream {
                guard let self else { break }
                resolveTask?.cancel()

                let filtered = userIds.filter { $0 != self.currentUserId }

                // Fast path: immediately clear the indicator when nobody
                // is typing, without waiting for any prior resolution.
                if filtered.isEmpty {
                    self.typingUsers = []
                    continue
                }

                let room = self.room
                resolveTask = Task {
                    var users: [TypingUser] = []
                    for userId in filtered {
                        if Task.isCancelled { return }
                        let name: String
                        if let displayName = try? await room.memberDisplayName(userId: userId), !displayName.isEmpty {
                            name = displayName
                        } else {
                            name = userId
                        }
                        let avatarURL = try? await room.memberAvatarUrl(userId: userId)
                        if Task.isCancelled { return }
                        users.append(TypingUser(id: userId, displayName: name, avatarURL: avatarURL))
                    }
                    self.typingUsers = users
                }
            }

            resolveTask?.cancel()
        }
    }

    /// Extracts the stable unique ID from a timeline item. This is called
    /// once per item during `applyDiffs` (when we already have the item)
    /// so the mapper can reuse cached messages by index lookup alone.
    ///
    /// Uses the SDK's `uniqueId()` which remains constant across the
    /// local echo → server confirmation transition, preventing structural
    /// updates in the table's diffable data source.
    /// Converts a message ID string into the SDK's ``EventOrTransactionId`` enum.
    ///
    /// Event IDs start with `$`; anything else is treated as a transaction ID
    /// (local echo that hasn't been confirmed by the server yet).
    private func eventOrTransactionId(from messageId: String) -> EventOrTransactionId {
        messageId.hasPrefix("$") ? .eventId(eventId: messageId) : .transactionId(transactionId: messageId)
    }

    private static func extractItemID(_ item: TimelineItem) -> String? {
        guard item.asEvent() != nil else { return nil }
        return item.uniqueId().id
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
                let oldIDs = timelineItemIDs
                let newIDs = values.map(Self.extractItemID)
                timelineItemIDs = newIDs
                timelineItems = values

                if oldIDs.isEmpty {
                    // First load — full remap required.
                    pendingChangedIndices = nil
                } else {
                    // Diff old vs new IDs to avoid a full remap when most
                    // items are unchanged (e.g. room resume with a few
                    // new messages appended).
                    markChangedIndicesForReset(oldIDs: oldIDs, newIDs: newIDs)
                }

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

        let diffSummary = diffs.map { diff -> String in
            switch diff {
            case .reset(let v): "reset(\(v.count))"
            case .append(let v): "append(\(v.count))"
            case .pushBack: "pushBack"
            case .pushFront: "pushFront"
            case .insert(let idx, _): "insert(@\(idx))"
            case .set(let idx, _): "set(@\(idx))"
            case .remove(let idx): "remove(@\(idx))"
            case .clear: "clear"
            case .popBack: "popBack"
            case .popFront: "popFront"
            case .truncate(let len): "truncate(\(len))"
            }
        }.joined(separator: ", ")
        let changedDesc = pendingChangedIndices.map { "\($0.count) changed" } ?? "full remap"
        activityLog?.log(
            category: .timeline, severity: .debug, source: "TimelineViewModel",
            summary: "\(diffs.count) diff(s) in \(roomLabel): \(itemCountBefore) → \(itemCountAfter) items",
            detail: "Diffs: \(diffSummary)\nIndices: \(changedDesc)",
            roomId: roomId
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

    /// Compares old and new item IDs after a `.reset` diff and marks only the
    /// indices that actually changed, avoiding a full remap when most content
    /// is unchanged (e.g. resuming a room with a few new messages).
    ///
    /// Falls back to a full remap (`pendingChangedIndices = nil`) when the
    /// arrays have diverged too much to cheaply diff (shared prefix < 50%
    /// of the smaller array).
    private func markChangedIndicesForReset(
        oldIDs: [String?],
        newIDs: [String?]
    ) {
        // Find the longest shared prefix of identical IDs.
        let minCount = min(oldIDs.count, newIDs.count)
        var sharedPrefix = 0
        while sharedPrefix < minCount && oldIDs[sharedPrefix] == newIDs[sharedPrefix] {
            sharedPrefix += 1
        }

        // If less than half the items match, a full remap is cheaper than
        // tracking a large changed set.
        if sharedPrefix < minCount / 2 {
            pendingChangedIndices = nil
            return
        }

        // Mark every index beyond the shared prefix as changed.
        if sharedPrefix < newIDs.count {
            if pendingChangedIndices == nil {
                pendingChangedIndices = IndexSet()
            }
            pendingChangedIndices?.insert(integersIn: sharedPrefix..<newIDs.count)
        }
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
            activityLog?.log(
                category: .timeline, severity: .debug, source: "TimelineViewModel",
                summary: "Rebuild discarded in \(roomLabel) (stale generation \(generation))",
                roomId: roomId
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
            activityLog?.log(
                category: .timeline, severity: .debug, source: "TimelineViewModel",
                summary: "Messages updated in \(roomLabel): \(mapping.messages.count) messages (v\(messagesVersion))",
                roomId: roomId
            )
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

    // MARK: - Translation

    public func translationState(for messageId: String) -> MessageTranslationState {
        translationStates[messageId] ?? .idle
    }

    /// Whether the Translate affordance should be shown for this message.
    /// Permissive on purpose — surfaces the action for any plain-text
    /// kind with non-empty body. We deliberately skip language pre-
    /// detection here: NLLanguageRecognizer mis-classifies short
    /// messages with common loanwords often enough that gating the UI
    /// on it leaves users wondering why the button vanished. If the
    /// detected language turns out to match the user's readable set,
    /// `translateMessage(_:)` short-circuits with `.alreadyReadable`
    /// and silently keeps state at `.idle`.
    public func canTranslateMessage(_ messageId: String) -> Bool {
        guard let message = messageCache[messageId] else { return false }
        switch message.kind {
        case .text, .emote, .notice:
            break
        default:
            return false
        }
        return !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func translateMessage(_ messageId: String) async {
        guard let body = messageCache[messageId]?.body, !body.isEmpty else { return }

        // Dedup: if this message is already queued or actively running,
        // ignore. (User clicked Translate twice on the same row.)
        if inFlightTranslations.contains(messageId)
            || pendingTranslationQueue.contains(where: { $0.messageId == messageId })
        {
            return
        }

        let detectedSource: Locale.Language
        do {
            detectedSource = try translator.detectSourceLanguage(in: body)
        } catch is MessageTranslator.DetectionError {
            // .alreadyReadable / .undetectable / .empty all mean "no
            // user-visible translation needed". Don't badge the row.
            translationStates.removeValue(forKey: messageId)
            translationsVersion &+= 1
            return
        } catch {
            translationStates[messageId] = .failed(reason: error.localizedDescription)
            translationsVersion &+= 1
            return
        }

        // Mark loading and enqueue. The SwiftUI translation slots in
        // `TimelineView` watch `pendingTranslationQueueVersion` and
        // call `claimNextTranslation()` when they have free capacity.
        translationStates[messageId] = .loading
        let request = PendingTranslationRequest(
            messageId: messageId,
            sourceLanguageTag: detectedSource.minimalIdentifier,
            targetLanguageTag: translator.targetLanguage.minimalIdentifier
        )
        pendingTranslationQueue.append(request)
        pendingTranslationQueueVersion &+= 1
        translationsVersion &+= 1
    }

    @MainActor public func claimNextTranslation() -> PendingTranslationRequest? {
        guard !pendingTranslationQueue.isEmpty else { return nil }
        let request = pendingTranslationQueue.removeFirst()
        inFlightTranslations.insert(request.messageId)
        pendingTranslationQueueVersion &+= 1
        return request
    }

    @MainActor public func runTranslation(
        for request: PendingTranslationRequest,
        translate: @MainActor @escaping (String) async throws -> String
    ) async {
        defer {
            inFlightTranslations.remove(request.messageId)
            translationsVersion &+= 1
        }
        guard let body = messageCache[request.messageId]?.body else {
            translationStates.removeValue(forKey: request.messageId)
            return
        }

        do {
            let translated = try await translate(body)
            translationStates[request.messageId] = .translated(
                text: translated,
                sourceLanguageTag: request.sourceLanguageTag
            )
        } catch {
            translationStates[request.messageId] = .failed(reason: error.localizedDescription)
            timelineLogger.warning("Translation failed for \(request.sourceLanguageTag, privacy: .public)→\(request.targetLanguageTag, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    public func clearTranslation(_ messageId: String) {
        guard translationStates.removeValue(forKey: messageId) != nil else { return }
        translationsVersion &+= 1
    }
}

/// Logger for translation flow — separate from the file-level logger
/// so the diagnostic surface is easy to filter in Console.
private let timelineLogger = Logger(subsystem: "RelayKit", category: "Timeline.Translation")
