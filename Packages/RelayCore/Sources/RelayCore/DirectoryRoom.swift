import Foundation

public struct DirectoryRoom: Identifiable, Hashable, Sendable {
    public var id: String { roomId }
    public let roomId: String
    public let name: String?
    public let topic: String?
    public let alias: String?
    public let avatarURL: String?
    public let memberCount: UInt64

    public init(
        roomId: String,
        name: String? = nil,
        topic: String? = nil,
        alias: String? = nil,
        avatarURL: String? = nil,
        memberCount: UInt64 = 0
    ) {
        self.roomId = roomId
        self.name = name
        self.topic = topic
        self.alias = alias
        self.avatarURL = avatarURL
        self.memberCount = memberCount
    }
}
