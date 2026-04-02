import AsyncAlgorithms
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import MatrixRustSDK
import OSLog
import RelayCore
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "RelaySDK", category: "RoomDetail")

/// Concrete implementation of ``RoomDetailViewModelProtocol`` backed by the Matrix Rust SDK.
///
/// ``RoomDetailViewModel`` manages a single room's message timeline. It subscribes to live
/// timeline diffs from the SDK using ``AsyncSDKListener``, converts them into ``TimelineMessage``
/// models, handles backward pagination via ``subscribeToBackPaginationStatus``, computes the
/// unread marker position, and observes typing notifications.
///
/// Timeline diffs are throttled at 500ms to prevent rapid structural view updates from
/// destabilizing SwiftUI's `LazyVStack` layout.
@Observable
public final class RoomDetailViewModel: RoomDetailViewModelProtocol {
    public private(set) var messages: [TimelineMessage] = []
    public private(set) var isLoading = true
    public private(set) var isLoadingMore = false
    public private(set) var hasReachedStart = false
    public var firstUnreadMessageId: String?
    public private(set) var typingUserDisplayNames: [String] = []
    public var errorMessage: String?
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
    public init(room: Room, currentUserId: String?, unreadCount: Int = 0) {
        self.room = room
        self.roomId = room.id()
        self.currentUserId = currentUserId
        self.unreadCount = unreadCount
        self.messageMapper = TimelineMessageMapper(currentUserId: currentUserId)
    }

    deinit {
        let tasks = MainActor.assumeIsolated { (observationTask, paginationTask, typingTask) }
        tasks.0?.cancel()
        tasks.1?.cancel()
        tasks.2?.cancel()
    }

    // MARK: - Public

    public func loadTimeline() async {
        guard sdkTimeline == nil else { return }

        isLoading = true
        do {
            try await setupTimeline(focus: .live(hideThreadedEvents: true))
            timelineFocus = .live
            observeTypingNotifications()
            if let tl = sdkTimeline {
                await paginateInitialHistory(tl)
            }
        } catch {
            logger.error("Failed to load timeline: \(error)")
            errorMessage = "Could not load messages: \(error.localizedDescription)"
        }
        isLoading = false
    }

    public func loadMoreHistory() async {
        guard let sdkTimeline, !isLoadingMore, !hasReachedStart else { return }
        do {
            _ = try await sdkTimeline.paginateBackwards(numEvents: 40)
        } catch {
            logger.error("Failed to load earlier messages: \(error)")
            errorMessage = "Could not load earlier messages: \(error.localizedDescription)"
        }
    }

    public func focusOnEvent(eventId: String) async {
        isLoading = true
        teardownTimeline()

        do {
            try await setupTimeline(focus: .event(
                eventId: eventId,
                numContextEvents: 50,
                hideThreadedEvents: true
            ))
            timelineFocus = .focusedOnEvent(eventId)
        } catch {
            logger.error("Failed to focus on event \(eventId): \(error)")
            errorMessage = "Could not load message: \(error.localizedDescription)"
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
            if let tl = sdkTimeline {
                await paginateInitialHistory(tl)
            }
        } catch {
            logger.error("Failed to return to live timeline: \(error)")
            errorMessage = "Could not restore timeline: \(error.localizedDescription)"
        }
        isLoading = false
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
            errorMessage = "Could not send message: \(error.localizedDescription)"
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
            errorMessage = "Could not toggle reaction: \(error.localizedDescription)"
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
            errorMessage = "Could not delete message: \(error.localizedDescription)"
        }
    }

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
               let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
            {
                let data: Data
                do {
                    data = try Data(contentsOf: url)
                } catch {
                    logger.error("Failed to read attachment \(filename): \(error)")
                    errorMessage = "Could not read \(filename): \(error.localizedDescription)"
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
                let fileSize = UInt64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0)

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
                let fileSize = UInt64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0)

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
                    errorMessage = "Could not read \(filename): \(error.localizedDescription)"
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
            errorMessage = "Could not send \(filename): \(error.localizedDescription)"
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

    private func paginateInitialHistory(_ tl: Timeline) async {
        do {
            _ = try await tl.paginateBackwards(numEvents: 40)
        } catch {
            logger.error("Failed to paginate initial history: \(error)")
        }
    }

    private func observeTimeline(_ tl: Timeline) {
        let listener = AsyncSDKListener<[TimelineDiff]>()

        observationTask = Task { [weak self] in
            guard let self else { return }

            self.timelineHandle = await tl.addListener(listener: listener)

            // Throttle diffs at 500ms to prevent rapid structural view updates
            let throttled = listener._throttle(for: .milliseconds(500), reducing: { result, next in
                (result ?? []) + next
            })

            for await diffs in throttled {
                self.applyDiffs(diffs)
                self.rebuildMessages()
            }
        }
    }

    private func observePaginationStatus(_ tl: Timeline) async throws {
        let listener = AsyncSDKListener<RoomPaginationStatus>()
        paginationHandle = try await tl.subscribeToBackPaginationStatus(listener: listener)

        paginationTask = Task { [weak self] in
            for await status in listener {
                guard let self else { break }

                switch status {
                case .idle(let hitStart):
                    self.isLoadingMore = false
                    self.hasReachedStart = hitStart

                    // Auto-paginate if we have very few items and haven't hit start
                    if !hitStart && self.timelineItems.count < 20 {
                        try? await Task.sleep(for: .milliseconds(500))
                        try? await tl.paginateBackwards(numEvents: 40)
                    }
                case .paginating:
                    self.isLoadingMore = true
                }
            }
        }
    }

    private func observeTypingNotifications() {
        let listener = AsyncSDKListener<[String]>()
        typingHandle = room.subscribeToTypingNotifications(listener: listener)

        typingTask = Task { [weak self] in
            for await userIds in listener {
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
        guard !newFetchIds.isEmpty, let tl = sdkTimeline else { return }
        fetchedReplyEventIds.formUnion(newFetchIds)
        Task {
            for eventId in newFetchIds {
                try? await tl.fetchDetailsForEvent(eventId: eventId)
            }
        }
    }
}
