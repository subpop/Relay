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
    private var roomViewModels: [String: RoomDetailViewModel] = [:]

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
        roomViewModels = [:]
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

        let sdkRooms = client.rooms().filter { $0.membership() == .joined && !$0.isSpace() }
        var summaries: [RoomSummary] = []

        for room in sdkRooms {
            let name = room.displayName() ?? room.id()
            let avatarUrl = room.avatarUrl()

            var unreadMessages: UInt64 = 0
            var unreadMentions: UInt64 = 0
            var isDirect = false
            if let info = try? await room.roomInfo() {
                unreadMessages = info.numUnreadMessages
                unreadMentions = info.numUnreadMentions
                isDirect = info.isDirect
            }

            let (lastMessage, lastTimestamp) = await latestMessagePreview(for: room)

            summaries.append(RoomSummary(
                id: room.id(),
                name: name,
                avatarURL: avatarUrl,
                lastMessage: lastMessage,
                lastMessageTimestamp: lastTimestamp,
                unreadCount: UInt(unreadMessages),
                unreadMentions: UInt(unreadMentions),
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

    public func userDisplayName() async -> String? {
        guard let client else { return nil }
        return try? await client.displayName()
    }

    public func setDisplayName(_ name: String) async throws {
        guard let client else { return }
        try await client.setDisplayName(name: name)
    }

    public func userAvatarURL() async -> String? {
        guard let client else { return nil }
        return try? await client.avatarUrl()
    }

    public func makeRoomDetailViewModel(roomId: String) -> (any RoomDetailViewModelProtocol)? {
        if let cached = roomViewModels[roomId] { return cached }
        guard let room = room(id: roomId) else { return nil }
        let unreadCount = rooms.first(where: { $0.id == roomId })?.unreadMessages ?? 0
        let vm = RoomDetailViewModel(room: room, currentUserId: userId(), unreadCount: Int(unreadCount))
        roomViewModels[roomId] = vm
        return vm
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
        roomViewModels.removeValue(forKey: id)
    }

    // MARK: - Read Receipts & Typing

    public func markAsRead(roomId: String, sendPublicReceipt: Bool) async {
        guard let room = room(id: roomId) else { return }
        let receiptType: ReceiptType = sendPublicReceipt ? .read : .readPrivate
        try? await room.markAsRead(receiptType: receiptType)
        await refreshRoomList()
    }

    public func sendTypingNotice(roomId: String, isTyping: Bool) async {
        guard let room = room(id: roomId) else { return }
        try? await room.typingNotice(isTyping: isTyping)
    }

    // MARK: - Room Details

    public func roomDetails(roomId: String) async -> RoomDetails? {
        guard let room = room(id: roomId) else { return nil }

        let info = try? await room.roomInfo()
        let name = room.displayName() ?? room.id()
        let topic = info?.topic
        let avatarUrl = room.avatarUrl()
        let isEncrypted = info?.encryptionState != .notEncrypted
        let isPublic = info?.isPublic ?? false
        let isDirect = info?.isDirect ?? false
        let canonicalAlias = info?.canonicalAlias

        let memberCount = info?.joinedMembersCount ?? room.joinedMembersCount()

        var memberDetails: [RoomMemberDetails] = []
        if let membersIterator = try? await room.members() {
            let chunk = membersIterator.nextChunk(chunkSize: 200)
            if let chunk {
                memberDetails = chunk.compactMap { member in
                    guard member.membership == .join else { return nil }
                    let role: RoomMemberDetails.Role = switch member.suggestedRoleForPowerLevel {
                    case .administrator: .administrator
                    case .moderator: .moderator
                    default: .user
                    }
                    return RoomMemberDetails(
                        userId: member.userId,
                        displayName: member.displayName,
                        avatarURL: member.avatarUrl,
                        role: role
                    )
                }
            }
        }

        return RoomDetails(
            id: room.id(),
            name: name,
            topic: topic,
            avatarURL: avatarUrl,
            isEncrypted: isEncrypted,
            isPublic: isPublic,
            isDirect: isDirect,
            canonicalAlias: canonicalAlias,
            memberCount: memberCount,
            members: memberDetails
        )
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

    private static let mediaCache = NSCache<NSString, NSData>()

    public func mediaContent(mxcURL: String) async -> Data? {
        let cacheKey = mxcURL as NSString
        if let cached = Self.mediaCache.object(forKey: cacheKey) {
            return cached as Data
        }
        guard let client else { return nil }
        do {
            let source = try MediaSource.fromUrl(url: mxcURL)
            let data = try await client.getMediaContent(mediaSource: source)
            Self.mediaCache.setObject(data as NSData, forKey: cacheKey)
            return data
        } catch {
            return nil
        }
    }

    public func mediaThumbnail(mxcURL: String, width: UInt64, height: UInt64) async -> Data? {
        let cacheKey = "\(mxcURL)_thumb_\(width)x\(height)" as NSString
        if let cached = Self.mediaCache.object(forKey: cacheKey) {
            return cached as Data
        }
        guard let client else { return nil }
        do {
            let source = try MediaSource.fromUrl(url: mxcURL)
            let data = try await client.getMediaThumbnail(mediaSource: source, width: width, height: height)
            Self.mediaCache.setObject(data as NSData, forKey: cacheKey)
            return data
        } catch {
            return nil
        }
    }

    // MARK: - Notification Settings

    private func notificationSettings() async throws -> NotificationSettings {
        guard let client else { throw MatrixServiceError.notLoggedIn }
        return await client.getNotificationSettings()
    }

    private func sdkMode(from mode: DefaultNotificationMode) -> RoomNotificationMode {
        switch mode {
        case .allMessages: .allMessages
        case .mentionsAndKeywordsOnly: .mentionsAndKeywordsOnly
        case .mute: .mute
        }
    }

    private func appMode(from mode: RoomNotificationMode) -> DefaultNotificationMode {
        switch mode {
        case .allMessages: .allMessages
        case .mentionsAndKeywordsOnly: .mentionsAndKeywordsOnly
        case .mute: .mute
        }
    }

    public func getDefaultNotificationMode(isOneToOne: Bool) async throws -> DefaultNotificationMode {
        let settings = try await notificationSettings()
        let mode = await settings.getDefaultRoomNotificationMode(isEncrypted: true, isOneToOne: isOneToOne)
        return appMode(from: mode)
    }

    public func setDefaultNotificationMode(isOneToOne: Bool, mode: DefaultNotificationMode) async throws {
        let settings = try await notificationSettings()
        let sdkMode = sdkMode(from: mode)
        try await settings.setDefaultRoomNotificationMode(isEncrypted: true, isOneToOne: isOneToOne, mode: sdkMode)
        try await settings.setDefaultRoomNotificationMode(isEncrypted: false, isOneToOne: isOneToOne, mode: sdkMode)
    }

    public func isCallNotificationEnabled() async throws -> Bool {
        try await notificationSettings().isCallEnabled()
    }

    public func setCallNotificationEnabled(_ enabled: Bool) async throws {
        try await notificationSettings().setCallEnabled(enabled: enabled)
    }

    public func isInviteNotificationEnabled() async throws -> Bool {
        try await notificationSettings().isInviteForMeEnabled()
    }

    public func setInviteNotificationEnabled(_ enabled: Bool) async throws {
        try await notificationSettings().setInviteForMeEnabled(enabled: enabled)
    }

    public func isRoomMentionEnabled() async throws -> Bool {
        try await notificationSettings().isRoomMentionEnabled()
    }

    public func setRoomMentionEnabled(_ enabled: Bool) async throws {
        try await notificationSettings().setRoomMentionEnabled(enabled: enabled)
    }

    public func isUserMentionEnabled() async throws -> Bool {
        try await notificationSettings().isUserMentionEnabled()
    }

    public func setUserMentionEnabled(_ enabled: Bool) async throws {
        try await notificationSettings().setUserMentionEnabled(enabled: enabled)
    }

    // MARK: - Devices

    private struct DevicesResponse: Decodable {
        struct Device: Decodable {
            let device_id: String
            let display_name: String?
            let last_seen_ip: String?
            let last_seen_ts: UInt64?
        }
        let devices: [Device]
    }

    public func getDevices() async throws -> [DeviceInfo] {
        guard let client else { throw MatrixServiceError.notLoggedIn }

        let currentDeviceId = try? client.deviceId()
        let session = try client.session()

        var request = URLRequest(url: URL(string: "\(client.homeserver())_matrix/client/v3/devices")!)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(DevicesResponse.self, from: data)

        return response.devices.map { device in
            let lastSeen: Date? = device.last_seen_ts.map {
                Date(timeIntervalSince1970: TimeInterval($0) / 1000)
            }
            return DeviceInfo(
                id: device.device_id,
                displayName: device.display_name,
                lastSeenIP: device.last_seen_ip,
                lastSeenTimestamp: lastSeen,
                isCurrentDevice: device.device_id == currentDeviceId
            )
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
