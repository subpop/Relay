import Foundation
import OSLog
import RelayCore
import SwiftData

private let logger = Logger(subsystem: "RelaySDK", category: "MessageStore")

// MARK: - SwiftData Model

@Model
final class CachedMessage {
    @Attribute(.unique) var eventId: String
    var roomId: String
    var senderID: String
    var senderDisplayName: String?
    var senderAvatarURL: String?
    var body: String
    var timestamp: Date
    var isOutgoing: Bool
    var kindRaw: String
    var reactionsJSON: Data?
    var isHighlighted: Bool
    var replyEventID: String?
    var replySenderID: String?
    var replySenderName: String?
    var replyBody: String?

    init(
        eventId: String,
        roomId: String,
        senderID: String,
        senderDisplayName: String?,
        senderAvatarURL: String?,
        body: String,
        timestamp: Date,
        isOutgoing: Bool,
        kindRaw: String,
        reactionsJSON: Data?,
        isHighlighted: Bool,
        replyEventID: String?,
        replySenderID: String?,
        replySenderName: String?,
        replyBody: String?
    ) {
        self.eventId = eventId
        self.roomId = roomId
        self.senderID = senderID
        self.senderDisplayName = senderDisplayName
        self.senderAvatarURL = senderAvatarURL
        self.body = body
        self.timestamp = timestamp
        self.isOutgoing = isOutgoing
        self.kindRaw = kindRaw
        self.reactionsJSON = reactionsJSON
        self.isHighlighted = isHighlighted
        self.replyEventID = replyEventID
        self.replySenderID = replySenderID
        self.replySenderName = replySenderName
        self.replyBody = replyBody
    }

    func toTimelineMessage() -> TimelineMessage {
        TimelineMessage(
            id: eventId,
            senderID: senderID,
            senderDisplayName: senderDisplayName,
            senderAvatarURL: senderAvatarURL,
            body: body,
            timestamp: timestamp,
            isOutgoing: isOutgoing,
            kind: kindFromRaw(kindRaw),
            reactions: Self.decodeReactions(reactionsJSON),
            isHighlighted: isHighlighted,
            replyDetail: makeReplyDetail()
        )
    }

    static func from(_ message: TimelineMessage, roomId: String) -> CachedMessage {
        CachedMessage(
            eventId: message.id,
            roomId: roomId,
            senderID: message.senderID,
            senderDisplayName: message.senderDisplayName,
            senderAvatarURL: message.senderAvatarURL,
            body: message.body,
            timestamp: message.timestamp,
            isOutgoing: message.isOutgoing,
            kindRaw: kindToRaw(message.kind),
            reactionsJSON: encodeReactions(message.reactions),
            isHighlighted: message.isHighlighted,
            replyEventID: message.replyDetail?.eventID,
            replySenderID: message.replyDetail?.senderID,
            replySenderName: message.replyDetail?.senderDisplayName,
            replyBody: message.replyDetail?.body
        )
    }

    // MARK: - Private

    private func makeReplyDetail() -> TimelineMessage.ReplyDetail? {
        guard let replyEventID, let replySenderID else { return nil }
        return .init(
            eventID: replyEventID,
            senderID: replySenderID,
            senderDisplayName: replySenderName,
            body: replyBody ?? ""
        )
    }

    private static func encodeReactions(_ reactions: [TimelineMessage.ReactionGroup]) -> Data? {
        guard !reactions.isEmpty else { return nil }
        let stored = reactions.map {
            StoredReaction(key: $0.key, count: $0.count, senderIDs: $0.senderIDs,
                           highlightedByCurrentUser: $0.highlightedByCurrentUser)
        }
        return try? JSONEncoder().encode(stored)
    }

    static func decodeReactions(_ data: Data?) -> [TimelineMessage.ReactionGroup] {
        guard let data else { return [] }
        guard let stored = try? JSONDecoder().decode([StoredReaction].self, from: data) else { return [] }
        return stored.map {
            .init(key: $0.key, count: $0.count, senderIDs: $0.senderIDs,
                  highlightedByCurrentUser: $0.highlightedByCurrentUser)
        }
    }
}

private struct StoredReaction: Codable {
    let key: String
    let count: Int
    let senderIDs: [String]
    let highlightedByCurrentUser: Bool
}

// MARK: - Kind Serialization

nonisolated private func kindToRaw(_ kind: TimelineMessage.Kind) -> String {
    switch kind {
    case .text: "text"
    case .emote: "emote"
    case .notice: "notice"
    case .image: "image"
    case .video: "video"
    case .audio: "audio"
    case .file: "file"
    case .location: "location"
    case .sticker: "sticker"
    case .poll: "poll"
    case .redacted: "redacted"
    case .encrypted: "encrypted"
    case .other: "other"
    }
}

nonisolated private func kindFromRaw(_ raw: String) -> TimelineMessage.Kind {
    switch raw {
    case "text": .text
    case "emote": .emote
    case "notice": .notice
    case "image": .image
    case "video": .video
    case "audio": .audio
    case "file": .file
    case "location": .location
    case "sticker": .sticker
    case "poll": .poll
    case "redacted": .redacted
    case "encrypted": .encrypted
    default: .other
    }
}

// MARK: - Message Store

@MainActor
final class MessageStore {
    static let shared = MessageStore()

    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    private init() {
        do {
            container = try ModelContainer(for: CachedMessage.self)
        } catch {
            logger.error("Failed to create MessageStore container: \(error)")
            fatalError("Failed to create MessageStore: \(error)")
        }
    }

    func loadMessages(roomId: String, limit: Int = 200) -> [TimelineMessage] {
        let descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate<CachedMessage> { $0.roomId == roomId },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        do {
            var limited = descriptor
            limited.fetchLimit = limit
            let cached = try context.fetch(limited)
            return cached.map { $0.toTimelineMessage() }
        } catch {
            logger.error("Failed to load cached messages for room \(roomId): \(error)")
            return []
        }
    }

    func save(_ messages: [TimelineMessage], roomId: String) {
        guard !messages.isEmpty else { return }

        for message in messages {
            context.insert(CachedMessage.from(message, roomId: roomId))
        }

        let currentIds = Set(messages.map(\.id))
        let descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate<CachedMessage> { $0.roomId == roomId }
        )
        if let all = try? context.fetch(descriptor) {
            for cached in all where !currentIds.contains(cached.eventId) {
                context.delete(cached)
            }
        }

        do {
            try context.save()
        } catch {
            logger.error("Failed to save cached messages for room \(roomId): \(error)")
        }
    }

    func pruneOldMessages(roomId: String, keepLast: Int = 500) {
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate<CachedMessage> { $0.roomId == roomId },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchOffset = keepLast

        do {
            let old = try context.fetch(descriptor)
            guard !old.isEmpty else { return }
            for message in old {
                context.delete(message)
            }
            try context.save()
            logger.info("Pruned \(old.count) old messages from room \(roomId)")
        } catch {
            logger.error("Failed to prune messages for room \(roomId): \(error)")
        }
    }
}
