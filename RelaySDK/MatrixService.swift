import AppKit
import Foundation
import MatrixRustSDK
import RelayCore
import Synchronization

public enum MatrixServiceError: LocalizedError {
    case notLoggedIn

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: "Not logged in"
        }
    }
}

@Observable
public final class MatrixService: MatrixServiceProtocol {

    public private(set) var authState: AuthState = .unknown
    public private(set) var syncState: SyncState = .idle
    public private(set) var rooms: [RoomSummary] = []

    public var isSyncing: Bool { syncState == .syncing || syncState == .running }

    // MARK: - Private State

    private var client: Client?
    private var syncService: SyncService?
    private var roomPollTask: Task<Void, Never>?
    private var syncStateHandle: TaskHandle?

    // MARK: - Persistence Model

    struct StoredSession: Codable, Sendable {
        var accessToken: String
        var refreshToken: String?
        var userId: String
        var deviceId: String
        var homeserverUrl: String
        var oidcData: String?
    }

    // MARK: - Data Paths

    private static var dataDirectory: URL {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Relay/matrix-data", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var cacheDirectory: URL {
        let url = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Relay/matrix-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public init() {}

    // MARK: - Session Restore

    public func restoreSession() async {
        guard let data = KeychainService.load(),
              let stored = try? JSONDecoder().decode(StoredSession.self, from: data)
        else {
            authState = .loggedOut
            return
        }

        do {
            let builder = ClientBuilder()
                .homeserverUrl(url: stored.homeserverUrl)
                .sessionPaths(
                    dataPath: Self.dataDirectory.path,
                    cachePath: Self.cacheDirectory.path
                )

            let newClient = try await builder.build()

            let session = Session(
                accessToken: stored.accessToken,
                refreshToken: stored.refreshToken,
                userId: stored.userId,
                deviceId: stored.deviceId,
                homeserverUrl: stored.homeserverUrl,
                oidcData: stored.oidcData,
                slidingSyncVersion: .native
            )
            try await newClient.restoreSession(session: session)

            client = newClient
            authState = .loggedIn(userId: stored.userId)
            await startSync()
        } catch {
            authState = .loggedOut
        }
    }

    // MARK: - Login

    public func login(username: String, password: String, homeserver: String) async {
        authState = .loggingIn

        do {
            let builder = ClientBuilder()
                .serverNameOrHomeserverUrl(serverNameOrUrl: homeserver)
                .sessionPaths(
                    dataPath: Self.dataDirectory.path,
                    cachePath: Self.cacheDirectory.path
                )

            let newClient = try await builder.build()

            try await newClient.login(
                username: username,
                password: password,
                initialDeviceName: "Relay",
                deviceId: nil
            )

            client = newClient

            let session = try newClient.session()
            let stored = StoredSession(
                accessToken: session.accessToken,
                refreshToken: session.refreshToken,
                userId: session.userId,
                deviceId: session.deviceId,
                homeserverUrl: session.homeserverUrl,
                oidcData: session.oidcData
            )
            if let encoded = try? JSONEncoder().encode(stored) {
                KeychainService.save(encoded)
            }

            authState = .loggedIn(userId: session.userId)
            await startSync()
        } catch {
            authState = .error(error.localizedDescription)
        }
    }

    // MARK: - Logout

    public func logout() async {
        roomPollTask?.cancel()
        roomPollTask = nil
        syncStateHandle = nil

        if let syncService {
            await syncService.stop()
        }
        try? await client?.logout()

        KeychainService.delete()

        client = nil
        syncService = nil
        rooms = []
        syncState = .idle
        authState = .loggedOut
    }

    // MARK: - Sync

    private func startSync() async {
        guard let client else { return }

        syncState = .syncing

        do {
            let builder = client.syncService()
            let service = try await builder.finish()

            observeSyncState(service)

            await service.start()
            syncService = service

            await waitForFirstSync()
            await refreshRoomList()
            startPollingRooms()
        } catch {
            syncState = .error
        }
    }

    private func observeSyncState(_ service: SyncService) {
        let observer = SyncStateObserverProxy { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .running:
                    self.syncState = .running
                case .idle:
                    self.syncState = .idle
                case .terminated, .error:
                    self.syncState = .error
                case .offline:
                    self.syncState = .idle
                }
            }
        }
        syncStateHandle = service.state(listener: observer)
    }

    private func waitForFirstSync() async {
        for _ in 0..<30 {
            if syncState == .running { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    // MARK: - Room List

    private func startPollingRooms() {
        roomPollTask?.cancel()
        roomPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await self?.refreshRoomList()
            }
        }
    }

    private func refreshRoomList() async {
        guard let client else { return }

        let sdkRooms = client.rooms().filter { $0.membership() == .joined }
        var summaries: [RoomSummary] = []

        for room in sdkRooms {
            let name = room.displayName() ?? room.id()
            let avatarUrl = room.avatarUrl()

            var unreadCount: UInt64 = 0
            var isDirect = false
            if let info = try? await room.roomInfo() {
                unreadCount = info.numUnreadNotifications
                isDirect = info.isDirect
            }

            let (lastMessage, lastTimestamp) = await latestMessagePreview(for: room)

            summaries.append(RoomSummary(
                id: room.id(),
                name: name,
                avatarURL: avatarUrl,
                lastMessage: lastMessage,
                lastMessageTimestamp: lastTimestamp,
                unreadCount: UInt(unreadCount),
                isDirect: isDirect
            ))
        }

        rooms = summaries.sorted { lhs, rhs in
            switch (lhs.lastMessageTimestamp, rhs.lastMessageTimestamp) {
            case (.some(let l), .some(let r)):
                return l > r
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    // MARK: - Latest Message Preview

    private func latestMessagePreview(for room: Room) async -> (String?, Date?) {
        let latest = await room.latestEvent()

        let content: TimelineItemContent
        let timestamp: Timestamp

        switch latest {
        case .remote(let ts, _, _, _, let c):
            content = c
            timestamp = ts
        case .local(let ts, _, _, let c, _):
            content = c
            timestamp = ts
        case .none:
            return (nil, nil)
        }

        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        let preview = contentPreview(content)
        return (preview, date)
    }

    private func contentPreview(_ content: TimelineItemContent) -> String? {
        switch content {
        case .msgLike(let msgLike):
            switch msgLike.kind {
            case .message(let mc):
                switch mc.msgType {
                case .text(let t): return t.body
                case .image: return "Sent an image"
                case .video: return "Sent a video"
                case .audio: return "Sent audio"
                case .file: return "Sent a file"
                case .emote(let e): return "* \(e.body)"
                case .notice(let n): return n.body
                case .location: return "Shared a location"
                case .gallery: return "Sent a gallery"
                case .other: return nil
                }
            case .sticker: return "Sent a sticker"
            case .poll: return "Started a poll"
            case .redacted: return "Message deleted"
            case .unableToDecrypt: return "Encrypted message"
            case .other: return nil
            }
        case .roomMembership: return "Membership changed"
        case .profileChange: return "Profile updated"
        default: return nil
        }
    }

    // MARK: - Room Access

    func room(id: String) -> Room? {
        client?.rooms().first { $0.id() == id }
    }

    public func userId() -> String? {
        try? client?.userId()
    }

    public func makeRoomDetailViewModel(roomId: String) -> (any RoomDetailViewModelProtocol)? {
        guard let room = room(id: roomId) else { return nil }
        return RoomDetailViewModel(room: room, currentUserId: userId())
    }

    // MARK: - Room Management

    public func joinRoom(idOrAlias: String) async throws {
        guard let client else { return }
        _ = try await client.joinRoomByIdOrAlias(roomIdOrAlias: idOrAlias, serverNames: [])
        await refreshRoomList()
    }

    public func createRoom(name: String, topic: String?, isPublic: Bool) async throws -> String {
        guard let client else { throw MatrixServiceError.notLoggedIn }
        let params = CreateRoomParameters(
            name: name,
            topic: topic,
            isEncrypted: !isPublic,
            isDirect: false,
            visibility: isPublic ? .public : .private,
            preset: isPublic ? .publicChat : .privateChat
        )
        let roomId = try await client.createRoom(request: params)
        await refreshRoomList()
        return roomId
    }

    public func leaveRoom(id: String) async throws {
        guard let room = room(id: id) else { return }
        try await room.leave()
        rooms.removeAll { $0.id == id }
    }

    // MARK: - Directory Search

    public func searchDirectory(query: String) async throws -> [DirectoryRoom] {
        guard let client else { return [] }
        let search = client.roomDirectorySearch()
        let collector = DirectorySearchCollector()

        let listener = DirectorySearchListenerProxy { updates in
            collector.apply(updates)
        }

        let handle = await search.results(listener: listener)
        try await search.search(filter: query, batchSize: 20, viaServerName: nil)
        try await Task.sleep(for: .milliseconds(500))

        let results = collector.snapshot()
        withExtendedLifetime(handle) {}
        return results
    }

    // MARK: - Media

    private static let avatarCache = NSCache<NSString, NSImage>()

    public func avatarThumbnail(mxcURL: String, size: CGFloat) async -> NSImage? {
        let scale = 2.0
        let px = UInt64(size * scale)
        let cacheKey = "\(mxcURL)_\(px)" as NSString

        if let cached = Self.avatarCache.object(forKey: cacheKey) {
            return cached
        }

        guard let client else { return nil }

        do {
            let source = try MediaSource.fromUrl(url: mxcURL)
            let data = try await client.getMediaThumbnail(mediaSource: source, width: px, height: px)
            guard let image = NSImage(data: data) else { return nil }
            Self.avatarCache.setObject(image, forKey: cacheKey)
            return image
        } catch {
            return nil
        }
    }
}

// MARK: - Sync State Observer Bridge

nonisolated final class SyncStateObserverProxy: SyncServiceStateObserver, @unchecked Sendable {
    private let handler: @Sendable (SyncServiceState) -> Void

    init(handler: @escaping @Sendable (SyncServiceState) -> Void) {
        self.handler = handler
    }

    func onUpdate(state: SyncServiceState) {
        handler(state)
    }
}

// MARK: - Directory Search Collector

nonisolated private final class DirectorySearchCollector: Sendable {
    private let storage = Mutex<[DirectoryRoom]>([])

    nonisolated func apply(_ updates: [RoomDirectorySearchEntryUpdate]) {
        storage.withLock { results in
            for update in updates {
                switch update {
                case .append(let values):
                    results.append(contentsOf: values.map(DirectoryRoom.from))
                case .clear:
                    results.removeAll()
                case .pushBack(let value):
                    results.append(.from(value))
                case .pushFront(let value):
                    results.insert(.from(value), at: 0)
                case .insert(let index, let value):
                    results.insert(.from(value), at: Int(index))
                case .set(let index, let value):
                    results[Int(index)] = .from(value)
                case .remove(let index):
                    results.remove(at: Int(index))
                case .popFront:
                    if !results.isEmpty { results.removeFirst() }
                case .popBack:
                    if !results.isEmpty { results.removeLast() }
                case .reset(let values):
                    results = values.map(DirectoryRoom.from)
                case .truncate(let length):
                    results = Array(results.prefix(Int(length)))
                }
            }
        }
    }

    nonisolated func snapshot() -> [DirectoryRoom] {
        storage.withLock { $0 }
    }
}

// MARK: - Directory Search Listener Bridge

nonisolated final class DirectorySearchListenerProxy: RoomDirectorySearchEntriesListener, @unchecked Sendable {
    private let handler: @Sendable ([RoomDirectorySearchEntryUpdate]) -> Void

    init(handler: @escaping @Sendable ([RoomDirectorySearchEntryUpdate]) -> Void) {
        self.handler = handler
    }

    func onUpdate(roomEntriesUpdate: [RoomDirectorySearchEntryUpdate]) {
        handler(roomEntriesUpdate)
    }
}

// MARK: - RoomDescription → DirectoryRoom

extension DirectoryRoom {
    nonisolated static func from(_ desc: RoomDescription) -> DirectoryRoom {
        DirectoryRoom(
            roomId: desc.roomId,
            name: desc.name,
            topic: desc.topic,
            alias: desc.alias,
            avatarURL: desc.avatarUrl,
            memberCount: desc.joinedMembers
        )
    }
}
