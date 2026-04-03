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

// ClientProxyProtocol.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The primary interface for interacting with a Matrix homeserver.
///
/// `ClientProxyProtocol` defines all operations for authentication,
/// room management, user profiles, media, push notifications, and
/// account data. Implementations are `@Observable`, so SwiftUI views
/// can read properties directly and react to changes.
///
/// ## Reactive Properties
///
/// Observable properties such as ``userID``, ``displayName``, and
/// ``avatarURL`` update automatically as the SDK receives new data.
///
/// ## Async Streams
///
/// Event-based data is exposed via `AsyncStream` properties:
/// - ``sendQueueUpdates`` — send queue state changes per room
/// - ``accountDataUpdates`` — global account data events
///
/// ## Topics
///
/// ### Authentication
/// - ``login(username:password:initialDeviceName:deviceId:)``
/// - ``restoreSession(_:)``
/// - ``logout()``
///
/// ### Room Access
/// - ``rooms()``
/// - ``room(id:)``
/// - ``createRoom(parameters:)``
/// - ``joinRoom(id:)``
///
/// ### User Profile
/// - ``displayName``
/// - ``avatarURL``
/// - ``setDisplayName(_:)``
/// - ``uploadAvatar(mimeType:data:)``
///
/// ### Encryption
/// - ``encryption()``
public protocol ClientProxyProtocol: AnyObject, Sendable {
    // MARK: - Properties

    /// The authenticated user's Matrix ID (e.g. `@user:matrix.org`).
    var userID: String { get }

    /// The device ID for this session.
    var deviceID: String { get }

    /// The homeserver URL this client is connected to.
    var homeserver: String { get }

    /// The user's avatar URL, if set.
    var avatarURL: URL? { get }

    /// The user's display name, if set.
    var displayName: String? { get }

    // MARK: - Async Streams

    /// An async stream of send queue update events, keyed by room ID.
    var sendQueueUpdates: AsyncStream<(roomId: String, update: RoomSendQueueUpdate)> { get }

    // MARK: - Authentication

    /// Authenticates with the homeserver using a username and password.
    ///
    /// - Parameters:
    ///   - username: The user's Matrix username or full MXID.
    ///   - password: The user's password.
    ///   - initialDeviceName: An optional display name for this device.
    ///   - deviceId: An optional specific device ID to reuse.
    /// - Throws: `ClientError` if authentication fails.
    func login(username: String, password: String, initialDeviceName: String?, deviceId: String?) async throws

    /// Restores a previously saved session.
    ///
    /// - Parameter session: The session data to restore.
    /// - Throws: `ClientError` if the session is invalid or expired.
    func restoreSession(_ session: Session) async throws

    /// Logs out the current session and invalidates the access token.
    ///
    /// - Throws: `ClientError` if logout fails.
    func logout() async throws

    // MARK: - Rooms

    /// Returns all rooms the user has access to.
    ///
    /// - Returns: An array of rooms.
    func rooms() -> [Room]

    /// Returns a specific room by its Matrix room ID.
    ///
    /// - Parameter id: The Matrix room ID (e.g. `!abc:matrix.org`).
    /// - Returns: The room if found, otherwise `nil`.
    /// - Throws: `ClientError` if the lookup fails.
    func room(id: String) throws -> Room?

    /// Creates a new room with the given parameters.
    ///
    /// - Parameter parameters: The room creation parameters.
    /// - Returns: The ID of the newly created room.
    /// - Throws: `ClientError` if room creation fails.
    func createRoom(parameters: CreateRoomParameters) async throws -> String

    /// Joins a room by its ID or alias.
    ///
    /// - Parameter id: The room ID or alias.
    /// - Returns: The joined room.
    /// - Throws: `ClientError` if joining fails.
    func joinRoom(id: String) async throws -> Room

    // MARK: - Media

    /// Uploads media data to the homeserver's content repository.
    ///
    /// - Parameters:
    ///   - mimeType: The MIME type of the media.
    ///   - data: The media data to upload.
    ///   - progressWatcher: An optional progress watcher for tracking upload.
    /// - Returns: The MXC URI of the uploaded media.
    /// - Throws: `ClientError` if the upload fails.
    func uploadMedia(mimeType: String, data: Data, progressWatcher: ProgressWatcher?) async throws -> String

    /// Retrieves media content from the homeserver.
    ///
    /// - Parameter mediaSource: The media source to download.
    /// - Returns: The media data.
    /// - Throws: `ClientError` if the download fails.
    func getMediaContent(mediaSource: MediaSource) async throws -> Data

    /// Retrieves a thumbnail for media content.
    ///
    /// - Parameters:
    ///   - mediaSource: The media source.
    ///   - width: The desired width in pixels.
    ///   - height: The desired height in pixels.
    /// - Returns: The thumbnail data.
    /// - Throws: `ClientError` if the download fails.
    func getMediaThumbnail(mediaSource: MediaSource, width: UInt64, height: UInt64) async throws -> Data

    // MARK: - User Profile

    /// Searches the user directory.
    ///
    /// - Parameters:
    ///   - searchTerm: The search query.
    ///   - limit: Maximum number of results.
    /// - Returns: The search results.
    /// - Throws: `ClientError` if the search fails.
    func searchUsers(searchTerm: String, limit: UInt64) async throws -> SearchUsersResults

    /// Fetches a user's profile.
    ///
    /// - Parameter userId: The Matrix user ID.
    /// - Returns: The user's profile.
    /// - Throws: `ClientError` if the fetch fails.
    func getProfile(userId: String) async throws -> UserProfile

    /// Updates the authenticated user's display name.
    ///
    /// - Parameter name: The new display name.
    /// - Throws: `ClientError` if the update fails.
    func setDisplayName(_ name: String) async throws

    /// Uploads a new avatar for the authenticated user.
    ///
    /// - Parameters:
    ///   - mimeType: The MIME type of the avatar image.
    ///   - data: The avatar image data.
    /// - Throws: `ClientError` if the upload fails.
    func uploadAvatar(mimeType: String, data: Data) async throws

    /// Removes the authenticated user's avatar.
    ///
    /// - Throws: `ClientError` if the removal fails.
    func removeAvatar() async throws

    // MARK: - Ignore List

    /// Returns the list of ignored user IDs.
    ///
    /// - Returns: An array of ignored user IDs.
    /// - Throws: `ClientError` if the fetch fails.
    func ignoredUsers() async throws -> [String]

    /// Adds a user to the ignore list.
    ///
    /// - Parameter userId: The user ID to ignore.
    /// - Throws: `ClientError` if the operation fails.
    func ignoreUser(userId: String) async throws

    /// Removes a user from the ignore list.
    ///
    /// - Parameter userId: The user ID to unignore.
    /// - Throws: `ClientError` if the operation fails.
    func unignoreUser(userId: String) async throws

    // MARK: - Push Notifications

    /// Registers a push notification endpoint with the homeserver.
    ///
    /// - Parameters:
    ///   - identifiers: The pusher identifiers.
    ///   - kind: The kind of pusher (HTTP or email).
    ///   - appDisplayName: The application display name.
    ///   - deviceDisplayName: The device display name.
    ///   - profileTag: An optional profile tag.
    ///   - lang: The language code.
    /// - Throws: `ClientError` if registration fails.
    func setPusher(identifiers: PusherIdentifiers, kind: PusherKind, appDisplayName: String, deviceDisplayName: String, profileTag: String?, lang: String) async throws

    /// Removes a push notification endpoint.
    ///
    /// - Parameter identifiers: The pusher identifiers to remove.
    /// - Throws: `ClientError` if removal fails.
    func deletePusher(identifiers: PusherIdentifiers) async throws

    // MARK: - Account Data

    /// Reads a global account data event by type.
    ///
    /// - Parameter eventType: The event type string.
    /// - Returns: The event content as a JSON string, or `nil`.
    /// - Throws: `ClientError` if the read fails.
    func accountData(eventType: String) async throws -> String?

    /// Sets a global account data event.
    ///
    /// - Parameters:
    ///   - eventType: The event type string.
    ///   - content: The event content as a JSON string.
    /// - Throws: `ClientError` if the write fails.
    func setAccountData(eventType: String, content: String) async throws

    // MARK: - Encryption

    /// Returns the encryption service for managing E2EE, backup, and recovery.
    ///
    /// - Returns: The encryption proxy.
    func encryption() -> Encryption

    // MARK: - Sync

    /// Creates a sync service builder for configuring sync.
    ///
    /// - Returns: The sync service builder.
    func syncService() -> SyncServiceBuilder

    // MARK: - Notifications

    /// Returns the notification settings.
    ///
    /// - Returns: The notification settings.
    func getNotificationSettings() async -> NotificationSettings

    /// Creates a notification client for processing push notifications.
    ///
    /// - Parameter processSetup: The notification process setup configuration.
    /// - Returns: The notification client.
    /// - Throws: `ClientError` if creation fails.
    func notificationClient(processSetup: NotificationProcessSetup) async throws -> NotificationClient

    // MARK: - Verification

    /// Returns the session verification controller.
    ///
    /// - Returns: The verification controller.
    /// - Throws: `ClientError` if the controller cannot be created.
    func getSessionVerificationController() async throws -> SessionVerificationController

    // MARK: - Store

    /// Returns the sizes of the local stores.
    ///
    /// - Returns: The store sizes.
    /// - Throws: `ClientError` if the sizes cannot be read.
    func getStoreSizes() async throws -> StoreSizes
}
