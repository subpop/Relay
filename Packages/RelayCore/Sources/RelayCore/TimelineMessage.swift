import Foundation

public struct TimelineMessage: Identifiable, Sendable {
    public enum Kind: Sendable, Equatable {
        case text
        case emote
        case notice
        case image
        case video
        case audio
        case file
        case location
        case sticker
        case poll
        case redacted
        case encrypted
        case other
    }

    public struct ReactionGroup: Sendable, Equatable, Identifiable {
        public var id: String { key }
        public let key: String
        public let count: Int
        public let senderIDs: [String]
        public let highlightedByCurrentUser: Bool

        public init(key: String, count: Int, senderIDs: [String], highlightedByCurrentUser: Bool) {
            self.key = key
            self.count = count
            self.senderIDs = senderIDs
            self.highlightedByCurrentUser = highlightedByCurrentUser
        }
    }

    public struct MediaInfo: Sendable, Equatable {
        public var mxcURL: String
        public var filename: String
        public var mimetype: String?
        public var width: UInt64?
        public var height: UInt64?
        public var size: UInt64?
        public var caption: String?

        public init(
            mxcURL: String,
            filename: String,
            mimetype: String? = nil,
            width: UInt64? = nil,
            height: UInt64? = nil,
            size: UInt64? = nil,
            caption: String? = nil
        ) {
            self.mxcURL = mxcURL
            self.filename = filename
            self.mimetype = mimetype
            self.width = width
            self.height = height
            self.size = size
            self.caption = caption
        }
    }

    public let id: String
    public let senderID: String
    public var senderDisplayName: String?
    public var senderAvatarURL: String?
    public var body: String
    public var timestamp: Date
    public var isOutgoing: Bool
    public var kind: Kind
    public var mediaInfo: MediaInfo?
    public var reactions: [ReactionGroup]

    public init(
        id: String,
        senderID: String,
        senderDisplayName: String? = nil,
        senderAvatarURL: String? = nil,
        body: String,
        timestamp: Date,
        isOutgoing: Bool,
        kind: Kind = .text,
        mediaInfo: MediaInfo? = nil,
        reactions: [ReactionGroup] = []
    ) {
        self.id = id
        self.senderID = senderID
        self.senderDisplayName = senderDisplayName
        self.senderAvatarURL = senderAvatarURL
        self.body = body
        self.timestamp = timestamp
        self.isOutgoing = isOutgoing
        self.kind = kind
        self.mediaInfo = mediaInfo
        self.reactions = reactions
    }

    public var displayName: String {
        senderDisplayName ?? senderID
    }

    public var formattedTime: String {
        timestamp.formatted(date: .omitted, time: .shortened)
    }

    public var isSpecialType: Bool {
        switch kind {
        case .text, .emote, .notice: false
        default: true
        }
    }
}
