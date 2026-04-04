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

// NotificationSettingsProxyProtocol.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

/// Manages push notification rules and per-room notification settings.
///
/// Provides methods to read and write notification modes (all messages,
/// mentions only, mute) for individual rooms and default configurations.
/// The ``settingsDidChange`` stream fires whenever any setting is modified.
///
/// ## Topics
///
/// ### Reactive Updates
/// - ``settingsDidChange``
///
/// ### Room Settings
/// - ``getRoomNotificationSettings(roomId:isEncrypted:isOneToOne:)``
/// - ``setRoomNotificationMode(roomId:mode:)``
/// - ``restoreDefaultRoomNotificationMode(roomId:)``
///
/// ### Default Settings
/// - ``getDefaultRoomNotificationMode(isEncrypted:isOneToOne:)``
/// - ``setDefaultRoomNotificationMode(isEncrypted:isOneToOne:mode:)``
///
/// ### Toggles
/// - ``isRoomMentionEnabled()``
/// - ``setRoomMentionEnabled(enabled:)``
/// - ``isCallEnabled()``
/// - ``setCallEnabled(enabled:)``
/// - ``isInviteForMeEnabled()``
/// - ``setInviteForMeEnabled(enabled:)``
public protocol NotificationSettingsProxyProtocol: AnyObject, Sendable {
    /// An async stream that emits when any notification setting changes.
    var settingsDidChange: AsyncStream<Void> { get }

    /// Gets the notification settings for a specific room.
    ///
    /// - Parameters:
    ///   - roomId: The room ID.
    ///   - isEncrypted: Whether the room is encrypted.
    ///   - isOneToOne: Whether the room is a direct message.
    /// - Returns: The room notification settings.
    /// - Throws: If fetching fails.
    func getRoomNotificationSettings(
        roomId: String,
        isEncrypted: Bool,
        isOneToOne: Bool
    ) async throws -> RoomNotificationSettings

    /// Sets the notification mode for a specific room.
    ///
    /// - Parameters:
    ///   - roomId: The room ID.
    ///   - mode: The notification mode to set.
    /// - Throws: If setting fails.
    func setRoomNotificationMode(roomId: String, mode: RoomNotificationMode) async throws

    /// Restores default notification settings for a room.
    ///
    /// - Parameter roomId: The room ID.
    /// - Throws: If restoring fails.
    func restoreDefaultRoomNotificationMode(roomId: String) async throws

    /// Gets the default notification mode for a room category.
    ///
    /// - Parameters:
    ///   - isEncrypted: Whether the room is encrypted.
    ///   - isOneToOne: Whether the room is a direct message.
    /// - Returns: The default notification mode.
    func getDefaultRoomNotificationMode(isEncrypted: Bool, isOneToOne: Bool) async -> RoomNotificationMode

    /// Sets the default notification mode for a room category.
    ///
    /// - Parameters:
    ///   - isEncrypted: Whether the room is encrypted.
    ///   - isOneToOne: Whether the room is a direct message.
    ///   - mode: The notification mode to set.
    /// - Throws: If setting fails.
    func setDefaultRoomNotificationMode(isEncrypted: Bool, isOneToOne: Bool, mode: RoomNotificationMode) async throws

    /// Checks if room mention notifications are enabled.
    ///
    /// - Returns: `true` if enabled.
    /// - Throws: If the check fails.
    func isRoomMentionEnabled() async throws -> Bool

    /// Enables or disables room mention notifications.
    ///
    /// - Parameter enabled: Whether to enable mentions.
    /// - Throws: If setting fails.
    func setRoomMentionEnabled(enabled: Bool) async throws

    /// Checks if call notifications are enabled.
    ///
    /// - Returns: `true` if enabled.
    /// - Throws: If the check fails.
    func isCallEnabled() async throws -> Bool

    /// Enables or disables call notifications.
    ///
    /// - Parameter enabled: Whether to enable call notifications.
    /// - Throws: If setting fails.
    func setCallEnabled(enabled: Bool) async throws

    /// Checks if invite notifications are enabled.
    ///
    /// - Returns: `true` if enabled.
    /// - Throws: If the check fails.
    func isInviteForMeEnabled() async throws -> Bool

    /// Enables or disables invite notifications.
    ///
    /// - Parameter enabled: Whether to enable invite notifications.
    /// - Throws: If setting fails.
    func setInviteForMeEnabled(enabled: Bool) async throws

    /// Checks if any keyword notification rules exist.
    ///
    /// - Returns: `true` if keyword rules exist.
    func containsKeywordsRules() async -> Bool

    /// Returns room IDs with custom notification rules.
    ///
    /// - Parameter enabled: Optional filter for enabled/disabled rules.
    /// - Returns: An array of room IDs.
    func getRoomsWithUserDefinedRules(enabled: Bool?) async -> [String]
}
