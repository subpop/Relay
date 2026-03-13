import AppKit
import Foundation
import RelayCore

@Observable
final class PreviewMatrixService: MatrixServiceProtocol {
    var authState: AuthState = .loggedIn(userId: "@preview:matrix.org")
    var syncState: SyncState = .running
    var rooms: [RoomSummary] = PreviewMatrixService.sampleRooms
    var isSyncing: Bool { false }

    func restoreSession() async {}
    func login(username: String, password: String, homeserver: String) async {}
    func logout() async {}
    func userId() -> String? { "@preview:matrix.org" }
    func avatarThumbnail(mxcURL: String, size: CGFloat) async -> NSImage? { nil }
    func makeRoomDetailViewModel(roomId: String) -> (any RoomDetailViewModelProtocol)? {
        PreviewRoomDetailViewModel()
    }
    func joinRoom(idOrAlias: String) async throws {}
    func createRoom(name: String, topic: String?, isPublic: Bool) async throws -> String { "!new:matrix.org" }
    func leaveRoom(id: String) async throws {
        rooms.removeAll { $0.id == id }
    }
    func searchDirectory(query: String) async throws -> [DirectoryRoom] {
        let all = [
            DirectoryRoom(roomId: "!design:matrix.org", name: "Design Team", topic: "UI/UX design discussion", alias: "#design:matrix.org", memberCount: 42),
            DirectoryRoom(roomId: "!swift:matrix.org", name: "Swift Developers", topic: "All things Swift", alias: "#swift:matrix.org", memberCount: 1200),
            DirectoryRoom(roomId: "!hq:matrix.org", name: "Matrix HQ", topic: "General Matrix chat", alias: "#matrix-hq:matrix.org", memberCount: 8500),
            DirectoryRoom(roomId: "!rust:matrix.org", name: "Rust Programming", topic: "Rust language discussion", alias: "#rust:matrix.org", memberCount: 650),
        ]
        guard !query.isEmpty else { return all }
        return all.filter { ($0.name ?? "").localizedCaseInsensitiveContains(query) || ($0.alias ?? "").localizedCaseInsensitiveContains(query) }
    }

    static let sampleRooms: [RoomSummary] = [
        RoomSummary(
            id: "!design:matrix.org",
            name: "Design Team",
            avatarURL: nil,
            lastMessage: "Let's finalize the mockups tomorrow",
            lastMessageTimestamp: .now.addingTimeInterval(-300),
            unreadCount: 3,
            unreadMentions: 1,
            isDirect: false
        ),
        RoomSummary(
            id: "!alice:matrix.org",
            name: "Alice",
            avatarURL: nil,
            lastMessage: "Sounds good, talk soon!",
            lastMessageTimestamp: .now.addingTimeInterval(-7200),
            unreadCount: 0,
            isDirect: true
        ),
        RoomSummary(
            id: "!hq:matrix.org",
            name: "Matrix HQ",
            avatarURL: nil,
            lastMessage: nil,
            lastMessageTimestamp: nil,
            unreadCount: 0,
            isDirect: false
        ),
        RoomSummary(
            id: "!bob:matrix.org",
            name: "Bob Chen",
            avatarURL: nil,
            lastMessage: "Sent an image",
            lastMessageTimestamp: .now.addingTimeInterval(-86400 * 2),
            unreadCount: 12,
            isDirect: true
        ),
    ]
}
