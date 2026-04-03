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

// ClientProxy.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// A proxy that wraps the Matrix SDK `Client` for use in SwiftUI.
///
/// `ClientProxy` is the primary entry point for interacting with a Matrix
/// homeserver. It manages authentication, room access, sync lifecycle,
/// and user profile operations.
///
/// All observable properties update on the main actor and can be read
/// directly from SwiftUI views. Async streams are consumed via
/// `.task { for await value in stream { ... } }`.
///
/// ## Topics
///
/// ### Authentication
/// - ``login(username:password:initialDeviceName:deviceId:)``
/// - ``restoreSession(_:)``
/// - ``logout()``
///
/// ### Rooms
/// - ``rooms()``
/// - ``room(id:)``
/// - ``createRoom(parameters:)``
/// - ``joinRoom(id:)``
@Observable
public final class ClientProxy: ClientProxyProtocol, @unchecked Sendable {
    /// The underlying SDK client.
    private let client: Client

    /// Retained task handles for active subscriptions.
    @ObservationIgnored nonisolated(unsafe) private var sendQueueTaskHandle: TaskHandle?
    private var _sendQueueListener: SendQueueUpdateListenerAdapter?

    // MARK: - Observable Properties

    /// The authenticated user's Matrix ID.
    public private(set) var userID: String

    /// The device ID for this session.
    public private(set) var deviceID: String

    /// The homeserver URL.
    public private(set) var homeserver: String

    /// The user's avatar URL.
    public private(set) var avatarURL: URL?

    /// The user's display name.
    public private(set) var displayName: String?

    // MARK: - Async Streams

    /// An async stream of send queue update events, keyed by room ID.
    public let sendQueueUpdates: AsyncStream<(roomId: String, update: RoomSendQueueUpdate)>

    private let sendQueueContinuation: AsyncStream<(roomId: String, update: RoomSendQueueUpdate)>.Continuation

    // MARK: - Initialization

    /// Creates a client proxy wrapping an SDK `Client`.
    ///
    /// - Parameter client: The SDK client instance.
    /// - Throws: `ClientError` if reading session info fails.
    public init(client: Client) throws {
        self.client = client
        self.userID = try client.userId()
        self.deviceID = try client.deviceId()
        self.homeserver = client.homeserver()

        let (stream, continuation) = AsyncStream<(roomId: String, update: RoomSendQueueUpdate)>.makeStream(
            bufferingPolicy: .bufferingNewest(10)
        )
        self.sendQueueUpdates = stream
        self.sendQueueContinuation = continuation

        // Use a dedicated listener for the two-parameter callback
        self._sendQueueListener = SendQueueUpdateListenerAdapter { roomId, update in
            continuation.yield((roomId: roomId, update: update))
        }
    }

    /// Starts observing SDK events.
    ///
    /// Call this after initialization to begin receiving reactive updates.
    /// This subscribes to send queue updates and other client-level events.
    public func startObserving() async throws {
        if let listener = _sendQueueListener {
            sendQueueTaskHandle = try await client.subscribeToSendQueueUpdates(
                listener: listener
            )
        }

        // Load initial profile
        self.avatarURL = try? await client.avatarUrl()?.matrixURL
        self.displayName = try? await client.displayName()
    }

    deinit {
        sendQueueTaskHandle?.cancel()
        sendQueueContinuation.finish()
    }

    // MARK: - Authentication

    public func login(username: String, password: String, initialDeviceName: String?, deviceId: String?) async throws {
        try await client.login(username: username, password: password, initialDeviceName: initialDeviceName, deviceId: deviceId)
        self.userID = try client.userId()
        self.deviceID = try client.deviceId()
    }

    public func restoreSession(_ session: Session) async throws {
        try await client.restoreSession(session: session)
        self.userID = try client.userId()
        self.deviceID = try client.deviceId()
    }

    public func logout() async throws {
        try await client.logout()
    }

    // MARK: - Rooms

    public func rooms() -> [Room] {
        client.rooms()
    }

    public func room(id: String) throws -> Room? {
        try client.getRoom(roomId: id)
    }

    public func createRoom(parameters: CreateRoomParameters) async throws -> String {
        try await client.createRoom(request: parameters)
    }

    public func joinRoom(id: String) async throws -> Room {
        try await client.joinRoomById(roomId: id)
    }

    // MARK: - Media

    public func uploadMedia(mimeType: String, data: Data, progressWatcher: ProgressWatcher?) async throws -> String {
        try await client.uploadMedia(mimeType: mimeType, data: data, progressWatcher: progressWatcher)
    }

    public func getMediaContent(mediaSource: MediaSource) async throws -> Data {
        try await client.getMediaContent(mediaSource: mediaSource)
    }

    public func getMediaThumbnail(mediaSource: MediaSource, width: UInt64, height: UInt64) async throws -> Data {
        try await client.getMediaThumbnail(mediaSource: mediaSource, width: width, height: height)
    }

    // MARK: - User Profile

    public func searchUsers(searchTerm: String, limit: UInt64) async throws -> SearchUsersResults {
        try await client.searchUsers(searchTerm: searchTerm, limit: limit)
    }

    public func getProfile(userId: String) async throws -> UserProfile {
        try await client.getProfile(userId: userId)
    }

    public func setDisplayName(_ name: String) async throws {
        try await client.setDisplayName(name: name)
        self.displayName = name
    }

    public func uploadAvatar(mimeType: String, data: Data) async throws {
        try await client.uploadAvatar(mimeType: mimeType, data: data)
        self.avatarURL = try? await client.avatarUrl()?.matrixURL
    }

    public func removeAvatar() async throws {
        try await client.removeAvatar()
        self.avatarURL = nil
    }

    // MARK: - Ignore List

    public func ignoredUsers() async throws -> [String] {
        try await client.ignoredUsers()
    }

    public func ignoreUser(userId: String) async throws {
        try await client.ignoreUser(userId: userId)
    }

    public func unignoreUser(userId: String) async throws {
        try await client.unignoreUser(userId: userId)
    }

    // MARK: - Push Notifications

    public func setPusher(identifiers: PusherIdentifiers, kind: PusherKind, appDisplayName: String, deviceDisplayName: String, profileTag: String?, lang: String) async throws {
        try await client.setPusher(identifiers: identifiers, kind: kind, appDisplayName: appDisplayName, deviceDisplayName: deviceDisplayName, profileTag: profileTag, lang: lang)
    }

    public func deletePusher(identifiers: PusherIdentifiers) async throws {
        try await client.deletePusher(identifiers: identifiers)
    }

    // MARK: - Account Data

    public func accountData(eventType: String) async throws -> String? {
        try await client.accountData(eventType: eventType)
    }

    public func setAccountData(eventType: String, content: String) async throws {
        try await client.setAccountData(eventType: eventType, content: content)
    }

    // MARK: - Services

    public func encryption() -> Encryption {
        client.encryption()
    }

    public func syncService() -> SyncServiceBuilder {
        client.syncService()
    }

    public func getNotificationSettings() async -> NotificationSettings {
        await client.getNotificationSettings()
    }

    public func notificationClient(processSetup: NotificationProcessSetup) async throws -> NotificationClient {
        try await client.notificationClient(processSetup: processSetup)
    }

    public func getSessionVerificationController() async throws -> SessionVerificationController {
        try await client.getSessionVerificationController()
    }

    public func getStoreSizes() async throws -> StoreSizes {
        try await client.getStoreSizes()
    }
}
