import Foundation

public struct DeviceInfo: Identifiable, Sendable {
    public let id: String
    public let displayName: String?
    public let lastSeenIP: String?
    public let lastSeenTimestamp: Date?
    public let isCurrentDevice: Bool

    public init(
        id: String,
        displayName: String?,
        lastSeenIP: String? = nil,
        lastSeenTimestamp: Date? = nil,
        isCurrentDevice: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.lastSeenIP = lastSeenIP
        self.lastSeenTimestamp = lastSeenTimestamp
        self.isCurrentDevice = isCurrentDevice
    }
}
