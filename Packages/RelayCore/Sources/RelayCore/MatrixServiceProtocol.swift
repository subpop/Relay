import AppKit
import SwiftUI

// MARK: - Shared Enums

public enum AuthState: Equatable, Sendable {
    case unknown
    case loggedOut
    case loggingIn
    case loggedIn(userId: String)
    case error(String)
}

public enum SyncState: Equatable, Sendable {
    case idle
    case syncing
    case running
    case error
}

public enum DefaultNotificationMode: Sendable, Equatable, CaseIterable {
    case allMessages
    case mentionsAndKeywordsOnly
    case mute

    public var label: String {
        switch self {
        case .allMessages: "All Messages"
        case .mentionsAndKeywordsOnly: "Mentions and Keywords Only"
        case .mute: "Mute"
        }
    }
}

// MARK: - Protocol

@MainActor
public protocol MatrixServiceProtocol: AnyObject, Observable {
    var authState: AuthState { get }
    var syncState: SyncState { get }
    var rooms: [RoomSummary] { get }
    var isSyncing: Bool { get }

    func restoreSession() async
    func login(username: String, password: String, homeserver: String) async
    func logout() async
    func userId() -> String?
    func avatarThumbnail(mxcURL: String, size: CGFloat) async -> NSImage?
    func makeRoomDetailViewModel(roomId: String) -> (any RoomDetailViewModelProtocol)?
    func joinRoom(idOrAlias: String) async throws
    func createRoom(name: String, topic: String?, isPublic: Bool) async throws -> String
    func leaveRoom(id: String) async throws
    func searchDirectory(query: String) async throws -> [DirectoryRoom]
    func markAsRead(roomId: String, sendPublicReceipt: Bool) async
    func sendTypingNotice(roomId: String, isTyping: Bool) async
    func roomDetails(roomId: String) async -> RoomDetails?
    func mediaContent(mxcURL: String) async -> Data?
    func mediaThumbnail(mxcURL: String, width: UInt64, height: UInt64) async -> Data?
    func userDisplayName() async -> String?
    func setDisplayName(_ name: String) async throws
    func userAvatarURL() async -> String?

    // MARK: Devices & Verification
    func getDevices() async throws -> [DeviceInfo]
    func isCurrentSessionVerified() async -> Bool
    func encryptionState() async -> EncryptionStatus
    func makeSessionVerificationViewModel() async throws -> (any SessionVerificationViewModelProtocol)?

    // MARK: Notification Settings (synced via push rules)
    func getDefaultNotificationMode(isOneToOne: Bool) async throws -> DefaultNotificationMode
    func setDefaultNotificationMode(isOneToOne: Bool, mode: DefaultNotificationMode) async throws
    func isCallNotificationEnabled() async throws -> Bool
    func setCallNotificationEnabled(_ enabled: Bool) async throws
    func isInviteNotificationEnabled() async throws -> Bool
    func setInviteNotificationEnabled(_ enabled: Bool) async throws
    func isRoomMentionEnabled() async throws -> Bool
    func setRoomMentionEnabled(_ enabled: Bool) async throws
    func isUserMentionEnabled() async throws -> Bool
    func setUserMentionEnabled(_ enabled: Bool) async throws
}

// MARK: - Environment Key

private struct MatrixServiceKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue: any MatrixServiceProtocol = PlaceholderMatrixService()
}

public extension EnvironmentValues {
    var matrixService: any MatrixServiceProtocol {
        get { self[MatrixServiceKey.self] }
        set { self[MatrixServiceKey.self] = newValue }
    }
}

@Observable
private final class PlaceholderMatrixService: MatrixServiceProtocol {
    var authState: AuthState = .unknown
    var syncState: SyncState = .idle
    var rooms: [RoomSummary] = []
    var isSyncing: Bool { false }
    func restoreSession() async {}
    func login(username: String, password: String, homeserver: String) async {}
    func logout() async {}
    func userId() -> String? { nil }
    func avatarThumbnail(mxcURL: String, size: CGFloat) async -> NSImage? { nil }
    func makeRoomDetailViewModel(roomId: String) -> (any RoomDetailViewModelProtocol)? { nil }
    func joinRoom(idOrAlias: String) async throws {}
    func createRoom(name: String, topic: String?, isPublic: Bool) async throws -> String { "" }
    func leaveRoom(id: String) async throws {}
    func searchDirectory(query: String) async throws -> [DirectoryRoom] { [] }
    func markAsRead(roomId: String, sendPublicReceipt: Bool) async {}
    func sendTypingNotice(roomId: String, isTyping: Bool) async {}
    func roomDetails(roomId: String) async -> RoomDetails? { nil }
    func mediaContent(mxcURL: String) async -> Data? { nil }
    func mediaThumbnail(mxcURL: String, width: UInt64, height: UInt64) async -> Data? { nil }
    func userDisplayName() async -> String? { nil }
    func setDisplayName(_ name: String) async throws {}
    func userAvatarURL() async -> String? { nil }
    func getDevices() async throws -> [DeviceInfo] { [] }
    func isCurrentSessionVerified() async -> Bool { false }
    func encryptionState() async -> EncryptionStatus { EncryptionStatus() }
    func makeSessionVerificationViewModel() async throws -> (any SessionVerificationViewModelProtocol)? { nil }
    func getDefaultNotificationMode(isOneToOne: Bool) async throws -> DefaultNotificationMode { .mentionsAndKeywordsOnly }
    func setDefaultNotificationMode(isOneToOne: Bool, mode: DefaultNotificationMode) async throws {}
    func isCallNotificationEnabled() async throws -> Bool { true }
    func setCallNotificationEnabled(_ enabled: Bool) async throws {}
    func isInviteNotificationEnabled() async throws -> Bool { true }
    func setInviteNotificationEnabled(_ enabled: Bool) async throws {}
    func isRoomMentionEnabled() async throws -> Bool { true }
    func setRoomMentionEnabled(_ enabled: Bool) async throws {}
    func isUserMentionEnabled() async throws -> Bool { true }
    func setUserMentionEnabled(_ enabled: Bool) async throws {}
}
