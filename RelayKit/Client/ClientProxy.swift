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

    /// Loads the authenticated user's profile (avatar URL and display name).
    ///
    /// Called eagerly after login so profile data is available before views
    /// access it. Safe to call multiple times; each call refreshes the values.
    public func loadProfile() async {
        self.avatarURL = try? await client.avatarUrl()?.matrixURL
        self.displayName = try? await client.displayName()
    }

    /// Starts observing SDK events.
    ///
    /// Call this after initialization to begin receiving reactive updates.
    /// This subscribes to send queue updates and other client-level events,
    /// and refreshes the user's profile.
    public func startObserving() async throws {
        if let listener = _sendQueueListener {
            sendQueueTaskHandle = try await client.subscribeToSendQueueUpdates(
                listener: listener
            )
        }

        await loadProfile()
    }

    deinit {
        sendQueueTaskHandle?.cancel()
        sendQueueContinuation.finish()
    }

    // MARK: - Authentication

    public func login(
        username: String,
        password: String,
        initialDeviceName: String?,
        deviceId: String?
    ) async throws {
        try await client.login(
            username: username,
            password: password,
            initialDeviceName: initialDeviceName,
            deviceId: deviceId
        )
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

    // swiftlint:disable:next function_parameter_count
    public func setPusher(
        identifiers: PusherIdentifiers,
        kind: PusherKind,
        appDisplayName: String,
        deviceDisplayName: String,
        profileTag: String?,
        lang: String
    ) async throws {
        try await client.setPusher(
            identifiers: identifiers,
            kind: kind,
            appDisplayName: appDisplayName,
            deviceDisplayName: deviceDisplayName,
            profileTag: profileTag,
            lang: lang
        )
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

    public func enableAllSendQueues(enable: Bool) async {
        await client.enableAllSendQueues(enable: enable)
    }

    public func syncService() -> SyncServiceBuilder {
        client.syncService()
    }

    public func spaceService() async -> SpaceService {
        await client.spaceService()
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

    // MARK: - OAuth / OIDC

    public func homeserverLoginDetails() async -> HomeserverLoginDetails {
        await client.homeserverLoginDetails()
    }

    public func urlForOidc(
        oidcConfiguration: OidcConfiguration,
        prompt: OidcPrompt?,
        loginHint: String?,
        deviceId: String?,
        additionalScopes: [String]?
    ) async throws -> OAuthAuthorizationData {
        try await client.urlForOidc(
            oidcConfiguration: oidcConfiguration,
            prompt: prompt,
            loginHint: loginHint,
            deviceId: deviceId,
            additionalScopes: additionalScopes
        )
    }

    public func loginWithOidcCallback(callbackUrl: String) async throws {
        try await client.loginWithOidcCallback(callbackUrl: callbackUrl)
    }

    public func session() throws -> Session {
        try client.session()
    }

    // MARK: - Room Directory

    public func roomDirectorySearch() -> RoomDirectorySearch {
        client.roomDirectorySearch()
    }

    // MARK: - Room Preview

    public func getRoomPreviewFromRoomId(roomId: String, viaServers: [String]) async throws -> RoomPreview {
        try await client.getRoomPreviewFromRoomId(roomId: roomId, viaServers: viaServers)
    }

    public func getRoomPreviewFromRoomAlias(roomAlias: String) async throws -> RoomPreview {
        try await client.getRoomPreviewFromRoomAlias(roomAlias: roomAlias)
    }

    // MARK: - Room Lookup

    public func getDmRoom(userId: String) throws -> Room? {
        try client.getDmRoom(userId: userId)
    }

    public func getRoom(roomId: String) throws -> Room? {
        try client.getRoom(roomId: roomId)
    }

    public func joinRoomByIdOrAlias(roomIdOrAlias: String, serverNames: [String]) async throws -> Room {
        try await client.joinRoomByIdOrAlias(roomIdOrAlias: roomIdOrAlias, serverNames: serverNames)
    }

    // MARK: - Room Account Data

    public func observeRoomAccountDataEvent(
        roomId: String,
        eventType: RoomAccountDataEventType,
        listener: RoomAccountDataListener
    ) throws -> TaskHandle {
        try client.observeRoomAccountDataEvent(
            roomId: roomId,
            eventType: eventType,
            listener: listener
        )
    }

    // MARK: - QR Code Login

    public func newGrantLoginWithQrCodeHandler() -> GrantLoginWithQrCodeHandler {
        client.newGrantLoginWithQrCodeHandler()
    }

    public func newLoginWithQrCodeHandler(oidcConfiguration: OidcConfiguration) -> LoginWithQrCodeHandler {
        client.newLoginWithQrCodeHandler(oidcConfiguration: oidcConfiguration)
    }
}
