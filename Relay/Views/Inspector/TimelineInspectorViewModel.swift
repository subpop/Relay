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
import Observation
import RelayInterface

/// Centralized view model for the ``TimelineInspectorView`` that loads and manages
/// all data needed by the inspector tabs (room details, members, notifications,
/// security state, and power levels).
@Observable
final class TimelineInspectorViewModel {
    // MARK: - Room Details

    var details: RoomDetails?
    var isLoading = true

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

    private var matrixService: (any MatrixServiceProtocol)?
    private(set) var roomId: String

    init(roomId: String, context: InspectorContext = .room) {
        self.roomId = roomId
        self.context = context
    }

    // MARK: - Loading

    func load(service: any MatrixServiceProtocol) async {
        matrixService = service
        isLoading = true
        details = await service.roomDetails(roomId: roomId)
        allMembers = details?.members ?? []
        isLoading = false
    }

    func loadAllMembers() async {
        guard let matrixService, !isLoadingMembers else { return }
        isLoadingMembers = true
        allMembers = await matrixService.roomMembers(roomId: roomId)
        isLoadingMembers = false
    }

    func loadNotificationSettings() async {
        guard let matrixService, isLoadingNotifications else { return }
        roomNotificationMode = try? await matrixService.getRoomNotificationMode(roomId: roomId)
        isLoadingNotifications = false
    }

    // MARK: - Notification Actions

    func setNotificationMode(_ mode: RoomNotificationMode) {
        guard let matrixService else { return }
        let previousMode = roomNotificationMode
        roomNotificationMode = mode
        Task {
            do {
                try await matrixService.setRoomNotificationMode(roomId: roomId, mode: mode)
            } catch {
                roomNotificationMode = previousMode
            }
        }
    }

    func restoreDefaultNotifications() {
        guard let matrixService else { return }
        let previousMode = roomNotificationMode
        roomNotificationMode = nil
        Task {
            do {
                try await matrixService.restoreDefaultRoomNotificationMode(roomId: roomId)
            } catch {
                roomNotificationMode = previousMode
            }
        }
    }

    // MARK: - Power Level Actions

    func setMemberPowerLevel(userId: String, powerLevel: Int64) async throws {
        guard let matrixService else { return }
        try await matrixService.setMemberPowerLevel(roomId: roomId, userId: userId, powerLevel: powerLevel)
        // Reload members to reflect the change
        await loadAllMembers()
    }

    // MARK: - Room Access Actions

    func updateJoinRule(_ rule: String) async throws {
        guard let matrixService else { return }
        try await matrixService.updateJoinRule(roomId: roomId, rule: rule)
        await reload()
    }

    func updateHistoryVisibility(_ visibility: String) async throws {
        guard let matrixService else { return }
        try await matrixService.updateHistoryVisibility(roomId: roomId, visibility: visibility)
        await reload()
    }

    func updateRoomVisibility(isPublic: Bool) async throws {
        guard let matrixService else { return }
        try await matrixService.updateRoomVisibility(roomId: roomId, isPublic: isPublic)
        await reload()
    }

    // MARK: - Space Settings Actions

    func setRoomName(_ name: String) async throws {
        guard let matrixService else { return }
        try await matrixService.setRoomName(roomId: roomId, name: name)
        await reload()
    }

    func setRoomTopic(_ topic: String) async throws {
        guard let matrixService else { return }
        try await matrixService.setRoomTopic(roomId: roomId, topic: topic)
        await reload()
    }

    func uploadRoomAvatar(mimeType: String, data: Data) async throws {
        guard let matrixService else { return }
        try await matrixService.uploadRoomAvatar(roomId: roomId, mimeType: mimeType, data: data)
        await reload()
    }

    func removeRoomAvatar() async throws {
        guard let matrixService else { return }
        try await matrixService.removeRoomAvatar(roomId: roomId)
        await reload()
    }

    /// Whether the current user has admin privileges in this room.
    var isCurrentUserAdmin: Bool {
        guard let currentUserId else { return false }
        return allMembers.first { $0.userId == currentUserId }?.role == .administrator
    }

    // MARK: - Helpers

    var currentUserId: String? {
        matrixService?.userId()
    }

    /// Reloads room details from the server.
    private func reload() async {
        guard let matrixService else { return }
        details = await matrixService.roomDetails(roomId: roomId)
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
        asAdmin: Bool = false
    ) -> TimelineInspectorViewModel {
        let vm = TimelineInspectorViewModel(roomId: roomId, context: context)
        let service = PreviewMatrixService()
        vm.matrixService = service
        let previewRole: RoomMemberDetails.Role = asAdmin ? .administrator : .user
        let previewPowerLevel: Int64 = asAdmin ? 100 : 0
        let details = RoomDetails(
            id: roomId,
            name: "Design Team",
            topic: "A place for the team to collaborate and share ideas.",
            isEncrypted: true,
            canonicalAlias: "#design-team:matrix.org",
            memberCount: 5,
            members: [
                RoomMemberDetails(
                    userId: "@alice:matrix.org", displayName: "Alice Smith",
                    role: .administrator, powerLevel: 100
                ),
                RoomMemberDetails(
                    userId: "@bob:matrix.org", displayName: "Bob Chen",
                    role: .moderator, powerLevel: 50
                ),
                RoomMemberDetails(userId: "@charlie:matrix.org", displayName: "Charlie Davis"),
                RoomMemberDetails(userId: "@diana:matrix.org", displayName: "Diana Evans"),
                RoomMemberDetails(
                    userId: "@preview:matrix.org", displayName: "You",
                    role: previewRole, powerLevel: previewPowerLevel
                )
            ],
            pinnedEventIds: ["$pinned1", "$pinned2"],
            joinRule: "invite",
            historyVisibility: "shared"
        )
        vm.details = details
        vm.allMembers = details.members
        vm.isLoading = false
        vm.isLoadingNotifications = false
        return vm
    }
}
