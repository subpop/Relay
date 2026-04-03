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
import AuthenticationServices
import Foundation
import RelayInterface
import os

private let logger = Logger(subsystem: "RelayKit", category: "MatrixService")

/// Errors that can be thrown by ``MatrixService`` operations.
public enum MatrixServiceError: LocalizedError {
    /// The operation requires an authenticated session but the user is not logged in.
    case notLoggedIn

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: "Not logged in"
        }
    }
}

/// The concrete implementation of ``MatrixServiceProtocol`` backed by the Matrix Rust SDK.
///
/// ``MatrixService`` acts as a thin facade that coordinates several focused sub-services:
/// - ``AuthenticationService`` — login, session restore, OAuth/OIDC
/// - ``SyncManager`` — sync lifecycle and state observation
/// - ``RoomListManager`` — room list polling and sorting
/// - ``MediaService`` — avatar and media caching/fetching
/// - ``DirectorySearchService`` — public room directory search
///
/// This class is `@Observable` and `@MainActor`-isolated so that SwiftUI views can bind
/// directly to its published state.
@Observable
public final class MatrixService: MatrixServiceProtocol {

    public private(set) var authState: AuthState = .unknown
    public var syncState: SyncState { syncManager.syncState }
    public var rooms: [RelayInterface.RoomSummary] { roomListManager.rooms }

    public var isSyncing: Bool { syncState == .syncing || syncState == .running }
    public var hasLoadedRooms: Bool { roomListManager.hasLoadedRooms }

    // MARK: - Private State

    private var client: Client?
    private var syncTask: Task<Void, Never>?
    private var roomViewModels: [String: RoomDetailViewModel] = [:]
    private var verificationController: SessionVerificationController?

    // MARK: - Sub-Services

    private let auth = AuthenticationService()
    private let syncManager = SyncManager()
    private let roomListManager = RoomListManager()
    private let media = MediaService()
    private let directorySearch = DirectorySearchService()

    /// Creates a new ``MatrixService``. Call ``restoreSession()`` after initialization to
    /// attempt automatic sign-in from a previously saved keychain session.
    public init() {}

    // MARK: - Session Restore

    public func restoreSession() async {
        if let (restoredClient, userId) = await auth.restoreSession() {
            client = restoredClient
            authState = .loggedIn(userId: userId)
        } else {
            authState = .loggedOut
        }
    }

    // MARK: - Login

    public func login(username: String, password: String, homeserver: String) async {
        authState = .loggingIn
        do {
            let (newClient, userId) = try await auth.login(username: username, password: password, homeserver: homeserver)
            client = newClient
            authState = .loggedIn(userId: userId)
        } catch {
            authState = .error(error.localizedDescription)
        }
    }

    // MARK: - OAuth Login

    public func startOAuthLogin(homeserver: String) async throws {
        authState = .loggingIn
        do {
            let (newClient, userId) = try await auth.startOAuthLogin(homeserver: homeserver)
            client = newClient
            authState = .loggedIn(userId: userId)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            authState = .loggedOut
        } catch {
            authState = .error(error.localizedDescription)
        }
    }

    // MARK: - Logout

    public func logout() async {
        syncTask?.cancel()
        syncTask = nil

        await syncManager.stop()
        try? await client?.logout()

        auth.clearSession()

        client = nil
        verificationController = nil
        roomListManager.reset()
        roomViewModels = [:]
        authState = .loggedOut
    }

    // MARK: - Sync

    public func startSyncIfNeeded() {
        guard syncManager.syncState == .idle else { return }
        syncTask = Task { await performSync() }
    }

    private func performSync() async {
        guard let client else { return }

        do {
            try await syncManager.startSync(client: client)
            verificationController = try? await client.getSessionVerificationController()
            if let syncService = syncManager.syncService {
                try await roomListManager.start(syncService: syncService)
            }
        } catch is CancellationError {
            // Logout cancelled the sync — don't overwrite state
        } catch {
            logger.error("Sync failed: \(error)")
        }
    }

    // MARK: - Room Access

    /// Looks up a joined room by its Matrix room identifier.
    ///
    /// - Parameter id: The Matrix room ID.
    /// - Returns: The SDK `Room` object, or `nil` if not found.
    func room(id: String) -> Room? {
        roomListManager.sdkRoom(id: id) ?? client?.rooms().first { $0.id() == id }
    }

    public func userId() -> String? {
        try? client?.userId()
    }

    public func userDisplayName() async -> String? {
        guard let client else { return nil }
        return try? await client.displayName()
    }

    public func setDisplayName(_ name: String) async throws {
        guard let client else { return }
        try await client.setDisplayName(name: name)
    }

    public func userAvatarURL() async -> String? {
        guard let client else { return nil }
        return try? await client.avatarUrl()
    }

    public func makeRoomDetailViewModel(roomId: String) -> (any RoomDetailViewModelProtocol)? {
        if let cached = roomViewModels[roomId] { return cached }
        guard let room = room(id: roomId) else { return nil }
        let unreadCount = rooms.first(where: { $0.id == roomId })?.unreadMessages ?? 0
        let vm = RoomDetailViewModel(room: room, currentUserId: userId(), unreadCount: Int(unreadCount))
        roomViewModels[roomId] = vm

        // Subscribe to this room at a higher detail level in the sliding sync.
        // This requests additional state events (including m.room.pinned_events)
        // that aren't included in the default room list sync.
        if let rls = roomListManager.roomListService {
            Task {
                try? await rls.subscribeToRooms(roomIds: [roomId])
            }
        }

        return vm
    }

    // MARK: - Room Management

    public func joinRoom(idOrAlias: String) async throws {
        guard let client else { return }
        _ = try await client.joinRoomByIdOrAlias(roomIdOrAlias: idOrAlias, serverNames: [])
    }

    public func createRoom(name: String, topic: String?, isPublic: Bool) async throws -> String {
        guard let client else { throw MatrixServiceError.notLoggedIn }
        let params = CreateRoomParameters(
            name: name,
            topic: topic,
            isEncrypted: !isPublic,
            isDirect: false,
            visibility: isPublic ? .public : .private,
            preset: isPublic ? .publicChat : .privateChat
        )
        return try await client.createRoom(request: params)
    }

    public func createRoom(options: CreateRoomOptions) async throws -> String {
        guard let client else { throw MatrixServiceError.notLoggedIn }
        let params = CreateRoomParameters(
            name: options.name,
            topic: options.topic,
            isEncrypted: options.isEncrypted,
            isDirect: false,
            visibility: options.isPublic ? .public : .private,
            preset: options.isPublic ? .publicChat : .privateChat,
            canonicalAlias: options.address
        )
        return try await client.createRoom(request: params)
    }

    public func makeRoomDirectoryViewModel() -> (any RoomDirectoryViewModelProtocol)? {
        guard let client else { return nil }
        return RoomDirectoryViewModel(client: client)
    }

    public func makeRoomPreviewViewModel(roomId: String) -> (any RoomPreviewViewModelProtocol)? {
        guard let client else { return nil }
        return RoomPreviewViewModel(roomId: roomId, client: client)
    }

    public func leaveRoom(id: String) async throws {
        guard let room = room(id: id) else { return }
        try await room.leave()
        roomViewModels.removeValue(forKey: id)
    }

    // MARK: - Read Receipts & Typing

    public func markAsRead(roomId: String, sendPublicReceipt: Bool) async {
        guard let room = room(id: roomId) else { return }

        // Optimistically clear unread indicators so the room list updates immediately
        // rather than waiting for the server round-trip through the sync loop.
        if let summary = rooms.first(where: { $0.id == roomId }) {
            summary.unreadMessages = 0
            summary.unreadMentions = 0
        }

        let receiptType: ReceiptType = sendPublicReceipt ? .read : .readPrivate
        try? await room.markAsRead(receiptType: receiptType)
    }

    public func fullyReadEventId(roomId: String) async -> String? {
        guard let client else { return nil }
        // Use a nonisolated(unsafe) var to hold the handle alive until the callback fires.
        nonisolated(unsafe) var handle: TaskHandle?
        let result: String? = await withCheckedContinuation { continuation in
            let listener = RoomAccountDataListenerAdapter { event, _ in
                switch event {
                case .fullyReadEvent(let eventId):
                    continuation.resume(returning: eventId)
                default:
                    continuation.resume(returning: nil)
                }
            }
            do {
                handle = try client.observeRoomAccountDataEvent(
                    roomId: roomId,
                    eventType: .fullyRead,
                    listener: listener
                )
            } catch {
                continuation.resume(returning: nil)
            }
        }
        _ = handle // Keep handle alive until continuation resolves
        return result
    }

    public func sendTypingNotice(roomId: String, isTyping: Bool) async {
        guard let room = room(id: roomId) else { return }
        try? await room.typingNotice(isTyping: isTyping)
    }

    // MARK: - Room Details

    public func roomDetails(roomId: String) async -> RoomDetails? {
        guard let room = room(id: roomId) else { return nil }

        let info = try? await room.roomInfo()
        let name = room.displayName() ?? room.id()
        let topic = info?.topic
        let avatarUrl = room.avatarUrl()
        let isEncrypted = info?.encryptionState != .notEncrypted
        let isPublic = info?.isPublic ?? false
        let isDirect = info?.isDirect ?? false
        let canonicalAlias = info?.canonicalAlias

        let memberCount = info?.joinedMembersCount ?? room.joinedMembersCount()

        var memberDetails: [RoomMemberDetails] = []
        if let membersIterator = try? await room.members() {
            let chunk = membersIterator.nextChunk(chunkSize: 200)
            if let chunk {
                memberDetails = chunk.compactMap { member in
                    guard member.membership == .join else { return nil }
                    let role: RoomMemberDetails.Role = switch member.suggestedRoleForPowerLevel {
                    case .administrator: .administrator
                    case .moderator: .moderator
                    default: .user
                    }
                    return RoomMemberDetails(
                        userId: member.userId,
                        displayName: member.displayName,
                        avatarURL: member.avatarUrl,
                        role: role
                    )
                }
            }
        }

        let pinnedEventIds = info?.pinnedEventIds ?? []

        return RoomDetails(
            id: room.id(),
            name: name,
            topic: topic,
            avatarURL: avatarUrl,
            isEncrypted: isEncrypted,
            isPublic: isPublic,
            isDirect: isDirect,
            canonicalAlias: canonicalAlias,
            memberCount: memberCount,
            members: memberDetails,
            pinnedEventIds: pinnedEventIds
        )
    }

    // MARK: - Pinned Messages

    public func pinnedMessages(roomId: String) async -> [TimelineMessage] {
        guard let room = room(id: roomId) else {
            logger.warning("pinnedMessages: room not found for \(roomId)")
            return []
        }

        let info = try? await room.roomInfo()
        let pinnedIds = info?.pinnedEventIds ?? []
        guard !pinnedIds.isEmpty else { return [] }

        let currentUser = userId()
        var messages: [TimelineMessage] = []

        // Fetch each pinned event directly from the server/cache using
        // Room.loadOrFetchEvent, which works regardless of whether the event
        // is in the loaded timeline window.
        for eventId in pinnedIds {
            do {
                let event = try await room.loadOrFetchEvent(eventId: eventId)
                let content = try event.content()

                guard case .messageLike(let msgContent) = content,
                      case .roomMessage(let messageType, _) = msgContent else {
                    continue
                }

                let body: String
                let kind: TimelineMessage.Kind
                switch messageType {
                case .text(let c):    body = c.body; kind = .text
                case .emote(let c):   body = c.body; kind = .emote
                case .notice(let c):  body = c.body; kind = .notice
                case .image:          body = "Image"; kind = .image
                case .video:          body = "Video"; kind = .video
                case .audio:          body = "Audio"; kind = .audio
                case .file:           body = "File";  kind = .file
                case .location:       body = "Location"; kind = .location
                case .gallery:        body = "Gallery"; kind = .image
                case .other(_, let b): body = b; kind = .other
                }

                let senderId = event.senderId()
                let displayName = try? await room.memberDisplayName(userId: senderId)
                let avatarURL = try? await room.memberAvatarUrl(userId: senderId)
                let ts = Date(timeIntervalSince1970: TimeInterval(event.timestamp()) / 1000)

                messages.append(TimelineMessage(
                    id: event.eventId(),
                    senderID: senderId,
                    senderDisplayName: displayName,
                    senderAvatarURL: avatarURL,
                    body: body,
                    timestamp: ts,
                    isOutgoing: senderId == currentUser,
                    kind: kind
                ))
            } catch {
                logger.warning("pinnedMessages: failed to fetch event \(eventId): \(error)")
            }
        }

        return messages
    }

    // MARK: - Directory Search

    public func searchDirectory(query: String) async throws -> [DirectoryRoom] {
        guard let client else { return [] }
        return try await directorySearch.search(query: query, client: client)
    }

    // MARK: - Media

    public func avatarThumbnail(mxcURL: String, size: CGFloat) async -> NSImage? {
        guard let client else { return nil }
        return await media.avatarThumbnail(mxcURL: mxcURL, size: size, client: client)
    }

    public func mediaContent(mxcURL: String) async -> Data? {
        guard let client else { return nil }
        return await media.mediaContent(mxcURL: mxcURL, client: client)
    }

    public func mediaThumbnail(mxcURL: String, width: UInt64, height: UInt64) async -> Data? {
        guard let client else { return nil }
        return await media.mediaThumbnail(mxcURL: mxcURL, width: width, height: height, client: client)
    }

    // MARK: - Notification Settings

    private func notificationSettings() async throws -> NotificationSettings {
        guard let client else { throw MatrixServiceError.notLoggedIn }
        return await client.getNotificationSettings()
    }

    private func sdkMode(from mode: DefaultNotificationMode) -> RoomNotificationMode {
        switch mode {
        case .allMessages: .allMessages
        case .mentionsAndKeywordsOnly: .mentionsAndKeywordsOnly
        case .mute: .mute
        }
    }

    private func appMode(from mode: RoomNotificationMode) -> DefaultNotificationMode {
        switch mode {
        case .allMessages: .allMessages
        case .mentionsAndKeywordsOnly: .mentionsAndKeywordsOnly
        case .mute: .mute
        }
    }

    public func getDefaultNotificationMode(isOneToOne: Bool) async throws -> DefaultNotificationMode {
        let settings = try await notificationSettings()
        let mode = await settings.getDefaultRoomNotificationMode(isEncrypted: true, isOneToOne: isOneToOne)
        return appMode(from: mode)
    }

    public func setDefaultNotificationMode(isOneToOne: Bool, mode: DefaultNotificationMode) async throws {
        let settings = try await notificationSettings()
        let sdkMode = sdkMode(from: mode)
        try await settings.setDefaultRoomNotificationMode(isEncrypted: true, isOneToOne: isOneToOne, mode: sdkMode)
        try await settings.setDefaultRoomNotificationMode(isEncrypted: false, isOneToOne: isOneToOne, mode: sdkMode)
    }

    public func isCallNotificationEnabled() async throws -> Bool {
        try await notificationSettings().isCallEnabled()
    }

    public func setCallNotificationEnabled(_ enabled: Bool) async throws {
        try await notificationSettings().setCallEnabled(enabled: enabled)
    }

    public func isInviteNotificationEnabled() async throws -> Bool {
        try await notificationSettings().isInviteForMeEnabled()
    }

    public func setInviteNotificationEnabled(_ enabled: Bool) async throws {
        try await notificationSettings().setInviteForMeEnabled(enabled: enabled)
    }

    public func isRoomMentionEnabled() async throws -> Bool {
        try await notificationSettings().isRoomMentionEnabled()
    }

    public func setRoomMentionEnabled(_ enabled: Bool) async throws {
        try await notificationSettings().setRoomMentionEnabled(enabled: enabled)
    }

    public func isUserMentionEnabled() async throws -> Bool {
        try await notificationSettings().isUserMentionEnabled()
    }

    public func setUserMentionEnabled(_ enabled: Bool) async throws {
        try await notificationSettings().setUserMentionEnabled(enabled: enabled)
    }

    // MARK: - Session Verification

    public func makeSessionVerificationViewModel() async throws -> (any SessionVerificationViewModelProtocol)? {
        guard let controller = verificationController else { return nil }
        return SessionVerificationViewModel(controller: controller)
    }

    public func isCurrentSessionVerified() async -> Bool {
        guard let client else { return false }
        return client.encryption().verificationState() == .verified
    }

    public func encryptionState() async -> EncryptionStatus {
        guard let client else { return EncryptionStatus() }
        let encryption = client.encryption()
        return EncryptionStatus(
            backupEnabled: encryption.backupState() == .enabled,
            recoveryEnabled: encryption.recoveryState() == .enabled
        )
    }

    // MARK: - Devices

    private struct DevicesResponse: Decodable {
        struct Device: Decodable {
            let device_id: String
            let display_name: String?
            let last_seen_ip: String?
            let last_seen_ts: UInt64?
        }
        let devices: [Device]
    }

    public func getDevices() async throws -> [DeviceInfo] {
        guard let client else { throw MatrixServiceError.notLoggedIn }

        let currentDeviceId = try? client.deviceId()
        let session = try client.session()

        var request = URLRequest(url: URL(string: "\(client.homeserver())_matrix/client/v3/devices")!)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(DevicesResponse.self, from: data)

        return response.devices.map { device in
            let lastSeen: Date? = device.last_seen_ts.map {
                Date(timeIntervalSince1970: TimeInterval($0) / 1000)
            }
            return DeviceInfo(
                id: device.device_id,
                displayName: device.display_name,
                lastSeenIP: device.last_seen_ip,
                lastSeenTimestamp: lastSeen,
                isCurrentDevice: device.device_id == currentDeviceId
            )
        }
    }
}
