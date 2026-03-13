import AppKit
import SwiftUI

// MARK: - Shared Enums

public enum AuthState: Equatable, Sendable {
    case unknown
    case loggedOut
    case loggingIn
    case loggedIn(userId: String)
    case error(String)
}

public enum SyncState: Equatable, Sendable {
    case idle
    case syncing
    case running
    case error
}

// MARK: - Protocol

@MainActor
public protocol MatrixServiceProtocol: AnyObject, Observable {
    var authState: AuthState { get }
    var syncState: SyncState { get }
    var rooms: [RoomSummary] { get }
    var isSyncing: Bool { get }

    func restoreSession() async
    func login(username: String, password: String, homeserver: String) async
    func logout() async
    func userId() -> String?
    func avatarThumbnail(mxcURL: String, size: CGFloat) async -> NSImage?
    func makeRoomDetailViewModel(roomId: String) -> (any RoomDetailViewModelProtocol)?
    func joinRoom(idOrAlias: String) async throws
    func createRoom(name: String, topic: String?, isPublic: Bool) async throws -> String
    func leaveRoom(id: String) async throws
    func searchDirectory(query: String) async throws -> [DirectoryRoom]
}

// MARK: - Environment Key

private struct MatrixServiceKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue: any MatrixServiceProtocol = PlaceholderMatrixService()
}

public extension EnvironmentValues {
    var matrixService: any MatrixServiceProtocol {
        get { self[MatrixServiceKey.self] }
        set { self[MatrixServiceKey.self] = newValue }
    }
}

@Observable
private final class PlaceholderMatrixService: MatrixServiceProtocol {
    var authState: AuthState = .unknown
    var syncState: SyncState = .idle
    var rooms: [RoomSummary] = []
    var isSyncing: Bool { false }
    func restoreSession() async {}
    func login(username: String, password: String, homeserver: String) async {}
    func logout() async {}
    func userId() -> String? { nil }
    func avatarThumbnail(mxcURL: String, size: CGFloat) async -> NSImage? { nil }
    func makeRoomDetailViewModel(roomId: String) -> (any RoomDetailViewModelProtocol)? { nil }
    func joinRoom(idOrAlias: String) async throws {}
    func createRoom(name: String, topic: String?, isPublic: Bool) async throws -> String { "" }
    func leaveRoom(id: String) async throws {}
    func searchDirectory(query: String) async throws -> [DirectoryRoom] { [] }
}
