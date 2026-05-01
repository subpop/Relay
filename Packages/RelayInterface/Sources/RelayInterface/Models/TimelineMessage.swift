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

/// A single message (or event) within a room's timeline.
///
/// ``TimelineMessage`` is the primary model used by the UI to render chat bubbles. It
/// supports text, emote, media, and special event types, and carries associated metadata
/// such as reactions, reply context, and highlight state.
public struct TimelineMessage: Identifiable, Sendable, Equatable {
    /// The delivery state of an outgoing message.
    public enum SendState: Sendable, Equatable {
        /// The message has not been sent to the server yet (local echo).
        case notSentYet
        /// The message failed to send. The associated value is a human-readable reason.
        case sendingFailed(String)
        /// The message was successfully delivered to the server.
        case sent
    }

    /// The content type of a timeline message.
    public enum Kind: Sendable, Equatable {
        /// A regular text message (optionally with Markdown formatting).
        case text
        /// An emote action (displayed as "* username does something").
        case emote
        /// A notice or system message (non-interactive informational text).
        case notice
        /// An image attachment.
        case image
        /// A video attachment.
        case video
        /// An audio attachment.
        case audio
        /// A generic file attachment.
        case file
        /// A shared geographic location.
        case location
        /// A sticker image.
        case sticker
        /// A poll event.
        case poll
        /// A message that has been deleted (redacted) by a user or moderator.
        case redacted
        /// A message that could not be decrypted (missing encryption keys).
        case encrypted
        /// Any other unsupported or unrecognized event type.
        case other
        /// A live shared geographic location.
        case liveLocation
        /// A room membership change (user joined, left, was kicked, banned, invited, etc.).
        case membership
        /// A profile change (display name or avatar update).
        case profileChange
        /// A room state change (room name, topic, avatar, encryption, join rules, etc.).
        case stateEvent
    }

    /// A group of emoji reactions attached to a message, aggregated by reaction key.
    public struct ReactionGroup: Sendable, Equatable, Identifiable {
        /// The stable identifier for this reaction group, derived from ``key``.
        public var id: String { key }

        /// The emoji or text key for this reaction (e.g. `"👍"` or `"❤️"`).
        public let key: String

        /// The total number of users who sent this reaction.
        public let count: Int

        /// The Matrix user IDs of all senders of this reaction.
        public let senderIDs: [String]

        /// Whether the current user has sent this particular reaction.
        public let highlightedByCurrentUser: Bool

        /// Creates a new ``ReactionGroup`` value.
        ///
        /// - Parameters:
        ///   - key: The emoji or text key for the reaction.
        ///   - count: The number of senders.
        ///   - senderIDs: The user IDs of all senders.
        ///   - highlightedByCurrentUser: Whether the current user reacted with this key.
        nonisolated public init(key: String, count: Int, senderIDs: [String], highlightedByCurrentUser: Bool) {
            self.key = key
            self.count = count
            self.senderIDs = senderIDs
            self.highlightedByCurrentUser = highlightedByCurrentUser
        }
    }

    /// Context about the parent message when this message is a reply.
    public struct ReplyDetail: Sendable, Equatable {
        /// The event ID of the message being replied to.
        public let eventID: String

        /// The Matrix user ID of the sender of the original message.
        public let senderID: String

        /// The display name of the original sender, if known.
        public var senderDisplayName: String?

        /// The text body of the original message.
        public let body: String

        /// The HTML-formatted body of the original message, if available.
        public let formattedBody: String?

        /// Creates a new ``ReplyDetail`` value.
        ///
        /// - Parameters:
        ///   - eventID: The event ID of the original message.
        ///   - senderID: The user ID of the original sender.
        ///   - senderDisplayName: The display name of the original sender.
        ///   - body: The body text of the original message.
        ///   - formattedBody: The HTML-formatted body, if available.
        nonisolated public init(
            eventID: String,
            senderID: String,
            senderDisplayName: String? = nil,
            body: String,
            formattedBody: String? = nil
        ) {
            self.eventID = eventID
            self.senderID = senderID
            self.senderDisplayName = senderDisplayName
            self.body = body
            self.formattedBody = formattedBody
        }

        /// The best available display name for the original sender, falling back to the user ID.
        nonisolated public var displayName: String {
            senderDisplayName ?? senderID
        }
    }

    /// Metadata about a media attachment (image, video, audio, or file) associated with a message.
    public struct MediaInfo: Sendable, Equatable {
        /// The `mxc://` URL pointing to the media content on the homeserver.
        public var mxcURL: String

        /// A JSON-serialized representation of the media source, preserving encryption metadata.
        ///
        /// For encrypted media, this contains the encryption keys, IV, and hashes needed to
        /// decrypt the downloaded content. For unencrypted media, this may be `nil` (the
        /// ``mxcURL`` alone is sufficient).
        public var mediaSourceJSON: String?

        /// The original filename of the uploaded media.
        public var filename: String

        /// The MIME type of the media (e.g. `"image/jpeg"`), if known.
        public var mimetype: String?

        /// The width of the media in pixels, if applicable.
        public var width: UInt64?

        /// The height of the media in pixels, if applicable.
        public var height: UInt64?

        /// The file size in bytes, if known.
        public var size: UInt64?

        /// An optional text caption attached to the media.
        public var caption: String?

        /// The duration of the media in seconds, if applicable (audio/video).
        public var duration: TimeInterval?

        /// Creates a new ``MediaInfo`` value.
        ///
        /// - Parameters:
        ///   - mxcURL: The `mxc://` URL for the media content.
        ///   - mediaSourceJSON: The JSON-serialized media source with encryption metadata.
        ///   - filename: The original filename.
        ///   - mimetype: The MIME type of the media.
        ///   - width: The width in pixels.
        ///   - height: The height in pixels.
        ///   - size: The file size in bytes.
        ///   - caption: An optional text caption.
        ///   - duration: The duration in seconds (audio/video).
        nonisolated public init(
            mxcURL: String,
            mediaSourceJSON: String? = nil,
            filename: String,
            mimetype: String? = nil,
            width: UInt64? = nil,
            height: UInt64? = nil,
            size: UInt64? = nil,
            caption: String? = nil,
            duration: TimeInterval? = nil
        ) {
            self.mxcURL = mxcURL
            self.mediaSourceJSON = mediaSourceJSON
            self.filename = filename
            self.mimetype = mimetype
            self.width = width
            self.height = height
            self.size = size
            self.caption = caption
            self.duration = duration
        }
    }

    /// A stable, opaque identifier for this message that remains constant across the
    /// local echo → server confirmation transition. Derived from the SDK's `uniqueId()`.
    ///
    /// Use this value (via ``Identifiable/id``) for table diffing, SwiftUI identity,
    /// and any purpose that requires a stable identity. For SDK operations that require
    /// an event or transaction ID, use ``eventID`` instead.
    public let id: String

    /// The Matrix event ID (prefixed with `$`) or transaction ID for this message.
    ///
    /// Use this value when calling SDK methods that require an ``EventOrTransactionId``
    /// (edit, redact, react, pin, send read receipt). For identity and diffing, use
    /// ``id`` instead.
    public let eventID: String

    /// The Matrix user ID of the sender (e.g. `"@alice:matrix.org"`).
    public let senderID: String

    /// The display name of the sender, if available.
    public var senderDisplayName: String?

    /// The `mxc://` URL of the sender's avatar, if available.
    public var senderAvatarURL: String?

    /// The text body of the message (may contain Markdown formatting).
    public var body: String

    /// The HTML-formatted body of the message, when the sender used `org.matrix.custom.html` format.
    ///
    /// When non-nil, the UI should prefer rendering this over ``body``, falling back to ``body``
    /// only when HTML parsing fails or the format is unsupported.
    public var formattedBody: String?

    /// The time at which this message was sent.
    public var timestamp: Date

    /// Whether this message was sent by the current user.
    public var isOutgoing: Bool

    /// The content type of this message.
    public var kind: Kind

    /// Media attachment metadata, present when ``kind`` is `.image`, `.video`, `.audio`, or `.file`.
    public var mediaInfo: MediaInfo?

    /// The aggregated emoji reactions on this message.
    public var reactions: [ReactionGroup]

    /// Whether this message mentions the current user (used for visual highlighting).
    public var isHighlighted: Bool

    /// Reply context, present when this message is a reply to another message.
    public var replyDetail: ReplyDetail?

    /// Whether this message has been edited since it was originally sent.
    public var isEdited: Bool

    /// The delivery state of this message, if it is an outgoing local echo.
    ///
    /// `nil` for incoming messages and outgoing messages that have already been
    /// confirmed by the server (i.e. they have an event ID rather than a
    /// transaction ID). When non-nil, the UI displays a sending indicator
    /// or error badge next to the message.
    public var sendState: SendState?

    /// Creates a new ``TimelineMessage`` value.
    ///
    /// - Parameters:
    ///   - id: The stable unique identifier (from the SDK's `uniqueId()`).
    ///   - eventID: The Matrix event ID or transaction ID for SDK operations.
    ///     Defaults to `id` when not provided (e.g. in previews).
    ///   - senderID: The sender's Matrix user ID.
    ///   - senderDisplayName: The sender's display name.
    ///   - senderAvatarURL: The sender's avatar URL.
    ///   - body: The message body text.
    ///   - formattedBody: The HTML-formatted body, if available.
    ///   - timestamp: The time the message was sent.
    ///   - isOutgoing: Whether the current user sent this message.
    ///   - kind: The content type. Defaults to `.text`.
    ///   - mediaInfo: Media attachment metadata, if applicable.
    ///   - reactions: Aggregated reactions. Defaults to an empty array.
    ///   - isHighlighted: Whether the message mentions the current user.
    ///   - replyDetail: Reply context, if this is a reply.
    ///   - isEdited: Whether the message has been edited. Defaults to `false`.
    ///   - sendState: The delivery state for outgoing messages. Defaults to `nil`.
    nonisolated public init(
        id: String,
        eventID: String? = nil,
        senderID: String,
        senderDisplayName: String? = nil,
        senderAvatarURL: String? = nil,
        body: String,
        formattedBody: String? = nil,
        timestamp: Date,
        isOutgoing: Bool,
        kind: Kind = .text,
        mediaInfo: MediaInfo? = nil,
        reactions: [ReactionGroup] = [],
        isHighlighted: Bool = false,
        replyDetail: ReplyDetail? = nil,
        isEdited: Bool = false,
        sendState: SendState? = nil
    ) {
        self.id = id
        self.eventID = eventID ?? id
        self.senderID = senderID
        self.senderDisplayName = senderDisplayName
        self.senderAvatarURL = senderAvatarURL
        self.body = body
        self.formattedBody = formattedBody
        self.timestamp = timestamp
        self.isOutgoing = isOutgoing
        self.kind = kind
        self.mediaInfo = mediaInfo
        self.reactions = reactions
        self.isHighlighted = isHighlighted
        self.replyDetail = replyDetail
        self.isEdited = isEdited
        self.sendState = sendState
    }

    /// The best available display name for the sender, falling back to the Matrix user ID.
    nonisolated public var displayName: String {
        senderDisplayName ?? senderID
    }

    /// The message timestamp formatted as a short time string (e.g. `"2:30 PM"`).
    nonisolated public var formattedTime: String {
        timestamp.formatted(date: .omitted, time: .shortened)
    }

    /// Whether this message is a non-text type that requires special rendering (media, redacted, encrypted, etc.).
    nonisolated public var isSpecialType: Bool {
        switch kind {
        case .text, .emote, .notice: false
        case .membership, .profileChange, .stateEvent: false
        default: true
        }
    }

    /// Whether this item represents a system event (membership change, profile update, or room state change)
    /// rather than a user-authored message.
    nonisolated public var isSystemEvent: Bool {
        switch kind {
        case .membership, .profileChange, .stateEvent: true
        default: false
        }
    }
}
