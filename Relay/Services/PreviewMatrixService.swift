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
import Foundation
import RelayInterface

/// A mock implementation of ``MatrixServiceProtocol`` for use in SwiftUI previews.
///
/// Returns static sample data for rooms, members, devices, and directory search results.
/// All mutating operations are no-ops (or operate only on the in-memory sample data).
@Observable
final class PreviewMatrixService: MatrixServiceProtocol {
    var authState: AuthState = .loggedIn(userId: "@preview:matrix.org")
    var syncState: SyncState = .running
    var rooms: [RoomSummary] = PreviewMatrixService.sampleRooms
    var isSyncing: Bool { false }
    var hasLoadedRooms: Bool = true
    var isSessionVerified: Bool = true
    var pendingVerificationRequest: IncomingVerificationRequest?
    var shouldPresentVerificationSheet: Bool = false
    var pendingDeepLink: MatrixURI?

    func restoreSession() async {}
    func login(username: String, password: String, homeserver: String) async {}
    func startOAuthLogin(
        homeserver: String,
        openURL: @escaping @concurrent @Sendable (URL) async throws -> URL
    ) async throws {}
    func logout() async {}
    func startSyncIfNeeded() {}
    func userId() -> String? { "@preview:matrix.org" }
    func avatarThumbnail(mxcURL: String, size: CGFloat) async -> NSImage? { nil }
    func makeTimelineViewModel(roomId: String) -> (any TimelineViewModelProtocol)? {
        PreviewTimelineViewModel()
    }
    func joinRoom(idOrAlias: String) async throws {}
    func createRoom(name: String, topic: String?, isPublic: Bool) async throws -> String { "!new:matrix.org" }
    func createRoom(options: CreateRoomOptions) async throws -> String { "!new:matrix.org" }
    func createDirectMessage(userId: String) async throws -> String { "!dm:matrix.org" }
    func makeRoomDirectoryViewModel() -> (any RoomDirectoryViewModelProtocol)? { PreviewRoomDirectoryViewModel() }
    func makeRoomPreviewViewModel(roomId: String) -> (any RoomPreviewViewModelProtocol)? {
        PreviewRoomPreviewViewModel(roomId: roomId)
    }
    func leaveRoom(id: String) async throws {
        rooms.removeAll { $0.id == id }
    }
    func sendTypingNotice(roomId: String, isTyping: Bool) async {}
    func markAsRead(roomId: String, sendPublicReceipt: Bool) async {
        if let room = rooms.first(where: { $0.id == roomId }) {
            room.unreadMessages = 0
            room.unreadMentions = 0
        }
    }
    func fullyReadEventId(roomId: String) async -> String? { nil }
    func roomDetails(roomId: String) async -> RoomDetails? {
        guard let summary = rooms.first(where: { $0.id == roomId }) else { return nil }
        return RoomDetails(
            id: summary.id,
            name: summary.name,
            topic: "A place for the team to collaborate and share ideas.",
            avatarURL: summary.avatarURL,
            isEncrypted: !summary.isDirect,
            isPublic: false,
            isDirect: summary.isDirect,
            canonicalAlias: "#\(summary.name.lowercased().replacing(" ", with: "-")):matrix.org",
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
                RoomMemberDetails(userId: "@preview:matrix.org", displayName: "You")
            ],
            pinnedEventIds: summary.pinnedEventIds,
            joinRule: "invite",
            historyVisibility: "shared"
        )
    }

    func roomMembers(roomId: String) async -> [RoomMemberDetails] {
        await roomDetails(roomId: roomId)?.members ?? []
    }

    func pinnedMessages(roomId: String) async -> [TimelineMessage] {
        guard let summary = rooms.first(where: { $0.id == roomId }),
              summary.hasPinnedMessages else { return [] }
        return [
            TimelineMessage(
                id: "$pinned1",
                senderID: "@alice:matrix.org",
                senderDisplayName: "Alice Smith",
                body: "Please read the project guidelines before contributing: https://wiki.example.org/guidelines",
                timestamp: .now.addingTimeInterval(-86400 * 7),
                isOutgoing: false
            ),
            TimelineMessage(
                id: "$pinned2",
                senderID: "@bob:matrix.org",
                senderDisplayName: "Bob Chen",
                body: "Next team meeting is **Wednesday at 3 PM UTC**. Don't forget!",
                timestamp: .now.addingTimeInterval(-86400 * 2),
                isOutgoing: false
            )
        ]
    }

    func mediaContent(mxcURL: String) async -> Data? { nil }
    func mediaThumbnail(mxcURL: String, width: UInt64, height: UInt64) async -> Data? { nil }
    func userDisplayName() async -> String? { "John Appleseed" }
    func setDisplayName(_ name: String) async throws {}
    func userAvatarURL() async -> String? { nil }

    func getDefaultNotificationMode(isOneToOne: Bool) async throws -> DefaultNotificationMode {
        isOneToOne ? .allMessages : .mentionsAndKeywordsOnly
    }
    func setDefaultNotificationMode(isOneToOne: Bool, mode: DefaultNotificationMode) async throws {}
    func hasConsistentNotificationSettings() async throws -> Bool { true }
    func fixInconsistentNotificationSettings() async throws {}
    var customNotificationRoomIds: [String] = []
    func roomsWithCustomNotificationSettings() async throws -> [String] { customNotificationRoomIds }
    func isCallNotificationEnabled() async throws -> Bool { true }
    func setCallNotificationEnabled(_ enabled: Bool) async throws {}
    func isInviteNotificationEnabled() async throws -> Bool { true }
    func setInviteNotificationEnabled(_ enabled: Bool) async throws {}
    func isRoomMentionEnabled() async throws -> Bool { true }
    func setRoomMentionEnabled(_ enabled: Bool) async throws {}
    func isUserMentionEnabled() async throws -> Bool { true }
    func setUserMentionEnabled(_ enabled: Bool) async throws {}
    func getNotificationKeywords() async throws -> [String] { ["matrix", "relay"] }
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

    func makeSessionVerificationViewModel() async throws -> (any SessionVerificationViewModelProtocol)? {
        PreviewSessionVerificationViewModel()
    }

    func declinePendingVerificationRequest() async {
        pendingVerificationRequest = nil
    }

    func isCurrentSessionVerified() async -> Bool { true }
    func encryptionState() async -> EncryptionStatus { EncryptionStatus(backupEnabled: true, recoveryEnabled: true) }

    func getDevices() async throws -> [DeviceInfo] {
        [
            DeviceInfo(
                id: "ABCDEF1234", displayName: "Relay (macOS)",
                lastSeenIP: "203.0.113.42",
                lastSeenTimestamp: .now.addingTimeInterval(-60),
                isCurrentDevice: true
            ),
            DeviceInfo(
                id: "GHIJKL5678", displayName: "Element (iOS)",
                lastSeenIP: "198.51.100.7",
                lastSeenTimestamp: .now.addingTimeInterval(-3600)
            ),
            DeviceInfo(
                id: "MNOPQR9012", displayName: "Element Web",
                lastSeenIP: "192.0.2.1",
                lastSeenTimestamp: .now.addingTimeInterval(-86400 * 3)
            ),
            DeviceInfo(
                id: "STUVWX3456", displayName: nil,
                lastSeenIP: nil,
                lastSeenTimestamp: .now.addingTimeInterval(-86400 * 30)
            )
        ]
    }

    func searchDirectory(query: String) async throws -> [DirectoryRoom] {
        let all = [
            DirectoryRoom(
                roomId: "!design:matrix.org", name: "Design Team",
                topic: "UI/UX design discussion",
                alias: "#design:matrix.org", memberCount: 42
            ),
            DirectoryRoom(
                roomId: "!swift:matrix.org", name: "Swift Developers",
                topic: "All things Swift",
                alias: "#swift:matrix.org", memberCount: 1200,
                isWorldReadable: true
            ),
            DirectoryRoom(
                roomId: "!hq:matrix.org", name: "Matrix HQ",
                topic: "General Matrix chat",
                alias: "#matrix-hq:matrix.org", memberCount: 8500,
                isWorldReadable: true
            ),
            DirectoryRoom(
                roomId: "!rust:matrix.org", name: "Rust Programming",
                topic: "Rust language discussion",
                alias: "#rust:matrix.org", memberCount: 650
            )
        ]
        guard !query.isEmpty else { return all }
        return all.filter {
            ($0.name ?? "").localizedCaseInsensitiveContains(query)
                || ($0.alias ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    /// Sample room data used to populate the room list in previews.
    static let sampleRooms: [RoomSummary] = [
        RoomSummary(
            id: "!design:matrix.org",
            name: "Design Team",
            topic: "UI/UX design discussion",
            avatarURL: nil,
            lastAuthor: "Alice",
            lastMessage: try? AttributedString(
                markdown: "Let's **finalize** the mockups tomorrow",
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ),
            lastMessageTimestamp: .now.addingTimeInterval(-300),
            unreadCount: 3,
            unreadMentions: 1,
            isDirect: false,
            pinnedEventIds: ["$pinned1", "$pinned2"]
        ),
        RoomSummary(
            id: "!alice:matrix.org",
            name: "Alice",
            avatarURL: nil,
            lastAuthor: "Alice",
            lastMessage: try? AttributedString(
                markdown: "Sounds good, talk *soon*!",
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ),
            lastMessageTimestamp: .now.addingTimeInterval(-7200),
            unreadCount: 0,
            isDirect: true
        ),
        RoomSummary(
            id: "!hq:matrix.org",
            name: "Matrix HQ",
            topic: "General discussion on anything related to Matrix",
            avatarURL: nil,
            lastAuthor: nil,
            lastMessage: nil,
            lastMessageTimestamp: nil,
            unreadCount: 0,
            isDirect: false,
            notificationMode: .mute
        ),
        RoomSummary(
            id: "!bob:matrix.org",
            name: "Bob Chen",
            avatarURL: nil,
            lastAuthor: "Charlie",
            lastMessage: AttributedString("Sent an image"),
            lastMessageTimestamp: .now.addingTimeInterval(-86400 * 2),
            unreadCount: 12,
            isDirect: true
        )
    ]
}
