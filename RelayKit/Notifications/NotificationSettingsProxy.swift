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

// NotificationSettingsProxy.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Observation

/// An `@Observable` proxy that wraps the Matrix SDK `NotificationSettings`.
///
/// Provides methods for reading and writing notification rules and
/// per-room notification modes. The ``settingsDidChange`` stream fires
/// whenever any setting is modified.
@Observable
public final class NotificationSettingsProxy: NotificationSettingsProxyProtocol, @unchecked Sendable {
    private let settings: NotificationSettings

    /// An async stream that emits when any notification setting changes.
    public let settingsDidChange: AsyncStream<Void>
    private let settingsDidChangeContinuation: AsyncStream<Void>.Continuation

    /// Creates a notification settings proxy.
    ///
    /// - Parameter settings: The SDK notification settings instance.
    public init(settings: NotificationSettings) {
        self.settings = settings

        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.settingsDidChange = stream
        self.settingsDidChangeContinuation = continuation

        settings.setDelegate(delegate: SDKListener { _ in
            continuation.yield(())
        })
    }

    deinit {
        settings.setDelegate(delegate: nil)
        settingsDidChangeContinuation.finish()
    }

    // MARK: - Room Settings

    public func getRoomNotificationSettings(roomId: String, isEncrypted: Bool, isOneToOne: Bool) async throws -> RoomNotificationSettings {
        try await settings.getRoomNotificationSettings(roomId: roomId, isEncrypted: isEncrypted, isOneToOne: isOneToOne)
    }

    public func setRoomNotificationMode(roomId: String, mode: RoomNotificationMode) async throws {
        try await settings.setRoomNotificationMode(roomId: roomId, mode: mode)
    }

    public func restoreDefaultRoomNotificationMode(roomId: String) async throws {
        try await settings.restoreDefaultRoomNotificationMode(roomId: roomId)
    }

    // MARK: - Default Settings

    public func getDefaultRoomNotificationMode(isEncrypted: Bool, isOneToOne: Bool) async -> RoomNotificationMode {
        await settings.getDefaultRoomNotificationMode(isEncrypted: isEncrypted, isOneToOne: isOneToOne)
    }

    public func setDefaultRoomNotificationMode(isEncrypted: Bool, isOneToOne: Bool, mode: RoomNotificationMode) async throws {
        try await settings.setDefaultRoomNotificationMode(isEncrypted: isEncrypted, isOneToOne: isOneToOne, mode: mode)
    }

    // MARK: - Toggles

    public func isRoomMentionEnabled() async throws -> Bool {
        try await settings.isRoomMentionEnabled()
    }

    public func setRoomMentionEnabled(enabled: Bool) async throws {
        try await settings.setRoomMentionEnabled(enabled: enabled)
    }

    public func isCallEnabled() async throws -> Bool {
        try await settings.isCallEnabled()
    }

    public func setCallEnabled(enabled: Bool) async throws {
        try await settings.setCallEnabled(enabled: enabled)
    }

    public func isInviteForMeEnabled() async throws -> Bool {
        try await settings.isInviteForMeEnabled()
    }

    public func setInviteForMeEnabled(enabled: Bool) async throws {
        try await settings.setInviteForMeEnabled(enabled: enabled)
    }

    public func containsKeywordsRules() async -> Bool {
        await settings.containsKeywordsRules()
    }

    public func getRoomsWithUserDefinedRules(enabled: Bool?) async -> [String] {
        await settings.getRoomsWithUserDefinedRules(enabled: enabled)
    }
}
