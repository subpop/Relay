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

import Foundation
import RelayInterface

/// Converts raw Matrix SDK timeline items into ``TimelineMessage`` models for the UI.
///
/// ``TimelineMessageMapper`` is a pure transformation layer with no side effects. It takes
/// an array of SDK ``TimelineItem`` values and produces an array of ``TimelineMessage``
/// models plus a set of event IDs whose reply details still need to be fetched from the
/// server.
///
/// Separating this mapping from the view model makes the conversion logic independently
/// testable and keeps the view model focused on state management and coordination.
struct TimelineMessageMapper: Sendable { // swiftlint:disable:this type_body_length
    /// The Matrix user ID of the signed-in user, used for highlight and reaction detection.
    let currentUserId: String?

    /// The result of mapping timeline items to messages.
    struct MappingResult {
        /// The ordered list of timeline messages, from oldest to newest.
        let messages: [TimelineMessage]
        /// Event IDs of messages with unresolved reply details that need fetching.
        let unresolvedReplyEventIds: Set<String>
    }

    // swiftlint:disable function_body_length cyclomatic_complexity
    /// Maps an array of raw SDK timeline items into ``TimelineMessage`` models.
    ///
    /// Handles message-like events, membership changes, profile changes, and room
    /// state events. Unsupported content types (e.g. call invites) are skipped.
    /// For each supported event, the mapper extracts the body, kind, media info,
    /// reactions, highlight status, and reply context.
    ///
    /// - Parameter items: The raw timeline items from the SDK.
    /// - Returns: A ``MappingResult`` containing the mapped messages and any unresolved reply IDs.
    func mapItems(_ items: [TimelineItem]) -> MappingResult {
    // swiftlint:enable function_body_length cyclomatic_complexity
        var result: [TimelineMessage] = []
        var pendingReplyFetchIds: Set<String> = []

        for item in items {
            guard let event = item.asEvent() else { continue }

            let msgBody: String
            let msgKind: TimelineMessage.Kind
            var msgMediaInfo: TimelineMessage.MediaInfo?
            var msgFormattedBody: String?
            var msgIsEdited = false
            switch event.content {
            case .msgLike(let msgLikeContent):
                switch msgLikeContent.kind {
                case .message(let messageContent):
                    msgIsEdited = messageContent.isEdited
                    switch messageContent.msgType {
                    case .text(let textContent):
                        msgBody = textContent.body
                        msgKind = .text
                        if case .html = textContent.formatted?.format {
                            msgFormattedBody = textContent.formatted?.body
                        }
                    case .emote(let emoteContent):
                        msgBody = emoteContent.body
                        msgKind = .emote
                        if case .html = emoteContent.formatted?.format {
                            msgFormattedBody = emoteContent.formatted?.body
                        }
                    case .notice(let noticeContent):
                        msgBody = noticeContent.body
                        msgKind = .notice
                        if case .html = noticeContent.formatted?.format {
                            msgFormattedBody = noticeContent.formatted?.body
                        }
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
                case .liveLocation:
                    msgBody = "Live location"
                    msgKind = .liveLocation
                }
            case .roomMembership(let userId, let userDisplayName, let change, _):
                let name = userDisplayName ?? userId
                msgBody = Self.membershipDescription(name: name, change: change)
                msgKind = .membership
            case .profileChange(let displayName, let prevDisplayName, let avatarUrl, let prevAvatarUrl):
                msgBody = Self.profileChangeDescription(
                    displayName: displayName,
                    prevDisplayName: prevDisplayName,
                    avatarUrl: avatarUrl,
                    prevAvatarUrl: prevAvatarUrl
                )
                msgKind = .profileChange
            case .state(_, let content):
                msgBody = Self.stateEventDescription(content)
                msgKind = .stateEvent
            default:
                continue
            }

            var msgReactions: [TimelineMessage.ReactionGroup] = []
            var isHighlighted = false
            var msgReplyDetail: TimelineMessage.ReplyDetail?
            var hasUnresolvedReply = false
            // swiftlint:disable:next identifier_name
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
                    // swiftlint:disable:next identifier_name
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
                        let replyDisplayName: String? =
                            if case .ready(let name, _, _) = senderProfile { name } else { nil }
                        let replyBody: String
                        var replyFormattedBody: String?
                        if case .msgLike(let replyMl) = content,
                           case .message(let replyMsg) = replyMl.kind {
                            replyBody = replyMsg.body
                            switch replyMsg.msgType {
                            case .text(let tc) where tc.formatted?.format == .html:
                                replyFormattedBody = tc.formatted?.body
                            case .emote(let ec) where ec.formatted?.format == .html:
                                replyFormattedBody = ec.formatted?.body
                            case .notice(let nc) where nc.formatted?.format == .html:
                                replyFormattedBody = nc.formatted?.body
                            default:
                                break
                            }
                        } else {
                            replyBody = "Message"
                        }
                        msgReplyDetail = .init(
                            eventID: replyEventId, senderID: sender,
                            senderDisplayName: replyDisplayName, body: replyBody,
                            formattedBody: replyFormattedBody
                        )
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

            // swiftlint:disable:next identifier_name
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
                formattedBody: msgFormattedBody,
                timestamp: ts,
                isOutgoing: event.isOwn,
                kind: msgKind,
                mediaInfo: msgMediaInfo,
                reactions: msgReactions,
                isHighlighted: isHighlighted,
                replyDetail: msgReplyDetail,
                isEdited: msgIsEdited
            ))
        }

        return MappingResult(messages: result, unresolvedReplyEventIds: pendingReplyFetchIds)
    }

    // swiftlint:disable function_body_length cyclomatic_complexity
    /// Maps a single `EventTimelineItem` into a ``TimelineMessage``, if it is a supported event.
    ///
    /// Returns `nil` for unsupported content types (e.g. call invites).
    func mapEventItem(_ event: EventTimelineItem) -> TimelineMessage? {
    // swiftlint:enable function_body_length cyclomatic_complexity
        // Re-use the batch mapper with a synthetic wrapper — the logic is identical.
        // EventTimelineItem doesn't conform to TimelineItem, so we duplicate the
        // core extraction inline. This keeps the single-event path simple.
        let msgBody: String
        let msgKind: TimelineMessage.Kind
        var msgMediaInfo: TimelineMessage.MediaInfo?
        var msgFormattedBody: String?
        var msgIsEdited = false

        switch event.content {
        case .msgLike(let msgLikeContent):
            switch msgLikeContent.kind {
            case .message(let messageContent):
                msgIsEdited = messageContent.isEdited
                switch messageContent.msgType {
                case .text(let textContent):
                    msgBody = textContent.body
                    msgKind = .text
                    if case .html = textContent.formatted?.format {
                        msgFormattedBody = textContent.formatted?.body
                    }
                case .emote(let emoteContent):
                    msgBody = emoteContent.body
                    msgKind = .emote
                    if case .html = emoteContent.formatted?.format {
                        msgFormattedBody = emoteContent.formatted?.body
                    }
                case .notice(let noticeContent):
                    msgBody = noticeContent.body
                    msgKind = .notice
                    if case .html = noticeContent.formatted?.format {
                        msgFormattedBody = noticeContent.formatted?.body
                    }
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
                return nil
            case .liveLocation:
                msgBody = "Live location"
                msgKind = .liveLocation
            }
        case .roomMembership(let userId, let userDisplayName, let change, _):
            let name = userDisplayName ?? userId
            msgBody = Self.membershipDescription(name: name, change: change)
            msgKind = .membership
        case .profileChange(let displayName, let prevDisplayName, let avatarUrl, let prevAvatarUrl):
            msgBody = Self.profileChangeDescription(
                displayName: displayName,
                prevDisplayName: prevDisplayName,
                avatarUrl: avatarUrl,
                prevAvatarUrl: prevAvatarUrl
            )
            msgKind = .profileChange
        case .state(_, let content):
            msgBody = Self.stateEventDescription(content)
            msgKind = .stateEvent
        default:
            return nil
        }

        let (displayName, avatarURL): (String?, String?) =
            switch event.senderProfile {
            case .ready(let name, _, let url):
                (name, url)
            default:
                (nil, nil)
            }

        // swiftlint:disable:next identifier_name
        let ts = Date(timeIntervalSince1970: TimeInterval(event.timestamp) / 1000)

        let eventId: String
        switch event.eventOrTransactionId {
        case .eventId(let id):
            eventId = id
        case .transactionId(let id):
            eventId = id
        }

        return TimelineMessage(
            id: eventId,
            senderID: event.sender,
            senderDisplayName: displayName,
            senderAvatarURL: avatarURL,
            body: msgBody,
            formattedBody: msgFormattedBody,
            timestamp: ts,
            isOutgoing: event.isOwn,
            kind: msgKind,
            mediaInfo: msgMediaInfo,
            isEdited: msgIsEdited
        )
    }

    // MARK: - System Event Descriptions

    // swiftlint:disable cyclomatic_complexity
    /// Returns a human-readable description for a membership change event.
    static func membershipDescription(name: String, change: MembershipChange?) -> String {
    // swiftlint:enable cyclomatic_complexity
        guard let change else { return "\(name) membership changed" }
        switch change {
        case .joined:
            return "\(name) joined the room"
        case .left:
            return "\(name) left the room"
        case .banned:
            return "\(name) was banned"
        case .unbanned:
            return "\(name) was unbanned"
        case .kicked:
            return "\(name) was removed from the room"
        case .invited:
            return "\(name) was invited"
        case .kickedAndBanned:
            return "\(name) was removed and banned"
        case .invitationAccepted:
            return "\(name) accepted the invitation"
        case .invitationRejected:
            return "\(name) rejected the invitation"
        case .invitationRevoked:
            return "\(name)'s invitation was revoked"
        case .knocked:
            return "\(name) requested to join"
        case .knockAccepted:
            return "\(name)'s join request was accepted"
        case .knockRetracted:
            return "\(name) retracted their join request"
        case .knockDenied:
            return "\(name)'s join request was denied"
        case .none, .error, .notImplemented:
            return "\(name) membership changed"
        }
    }

    /// Returns a human-readable description for a profile change event.
    static func profileChangeDescription(
        displayName: String?,
        prevDisplayName: String?,
        avatarUrl: String?,
        prevAvatarUrl: String?
    ) -> String {
        let nameChanged = displayName != prevDisplayName
        let avatarChanged = avatarUrl != prevAvatarUrl

        if nameChanged, let prev = prevDisplayName, let new = displayName {
            if avatarChanged {
                return "\(prev) changed their name to \(new) and updated their avatar"
            }
            return "\(prev) changed their name to \(new)"
        } else if nameChanged, let new = displayName {
            if avatarChanged {
                return "\(new) set their name and updated their avatar"
            }
            return "\(new) set their display name"
        } else if nameChanged, let prev = prevDisplayName {
            return "\(prev) removed their display name"
        } else if avatarChanged {
            let name = displayName ?? prevDisplayName ?? "A user"
            if avatarUrl != nil {
                return "\(name) updated their avatar"
            }
            return "\(name) removed their avatar"
        }

        let name = displayName ?? prevDisplayName ?? "A user"
        return "\(name) updated their profile"
    }

    // swiftlint:disable cyclomatic_complexity
    /// Returns a human-readable description for a room state change event.
    static func stateEventDescription(_ state: OtherState) -> String {
    // swiftlint:enable cyclomatic_complexity
        switch state {
        case .roomName(let name):
            if let name, !name.isEmpty {
                return "Room name changed to \(name)"
            }
            return "Room name was removed"
        case .roomTopic(let topic):
            if let topic, !topic.isEmpty {
                return "Room topic was changed"
            }
            return "Room topic was removed"
        case .roomAvatar:
            return "Room avatar was changed"
        case .roomCreate:
            return "Room was created"
        case .roomEncryption:
            return "Encryption was enabled"
        case .roomHistoryVisibility:
            return "History visibility was changed"
        case .roomJoinRules:
            return "Join rules were changed"
        case .roomPinnedEvents:
            return "Pinned messages were updated"
        case .roomGuestAccess:
            return "Guest access was changed"
        case .roomServerAcl:
            return "Server access control was updated"
        case .roomTombstone:
            return "This room has been replaced"
        case .roomCanonicalAlias:
            return "Room address was changed"
        case .roomAliases:
            return "Room aliases were updated"
        case .roomThirdPartyInvite(let displayName):
            if let displayName {
                return "\(displayName) was invited via a third-party service"
            }
            return "A third-party invitation was sent"
        case .roomPowerLevels:
            return "Permissions were changed"
        case .spaceChild:
            return "Space children were updated"
        case .spaceParent:
            return "Space parent was changed"
        case .policyRuleRoom, .policyRuleServer, .policyRuleUser:
            return "A moderation policy was updated"
        case .custom:
            return "Room settings were updated"
        }
    }
}
