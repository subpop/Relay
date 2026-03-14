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

    public let id: String
    public let senderID: String
    public var senderDisplayName: String?
    public var senderAvatarURL: String?
    public var body: String
    public var timestamp: Date
    public var isOutgoing: Bool
    public var kind: Kind

    public init(
        id: String,
        senderID: String,
        senderDisplayName: String? = nil,
        senderAvatarURL: String? = nil,
        body: String,
        timestamp: Date,
        isOutgoing: Bool,
        kind: Kind = .text
    ) {
        self.id = id
        self.senderID = senderID
        self.senderDisplayName = senderDisplayName
        self.senderAvatarURL = senderAvatarURL
        self.body = body
        self.timestamp = timestamp
        self.isOutgoing = isOutgoing
        self.kind = kind
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
