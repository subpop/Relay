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

import Foundation
import MatrixKit
import Observation

/// Centralized view model for the ``TimelineInspectorView`` that loads and manages
/// all data needed by the inspector tabs (room details, members, notifications,
/// security state, and power levels).
@Observable
final class TimelineInspectorViewModel {
    // MARK: - Room Details

    var details: RoomDetails?
    var isLoading = true

    /// Human-readable load failure, when details could not be resolved.
    var loadError: String?

    // MARK: - Members

    var allMembers: [RoomMemberDetails] = []
    var isLoadingMembers = false

    // MARK: - Notifications

    var roomNotificationMode: RoomNotificationMode?
    var isNotificationDefault: Bool { roomNotificationMode == nil }
    var isLoadingNotifications = true

    // MARK: - Context

    /// The inspector context (room or space).
    let context: InspectorContext

    // MARK: - State

    private var client: RelayClient?
    private(set) var roomId: String

    init(roomId: String, context: InspectorContext = .room) {
        self.roomId = roomId
        self.context = context
    }

    // MARK: - Loading

    func load(client: RelayClient) async {
        self.client = client
        isLoading = true
        loadError = nil
        details = await client.roomDetails(roomId: roomId)
        allMembers = details?.members ?? []
        if details == nil {
            loadError = "Couldn't load room details."
        }
        isLoading = false
    }

    /// Retry loading after a failure (used by the inspector's error UI).
    func retryLoading() async {
        guard let client else { return }
        await load(client: client)
    }

    func loadAllMembers() async {
        guard let client, !isLoadingMembers else { return }
        isLoadingMembers = true
        allMembers = await client.roomDetails(roomId: roomId)?.members ?? allMembers
        isLoadingMembers = false
    }

    /// Resolve a possibly-stale ``UserProfile`` (e.g. captured when a
    /// timeline member was tapped) against the freshest known member
    /// data. Falls back to a network member fetch when the user isn't
    /// in the cached list yet (e.g. a brand-new joiner), and to the
    /// passed profile when the user can't be found at all.
    func resolveProfile(_ profile: UserProfile) async -> UserProfile {
        if let member = allMembers.first(where: { $0.userId.value == profile.userId }) {
            return UserProfile(member: member)
        }
        await loadAllMembers()
        if let member = allMembers.first(where: { $0.userId.value == profile.userId }) {
            return UserProfile(member: member)
        }
        return profile
    }

    func loadNotificationSettings() async {
        guard let client, isLoadingNotifications else { return }
        roomNotificationMode = try? await client.roomNotificationMode(roomId: roomId)
        isLoadingNotifications = false
    }

    // MARK: - Notification Actions

    func setNotificationMode(_ mode: RoomNotificationMode) {
        guard let client else { return }
        let previousMode = roomNotificationMode
        roomNotificationMode = mode
        Task {
            do {
                try await client.setRoomNotificationMode(roomId: roomId, mode: mode)
            } catch {
                roomNotificationMode = previousMode
            }
        }
    }

    func restoreDefaultNotifications() {
        guard let client else { return }
        let previousMode = roomNotificationMode
        roomNotificationMode = nil
        Task {
            do {
                try await client.restoreDefaultRoomNotificationMode(roomId: roomId)
            } catch {
                roomNotificationMode = previousMode
            }
        }
    }

    // MARK: - Power Level Actions

    func setMemberPowerLevel(userId: String, powerLevel: Int) async throws {
        guard let client else { return }
        try await client.setMemberPowerLevel(
            roomId: roomId, userId: userId, powerLevel: powerLevel)
        // Optimistically update the local member list so the UI reflects the
        // change immediately, rather than re-fetching details which may not
        // yet reflect the new power levels.
        if let index = allMembers.firstIndex(where: { $0.userId.value == userId }) {
            let member = allMembers[index]
            allMembers[index] = RoomMemberDetails(
                userId: member.userId,
                displayName: member.displayName,
                avatarURL: member.avatarURL,
                role: RoomMemberDetails.Role.of(powerLevel),
                powerLevel: powerLevel,
                isCreator: member.isCreator
            )
        }
    }

    // MARK: - Room Access Actions

    func updateJoinRule(_ rule: String) async throws {
        guard let client else { return }
        try await client.updateJoinRule(roomId: roomId, rule: rule)
        await reload()
    }

    func updateHistoryVisibility(_ visibility: String) async throws {
        guard let client else { return }
        try await client.updateHistoryVisibility(roomId: roomId, visibility: visibility)
        await reload()
    }

    func updateRoomVisibility(isPublic: Bool) async throws {
        guard let client else { return }
        try await client.updateRoomVisibility(roomId: roomId, isPublic: isPublic)
        await reload()
    }

    // MARK: - Space Settings Actions

    func setRoomName(_ name: String) async throws {
        guard let client else { return }
        try await client.setRoomName(roomId: roomId, name: name)
        await reload()
    }

    func setRoomTopic(_ topic: String) async throws {
        guard let client else { return }
        try await client.setRoomTopic(roomId: roomId, topic: topic)
        await reload()
    }

    func uploadRoomAvatar(mimeType: String, data: Data) async throws {
        guard let client else { return }
        try await client.uploadRoomAvatar(roomId: roomId, mimeType: mimeType, data: data)
        await reload()
    }

    func removeRoomAvatar() async throws {
        guard let client else { return }
        try await client.removeRoomAvatar(roomId: roomId)
        await reload()
    }

    // MARK: - Alias Actions

    func updateCanonicalAlias(_ alias: String?, altAliases: [String]) async throws {
        guard let client else { return }
        try await client.updateCanonicalAlias(roomId: roomId, alias: alias, altAliases: altAliases)

        // Optimistically update local details so the UI reflects the change
        // immediately, without waiting for sync to propagate the state event.
        if let current = details {
            details = RoomDetails(
                id: current.id,
                name: current.name,
                topic: current.topic,
                avatarURL: current.avatarURL,
                isEncrypted: current.isEncrypted,
                isPublic: current.isPublic,
                isDirect: current.isDirect,
                canonicalAlias: alias,
                alternativeAliases: altAliases,
                memberCount: current.memberCount,
                members: current.members,
                pinnedEventIds: current.pinnedEventIds,
                joinRule: current.joinRule,
                historyVisibility: current.historyVisibility,
                permissions: current.permissions,
                powerLevelSettings: current.powerLevelSettings
            )
        }
    }

    @discardableResult
    func publishRoomAlias(_ alias: String) async throws -> Bool {
        guard let client else { return false }
        return try await client.publishRoomAlias(roomId: roomId, alias: alias)
    }

    @discardableResult
    func removeRoomAlias(_ alias: String) async throws -> Bool {
        guard let client else { return false }
        try await client.removeRoomAlias(alias)
        return true
    }

    func isRoomAliasAvailable(_ alias: String) async throws -> Bool {
        guard let client else { return false }
        return try await client.isRoomAliasAvailable(alias)
    }

    // MARK: - Permission Actions

    func updatePowerLevelSettings(_ settings: RoomPowerLevelSettings) async throws {
        guard let client else { return }
        try await client.updatePowerLevelSettings(roomId: roomId, settings: settings)
        await reload()
    }

    /// Whether the current user has admin privileges in this room.
    var isCurrentUserAdmin: Bool {
        guard let currentUserId else { return false }
        return allMembers.first { $0.userId.value == currentUserId }?.role == .administrator
    }

    /// The current user's fine-grained capabilities within this room.
    var permissions: RoomPermissions? { details?.permissions }

    /// The numeric power level thresholds configured for this room.
    var powerLevelSettings: RoomPowerLevelSettings? { details?.powerLevelSettings }

    /// Whether the current user can edit any room detail (name, topic, or avatar).
    var canEditRoomDetails: Bool {
        permissions?.canEditName == true
            || permissions?.canEditTopic == true
            || permissions?.canEditAvatar == true
    }

    /// Whether the current user can change the room's join rule.
    var canEditJoinRules: Bool { permissions?.canEditJoinRules ?? false }

    /// Whether the current user can change the room's history visibility.
    var canEditHistoryVisibility: Bool { permissions?.canEditHistoryVisibility ?? false }

    /// Whether the current user can edit the room's canonical alias and alternative aliases.
    var canEditCanonicalAlias: Bool { permissions?.canEditCanonicalAlias ?? false }

    /// Whether the current user can edit any room access setting (join rules or history visibility).
    var canEditAccess: Bool { canEditJoinRules || canEditHistoryVisibility }

    // MARK: - Helpers

    var currentUserId: String? {
        client?.userId()
    }

    /// The current user's homeserver domain, derived from their user ID.
    /// Used to construct full room aliases (e.g. `#room:matrix.org`).
    var homeserver: String? {
        guard let userId = currentUserId,
              let atIndex = userId.firstIndex(of: ":") else { return nil }
        return String(userId[userId.index(after: atIndex)...])
    }

    /// Reloads room details from the server.
    private func reload() async {
        guard let client else { return }
        details = await client.roomDetails(roomId: roomId)
    }

    /// Creates a view model pre-populated with preview data for use in `#Preview` blocks.
    ///
    /// - Parameters:
    ///   - roomId: The room ID for the preview.
    ///   - context: The inspector context (`.room` or `.space`).
    ///   - asAdmin: When `true`, the preview user (`@preview:matrix.org`) is given the
    ///     administrator role so that admin-gated UI (e.g. editable security settings) is visible.
    static func preview(
        roomId: String = "!design:matrix.org",
        context: InspectorContext = .room,
        asAdmin: Bool = false,
        isDirect: Bool = false
    ) -> TimelineInspectorViewModel {
        let vm = TimelineInspectorViewModel(roomId: roomId, context: context)
        let previewRole: RoomMemberDetails.Role = asAdmin ? .administrator : .user
        let previewPowerLevel: Int = asAdmin ? 100 : 0
        let previewPermissions: RoomPermissions? = asAdmin ? RoomPermissions(
            canEditName: true, canEditTopic: true, canEditAvatar: true,
            canInvite: true, canKick: true, canBan: true,
            canRedactOther: true, canChangePermissions: true,
            canPin: true, canEditJoinRules: true, canEditHistoryVisibility: true,
            canEditCanonicalAlias: true, canSendMessages: true
        ) : RoomPermissions()
        let previewPowerLevelSettings: RoomPowerLevelSettings? = asAdmin
            ? RoomPowerLevelSettings() : nil
        let details = RoomDetails(
            id: RoomId(unchecked: roomId),
            name: "Design Team",
            topic: "A place for the team to collaborate and share ideas.",
            isEncrypted: true,
            isDirect: isDirect,
            canonicalAlias: "#design-team:matrix.org",
            alternativeAliases: ["#design:matrix.org"],
            memberCount: 5,
            members: [
                RoomMemberDetails(
                    userId: UserId(unchecked: "@alice:matrix.org"),
                    displayName: "Alice Smith",
                    role: .administrator, powerLevel: 100, isCreator: true
                ),
                RoomMemberDetails(
                    userId: UserId(unchecked: "@bob:matrix.org"),
                    displayName: "Bob Chen",
                    role: .moderator, powerLevel: 50
                ),
                RoomMemberDetails(
                    userId: UserId(unchecked: "@charlie:matrix.org"),
                    displayName: "Charlie Davis"),
                RoomMemberDetails(
                    userId: UserId(unchecked: "@diana:matrix.org"),
                    displayName: "Diana Evans"),
                RoomMemberDetails(
                    userId: UserId(unchecked: "@preview:matrix.org"),
                    displayName: "You",
                    role: previewRole, powerLevel: previewPowerLevel
                ),
            ],
            pinnedEventIds: ["$pinned1", "$pinned2"],
            joinRule: "invite",
            historyVisibility: "shared",
            permissions: previewPermissions,
            powerLevelSettings: previewPowerLevelSettings
        )
        vm.details = details
        vm.allMembers = details.members
        vm.isLoading = false
        vm.isLoadingNotifications = false
        return vm
    }
}
