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
/// timeline diffs from the SDK, converts them into ``TimelineMessage`` models, handles
/// backward pagination, caches messages via ``MessageStore``, computes the unread marker
/// position, and observes typing notifications.
@Observable
public final class RoomDetailViewModel: RoomDetailViewModelProtocol {
    public private(set) var messages: [TimelineMessage] = []
    public private(set) var isLoading = true
    public private(set) var isLoadingMore = false
    public private(set) var hasReachedStart = false
    public private(set) var firstUnreadMessageId: String?
    public private(set) var typingUserDisplayNames: [String] = []
    public var errorMessage: String?

    private let room: Room
    private let roomId: String
    private let currentUserId: String?
    private let unreadCount: Int
    private var timeline: Timeline?
    private var observationTask: Task<Void, Never>?
    private var typingTask: Task<Void, Never>?
    private let diffProcessor = TimelineDiffProcessor()
    private let messageMapper: TimelineMessageMapper
    private var hasComputedUnreadMarker = false
    private var saveCacheTask: Task<Void, Never>?
    private var fetchedReplyEventIds: Set<String> = []

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
        let tasks = MainActor.assumeIsolated { (observationTask, typingTask) }
        tasks.0?.cancel()
        tasks.1?.cancel()
    }

    // MARK: - Public

    public func loadTimeline() async {
        guard timeline == nil else { return }

        let cached = MessageStore.shared.loadMessages(roomId: roomId)
        if !cached.isEmpty && messages.isEmpty {
            messages = cached
        }

        isLoading = messages.isEmpty
        hasReachedStart = false

        do {
            let tl = try await room.timeline()
            timeline = tl
            observeTimeline(tl)
            observeTypingNotifications()
            await paginateInitialHistory(tl)
        } catch {
            logger.error("Failed to load timeline: \(error)")
            errorMessage = "Could not load messages: \(error.localizedDescription)"
        }
        isLoading = false
    }

    public func loadMoreHistory() async {
        guard let timeline, !isLoadingMore, !hasReachedStart else { return }
        isLoadingMore = true
        do {
            let reachedStart = try await timeline.paginateBackwards(numEvents: 40)
            hasReachedStart = reachedStart
        } catch {
            logger.error("Failed to load earlier messages: \(error)")
            errorMessage = "Could not load earlier messages: \(error.localizedDescription)"
        }
        isLoadingMore = false
    }

    public func send(text: String, inReplyTo eventId: String? = nil) async {
        guard let timeline else { return }
        let msg = messageEventContentFromMarkdown(md: text)
        do {
            if let eventId {
                try await timeline.sendReply(msg: msg, eventId: eventId)
            } else {
                _ = try await timeline.send(msg: msg)
            }
        } catch {
            logger.error("Failed to send message: \(error)")
            errorMessage = "Could not send message: \(error.localizedDescription)"
        }
    }

    public func toggleReaction(messageId: String, key: String) async {
        guard let timeline else { return }
        let itemId: EventOrTransactionId = if messageId.hasPrefix("$") {
            .eventId(eventId: messageId)
        } else {
            .transactionId(transactionId: messageId)
        }
        do {
            _ = try await timeline.toggleReaction(itemId: itemId, key: key)
        } catch {
            logger.error("Failed to toggle reaction: \(error)")
            errorMessage = "Could not toggle reaction: \(error.localizedDescription)"
        }
    }

    public func sendAttachment(url: URL) async {
        guard let timeline else { return }

        let filename = url.lastPathComponent
        let utType = UTType(filenameExtension: url.pathExtension) ?? .data
        let mime = utType.preferredMIMEType

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
                    caption: nil,
                    formattedCaption: nil,
                    mentions: nil,
                    inReplyTo: nil
                )
                handle = try timeline.sendImage(
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
                    caption: nil,
                    formattedCaption: nil,
                    mentions: nil,
                    inReplyTo: nil
                )
                handle = try timeline.sendVideo(
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
                    caption: nil,
                    formattedCaption: nil,
                    mentions: nil,
                    inReplyTo: nil
                )
                handle = try timeline.sendAudio(
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
                    caption: nil,
                    formattedCaption: nil,
                    mentions: nil,
                    inReplyTo: nil
                )
                handle = try timeline.sendFile(
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

    // MARK: - Private

    private func scheduleCacheSave() {
        saveCacheTask?.cancel()
        let snapshot = messages
        let rid = roomId
        saveCacheTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            MessageStore.shared.save(snapshot, roomId: rid)
        }
    }

    private func paginateInitialHistory(_ tl: Timeline) async {
        do {
            let reachedStart = try await tl.paginateBackwards(numEvents: 40)
            hasReachedStart = reachedStart
        } catch {
            logger.error("Failed to paginate initial history: \(error)")
        }
    }

    private func observeTimeline(_ tl: Timeline) {
        observationTask = Task { [weak self] in
            guard let self else { return }

            var listenerContinuation: AsyncStream<[TimelineDiff]>.Continuation!
            let stream = AsyncStream<[TimelineDiff]> { continuation in
                listenerContinuation = continuation
            }

            let listener = TimelineListenerProxy(continuation: listenerContinuation)
            let handle = await tl.addListener(listener: listener)

            for await diffs in stream {
                self.diffProcessor.applyDiffs(diffs)
                self.rebuildMessages()
            }

            _ = handle
        }
    }

    private func observeTypingNotifications() {
        typingTask = Task { [weak self] in
            guard let self else { return }

            var continuation: AsyncStream<[String]>.Continuation!
            let stream = AsyncStream<[String]> { continuation = $0 }

            let listener = TypingNotificationsListenerProxy(continuation: continuation)
            let handle = room.subscribeToTypingNotifications(listener: listener)

            for await userIds in stream {
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

            _ = handle
        }
    }

    private func rebuildMessages() {
        let mapping = messageMapper.mapItems(diffProcessor.timelineItems)
        messages = mapping.messages

        computeUnreadMarkerIfNeeded(mapping.messages)
        resolveUnfetchedReplies(mapping.unresolvedReplyEventIds)

        if !mapping.messages.isEmpty {
            scheduleCacheSave()
        }
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
        guard !newFetchIds.isEmpty, let tl = timeline else { return }
        fetchedReplyEventIds.formUnion(newFetchIds)
        Task {
            for eventId in newFetchIds {
                try? await tl.fetchDetailsForEvent(eventId: eventId)
            }
        }
    }
}

// MARK: - Timeline Listener Bridge

/// Bridges `TimelineListener` callbacks from the Matrix Rust SDK into an `AsyncStream` of diffs.
nonisolated final class TimelineListenerProxy: TimelineListener, @unchecked Sendable {
    private let continuation: AsyncStream<[TimelineDiff]>.Continuation

    init(continuation: AsyncStream<[TimelineDiff]>.Continuation) {
        self.continuation = continuation
    }

    func onUpdate(diff: [TimelineDiff]) {
        continuation.yield(diff)
    }
}

/// Bridges `TypingNotificationsListener` callbacks from the Matrix Rust SDK into an `AsyncStream` of user IDs.
nonisolated final class TypingNotificationsListenerProxy: TypingNotificationsListener, @unchecked Sendable {
    private let continuation: AsyncStream<[String]>.Continuation

    init(continuation: AsyncStream<[String]>.Continuation) {
        self.continuation = continuation
    }

    func call(typingUserIds: [String]) {
        continuation.yield(typingUserIds)
    }
}
