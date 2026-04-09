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
import os
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

    /// User-defined notification keywords. Messages whose body contains any of
    /// these keywords (case-insensitive) will be highlighted with the "@" badge.
    let notificationKeywords: [String]

    /// The result of mapping timeline items to messages.
    struct MappingResult {
        /// The ordered list of timeline messages, from oldest to newest.
        let messages: [TimelineMessage]
        /// Event IDs of messages with unresolved reply details that need fetching.
        let unresolvedReplyEventIds: Set<String>
    }

    /// The result of mapping a single timeline item to a message.
    struct SingleItemResult: Sendable {
        /// The mapped message.
        let message: TimelineMessage
        /// Whether the message has an unresolved reply that needs fetching.
        let hasUnresolvedReply: Bool
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
                            mediaSourceJSON: imageContent.source.toJson(),
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
                            mediaSourceJSON: videoContent.source.toJson(),
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
                            mediaSourceJSON: audioContent.source.toJson(),
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
                            mediaSourceJSON: fileContent.source.toJson(),
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
            case .state(let stateKey, let content):
                let (body, kind) = Self.describeStateEvent(
                    content,
                    stateKey: stateKey,
                    senderDisplayName: {
                        if case .ready(let name, _, _) = event.senderProfile { return name }
                        return nil
                    }(),
                    senderId: event.sender
                )
                // Skip noisy internal events (encryption key exchange).
                guard let body else { continue }
                msgBody = body
                msgKind = kind
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

                if !event.isOwn {
                    // Check structured mention data from the event content.
                    if let userId = currentUserId,
                       case .message(let mc) = ml.kind,
                       let mentions = mc.mentions {
                        isHighlighted = mentions.userIds.contains(userId) || mentions.room
                    }
                    // Fall back to client-side body matching for user ID and keywords.
                    if !isHighlighted {
                        isHighlighted = HighlightMatcher.bodyMatchesHighlightRules(
                            msgBody,
                            currentUserId: currentUserId,
                            keywords: notificationKeywords
                        )
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
                isEdited: msgIsEdited,
                sendState: Self.mapSendState(event.localSendState)
            ))
        }

        return MappingResult(messages: result, unresolvedReplyEventIds: pendingReplyFetchIds)
    }

    /// Maps a single SDK ``TimelineItem`` into a ``SingleItemResult``.
    ///
    /// Returns `nil` if the item is not an event or has an unsupported content type.
    /// This is the preferred entry point for surgical (per-item) mapping.
    nonisolated func mapItem(_ item: TimelineItem) -> SingleItemResult? {
        guard let event = item.asEvent() else { return nil }

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
                        mediaSourceJSON: imageContent.source.toJson(),
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
                        mediaSourceJSON: videoContent.source.toJson(),
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
                        mediaSourceJSON: audioContent.source.toJson(),
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
                        mediaSourceJSON: fileContent.source.toJson(),
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
                if !isHighlighted {
                    isHighlighted = notificationKeywords.contains { msgBody.localizedStandardContains($0) }
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

        let message = TimelineMessage(
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
            isEdited: msgIsEdited,
            sendState: Self.mapSendState(event.localSendState)
        )
        return SingleItemResult(message: message, hasUnresolvedReply: hasUnresolvedReply)
    }

    /// Maps an array of SDK timeline items into messages, reusing cached messages
    /// for items at unchanged indices.
    ///
    /// - Parameters:
    ///   - items: The full timeline items array.
    ///   - itemIDs: Pre-extracted event/transaction IDs parallel to `items`,
    ///     maintained by `TimelineViewModel.applyDiffs` to avoid FFI calls
    ///     during cache lookups. `nil` entries represent non-event items.
    ///   - changedIndices: Indices that were modified by the latest diff batch.
    ///     Pass `nil` to remap all items (equivalent to a reset).
    ///   - existingMessages: Previously mapped messages keyed by event/transaction ID,
    ///     used to avoid remapping unchanged items.
    /// - Returns: A ``MappingResult`` with the ordered messages and unresolved reply IDs.
    @concurrent
    func mapItemsIncrementally(
        _ items: [TimelineItem],
        itemIDs: [String?],
        changedIndices: IndexSet?,
        existingMessages: [String: TimelineMessage]
    ) async -> MappingResult {
        let mapState = PerformanceSignposts.messageMapper.beginInterval(
            PerformanceSignposts.MessageMapperName.mapIncrementally,
            "\(items.count) items, \(changedIndices?.count ?? -1) changed"
        )

        var result: [TimelineMessage] = []
        result.reserveCapacity(items.count)
        var pendingReplyFetchIds: Set<String> = []
        var cacheHits = 0
        var cacheMisses = 0
        var ffiLookups = 0

        for index in items.indices {
            let item = items[index]

            // If we have a known set of changed indices and this index isn't
            // in it, reuse the cached message via the pre-extracted ID — no
            // FFI call needed.
            if let changedIndices, !changedIndices.contains(index) {
                if let itemID = itemIDs[index],
                   let cached = existingMessages[itemID] {
                    cacheHits += 1
                    result.append(cached)
                    continue
                }
                cacheMisses += 1
            }

            // Map the item from scratch (involves FFI calls).
            ffiLookups += 1
            if let mapped = mapItem(item) {
                if mapped.hasUnresolvedReply {
                    pendingReplyFetchIds.insert(mapped.message.id)
                }
                result.append(mapped.message)
            }
        }

        PerformanceSignposts.messageMapper.endInterval(
            PerformanceSignposts.MessageMapperName.mapIncrementally,
            mapState,
            "\(result.count) mapped, \(cacheHits) hits, \(cacheMisses) misses, \(ffiLookups) FFI lookups"
        )
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
                        mediaSourceJSON: imageContent.source.toJson(),
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
                        mediaSourceJSON: videoContent.source.toJson(),
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
                        mediaSourceJSON: audioContent.source.toJson(),
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
                        mediaSourceJSON: fileContent.source.toJson(),
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
        case .state(let stateKey, let content):
            let (body, kind) = Self.describeStateEvent(
                content,
                stateKey: stateKey,
                senderDisplayName: {
                    if case .ready(let name, _, _) = event.senderProfile { return name }
                    return nil
                }(),
                senderId: event.sender
            )
            guard let body else { return nil }
            msgBody = body
            msgKind = kind
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
            isEdited: msgIsEdited,
            sendState: Self.mapSendState(event.localSendState)
        )
    }

    // MARK: - Send State Mapping

    /// Converts the SDK's ``EventSendState`` into the app's ``TimelineMessage.SendState``.
    ///
    /// Returns `nil` for events that have no local send state (i.e. remote events
    /// or confirmed local echoes whose state has been cleared by the SDK).
    nonisolated private static func mapSendState(_ sdkState: EventSendState?) -> TimelineMessage.SendState? {
        guard let sdkState else { return nil }
        switch sdkState {
        case .notSentYet:
            return .notSentYet
        case .sendingFailed(let error, _):
            return .sendingFailed(sendFailureDescription(error))
        case .sent:
            return .sent
        }
    }

    /// Returns a human-readable description for a send queue wedge error.
    nonisolated private static func sendFailureDescription(_ error: QueueWedgeError) -> String {
        switch error {
        case .insecureDevices:
            "Unverified devices in this room"
        case .identityViolations:
            "A user's verification status changed"
        case .crossVerificationRequired:
            "Session verification required"
        case .missingMediaContent:
            "Media content is no longer available"
        case .invalidMimeType(let mimeType):
            "Invalid file type: \(mimeType)"
        case .genericApiError(let msg):
            msg
        }
    }

    // MARK: - System Event Descriptions

    // swiftlint:disable cyclomatic_complexity
    /// Returns a human-readable description for a membership change event.
    nonisolated static func membershipDescription(name: String, change: MembershipChange?) -> String {
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
    nonisolated static func profileChangeDescription(
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

    /// Routes a state event to the appropriate description and message kind.
    ///
    /// Returns `nil` body for events that should be hidden (e.g. encryption key exchange).
    static func describeStateEvent(
        _ state: OtherState,
        stateKey: String,
        senderDisplayName: String?,
        senderId: String
    ) -> (body: String?, kind: TimelineMessage.Kind) {
        if case .custom(let type) = state {
            switch type {
            case "org.matrix.msc3401.call.member":
                let name = senderDisplayName ?? senderId
                // Empty state key or one starting with "_" indicates join/leave.
                // A non-empty content means joining; removal sends empty content
                // which the SDK may or may not surface — treat presence of the event as a join.
                return ("\(name) started a call", .callEvent)
            case "io.element.call.encryption_keys":
                // Internal key exchange — don't show in timeline.
                return (nil, .stateEvent)
            default:
                return (stateEventDescription(state), .stateEvent)
            }
        }
        return (stateEventDescription(state), .stateEvent)
    }

    // swiftlint:disable cyclomatic_complexity
    /// Returns a human-readable description for a room state change event.
    nonisolated static func stateEventDescription(_ state: OtherState) -> String {
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
