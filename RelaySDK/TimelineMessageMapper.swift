import Foundation
import MatrixRustSDK
import RelayCore

/// Converts raw Matrix SDK timeline items into ``TimelineMessage`` models for the UI.
///
/// ``TimelineMessageMapper`` is a pure transformation layer with no side effects. It takes
/// an array of SDK ``TimelineItem`` values and produces an array of ``TimelineMessage``
/// models plus a set of event IDs whose reply details still need to be fetched from the
/// server.
///
/// Separating this mapping from the view model makes the conversion logic independently
/// testable and keeps the view model focused on state management and coordination.
struct TimelineMessageMapper {
    /// The Matrix user ID of the signed-in user, used for highlight and reaction detection.
    let currentUserId: String?

    /// The result of mapping timeline items to messages.
    struct MappingResult {
        /// The ordered list of timeline messages, from oldest to newest.
        let messages: [TimelineMessage]
        /// Event IDs of messages with unresolved reply details that need fetching.
        let unresolvedReplyEventIds: Set<String>
    }

    /// Maps an array of raw SDK timeline items into ``TimelineMessage`` models.
    ///
    /// Items that are not message-like events (e.g. room state events) are skipped.
    /// For each message-like event, the mapper extracts the body, kind, media info,
    /// reactions, highlight status, and reply context.
    ///
    /// - Parameter items: The raw timeline items from the SDK.
    /// - Returns: A ``MappingResult`` containing the mapped messages and any unresolved reply IDs.
    func mapItems(_ items: [TimelineItem]) -> MappingResult {
        var result: [TimelineMessage] = []
        var pendingReplyFetchIds: Set<String> = []

        for item in items {
            guard let event = item.asEvent() else { continue }

            let msgBody: String
            let msgKind: TimelineMessage.Kind
            var msgMediaInfo: TimelineMessage.MediaInfo?
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
                    case .image(let imageContent):
                        msgBody = imageContent.caption ?? "Image"
                        msgKind = .image
                        msgMediaInfo = .init(
                            mxcURL: imageContent.source.url(),
                            filename: imageContent.filename,
                            mimetype: imageContent.info?.mimetype,
                            width: imageContent.info?.width,
                            height: imageContent.info?.height,
                            size: imageContent.info?.size,
                            caption: imageContent.caption
                        )
                    case .video(let videoContent):
                        msgBody = videoContent.caption ?? videoContent.filename
                        msgKind = .video
                        msgMediaInfo = .init(
                            mxcURL: videoContent.source.url(),
                            filename: videoContent.filename,
                            mimetype: videoContent.info?.mimetype,
                            width: videoContent.info?.width,
                            height: videoContent.info?.height,
                            size: videoContent.info?.size,
                            caption: videoContent.caption,
                            duration: videoContent.info?.duration
                        )
                    case .audio(let audioContent):
                        msgBody = audioContent.caption ?? audioContent.filename
                        msgKind = .audio
                        msgMediaInfo = .init(
                            mxcURL: audioContent.source.url(),
                            filename: audioContent.filename,
                            mimetype: audioContent.info?.mimetype,
                            size: audioContent.info?.size,
                            caption: audioContent.caption,
                            duration: audioContent.info?.duration
                        )
                    case .file(let fileContent):
                        msgBody = fileContent.caption ?? fileContent.filename
                        msgKind = .file
                        msgMediaInfo = .init(
                            mxcURL: fileContent.source.url(),
                            filename: fileContent.filename,
                            mimetype: fileContent.info?.mimetype,
                            size: fileContent.info?.size,
                            caption: fileContent.caption
                        )
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

            var msgReactions: [TimelineMessage.ReactionGroup] = []
            var isHighlighted = false
            var msgReplyDetail: TimelineMessage.ReplyDetail?
            var hasUnresolvedReply = false
            if case .msgLike(let ml) = event.content {
                msgReactions = ml.reactions.map { reaction in
                    TimelineMessage.ReactionGroup(
                        key: reaction.key,
                        count: reaction.senders.count,
                        senderIDs: reaction.senders.map(\.senderId),
                        highlightedByCurrentUser: reaction.senders.contains { $0.senderId == currentUserId }
                    )
                }

                if !event.isOwn, let userId = currentUserId {
                    if case .message(let mc) = ml.kind, let mentions = mc.mentions {
                        isHighlighted = mentions.userIds.contains(userId) || mentions.room
                    }
                    if !isHighlighted {
                        isHighlighted = msgBody.contains(userId)
                    }
                }

                if let replyTo = ml.inReplyTo {
                    let replyEventId = replyTo.eventId()
                    switch replyTo.event() {
                    case .ready(let content, let sender, let senderProfile, _, _):
                        let replyDisplayName: String? = if case .ready(let name, _, _) = senderProfile { name } else { nil }
                        let replyBody: String
                        if case .msgLike(let replyMl) = content,
                           case .message(let replyMsg) = replyMl.kind {
                            replyBody = replyMsg.body
                        } else {
                            replyBody = "Message"
                        }
                        msgReplyDetail = .init(eventID: replyEventId, senderID: sender, senderDisplayName: replyDisplayName, body: replyBody)
                    case .pending:
                        msgReplyDetail = .init(eventID: replyEventId, senderID: "", senderDisplayName: nil, body: "")
                        hasUnresolvedReply = true
                    case .unavailable:
                        msgReplyDetail = .init(eventID: replyEventId, senderID: "", senderDisplayName: nil, body: "")
                        hasUnresolvedReply = true
                    case .error:
                        msgReplyDetail = .init(eventID: replyEventId, senderID: "", senderDisplayName: nil, body: "")
                    }
                }
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

            if hasUnresolvedReply {
                pendingReplyFetchIds.insert(eventId)
            }

            result.append(TimelineMessage(
                id: eventId,
                senderID: event.sender,
                senderDisplayName: displayName,
                senderAvatarURL: avatarURL,
                body: msgBody,
                timestamp: ts,
                isOutgoing: event.isOwn,
                kind: msgKind,
                mediaInfo: msgMediaInfo,
                reactions: msgReactions,
                isHighlighted: isHighlighted,
                replyDetail: msgReplyDetail
            ))
        }

        return MappingResult(messages: result, unresolvedReplyEventIds: pendingReplyFetchIds)
    }
}
