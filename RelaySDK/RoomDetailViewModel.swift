import Foundation
import MatrixRustSDK
import RelayCore

@Observable
public final class RoomDetailViewModel: RoomDetailViewModelProtocol {
    public private(set) var messages: [TimelineMessage] = []
    public private(set) var isLoading = true
    public private(set) var isLoadingMore = false
    public private(set) var hasReachedStart = false
    public private(set) var firstUnreadMessageId: String?

    private let room: Room
    private let currentUserId: String?
    private let unreadCount: Int
    private var timeline: Timeline?
    private var observationTask: Task<Void, Never>?
    private var timelineItems: [TimelineItem] = []
    private var hasComputedUnreadMarker = false

    public init(room: Room, currentUserId: String?, unreadCount: Int = 0) {
        self.room = room
        self.currentUserId = currentUserId
        self.unreadCount = unreadCount
    }

    deinit {
        let task = MainActor.assumeIsolated { observationTask }
        task?.cancel()
    }

    // MARK: - Public

    public func loadTimeline() async {
        observationTask?.cancel()
        messages = []
        timelineItems = []
        isLoading = true
        hasReachedStart = false

        do {
            let tl = try await room.timeline()
            timeline = tl
            observeTimeline(tl)
            await paginateInitialHistory(tl)
        } catch {
            isLoading = false
        }
    }

    public func loadMoreHistory() async {
        guard let timeline, !isLoadingMore, !hasReachedStart else { return }
        isLoadingMore = true
        do {
            let reachedStart = try await timeline.paginateBackwards(numEvents: 40)
            hasReachedStart = reachedStart
        } catch {}
        isLoadingMore = false
    }

    public func send(text: String) async {
        guard let timeline else { return }
        _ = try? await timeline.send(msg: messageEventContentFromMarkdown(md: text))
    }

    // MARK: - Private

    private func paginateInitialHistory(_ tl: Timeline) async {
        do {
            let reachedStart = try await tl.paginateBackwards(numEvents: 40)
            hasReachedStart = reachedStart
        } catch {}
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

            self.isLoading = false

            for await diffs in stream {
                self.applyDiffs(diffs)
                self.rebuildMessages()
            }

            _ = handle
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
        var result: [TimelineMessage] = []

        for item in timelineItems {
            guard let event = item.asEvent() else { continue }

            let msgBody: String
            let msgKind: TimelineMessage.Kind
            switch event.content {
            case .msgLike(let msgLikeContent):
                switch msgLikeContent.kind {
                case .message(let messageContent):
                    switch messageContent.msgType {
                    case .text(let textContent):
                        msgBody = textContent.body
                        msgKind = .text
                    case .emote(let emoteContent):
                        msgBody = emoteContent.body
                        msgKind = .emote
                    case .notice(let noticeContent):
                        msgBody = noticeContent.body
                        msgKind = .notice
                    case .image:
                        msgBody = "Image"
                        msgKind = .image
                    case .video:
                        msgBody = "Video"
                        msgKind = .video
                    case .audio:
                        msgBody = "Audio"
                        msgKind = .audio
                    case .file:
                        msgBody = "File"
                        msgKind = .file
                    case .location:
                        msgBody = "Location"
                        msgKind = .location
                    case .gallery:
                        msgBody = "Gallery"
                        msgKind = .image
                    case .other:
                        msgBody = "Message"
                        msgKind = .other
                    }
                case .sticker:
                    msgBody = "Sticker"
                    msgKind = .sticker
                case .poll:
                    msgBody = "Poll"
                    msgKind = .poll
                case .redacted:
                    msgBody = "This message was deleted"
                    msgKind = .redacted
                case .unableToDecrypt:
                    msgBody = "Waiting for encryption key"
                    msgKind = .encrypted
                case .other:
                    continue
                }
            default:
                continue
            }

            let (displayName, avatarURL): (String?, String?) =
                switch event.senderProfile {
                case .ready(let name, _, let url):
                    (name, url)
                default:
                    (nil, nil)
                }

            let ts = Date(timeIntervalSince1970: TimeInterval(event.timestamp) / 1000)

            let eventId: String
            switch event.eventOrTransactionId {
            case .eventId(let id):
                eventId = id
            case .transactionId(let id):
                eventId = id
            }

            result.append(TimelineMessage(
                id: eventId,
                senderID: event.sender,
                senderDisplayName: displayName,
                senderAvatarURL: avatarURL,
                body: msgBody,
                timestamp: ts,
                isOutgoing: event.isOwn,
                kind: msgKind
            ))
        }

        messages = result

        if !hasComputedUnreadMarker && unreadCount > 0 && !result.isEmpty {
            hasComputedUnreadMarker = true
            let incomingMessages = result.filter { !$0.isOutgoing }
            if unreadCount <= incomingMessages.count {
                let markerIndex = incomingMessages.count - unreadCount
                firstUnreadMessageId = incomingMessages[markerIndex].id
            }
        }
    }
}

// MARK: - Timeline Listener Bridge

nonisolated final class TimelineListenerProxy: TimelineListener, @unchecked Sendable {
    private let continuation: AsyncStream<[TimelineDiff]>.Continuation

    init(continuation: AsyncStream<[TimelineDiff]>.Continuation) {
        self.continuation = continuation
    }

    func onUpdate(diff: [TimelineDiff]) {
        continuation.yield(diff)
    }
}
