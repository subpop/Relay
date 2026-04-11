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

import AppKit
import SwiftUI

// MARK: - Shared Enums

/// The authentication state of the Matrix client.
public enum AuthState: Equatable, Sendable {
    /// The session state has not yet been determined (app just launched).
    case unknown
    /// No active session; the user needs to sign in.
    case loggedOut
    /// A login attempt is currently in progress.
    case loggingIn
    /// The user is authenticated. The associated value is the Matrix user ID (e.g. `"@alice:matrix.org"`).
    case loggedIn(userId: String)
    /// Authentication failed. The associated value is a human-readable error message.
    case error(String)
}

/// The synchronization state of the Matrix client with the homeserver.
public enum SyncState: Equatable, Sendable {
    /// The sync service has not been started.
    case idle
    /// The initial sync is in progress (first connection after login or restore).
    case syncing
    /// The sync service is running and continuously receiving updates.
    case running
    /// The sync service encountered an error and stopped.
    /// The associated value is a human-readable error description.
    case error(String)
}

/// The default notification mode for rooms, corresponding to Matrix push rule presets.
public enum DefaultNotificationMode: Sendable, Equatable, CaseIterable {
    /// Notify for every message in the room.
    case allMessages
    /// Notify only when the user is mentioned or a keyword matches.
    case mentionsAndKeywordsOnly
    /// Suppress all notifications from the room.
    case mute

    /// A human-readable label for display in settings UI.
    nonisolated public var label: String {
        switch self {
        case .allMessages: "All Messages"
        case .mentionsAndKeywordsOnly: "Mentions and Keywords Only"
        case .mute: "Mute"
        }
    }
}

/// The notification mode for a specific room, corresponding to Matrix push rule overrides.
public enum RoomNotificationMode: Sendable, Equatable, CaseIterable {
    /// Notify for every message in the room.
    case allMessages
    /// Notify only when the user is mentioned or a keyword matches.
    case mentionsAndKeywordsOnly
    /// Suppress all notifications from the room.
    case mute

    /// A human-readable label for display in settings UI.
    nonisolated public var label: String {
        switch self {
        case .allMessages: "All Messages"
        case .mentionsAndKeywordsOnly: "Mentions Only"
        case .mute: "Mute"
        }
    }

    /// An SF Symbol icon name suitable for display alongside the label.
    nonisolated public var icon: String {
        switch self {
        case .allMessages: "bell.fill"
        case .mentionsAndKeywordsOnly: "at"
        case .mute: "bell.slash"
        }
    }
}

// MARK: - Incoming Verification Request

/// A lightweight representation of an incoming session verification request
/// from another device, suitable for display in the UI.
public struct IncomingVerificationRequest: Sendable, Identifiable {
    /// The device ID that initiated the verification request.
    public let deviceId: String
    /// The Matrix user ID of the sender.
    public let senderId: String
    /// The flow identifier for the verification request.
    public let flowId: String

    public var id: String { flowId }

    public init(deviceId: String, senderId: String, flowId: String) {
        self.deviceId = deviceId
        self.senderId = senderId
        self.flowId = flowId
    }
}

// MARK: - Protocol

/// The central protocol for interacting with the Matrix homeserver.
///
/// ``MatrixServiceProtocol`` defines the contract that both the real ``MatrixService``
/// (backed by the Matrix Rust SDK) and preview/mock implementations conform to. It covers
/// authentication, sync, room management, media retrieval, user profile management,
/// device/session management, encryption state, and notification settings.
///
/// All requirements are `@MainActor`-isolated. Implementations must be `Observable` so
/// that SwiftUI views can react to state changes.
@MainActor
public protocol MatrixServiceProtocol: AnyObject, Observable {
    /// The current authentication state of the client.
    var authState: AuthState { get }

    /// The current synchronization state with the homeserver.
    var syncState: SyncState { get }

    /// The list of joined rooms, sorted by most recent activity.
    var rooms: [RoomSummary] { get }

    /// Whether the client is actively syncing (`syncing` or `running`).
    var isSyncing: Bool { get }

    /// Whether the initial room list has been loaded after sync started.
    ///
    /// This becomes `true` after the first successful room list fetch, allowing
    /// views to distinguish between "still loading for the first time" and
    /// "rooms loaded but the list is empty."
    var hasLoadedRooms: Bool { get }

    /// Attempts to restore a previously saved session from the keychain.
    func restoreSession() async

    /// Authenticates with the homeserver using a username and password.
    ///
    /// - Parameters:
    ///   - username: The Matrix username (local part, without `@` prefix).
    ///   - password: The account password.
    ///   - homeserver: The homeserver URL or server name.
    func login(username: String, password: String, homeserver: String) async

    /// Initiates an OAuth/OIDC login flow, using the provided closure to open the browser.
    ///
    /// The `openURL` closure receives the OIDC authorization URL and must return the
    /// callback URL after the user completes authentication. Callers typically implement
    /// this using SwiftUI's `WebAuthenticationSession` environment value.
    ///
    /// - Parameters:
    ///   - homeserver: The homeserver URL or server name.
    ///   - openURL: A closure that opens the authorization URL in a browser and returns
    ///     the callback URL.
    /// - Throws: If the homeserver doesn't support OIDC or the browser flow fails.
    func startOAuthLogin(
        homeserver: String,
        openURL: @escaping @concurrent @Sendable (URL) async throws -> URL
    ) async throws

    /// Signs out, clears the session, and resets local data.
    func logout() async

    /// Starts the background sync service if it is not already running.
    func startSyncIfNeeded()

    /// Returns the Matrix user ID of the currently authenticated user, if any.
    func userId() -> String?

    /// Downloads and returns a thumbnail of a Matrix media URL as an `NSImage`.
    ///
    /// Results are cached in memory to avoid redundant network requests.
    ///
    /// - Parameters:
    ///   - mxcURL: The `mxc://` URL of the media.
    ///   - size: The desired display size in points (the actual download is at 2x scale).
    /// - Returns: The thumbnail image, or `nil` if the download failed.
    func avatarThumbnail(mxcURL: String, size: CGFloat) async -> NSImage?

    /// Creates (or returns a cached) view model for displaying a room's message timeline.
    ///
    /// - Parameter roomId: The Matrix room identifier.
    /// - Returns: A ``TimelineViewModelProtocol`` instance, or `nil` if the room is not found.
    func makeTimelineViewModel(roomId: String) -> (any TimelineViewModelProtocol)?

    /// Joins a room by its ID or alias.
    ///
    /// - Parameter idOrAlias: A room ID (e.g. `"!abc:matrix.org"`) or alias (e.g. `"#room:matrix.org"`).
    func joinRoom(idOrAlias: String) async throws

    /// Creates a new room and returns its room ID.
    ///
    /// - Parameters:
    ///   - name: The display name for the room.
    ///   - topic: An optional topic description.
    ///   - isPublic: Whether the room should be publicly joinable. Public rooms are not encrypted.
    /// - Returns: The Matrix room ID of the newly created room.
    func createRoom(name: String, topic: String?, isPublic: Bool) async throws -> String

    /// Creates a new room with detailed options and returns its room ID.
    ///
    /// - Parameter options: The room creation parameters.
    /// - Returns: The Matrix room ID of the newly created room.
    func createRoom(options: CreateRoomOptions) async throws -> String

    /// Opens or creates a direct message room with the given user.
    ///
    /// If a DM room already exists with the specified user, its room ID is returned.
    /// Otherwise a new encrypted, private DM room is created and the user is invited.
    ///
    /// - Parameter userId: The Matrix user ID to message (e.g. `"@alice:matrix.org"`).
    /// - Returns: The Matrix room ID of the DM room.
    func createDirectMessage(userId: String) async throws -> String

    /// Creates a view model for browsing the public room directory.
    ///
    /// - Returns: A ``RoomDirectoryViewModelProtocol`` instance, or `nil` if not available.
    func makeRoomDirectoryViewModel() -> (any RoomDirectoryViewModelProtocol)?

    /// Creates a view model for previewing a room before joining.
    ///
    /// - Parameter roomId: The Matrix room identifier to preview.
    /// - Returns: A ``RoomPreviewViewModelProtocol`` instance, or `nil` if not available.
    func makeRoomPreviewViewModel(roomId: String) -> (any RoomPreviewViewModelProtocol)?

    /// Leaves a room and removes it from the local room list.
    ///
    /// - Parameter id: The Matrix room identifier.
    func leaveRoom(id: String) async throws

    /// Searches the public room directory for rooms matching the query.
    ///
    /// - Parameter query: The search string to match against room names and aliases.
    /// - Returns: A list of matching ``DirectoryRoom`` results.
    func searchDirectory(query: String) async throws -> [DirectoryRoom]

    /// Sends a read receipt for the latest message in a room.
    ///
    /// - Parameters:
    ///   - roomId: The Matrix room identifier.
    ///   - sendPublicReceipt: Whether to send a public read receipt (visible to other users).
    func markAsRead(roomId: String, sendPublicReceipt: Bool) async

    /// Returns the event ID of the user's fully-read marker (`m.fully_read`) in a room.
    ///
    /// The fully-read marker represents the furthest point the user has read up to,
    /// and is used to restore scroll position when re-opening a room.
    ///
    /// - Parameter roomId: The Matrix room identifier.
    /// - Returns: The event ID of the fully-read marker, or `nil` if unavailable.
    func fullyReadEventId(roomId: String) async -> String?

    /// Sends or clears a typing notification in a room.
    ///
    /// - Parameters:
    ///   - roomId: The Matrix room identifier.
    ///   - isTyping: `true` to indicate the user is typing, `false` to stop.
    func sendTypingNotice(roomId: String, isTyping: Bool) async

    /// Fetches the full details and member list for a room.
    ///
    /// - Parameter roomId: The Matrix room identifier.
    /// - Returns: A ``RoomDetails`` snapshot, or `nil` if the room is not found.
    func roomDetails(roomId: String) async -> RoomDetails?

    /// Fetches the joined members of a room.
    ///
    /// Unlike ``roomDetails(roomId:)``, this method iterates through all chunks
    /// returned by the SDK's member iterator so rooms with more than 200 members
    /// are fully covered.
    ///
    /// - Parameter roomId: The Matrix room identifier.
    /// - Returns: The list of joined room members, or an empty array if the room
    ///   is not found.
    func roomMembers(roomId: String) async -> [RoomMemberDetails]

    /// Fetches the pinned messages for a room.
    ///
    /// Creates a pinned-events-focused timeline, loads the pinned events, and returns
    /// them as ``TimelineMessage`` models.
    ///
    /// - Parameter roomId: The Matrix room identifier.
    /// - Returns: The list of pinned messages, or an empty array if none exist.
    func pinnedMessages(roomId: String) async -> [TimelineMessage]

    /// Downloads the full-resolution content of a Matrix media URL.
    ///
    /// - Parameter mxcURL: The `mxc://` URL of the media.
    /// - Returns: The raw media data, or `nil` if the download failed.
    func mediaContent(mxcURL: String) async -> Data?

    /// Downloads a thumbnail of a Matrix media URL at the specified dimensions.
    ///
    /// - Parameters:
    ///   - mxcURL: The `mxc://` URL of the media.
    ///   - width: The desired thumbnail width in pixels.
    ///   - height: The desired thumbnail height in pixels.
    /// - Returns: The thumbnail data, or `nil` if the download failed.
    func mediaThumbnail(mxcURL: String, width: UInt64, height: UInt64) async -> Data?

    /// Returns the display name of the currently authenticated user.
    func userDisplayName() async -> String?

    /// Updates the display name of the currently authenticated user.
    ///
    /// - Parameter name: The new display name.
    func setDisplayName(_ name: String) async throws

    /// Returns the `mxc://` avatar URL of the currently authenticated user.
    func userAvatarURL() async -> String?

    // MARK: Devices & Verification

    /// Whether the current session has been verified via cross-signing.
    ///
    /// This property is updated reactively as the SDK's verification state changes,
    /// so views can bind to it directly.
    var isSessionVerified: Bool { get }

    /// An incoming verification request from another device, if one is pending.
    ///
    /// When non-`nil`, a system notification is posted allowing the user to accept.
    /// Set back to `nil` when the request is handled or dismissed.
    var pendingVerificationRequest: IncomingVerificationRequest? { get set }

    /// Set to `true` when the user accepts a verification request via a system
    /// notification. The UI observes this flag to present the verification sheet.
    var shouldPresentVerificationSheet: Bool { get set }

    /// A deep link received from an external `matrix:` URI or `matrix.to` URL.
    ///
    /// Set by the app's `onOpenURL` handler when an external link is opened.
    /// The UI observes this property and navigates to the referenced room or user
    /// once the client is logged in and syncing. The UI clears this after handling.
    var pendingDeepLink: MatrixURI? { get set }

    /// Declines and clears the pending incoming verification request.
    ///
    /// Cancels the verification flow on the SDK side and sets
    /// ``pendingVerificationRequest`` to `nil`.
    func declinePendingVerificationRequest() async

    /// Fetches the list of all devices (sessions) associated with the current user's account.
    func getDevices() async throws -> [DeviceInfo]

    /// Returns whether the current session has been verified via cross-signing.
    func isCurrentSessionVerified() async -> Bool

    /// Returns the current encryption, key backup, and recovery state.
    func encryptionState() async -> EncryptionStatus

    /// Creates a view model for performing interactive session verification (SAS emoji comparison).
    ///
    /// - Returns: A ``SessionVerificationViewModelProtocol`` instance, or `nil` if the
    ///   verification controller is not available.
    func makeSessionVerificationViewModel() async throws -> (any SessionVerificationViewModelProtocol)?

    // MARK: Notification Settings (synced via push rules)

    /// Returns the default notification mode for rooms of the given type.
    ///
    /// - Parameter isOneToOne: `true` for direct message rooms, `false` for group rooms.
    func getDefaultNotificationMode(isOneToOne: Bool) async throws -> DefaultNotificationMode

    /// Sets the default notification mode for rooms of the given type.
    ///
    /// - Parameters:
    ///   - isOneToOne: `true` for direct message rooms, `false` for group rooms.
    ///   - mode: The notification mode to apply.
    func setDefaultNotificationMode(isOneToOne: Bool, mode: DefaultNotificationMode) async throws

    /// Checks whether the encrypted and unencrypted push rules are consistent
    /// for both direct and group chats.
    ///
    /// Old Matrix clients sometimes set different notification modes for encrypted
    /// vs unencrypted rooms. When a mismatch is detected, the user should be
    /// prompted to fix it.
    ///
    /// - Returns: `true` if the settings are consistent, `false` if there is a mismatch.
    func hasConsistentNotificationSettings() async throws -> Bool

    /// Repairs inconsistent notification settings by aligning encrypted and
    /// unencrypted push rules to the same mode.
    func fixInconsistentNotificationSettings() async throws

    /// Returns the room IDs that have user-defined (per-room) notification overrides.
    ///
    /// - Returns: An array of room IDs with custom notification settings.
    func roomsWithCustomNotificationSettings() async throws -> [String]

    /// Returns whether notifications for incoming calls are enabled.
    func isCallNotificationEnabled() async throws -> Bool

    /// Enables or disables notifications for incoming calls.
    func setCallNotificationEnabled(_ enabled: Bool) async throws

    /// Returns whether notifications for room invitations are enabled.
    func isInviteNotificationEnabled() async throws -> Bool

    /// Enables or disables notifications for room invitations.
    func setInviteNotificationEnabled(_ enabled: Bool) async throws

    /// Returns whether notifications for `@room` mentions are enabled.
    func isRoomMentionEnabled() async throws -> Bool

    /// Enables or disables notifications for `@room` mentions.
    func setRoomMentionEnabled(_ enabled: Bool) async throws

    /// Returns whether notifications for `@user` mentions are enabled.
    func isUserMentionEnabled() async throws -> Bool

    /// Enables or disables notifications for `@user` mentions.
    func setUserMentionEnabled(_ enabled: Bool) async throws

    // MARK: Keyword Notification Settings

    /// Returns the list of user-defined notification keywords.
    ///
    /// Keywords are extracted from the `content` push rules in the user's
    /// push ruleset. Only non-default, enabled rules are returned.
    func getNotificationKeywords() async throws -> [String]

    /// Adds a keyword to the notification push rules.
    ///
    /// Creates a `content`-type push rule where the keyword pattern triggers
    /// a notification with sound.
    /// - Parameter keyword: The keyword pattern to match against message bodies.
    func addNotificationKeyword(_ keyword: String) async throws

    /// Removes a keyword from the notification push rules.
    ///
    /// Disables the `content`-type push rule for the given keyword by setting
    /// its actions to empty.
    /// - Parameter keyword: The keyword pattern to remove.
    func removeNotificationKeyword(_ keyword: String) async throws

    // MARK: Per-Room Notification Settings

    /// Returns the notification mode for a specific room.
    ///
    /// - Parameter roomId: The Matrix room identifier.
    /// - Returns: The room's notification mode, or `nil` if the room uses the default.
    func getRoomNotificationMode(roomId: String) async throws -> RoomNotificationMode?

    /// Sets the notification mode for a specific room.
    ///
    /// - Parameters:
    ///   - roomId: The Matrix room identifier.
    ///   - mode: The notification mode to apply.
    func setRoomNotificationMode(roomId: String, mode: RoomNotificationMode) async throws

    /// Restores the default notification mode for a room, removing any per-room override.
    ///
    /// - Parameter roomId: The Matrix room identifier.
    func restoreDefaultRoomNotificationMode(roomId: String) async throws

    // MARK: Power Levels

    /// Sets a member's power level in a room.
    ///
    /// - Parameters:
    ///   - roomId: The Matrix room identifier.
    ///   - userId: The user ID whose power level to change.
    ///   - powerLevel: The new power level value.
    func setMemberPowerLevel(roomId: String, userId: String, powerLevel: Int64) async throws

    // MARK: Room Access Settings

    /// Updates the join rule for a room.
    ///
    /// - Parameters:
    ///   - roomId: The Matrix room identifier.
    ///   - rule: The join rule string (`"public"`, `"invite"`, `"knock"`).
    func updateJoinRule(roomId: String, rule: String) async throws

    /// Updates the history visibility for a room.
    ///
    /// - Parameters:
    ///   - roomId: The Matrix room identifier.
    ///   - visibility: The history visibility string (`"joined"`, `"invited"`, `"shared"`, `"world_readable"`).
    func updateHistoryVisibility(roomId: String, visibility: String) async throws

    /// Updates the room directory visibility.
    ///
    /// - Parameters:
    ///   - roomId: The Matrix room identifier.
    ///   - isPublic: Whether the room should be listed in the public directory.
    func updateRoomVisibility(roomId: String, isPublic: Bool) async throws

    // MARK: Member Moderation

    /// Kicks a user from a room.
    ///
    /// - Parameters:
    ///   - roomId: The Matrix room identifier.
    ///   - userId: The user to kick.
    ///   - reason: An optional reason for the kick.
    func kickMember(roomId: String, userId: String, reason: String?) async throws

    /// Bans a user from a room, preventing them from rejoining.
    ///
    /// - Parameters:
    ///   - roomId: The Matrix room identifier.
    ///   - userId: The user to ban.
    ///   - reason: An optional reason for the ban.
    func banMember(roomId: String, userId: String, reason: String?) async throws

    /// Unbans a user from a room, allowing them to rejoin.
    ///
    /// - Parameters:
    ///   - roomId: The Matrix room identifier.
    ///   - userId: The user to unban.
    func unbanMember(roomId: String, userId: String) async throws

    // MARK: Ignore List

    /// Returns whether a user is on the ignore list.
    ///
    /// - Parameter userId: The user to check.
    func isUserIgnored(userId: String) async throws -> Bool

    /// Adds a user to the ignore list. Ignored users' messages are hidden.
    ///
    /// - Parameter userId: The user to ignore.
    func ignoreUser(userId: String) async throws

    /// Removes a user from the ignore list.
    ///
    /// - Parameter userId: The user to unignore.
    func unignoreUser(userId: String) async throws
}

// MARK: - Environment Key

private struct MatrixServiceKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue: any MatrixServiceProtocol = PlaceholderMatrixService()
}

/// SwiftUI environment accessor for the shared ``MatrixServiceProtocol`` instance.
public extension EnvironmentValues {
    /// The Matrix service used throughout the app for homeserver communication.
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
    var hasLoadedRooms: Bool = false
    var isSessionVerified: Bool = false
    var pendingVerificationRequest: IncomingVerificationRequest?
    var shouldPresentVerificationSheet: Bool = false
    var pendingDeepLink: MatrixURI?
    func declinePendingVerificationRequest() async {}
    func restoreSession() async {}
    func login(username: String, password: String, homeserver: String) async {}
    func startOAuthLogin(
        homeserver: String,
        openURL: @escaping @concurrent @Sendable (URL) async throws -> URL
    ) async throws {}
    func logout() async {}
    func startSyncIfNeeded() {}
    func userId() -> String? { nil }
    func avatarThumbnail(mxcURL: String, size: CGFloat) async -> NSImage? { nil }
    func makeTimelineViewModel(roomId: String) -> (any TimelineViewModelProtocol)? { nil }
    func joinRoom(idOrAlias: String) async throws {}
    func createRoom(name: String, topic: String?, isPublic: Bool) async throws -> String { "" }
    func createRoom(options: CreateRoomOptions) async throws -> String { "" }
    func createDirectMessage(userId: String) async throws -> String { "" }
    func makeRoomDirectoryViewModel() -> (any RoomDirectoryViewModelProtocol)? { nil }
    func makeRoomPreviewViewModel(roomId: String) -> (any RoomPreviewViewModelProtocol)? { nil }
    func leaveRoom(id: String) async throws {}
    func searchDirectory(query: String) async throws -> [DirectoryRoom] { [] }
    func markAsRead(roomId: String, sendPublicReceipt: Bool) async {}
    func fullyReadEventId(roomId: String) async -> String? { nil }
    func sendTypingNotice(roomId: String, isTyping: Bool) async {}
    func roomDetails(roomId: String) async -> RoomDetails? { nil }
    func roomMembers(roomId: String) async -> [RoomMemberDetails] { [] }
    func pinnedMessages(roomId: String) async -> [TimelineMessage] { [] }
    func mediaContent(mxcURL: String) async -> Data? { nil }
    func mediaThumbnail(mxcURL: String, width: UInt64, height: UInt64) async -> Data? { nil }
    func userDisplayName() async -> String? { nil }
    func setDisplayName(_ name: String) async throws {}
    func userAvatarURL() async -> String? { nil }
    func getDevices() async throws -> [DeviceInfo] { [] }
    func isCurrentSessionVerified() async -> Bool { false }
    func encryptionState() async -> EncryptionStatus { EncryptionStatus() }
    func makeSessionVerificationViewModel() async throws -> (any SessionVerificationViewModelProtocol)? { nil }
    func getDefaultNotificationMode(
        isOneToOne: Bool
    ) async throws -> DefaultNotificationMode { .mentionsAndKeywordsOnly }
    func setDefaultNotificationMode(isOneToOne: Bool, mode: DefaultNotificationMode) async throws {}
    func hasConsistentNotificationSettings() async throws -> Bool { true }
    func fixInconsistentNotificationSettings() async throws {}
    func roomsWithCustomNotificationSettings() async throws -> [String] { [] }
    func isCallNotificationEnabled() async throws -> Bool { true }
    func setCallNotificationEnabled(_ enabled: Bool) async throws {}
    func isInviteNotificationEnabled() async throws -> Bool { true }
    func setInviteNotificationEnabled(_ enabled: Bool) async throws {}
    func isRoomMentionEnabled() async throws -> Bool { true }
    func setRoomMentionEnabled(_ enabled: Bool) async throws {}
    func isUserMentionEnabled() async throws -> Bool { true }
    func setUserMentionEnabled(_ enabled: Bool) async throws {}
    func getNotificationKeywords() async throws -> [String] { [] }
    func addNotificationKeyword(_ keyword: String) async throws {}
    func removeNotificationKeyword(_ keyword: String) async throws {}
    func getRoomNotificationMode(roomId: String) async throws -> RoomNotificationMode? { nil }
    func setRoomNotificationMode(roomId: String, mode: RoomNotificationMode) async throws {}
    func restoreDefaultRoomNotificationMode(roomId: String) async throws {}
    func setMemberPowerLevel(roomId: String, userId: String, powerLevel: Int64) async throws {}
    func updateJoinRule(roomId: String, rule: String) async throws {}
    func updateHistoryVisibility(roomId: String, visibility: String) async throws {}
    func updateRoomVisibility(roomId: String, isPublic: Bool) async throws {}
    func kickMember(roomId: String, userId: String, reason: String?) async throws {}
    func banMember(roomId: String, userId: String, reason: String?) async throws {}
    func unbanMember(roomId: String, userId: String) async throws {}
    func isUserIgnored(userId: String) async throws -> Bool { false }
    func ignoreUser(userId: String) async throws {}
    func unignoreUser(userId: String) async throws {}
}
