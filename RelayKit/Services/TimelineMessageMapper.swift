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

    // MARK: - Extracted Content

    /// The result of extracting content from an `EventTimelineItem`.
    private struct ExtractedContent {
        var body: String
        var kind: TimelineMessage.Kind
        var formattedBody: String?
        var isEdited: Bool
    }

    // swiftlint:disable function_body_length cyclomatic_complexity
    /// Extracts the body, kind, and formatted body from an event's content.
    ///
    /// Returns `nil` for unsupported content types (e.g. call invites, encryption keys).
    nonisolated private static func extractContent(from event: EventTimelineItem) -> ExtractedContent? {
    // swiftlint:enable function_body_length cyclomatic_complexity
        let body: String
        let kind: TimelineMessage.Kind
        var formattedBody: String?
        var isEdited = false

        switch event.content {
        case .msgLike(let msgLikeContent):
            switch msgLikeContent.kind {
            case .message(let messageContent):
                isEdited = messageContent.isEdited
                switch messageContent.msgType {
                case .text(let textContent):
                    body = textContent.body
                    kind = .text
                    if case .html = textContent.formatted?.format {
                        formattedBody = textContent.formatted?.body
                    }
                case .emote(let emoteContent):
                    body = emoteContent.body
                    kind = .emote
                    if case .html = emoteContent.formatted?.format {
                        formattedBody = emoteContent.formatted?.body
                    }
                case .notice(let noticeContent):
                    body = noticeContent.body
                    kind = .notice
                    if case .html = noticeContent.formatted?.format {
                        formattedBody = noticeContent.formatted?.body
                    }
                case .image(let imageContent):
                    body = imageContent.caption ?? "Image"
                    kind = .image(.init(
                        mxcURL: imageContent.source.url(),
                        mediaSourceJSON: imageContent.source.toJson(),
                        filename: imageContent.filename,
                        mimetype: imageContent.info?.mimetype,
                        width: imageContent.info?.width,
                        height: imageContent.info?.height,
                        size: imageContent.info?.size,
                        caption: imageContent.caption
                    ))
                case .video(let videoContent):
                    body = videoContent.caption ?? videoContent.filename
                    kind = .video(.init(
                        mxcURL: videoContent.source.url(),
                        mediaSourceJSON: videoContent.source.toJson(),
                        filename: videoContent.filename,
                        mimetype: videoContent.info?.mimetype,
                        width: videoContent.info?.width,
                        height: videoContent.info?.height,
                        size: videoContent.info?.size,
                        caption: videoContent.caption,
                        duration: videoContent.info?.duration
                    ))
                case .audio(let audioContent):
                    body = audioContent.caption ?? audioContent.filename
                    kind = .audio(.init(
                        mxcURL: audioContent.source.url(),
                        mediaSourceJSON: audioContent.source.toJson(),
                        filename: audioContent.filename,
                        mimetype: audioContent.info?.mimetype,
                        size: audioContent.info?.size,
                        caption: audioContent.caption,
                        duration: audioContent.info?.duration
                    ))
                case .file(let fileContent):
                    body = fileContent.caption ?? fileContent.filename
                    kind = .file(.init(
                        mxcURL: fileContent.source.url(),
                        mediaSourceJSON: fileContent.source.toJson(),
                        filename: fileContent.filename,
                        mimetype: fileContent.info?.mimetype,
                        size: fileContent.info?.size,
                        caption: fileContent.caption
                    ))
                case .location:
                    body = "Location"
                    kind = .location
                case .gallery:
                    body = "Gallery"
                    kind = .other
                case .other:
                    body = "Message"
                    kind = .other
                }
            case .sticker(let stickerBody, let stickerInfo, let stickerSource):
                body = stickerBody
                kind = .sticker(.init(
                    mxcURL: stickerSource.url(),
                    mediaSourceJSON: stickerSource.toJson(),
                    filename: stickerBody,
                    mimetype: stickerInfo.mimetype,
                    width: stickerInfo.width,
                    height: stickerInfo.height,
                    size: stickerInfo.size
                ))
            case .poll:
                body = "Poll"
                kind = .poll
            case .redacted:
                body = "This message was deleted"
                kind = .redacted
            case .unableToDecrypt:
                body = "Waiting for encryption key"
                kind = .encrypted
            case .other:
                return nil
            case .liveLocation:
                body = "Live location"
                kind = .liveLocation
            }
        case .roomMembership(let userId, let userDisplayName, let change, _):
            let name = userDisplayName ?? userId
            let attributed = membershipDescription(name: name, userId: userId, change: change)
            body = String(attributed.characters)
            kind = .membership(attributed)
        case .profileChange(let displayName, let prevDisplayName, let avatarUrl, let prevAvatarUrl):
            let senderInfo = extractSenderInfo(event)
            let attributed = profileChangeDescription(
                displayName: displayName,
                prevDisplayName: prevDisplayName,
                avatarUrl: avatarUrl,
                prevAvatarUrl: prevAvatarUrl,
                senderName: senderInfo.displayName ?? event.sender,
                userId: event.sender
            )
            body = String(attributed.characters)
            kind = .profileChange(attributed)
        case .state(let stateKey, let content):
            let (stateBody, stateKind) = describeStateEvent(
                content,
                stateKey: stateKey,
                senderDisplayName: {
                    if case .ready(let name, _, _) = event.senderProfile { return name }
                    return nil
                }(),
                senderId: event.sender
            )
            guard let stateBody else { return nil }
            body = stateBody
            kind = stateKind
        default:
            return nil
        }

        return ExtractedContent(
            body: body, kind: kind,
            formattedBody: formattedBody, isEdited: isEdited
        )
    }

    /// Extracts the sender display name and avatar URL from an event's sender profile.
    nonisolated private static func extractSenderInfo(
        _ event: EventTimelineItem
    ) -> (displayName: String?, avatarURL: String?) {
        switch event.senderProfile {
        case .ready(let name, _, let url): (name, url)
        default: (nil, nil)
        }
    }

    /// Extracts the event ID or transaction ID as a stable string identifier.
    nonisolated private static func extractEventId(_ event: EventTimelineItem) -> String {
        switch event.eventOrTransactionId {
        case .eventId(let id): id
        case .transactionId(let id): id
        }
    }

    /// Extracts reactions, highlight status, reply detail, and thread root from
    /// a message-like event's content.
    nonisolated private func extractReactionsAndContext(
        from event: EventTimelineItem,
        body: String
    ) -> (
        reactions: [TimelineMessage.ReactionGroup],
        isHighlighted: Bool,
        replyDetail: TimelineMessage.ReplyDetail?,
        hasUnresolvedReply: Bool,
        threadRootEventID: String?
    ) {
        guard case .msgLike(let ml) = event.content else {
            return ([], false, nil, false, nil)
        }

        let reactions = ml.reactions.map { reaction in
            TimelineMessage.ReactionGroup(
                key: reaction.key,
                count: reaction.senders.count,
                senderIDs: reaction.senders.map(\.senderId),
                highlightedByCurrentUser: reaction.senders.contains { $0.senderId == currentUserId }
            )
        }

        var isHighlighted = false
        if !event.isOwn {
            if let userId = currentUserId,
               case .message(let mc) = ml.kind,
               let mentions = mc.mentions {
                isHighlighted = mentions.userIds.contains(userId) || mentions.room
            }
            if !isHighlighted {
                isHighlighted = HighlightMatcher.bodyMatchesHighlightRules(
                    body, currentUserId: currentUserId, keywords: notificationKeywords
                )
            }
        }

        var replyDetail: TimelineMessage.ReplyDetail?
        var hasUnresolvedReply = false
        if let replyTo = ml.inReplyTo {
            let replyEventId = replyTo.eventId()
            switch replyTo.event() {
            case .ready(let content, let sender, let senderProfile, _, _):
                let replyDisplayName: String? =
                    if case .ready(let name, _, _) = senderProfile { name } else { nil }
                let replyBody: String
                var replyFormattedBody: String?
                var replyImageURL: String?
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
                    case .image(let ic):
                        replyImageURL = ic.source.url()
                    default:
                        break
                    }
                } else {
                    replyBody = "Message"
                }
                replyDetail = .init(
                    eventID: replyEventId, senderID: sender,
                    senderDisplayName: replyDisplayName, body: replyBody,
                    formattedBody: replyFormattedBody,
                    imageURL: replyImageURL
                )
            case .pending:
                replyDetail = .init(eventID: replyEventId, senderID: "", senderDisplayName: nil, body: "")
                hasUnresolvedReply = true
            case .unavailable:
                replyDetail = .init(eventID: replyEventId, senderID: "", senderDisplayName: nil, body: "")
                hasUnresolvedReply = true
            case .error:
                replyDetail = .init(eventID: replyEventId, senderID: "", senderDisplayName: nil, body: "")
            }
        }

        return (reactions, isHighlighted, replyDetail, hasUnresolvedReply, ml.threadRoot)
    }

    // MARK: - Mapping Methods

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
        var result: [TimelineMessage] = []
        var pendingReplyFetchIds: Set<String> = []

        for item in items {
            guard let event = item.asEvent() else { continue }
            guard let content = Self.extractContent(from: event) else { continue }

            let context = extractReactionsAndContext(from: event, body: content.body)
            let (displayName, avatarURL) = Self.extractSenderInfo(event)
            let ts = Date(timeIntervalSince1970: TimeInterval(event.timestamp) / 1000)
            let stableId = item.uniqueId().id
            let eventId = Self.extractEventId(event)

            if context.hasUnresolvedReply {
                pendingReplyFetchIds.insert(eventId)
            }

            result.append(TimelineMessage(
                id: stableId,
                eventID: eventId,
                senderID: event.sender,
                senderDisplayName: displayName,
                senderAvatarURL: avatarURL,
                body: content.body,
                formattedBody: content.formattedBody,
                timestamp: ts,
                isOutgoing: event.isOwn,
                kind: content.kind,
                reactions: context.reactions,
                isHighlighted: context.isHighlighted,
                highlightedMentionUserId: context.isHighlighted ? currentUserId : nil,
                highlightKeywords: context.isHighlighted ? notificationKeywords : [],
                replyDetail: context.replyDetail,
                isEdited: content.isEdited,
                sendState: Self.mapSendState(event.localSendState),
                threadRootEventID: context.threadRootEventID
            ))
        }

        result = Self.deduplicateCallEvents(result)
        return MappingResult(messages: result, unresolvedReplyEventIds: pendingReplyFetchIds)
    }

    /// Maps a single SDK ``TimelineItem`` into a ``SingleItemResult``.
    ///
    /// Returns `nil` if the item is not an event or has an unsupported content type.
    /// This is the preferred entry point for surgical (per-item) mapping.
    nonisolated func mapItem(_ item: TimelineItem) -> SingleItemResult? {
        guard let event = item.asEvent() else { return nil }
        guard let content = Self.extractContent(from: event) else { return nil }

        let context = extractReactionsAndContext(from: event, body: content.body)
        let (displayName, avatarURL) = Self.extractSenderInfo(event)
        let ts = Date(timeIntervalSince1970: TimeInterval(event.timestamp) / 1000)
        let stableId = item.uniqueId().id
        let eventId = Self.extractEventId(event)

        let message = TimelineMessage(
            id: stableId,
            eventID: eventId,
            senderID: event.sender,
            senderDisplayName: displayName,
            senderAvatarURL: avatarURL,
            body: content.body,
            formattedBody: content.formattedBody,
            timestamp: ts,
            isOutgoing: event.isOwn,
            kind: content.kind,
            reactions: context.reactions,
            isHighlighted: context.isHighlighted,
            highlightedMentionUserId: context.isHighlighted ? currentUserId : nil,
            highlightKeywords: context.isHighlighted ? notificationKeywords : [],
            replyDetail: context.replyDetail,
            isEdited: content.isEdited,
            sendState: Self.mapSendState(event.localSendState),
            threadRootEventID: context.threadRootEventID
        )
        return SingleItemResult(message: message, hasUnresolvedReply: context.hasUnresolvedReply)
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
            let itemState = PerformanceSignposts.messageMapper.beginInterval(
                PerformanceSignposts.MessageMapperName.mapSingleItem
            )
            if let mapped = mapItem(item) {
                if mapped.hasUnresolvedReply {
                    pendingReplyFetchIds.insert(mapped.message.eventID)
                }
                result.append(mapped.message)
                PerformanceSignposts.messageMapper.endInterval(
                    PerformanceSignposts.MessageMapperName.mapSingleItem,
                    itemState,
                    "mapped"
                )
            } else {
                PerformanceSignposts.messageMapper.endInterval(
                    PerformanceSignposts.MessageMapperName.mapSingleItem,
                    itemState,
                    "skipped"
                )
            }
        }

        PerformanceSignposts.messageMapper.endInterval(
            PerformanceSignposts.MessageMapperName.mapIncrementally,
            mapState,
            "\(result.count) mapped, \(cacheHits) hits, \(cacheMisses) misses, \(ffiLookups) FFI lookups"
        )
        return MappingResult(messages: result, unresolvedReplyEventIds: pendingReplyFetchIds)
    }

    /// Maps a single `EventTimelineItem` into a ``TimelineMessage``, if it is a supported event.
    ///
    /// Returns `nil` for unsupported content types (e.g. call invites).
    ///
    /// - Parameters:
    ///   - event: The SDK event timeline item.
    ///   - uniqueId: The stable unique identifier from the parent ``TimelineItem``.
    ///     When mapping from an `EventTimelineItem` directly (e.g. pinned messages),
    ///     pass the event ID as a fallback since pinned messages are always server-confirmed.
    func mapEventItem(_ event: EventTimelineItem, uniqueId: String) -> TimelineMessage? {
        guard let content = Self.extractContent(from: event) else { return nil }

        let (displayName, avatarURL) = Self.extractSenderInfo(event)
        let ts = Date(timeIntervalSince1970: TimeInterval(event.timestamp) / 1000)
        let eventId = Self.extractEventId(event)

        return TimelineMessage(
            id: uniqueId,
            eventID: eventId,
            senderID: event.sender,
            senderDisplayName: displayName,
            senderAvatarURL: avatarURL,
            body: content.body,
            formattedBody: content.formattedBody,
            timestamp: ts,
            isOutgoing: event.isOwn,
            kind: content.kind,
            isEdited: content.isEdited,
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

    // MARK: - Call Event Deduplication

    /// Removes duplicate consecutive call events from the same sender.
    ///
    /// When a user ends a call, the MatrixRTC leave event (`{}` content) appears
    /// in the timeline as a second "started a call" message from the same sender.
    /// This filters out those duplicates, keeping only the first occurrence in each
    /// consecutive run.
    private static func deduplicateCallEvents(_ messages: [TimelineMessage]) -> [TimelineMessage] {
        var result: [TimelineMessage] = []
        for message in messages {
            if case .callEvent = message.kind,
               let last = result.last,
               case .callEvent = last.kind,
               last.senderID == message.senderID {
                continue
            }
            result.append(message)
        }
        return result
    }

    // MARK: - System Event Descriptions

    // swiftlint:disable cyclomatic_complexity
    /// Returns a human-readable description for a membership change event.
    ///
    /// - Parameters:
    ///   - name: The display name (or user ID) of the member.
    ///   - userId: The member's Matrix user ID, used to build `matrix.to` links.
    ///   - change: The type of membership change.
    nonisolated static func membershipDescription(
        name: String,
        userId: String? = nil,
        change: MembershipChange?
    ) -> AttributedString {
    // swiftlint:enable cyclomatic_complexity
        let linked = linkedName(name, userId: userId)
        guard let change else { return linked + plain(" membership changed") }
        switch change {
        case .joined:
            return linked + plain(" joined the room")
        case .left:
            return linked + plain(" left the room")
        case .banned:
            return linked + plain(" was banned")
        case .unbanned:
            return linked + plain(" was unbanned")
        case .kicked:
            return linked + plain(" was removed from the room")
        case .invited:
            return linked + plain(" was invited")
        case .kickedAndBanned:
            return linked + plain(" was removed and banned")
        case .invitationAccepted:
            return linked + plain(" accepted the invitation")
        case .invitationRejected:
            return linked + plain(" rejected the invitation")
        case .invitationRevoked:
            return linked + plain("'s invitation was revoked")
        case .knocked:
            return linked + plain(" requested to join")
        case .knockAccepted:
            return linked + plain("'s join request was accepted")
        case .knockRetracted:
            return linked + plain(" retracted their join request")
        case .knockDenied:
            return linked + plain("'s join request was denied")
        case .none, .error, .notImplemented:
            return linked + plain(" membership changed")
        }
    }

    /// Returns a human-readable description for a profile change event.
    ///
    /// - Parameters:
    ///   - displayName: The new display name from the event content.
    ///   - prevDisplayName: The previous display name from the event content.
    ///   - avatarUrl: The new avatar URL from the event content.
    ///   - prevAvatarUrl: The previous avatar URL from the event content.
    ///   - senderName: Fallback name from the sender profile or user ID.
    ///   - userId: The sender's Matrix user ID, used to build `matrix.to` links.
    nonisolated static func profileChangeDescription(
        displayName: String?,
        prevDisplayName: String?,
        avatarUrl: String?,
        prevAvatarUrl: String?,
        senderName: String? = nil,
        userId: String? = nil
    ) -> AttributedString {
        let nameChanged = displayName != prevDisplayName
        let avatarChanged = avatarUrl != prevAvatarUrl

        if nameChanged, let prev = prevDisplayName, let new = displayName {
            if avatarChanged {
                return linkedName(prev, userId: userId) + plain(" changed their name to ")
                    + linkedName(new, userId: userId) + plain(" and updated their avatar")
            }
            return linkedName(prev, userId: userId) + plain(" changed their name to ")
                + linkedName(new, userId: userId)
        } else if nameChanged, let new = displayName {
            if avatarChanged {
                return linkedName(new, userId: userId) + plain(" set their name and updated their avatar")
            }
            return linkedName(new, userId: userId) + plain(" set their display name")
        } else if nameChanged, let prev = prevDisplayName {
            return linkedName(prev, userId: userId) + plain(" removed their display name")
        } else if avatarChanged {
            let name = displayName ?? prevDisplayName ?? senderName ?? "A user"
            if avatarUrl != nil {
                return linkedName(name, userId: userId) + plain(" updated their avatar")
            }
            return linkedName(name, userId: userId) + plain(" removed their avatar")
        }

        let name = displayName ?? prevDisplayName ?? senderName ?? "A user"
        return linkedName(name, userId: userId) + plain(" updated their profile")
    }

    // MARK: - Attributed String Helpers

    /// Creates an `AttributedString` for a user name, optionally linking it to a
    /// `matrix.to` URL when a user ID is available.
    private nonisolated static func linkedName(_ name: String, userId: String?) -> AttributedString {
        var result = AttributedString(name)
        if let userId,
           let encoded = userId.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
           let url = URL(string: "https://matrix.to/#/\(encoded)") {
            result.link = url
        }
        return result
    }

    /// Creates a plain (unlinked) `AttributedString` from a literal string.
    private nonisolated static func plain(_ text: String) -> AttributedString {
        AttributedString(text)
    }

    /// Routes a state event to the appropriate description and message kind.
    ///
    /// Returns `nil` body for events that should be hidden (e.g. encryption key exchange).
    nonisolated static func describeStateEvent(
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
                let body = "\(name) started a call"
                return (body, .callEvent(AttributedString(body)))
            case "io.element.call.encryption_keys":
                // Internal key exchange — don't show in timeline.
                return (nil, .stateEvent(AttributedString()))
            default:
                let body = stateEventDescription(state)
                return (body, .stateEvent(AttributedString(body)))
            }
        }
        let body = stateEventDescription(state)
        return (body, .stateEvent(AttributedString(body)))
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
