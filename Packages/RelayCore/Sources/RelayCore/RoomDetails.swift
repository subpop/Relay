import Foundation

public struct RoomDetails: Sendable {
    public let id: String
    public let name: String
    public let topic: String?
    public let avatarURL: String?
    public let isEncrypted: Bool
    public let isPublic: Bool
    public let isDirect: Bool
    public let canonicalAlias: String?
    public let memberCount: UInt64
    public let members: [RoomMemberDetails]

    public init(
        id: String,
        name: String,
        topic: String? = nil,
        avatarURL: String? = nil,
        isEncrypted: Bool = false,
        isPublic: Bool = false,
        isDirect: Bool = false,
        canonicalAlias: String? = nil,
        memberCount: UInt64 = 0,
        members: [RoomMemberDetails] = []
    ) {
        self.id = id
        self.name = name
        self.topic = topic
        self.avatarURL = avatarURL
        self.isEncrypted = isEncrypted
        self.isPublic = isPublic
        self.isDirect = isDirect
        self.canonicalAlias = canonicalAlias
        self.memberCount = memberCount
        self.members = members
    }
}

public struct RoomMemberDetails: Identifiable, Sendable {
    public var id: String { userId }
    public let userId: String
    public let displayName: String?
    public let avatarURL: String?
    public let role: Role

    public enum Role: String, Sendable {
        case administrator
        case moderator
        case user
    }

    public init(
        userId: String,
        displayName: String? = nil,
        avatarURL: String? = nil,
        role: Role = .user
    ) {
        self.userId = userId
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.role = role
    }
}
