// swiftlint:disable file_length
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
import os

private let logger = Logger(subsystem: "RelayKit", category: "MatrixService")

/// The concrete implementation of ``MatrixServiceProtocol`` backed by the Matrix Rust SDK.
///
/// ``MatrixService`` acts as a thin facade that coordinates several focused sub-services:
/// - ``AuthenticationService`` — login, session restore, OAuth/OIDC
/// - ``SyncManager`` — sync lifecycle and state observation
/// - ``RoomListManager`` — room list polling and sorting
/// - ``MediaService`` — avatar and media caching/fetching
/// - ``DirectorySearchService`` — public room directory search
///
/// This class is `@Observable` and `@MainActor`-isolated so that SwiftUI views can bind
/// directly to its published state.
@Observable
// swiftlint:disable:next type_body_length
public final class MatrixService: MatrixServiceProtocol {

    public private(set) var authState: AuthState = .unknown
    public var syncState: SyncState { syncManager.syncState }
    public var rooms: [RelayInterface.RoomSummary] { roomListManager.rooms }
    public var spaces: [RelayInterface.RoomSummary] { spaceListManager.spaces }

    public var isSyncing: Bool { syncState == .syncing || syncState == .running }
    public var hasLoadedRooms: Bool { roomListManager.hasLoadedRooms }

    public private(set) var isSessionVerified: Bool = false
    public private(set) var hasCheckedVerificationState: Bool = false
    public var pendingVerificationRequest: IncomingVerificationRequest?
    public var shouldPresentVerificationSheet: Bool = false
    public var pendingDeepLink: MatrixURI?
    public let errorReporter = ErrorReporter()

    /// Callback invoked when a room has new notification-worthy unread activity.
    ///
    /// The app layer sets this to post system notifications. The callback
    /// provides the room name, room ID, message body, and whether it's a mention.
    public var onNotificationEvent: ((RoomNotificationEvent) -> Void)? {
        didSet { roomListManager.onNotificationEvent = onNotificationEvent }
    }

    // MARK: - Private State

    private var client: ClientProxy?
    private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var timelineViewModels: [String: TimelineViewModel] = [:]
    /// Room IDs ordered by most-recent access (last element = most recent).
    /// Used to implement LRU eviction for ``timelineViewModels``.
    @ObservationIgnored private var timelineAccessOrder: [String] = []
    /// Maximum number of ``TimelineViewModel`` instances to keep cached.
    /// When exceeded, the least-recently-used entry is evicted.
    private let timelineCacheCapacity = 10
    private var cachedNotificationKeywords: [String] = []
    private var verificationController: SessionVerificationControllerProxy?
    private var verificationObservationTask: Task<Void, Never>?
    private var verificationStateTask: Task<Void, Never>?


    // MARK: - Sub-Services

    private let auth = AuthenticationService()
    private let networkMonitor = NetworkMonitor()
    private let syncManager: SyncManager
    private let roomListManager = RoomListManager()
    private let spaceListManager = SpaceListManager()
    private let media = MediaService()
    private let directorySearch = DirectorySearchService()

    /// Creates a new ``MatrixService``. Call ``restoreSession()`` after initialization to
    /// attempt automatic sign-in from a previously saved keychain session.
    public init() {
        syncManager = SyncManager(networkMonitor: networkMonitor)
    }

    // MARK: - Session Restore

    public func restoreSession() async {
        if let (restoredClient, userId) = await auth.restoreSession() {
            client = restoredClient
            await restoredClient.loadProfile()
            authState = .loggedIn(userId: userId)
        } else {
            authState = .loggedOut
        }
    }

    // MARK: - Login

    public func login(username: String, password: String, homeserver: String) async {
        authState = .loggingIn
        do {
            let (newClient, userId) = try await auth.login(
                username: username, password: password, homeserver: homeserver
            )
            client = newClient
            await newClient.loadProfile()
            authState = .loggedIn(userId: userId)
        } catch {
            authState = .error(error.localizedDescription)
        }
    }

    // MARK: - OAuth Login

    public func startOAuthLogin(
        homeserver: String,
        openURL: @escaping @concurrent @Sendable (URL) async throws -> URL
    ) async throws {
        authState = .loggingIn
        do {
            let (newClient, userId) = try await auth.startOAuthLogin(
                homeserver: homeserver,
                openURL: openURL
            )
            client = newClient
            await newClient.loadProfile()
            authState = .loggedIn(userId: userId)
        } catch {
            authState = .error(error.localizedDescription)
        }
    }

    // MARK: - Logout

    public func logout() async {
        // Set authState first so SwiftUI immediately switches to LoginView.
        // This prevents ContentView from seeing syncState == .idle (after
        // syncManager.stop()) and re-triggering startSyncIfNeeded() on the
        // old client while logout is still tearing down.
        authState = .loggedOut

        syncTask?.cancel()
        syncTask = nil
        verificationObservationTask?.cancel()
        verificationObservationTask = nil
        verificationStateTask?.cancel()
        verificationStateTask = nil

        networkMonitor.stop()
        await syncManager.stop()
        try? await client?.logout()

        auth.clearSession()

        client = nil
        verificationController = nil
        isSessionVerified = false
        hasCheckedVerificationState = false
        isVerificationFlowActive = false
        pendingVerificationRequest = nil
        shouldPresentVerificationSheet = false
        roomListManager.reset()
        spaceListManager.reset()
        media.reset()
        timelineViewModels = [:]
        timelineAccessOrder = []
        cachedNotificationKeywords = []
        pendingDeepLink = nil
    }

    // MARK: - Clear Local Data

    public func clearLocalData() async {
        // Tear down sync and background tasks, but keep the keychain session.
        syncTask?.cancel()
        syncTask = nil
        verificationObservationTask?.cancel()
        verificationObservationTask = nil
        verificationStateTask?.cancel()
        verificationStateTask = nil

        networkMonitor.stop()
        await syncManager.stop()

        // Release the current client so the SDK releases its file handles.
        client = nil
        verificationController = nil
        isSessionVerified = false
        hasCheckedVerificationState = false
        isVerificationFlowActive = false
        pendingVerificationRequest = nil
        shouldPresentVerificationSheet = false
        roomListManager.reset()
        spaceListManager.reset()
        media.reset()
        timelineViewModels = [:]
        timelineAccessOrder = []
        cachedNotificationKeywords = []
        pendingDeepLink = nil

        // Delete the on-disk data and cache directories.
        AuthenticationService.resetLocalSessionData()

        // Restore the session from the keychain, rebuilding the client
        // with a fresh data store, then restart sync.
        await restoreSession()
        startSyncIfNeeded()
    }

    // MARK: - Sync

    public func startSyncIfNeeded() {
        guard syncManager.syncState == .idle else { return }
        syncTask = Task { await performSync() }
    }

    private func performSync() async {
        guard let client else { return }

        do {
            // Start network monitoring before sync so the SyncManager can
            // react to connectivity changes from the very beginning.
            networkMonitor.start()

            // Wire the restart callback so SyncManager can notify us when
            // the sync service is rebuilt after a connectivity restoration.
            // RoomListManager re-subscribes to the new service's room list,
            // preserving existing room state and receiving incremental diffs.
            syncManager.onSyncServiceRestarted = { [weak self] syncService in
                guard let self else { return }
                try await self.roomListManager.restart(syncService: syncService)
            }

            try await syncManager.startSync(client: client)
            try await client.startObserving()
            if let sdkController = try? await client.getSessionVerificationController() {
                verificationController = SessionVerificationControllerProxy(controller: sdkController)
                observeVerificationController()
            }
            observeVerificationState(client: client)
            if let syncService = syncManager.syncService {
                try await roomListManager.start(syncService: syncService)
            }
            observeSpaceDescendants()
            await spaceListManager.start(client: client)
            cachedNotificationKeywords = (try? await getNotificationKeywords()) ?? []
            roomListManager.notificationKeywords = cachedNotificationKeywords
            roomListManager.currentUserId = client.userID
        } catch is CancellationError {
            // Logout cancelled the sync — don't overwrite state
        } catch {
            logger.error("Sync failed: \(error)")
        }
    }

    /// Whether a verification flow is currently being managed by a view model.
    ///
    /// When `true`, the `observeVerificationController` observer should not surface
    /// incoming requests as `pendingVerificationRequest` — the active view model
    /// handles them directly.
    private var isVerificationFlowActive = false

    /// Observes the verification controller's flow state for incoming verification requests.
    ///
    /// Only surfaces requests when no verification view model is currently active.
    /// When the user has the verification sheet open (outgoing or incoming), the
    /// ``SessionVerificationViewModel`` handles flow state transitions directly.
    private func observeVerificationController() {
        verificationObservationTask?.cancel()
        verificationObservationTask = Task { [weak self] in
            guard let self, let controller = verificationController else { return }
            while !Task.isCancelled {
                let flowState = await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = controller.flowState
                    } onChange: {
                        Task { @MainActor in
                            continuation.resume(returning: controller.flowState)
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                if case .receivedRequest(let details) = flowState, !isVerificationFlowActive {
                    logger.info("Incoming verification request from device \(details.deviceId)")
                    pendingVerificationRequest = IncomingVerificationRequest(
                        deviceId: String(details.deviceId),
                        senderId: details.senderProfile.userId,
                        flowId: details.flowId
                    )
                }
            }
        }
    }

    /// Observes the SDK encryption verification state and keeps `isSessionVerified` in sync.
    private func observeVerificationState(client: ClientProxy) {
        verificationStateTask?.cancel()
        isSessionVerified = client.encryption().verificationState() == .verified
        hasCheckedVerificationState = true
        verificationStateTask = Task { [weak self] in
            let encryption = client.encryption()
            let listener = SDKListener<MatrixRustSDK.VerificationState> { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.isSessionVerified = state == .verified
                }
            }
            let handle = encryption.verificationStateListener(listener: listener)
            // Keep the handle alive until the task is cancelled.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
            }
            handle.cancel()
        }
    }

    // MARK: - Space Descendants

    /// Observes changes to the space-to-room mapping and propagates `parentSpaceIds`
    /// to each room's ``RoomSummary``.
    ///
    /// When the ``SpaceListManager`` updates its ``SpaceListManager/spaceDescendants``
    /// mapping (due to rooms being added/removed from spaces), this method iterates
    /// through all rooms and updates their `parentSpaceIds` accordingly.
    private func observeSpaceDescendants() {
        spaceListManager.onDescendantsChanged = { [weak self] in
            self?.applySpaceDescendantsToRooms()
        }
        roomListManager.onRoomsRebuilt = { [weak self] in
            self?.applySpaceDescendantsToRooms()
        }
    }

    /// Updates each room and space summary's `parentSpaceIds` from the current space descendants map.
    private func applySpaceDescendantsToRooms() {
        let descendants = spaceListManager.spaceDescendants

        // Apply to rooms
        for room in roomListManager.rooms {
            var newParents = Set<String>()
            for (spaceId, childIds) in descendants where childIds.contains(room.id) {
                newParents.insert(spaceId)
            }
            if room.parentSpaceIds != newParents {
                room.parentSpaceIds = newParents
            }
        }

        // Apply to spaces (so sub-spaces know their parent)
        for space in spaceListManager.spaces {
            var newParents = Set<String>()
            for (spaceId, childIds) in descendants where childIds.contains(space.id) {
                newParents.insert(spaceId)
            }
            if space.parentSpaceIds != newParents {
                space.parentSpaceIds = newParents
            }
        }
    }

    // MARK: - Room Access

    /// Looks up a joined room by its Matrix room identifier.
    ///
    /// - Parameter id: The Matrix room ID.
    /// - Returns: The SDK `Room` object, or `nil` if not found.
    func room(id: String) -> Room? {
        roomListManager.sdkRoom(id: id) ?? client?.rooms().first { $0.id() == id }
    }

    public func userId() -> String? {
        client?.userID
    }

    public func userDisplayName() async -> String? {
        guard let client else { return nil }
        return client.displayName
    }

    public func setDisplayName(_ name: String) async throws {
        guard let client else { return }
        try await client.setDisplayName(name)
    }

    public func userAvatarURL() async -> String? {
        guard let client else { return nil }
        return client.avatarURL?.absoluteString
    }

    public func makeTimelineViewModel(roomId: String) -> (any TimelineViewModelProtocol)? {
        if let cached = timelineViewModels[roomId] {
            touchTimelineAccessOrder(roomId)
            return cached
        }
        guard let room = room(id: roomId) else { return nil }
        let unreadCount = rooms.first(where: { $0.id == roomId })?.unreadMessages ?? 0
        // swiftlint:disable:next identifier_name
        let vm = TimelineViewModel(
            room: room, currentUserId: userId(),
            unreadCount: Int(unreadCount),
            notificationKeywords: cachedNotificationKeywords,
            errorReporter: errorReporter
        )
        timelineViewModels[roomId] = vm
        touchTimelineAccessOrder(roomId)
        evictStaleTimelines()

        // Subscribe to this room at a higher detail level in the sliding sync.
        // This requests additional state events (including m.room.pinned_events)
        // that aren't included in the default room list sync.
        if let rls = roomListManager.roomListService {
            Task {
                try? await rls.subscribeToRooms(roomIds: [roomId])
            }
        }

        return vm
    }

    /// Suspends the timeline view model for a room to free background resources.
    ///
    /// The cached ``TimelineViewModel`` is kept so previously loaded messages are
    /// available for instant display, but its SDK observation tasks and handles
    /// are released.
    public func suspendTimeline(roomId: String) {
        guard let vm = timelineViewModels[roomId], !vm.isSuspended else { return }
        vm.suspend()
        // The SDK's Timeline object is released by suspend(), allowing the
        // Rust runtime to drop its internal resources.  There is no explicit
        // unsubscribe API on RoomListService -- the server-side sliding sync
        // window is managed automatically by the SDK.
        logger.info("Suspended timeline VM for room \(roomId)")
    }

    /// Resumes a previously suspended timeline view model, re-establishing live
    /// observation with the SDK.
    ///
    /// This also re-subscribes to the room in sliding sync so the server
    /// prioritises updates for it again.
    public func resumeTimeline(roomId: String) async {
        await timelineViewModels[roomId]?.resume()

        // Re-subscribe so the sliding sync proxy knows this room is active
        // again and should receive higher-detail updates.
        if let rls = roomListManager.roomListService {
            try? await rls.subscribeToRooms(roomIds: [roomId])
        }
    }

    /// Moves `roomId` to the end of the access-order list (most recently used).
    private func touchTimelineAccessOrder(_ roomId: String) {
        timelineAccessOrder.removeAll { $0 == roomId }
        timelineAccessOrder.append(roomId)
    }

    /// Evicts the least-recently-used timeline view models when the cache
    /// exceeds ``timelineCacheCapacity``. Suspended VMs are evicted first;
    /// if all are active, the oldest is suspended then evicted.
    private func evictStaleTimelines() {
        while timelineViewModels.count > timelineCacheCapacity, !timelineAccessOrder.isEmpty {
            let candidateId = timelineAccessOrder.removeFirst()
            guard let vm = timelineViewModels[candidateId] else { continue }
            if !vm.isSuspended {
                vm.suspend()
            }
            timelineViewModels.removeValue(forKey: candidateId)
            logger.info("Evicted timeline VM for room \(candidateId)")
        }
    }

    // MARK: - Room Management

    public func joinRoom(idOrAlias: String) async throws {
        guard let client else { return }
        _ = try await client.joinRoomByIdOrAlias(roomIdOrAlias: idOrAlias, serverNames: [])
    }

    public func acceptInvite(roomId: String) async throws {
        guard let sdkRoom = room(id: roomId) else { return }
        try await sdkRoom.join()
    }

    public func declineInvite(roomId: String) async throws {
        guard let sdkRoom = room(id: roomId) else { return }
        try await sdkRoom.leave()
    }

    public func createRoom(name: String, topic: String?, isPublic: Bool) async throws -> String {
        guard let client else { throw RelayError.notLoggedIn }
        let params = CreateRoomParameters(
            name: name,
            topic: topic,
            isEncrypted: !isPublic,
            isDirect: false,
            visibility: isPublic ? .public : .private,
            preset: isPublic ? .publicChat : .privateChat
        )
        return try await client.createRoom(parameters: params)
    }

    public func createRoom(options: CreateRoomOptions) async throws -> String {
        guard let client else { throw RelayError.notLoggedIn }
        let params = CreateRoomParameters(
            name: options.name,
            topic: options.topic,
            isEncrypted: options.isEncrypted,
            isDirect: false,
            visibility: options.isPublic ? .public : .private,
            preset: options.isPublic ? .publicChat : .privateChat,
            canonicalAlias: options.address,
            isSpace: options.isSpace
        )
        return try await client.createRoom(parameters: params)
    }

    public func createDirectMessage(userId: String) async throws -> String {
        guard let client else { throw RelayError.notLoggedIn }

        // Check if a DM room already exists with this user
        if let existingRoom = try? client.getDmRoom(userId: userId) {
            return existingRoom.id()
        }

        // Create a new DM room
        let params = CreateRoomParameters(
            name: nil,
            isEncrypted: true,
            isDirect: true,
            visibility: .private,
            preset: .trustedPrivateChat,
            invite: [userId]
        )
        return try await client.createRoom(parameters: params)
    }

    public func makeRoomDirectoryViewModel() -> (any RoomDirectoryViewModelProtocol)? {
        guard let client else { return nil }
        return RoomDirectoryViewModel(client: client, errorReporter: errorReporter)
    }

    public func makeRoomPreviewViewModel(roomId: String) -> (any RoomPreviewViewModelProtocol)? {
        guard let client else { return nil }
        return RoomPreviewViewModel(roomId: roomId, client: client, errorReporter: errorReporter)
    }

    public func makeSpaceHierarchyViewModel(spaceId: String) -> (any SpaceHierarchyViewModelProtocol)? {
        guard let client else { return nil }
        let spaceName = spaceListManager.spaces.first(where: { $0.id == spaceId })?.name ?? ""
        return SpaceHierarchyViewModel(
            spaceId: spaceId,
            spaceName: spaceName,
            client: client,
            errorReporter: errorReporter
        )
    }

    public func leaveRoom(id: String) async throws {
        guard let room = room(id: id) else { return }
        try await room.leave()
        timelineViewModels.removeValue(forKey: id)
        timelineAccessOrder.removeAll { $0 == id }
    }

    public func leaveSpace(spaceId: String) async throws -> [LeaveSpaceChild] {
        guard let client else { return [] }
        let service = await client.spaceService()
        let handle = try await service.leaveSpace(spaceId: spaceId)
        return handle.rooms().map { room in
            LeaveSpaceChild(
                roomId: room.spaceRoom.roomId,
                name: room.spaceRoom.displayName,
                avatarURL: room.spaceRoom.avatarUrl,
                isLastOwner: room.isLastOwner,
                memberCount: room.spaceRoom.numJoinedMembers,
                isSpace: room.spaceRoom.roomType == .space
            )
        }
    }

    public func confirmLeaveSpace(spaceId: String, roomIds: [String]) async throws {
        guard let client else { return }
        let service = await client.spaceService()
        let handle = try await service.leaveSpace(spaceId: spaceId)
        var allIds = roomIds
        if !allIds.contains(spaceId) {
            allIds.append(spaceId)
        }
        try await handle.leave(roomIds: allIds)
        for id in allIds {
            timelineViewModels.removeValue(forKey: id)
            timelineAccessOrder.removeAll { $0 == id }
        }
    }

    public func inviteUser(roomId: String, userId: String) async throws {
        guard let room = room(id: roomId) else { return }
        try await room.inviteUserById(userId: userId)
    }

    public func setRoomName(roomId: String, name: String) async throws {
        guard let room = room(id: roomId) else { return }
        try await room.setName(name: name)
    }

    public func setRoomTopic(roomId: String, topic: String) async throws {
        guard let room = room(id: roomId) else { return }
        try await room.setTopic(topic: topic)
    }

    public func uploadRoomAvatar(roomId: String, mimeType: String, data: Data) async throws {
        guard let room = room(id: roomId) else { return }
        try await room.uploadAvatar(mimeType: mimeType, data: data, mediaInfo: nil)
    }

    public func removeRoomAvatar(roomId: String) async throws {
        guard let room = room(id: roomId) else { return }
        try await room.removeAvatar()
    }

    public func editableSpaces() async -> [EditableSpace] {
        guard let client else { return [] }
        let service = await client.spaceService()
        let sdkSpaces = await service.editableSpaces()
        return sdkSpaces.map { spaceRoom in
            EditableSpace(
                roomId: spaceRoom.roomId,
                name: spaceRoom.displayName,
                avatarURL: spaceRoom.avatarUrl
            )
        }
    }

    public func addChildToSpace(childId: String, spaceId: String) async throws {
        guard let client else { throw RelayError.notLoggedIn }
        let service = await client.spaceService()
        try await service.addChildToSpace(childId: childId, spaceId: spaceId)
    }

    public func removeChildFromSpace(childId: String, spaceId: String) async throws {
        guard let client else { throw RelayError.notLoggedIn }
        let service = await client.spaceService()
        try await service.removeChildFromSpace(childId: childId, spaceId: spaceId)
    }

    public func setFavourite(roomId: String, isFavourite: Bool) async throws {
        guard let room = room(id: roomId) else { return }
        try await room.setIsFavourite(isFavourite: isFavourite, tagOrder: nil)
    }

    // MARK: - Read Receipts & Typing

    public func markAsRead(roomId: String, sendPublicReceipt: Bool) async {
        guard let room = room(id: roomId) else { return }

        // Optimistically clear unread indicators so the room list updates immediately
        // rather than waiting for the server round-trip through the sync loop.
        // The isOptimisticallyCleared flag prevents the room info listener from
        // overwriting these zeros with stale SDK values before the server processes
        // the read receipt.
        if let summary = rooms.first(where: { $0.id == roomId }) {
            summary.unreadMessages = 0
            summary.unreadMentions = 0
            summary.hasKeywordHighlight = false
            summary.isOptimisticallyCleared = true
        }

        let receiptType: ReceiptType = sendPublicReceipt ? .read : .readPrivate
        try? await room.markAsRead(receiptType: receiptType)
    }

    public func fullyReadEventId(roomId: String) async -> String? {
        guard let client else { return nil }
        // Use a nonisolated(unsafe) var to hold the handle alive until the callback fires.
        nonisolated(unsafe) var handle: TaskHandle?
        let result: String? = await withCheckedContinuation { continuation in
            let listener = RoomAccountDataListenerAdapter { event, _ in
                switch event {
                case .fullyReadEvent(let eventId):
                    continuation.resume(returning: eventId)
                default:
                    continuation.resume(returning: nil)
                }
            }
            do {
                handle = try client.observeRoomAccountDataEvent(
                    roomId: roomId,
                    eventType: .fullyRead,
                    listener: listener
                )
            } catch {
                continuation.resume(returning: nil)
            }
        }
        _ = handle // Keep handle alive until continuation resolves
        return result
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
                memberDetails = chunk.compactMap { member -> RoomMemberDetails? in
                    guard member.membership == .join else { return nil }
                    let isCreator = member.suggestedRoleForPowerLevel == .creator
                    let role: RoomMemberDetails.Role = switch member.suggestedRoleForPowerLevel {
                    case .creator, .administrator: .administrator
                    case .moderator: .moderator
                    default: .user
                    }
                    let pl: Int64 = switch member.powerLevel {
                    case .value(let value): value
                    case .infinite: 100
                    }
                    return RoomMemberDetails(
                        userId: member.userId,
                        displayName: member.displayName,
                        avatarURL: member.avatarUrl,
                        role: role,
                        powerLevel: pl,
                        isCreator: isCreator
                    )
                }
            }
        }

        let pinnedEventIds = info?.pinnedEventIds ?? []

        let joinRuleString: String? = switch info?.joinRule {
        case .public: "public"
        case .invite: "invite"
        case .knock: "knock"
        case .restricted: "restricted"
        case .knockRestricted: "knock_restricted"
        case .custom(let rule): rule
        default: nil
        }

        let histVisString: String? = switch info?.historyVisibility {
        case .joined: "joined"
        case .invited: "invited"
        case .shared: "shared"
        case .worldReadable: "world_readable"
        default: nil
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
            members: memberDetails,
            pinnedEventIds: pinnedEventIds,
            joinRule: joinRuleString,
            historyVisibility: histVisString
        )
    }

    // MARK: - Room Members

    public func roomMembers(roomId: String) async -> [RoomMemberDetails] {
        guard let room = room(id: roomId) else { return [] }

        var memberDetails: [RoomMemberDetails] = []
        guard let membersIterator = try? await room.members() else { return [] }

        while let chunk = membersIterator.nextChunk(chunkSize: 500) {
            for member in chunk where member.membership == .join {
                let isCreator = member.suggestedRoleForPowerLevel == .creator
                let role: RoomMemberDetails.Role = switch member.suggestedRoleForPowerLevel {
                case .creator, .administrator: .administrator
                case .moderator: .moderator
                default: .user
                }
                let pl: Int64 = switch member.powerLevel {
                case .value(let value): value
                case .infinite: 100
                }
                memberDetails.append(
                    RoomMemberDetails(
                        userId: member.userId,
                        displayName: member.displayName,
                        avatarURL: member.avatarUrl,
                        role: role,
                        powerLevel: pl,
                        isCreator: isCreator
                    )
                )
            }
        }

        return memberDetails
    }

    // MARK: - Pinned Messages

    // swiftlint:disable:next cyclomatic_complexity
    public func pinnedMessages(roomId: String) async -> [TimelineMessage] {
        guard let room = room(id: roomId) else {
            logger.warning("pinnedMessages: room not found for \(roomId)")
            return []
        }

        let info = try? await room.roomInfo()
        let pinnedIds = info?.pinnedEventIds ?? []
        guard !pinnedIds.isEmpty else { return [] }

        let currentUser = userId()
        var messages: [TimelineMessage] = []

        // Fetch each pinned event directly from the server/cache using
        // Room.loadOrFetchEvent, which works regardless of whether the event
        // is in the loaded timeline window.
        for eventId in pinnedIds {
            do {
                let event = try await room.loadOrFetchEvent(eventId: eventId)
                let content = try event.content()

                guard case .messageLike(let msgContent) = content,
                      case .roomMessage(let messageType, _) = msgContent else {
                    continue
                }

                let body: String
                let kind: TimelineMessage.Kind
                // swiftlint:disable identifier_name
                switch messageType {
                case .text(let c):    body = c.body; kind = .text
                case .emote(let c):   body = c.body; kind = .emote
                case .notice(let c):  body = c.body; kind = .notice
                case .image:          body = "Image"; kind = .image
                case .video:          body = "Video"; kind = .video
                case .audio:          body = "Audio"; kind = .audio
                case .file:           body = "File";  kind = .file
                case .location:       body = "Location"; kind = .location
                case .gallery:        body = "Gallery"; kind = .image
                case .other(_, let b): body = b; kind = .other
                }
                // swiftlint:enable identifier_name

                let senderId = event.senderId()
                let displayName = try? await room.memberDisplayName(userId: senderId)
                let avatarURL = try? await room.memberAvatarUrl(userId: senderId)
                // swiftlint:disable:next identifier_name
                let ts = Date(timeIntervalSince1970: TimeInterval(event.timestamp()) / 1000)

                messages.append(TimelineMessage(
                    id: event.eventId(),
                    senderID: senderId,
                    senderDisplayName: displayName,
                    senderAvatarURL: avatarURL,
                    body: body,
                    timestamp: ts,
                    isOutgoing: senderId == currentUser,
                    kind: kind
                ))
            } catch {
                logger.warning("pinnedMessages: failed to fetch event \(eventId): \(error)")
            }
        }

        return messages
    }

    // MARK: - Directory Search

    public func searchDirectory(query: String) async throws -> [DirectoryRoom] {
        guard let client else { return [] }
        return try await directorySearch.search(query: query, client: client)
    }

    // MARK: - Media

    public func avatarThumbnail(mxcURL: String, size: CGFloat) async -> NSImage? {
        guard let client else { return nil }
        return await media.avatarThumbnail(mxcURL: mxcURL, size: size, client: client)
    }

    public func mediaContent(mxcURL: String, mediaSourceJSON: String?) async -> Data? {
        guard let client else { return nil }
        return await media.mediaContent(mxcURL: mxcURL, mediaSourceJSON: mediaSourceJSON, client: client)
    }

    public func mediaThumbnail(mxcURL: String, mediaSourceJSON: String?, width: UInt64, height: UInt64) async -> Data? {
        guard let client else { return nil }
        return await media.mediaThumbnail(mxcURL: mxcURL, mediaSourceJSON: mediaSourceJSON, width: width, height: height, client: client)
    }

    // MARK: - Notification Settings

    private func notificationSettings() async throws -> NotificationSettings {
        guard let client else { throw RelayError.notLoggedIn }
        return await client.getNotificationSettings()
    }

    private func sdkMode(from mode: DefaultNotificationMode) -> MatrixRustSDK.RoomNotificationMode {
        switch mode {
        case .allMessages: .allMessages
        case .mentionsAndKeywordsOnly: .mentionsAndKeywordsOnly
        case .mute: .mute
        }
    }

    private func appMode(from mode: MatrixRustSDK.RoomNotificationMode) -> DefaultNotificationMode {
        switch mode {
        case .allMessages: .allMessages
        case .mentionsAndKeywordsOnly: .mentionsAndKeywordsOnly
        case .mute: .mute
        }
    }

    private func sdkRoomMode(
        from mode: RelayInterface.RoomNotificationMode
    ) -> MatrixRustSDK.RoomNotificationMode {
        switch mode {
        case .allMessages: .allMessages
        case .mentionsAndKeywordsOnly: .mentionsAndKeywordsOnly
        case .mute: .mute
        }
    }

    private func appRoomMode(
        from mode: MatrixRustSDK.RoomNotificationMode
    ) -> RelayInterface.RoomNotificationMode {
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

    public func hasConsistentNotificationSettings() async throws -> Bool {
        let settings = try await notificationSettings()

        let directEncrypted = await settings.getDefaultRoomNotificationMode(isEncrypted: true, isOneToOne: true)
        let directUnencrypted = await settings.getDefaultRoomNotificationMode(isEncrypted: false, isOneToOne: true)
        let groupEncrypted = await settings.getDefaultRoomNotificationMode(isEncrypted: true, isOneToOne: false)
        let groupUnencrypted = await settings.getDefaultRoomNotificationMode(isEncrypted: false, isOneToOne: false)

        return directEncrypted == directUnencrypted && groupEncrypted == groupUnencrypted
    }

    public func fixInconsistentNotificationSettings() async throws {
        let settings = try await notificationSettings()

        // For each chat type, read the encrypted mode and apply it to unencrypted as well
        let directMode = await settings.getDefaultRoomNotificationMode(isEncrypted: true, isOneToOne: true)
        try await settings.setDefaultRoomNotificationMode(isEncrypted: false, isOneToOne: true, mode: directMode)

        let groupMode = await settings.getDefaultRoomNotificationMode(isEncrypted: true, isOneToOne: false)
        try await settings.setDefaultRoomNotificationMode(isEncrypted: false, isOneToOne: false, mode: groupMode)
    }

    public func roomsWithCustomNotificationSettings() async throws -> [String] {
        let settings = try await notificationSettings()
        let ids = await settings.getRoomsWithUserDefinedRules(enabled: true)
        return Array(Set(ids))
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

    // MARK: - Keyword Notification Settings

    public func getNotificationKeywords() async throws -> [String] {
        guard let client else { throw RelayError.notLoggedIn }
        let session = try client.session()

        var request = URLRequest(
            url: URL(string: "\(client.homeserver)_matrix/client/v3/pushrules/global/")!
        )
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let ruleset = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = ruleset["content"] as? [[String: Any]]
        else {
            return []
        }

        var keywords: [String] = []

        for rule in content {
            guard let isDefault = rule["default"] as? Bool, !isDefault,
                  let enabled = rule["enabled"] as? Bool, enabled,
                  let actions = rule["actions"] as? [Any], !actions.isEmpty,
                  let pattern = rule["pattern"] as? String
            else { continue }
            keywords.append(pattern)
        }

        return keywords
    }

    /// The request body for creating a content-type push rule via the Matrix
    /// REST API. Uses `Codable` for type-safe JSON serialization.
    private struct ContentPushRuleBody: Encodable {
        enum Action: Encodable {
            case notify
            case setTweak(name: String, value: String? = nil)

            func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .notify:
                    try container.encode("notify")
                case .setTweak(let name, let value):
                    var tweakDict: [String: String] = ["set_tweak": name]
                    if let value { tweakDict["value"] = value }
                    try container.encode(tweakDict)
                }
            }
        }

        let pattern: String
        let actions: [Action]
    }

    public func addNotificationKeyword(_ keyword: String) async throws {
        guard let client else { throw RelayError.notLoggedIn }
        let session = try client.session()

        let encodedKeyword = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? keyword
        let url = URL(string: "\(client.homeserver)_matrix/client/v3/pushrules/global/content/\(encodedKeyword)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ContentPushRuleBody(
            pattern: keyword,
            actions: [.notify, .setTweak(name: "highlight"), .setTweak(name: "sound", value: "default")]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            let serverMessage = String(data: data, encoding: .utf8) ?? ""
            throw RelayError.notificationSettingsFailed("Failed to add keyword rule: \(serverMessage)")
        }

        if !cachedNotificationKeywords.contains(keyword) {
            cachedNotificationKeywords.append(keyword)
        }
        roomListManager.notificationKeywords = cachedNotificationKeywords
    }

    public func removeNotificationKeyword(_ keyword: String) async throws {
        guard let client else { throw RelayError.notLoggedIn }
        let session = try client.session()

        let encodedKeyword = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? keyword
        let url = URL(string: "\(client.homeserver)_matrix/client/v3/pushrules/global/content/\(encodedKeyword)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            let serverMessage = String(data: data, encoding: .utf8) ?? ""
            throw RelayError.notificationSettingsFailed("Failed to remove keyword rule: \(serverMessage)")
        }

        cachedNotificationKeywords.removeAll { $0 == keyword }
        roomListManager.notificationKeywords = cachedNotificationKeywords
    }

    // MARK: - Per-Room Notification Settings

    public func getRoomNotificationMode(roomId: String) async throws -> RelayInterface.RoomNotificationMode? {
        guard let sdkRoom = room(id: roomId) else { return nil }
        let settings = try await notificationSettings()
        let info = try? await sdkRoom.roomInfo()
        let isEncrypted = info?.encryptionState != .notEncrypted
        let isOneToOne = info?.isDirect ?? false
        let roomSettings = try await settings.getRoomNotificationSettings(
            roomId: roomId,
            isEncrypted: isEncrypted,
            isOneToOne: isOneToOne
        )
        guard !roomSettings.isDefault else { return nil }
        return appRoomMode(from: roomSettings.mode)
    }

    public func setRoomNotificationMode(
        roomId: String,
        mode: RelayInterface.RoomNotificationMode
    ) async throws {
        let settings = try await notificationSettings()
        try await settings.setRoomNotificationMode(roomId: roomId, mode: sdkRoomMode(from: mode))
    }

    public func restoreDefaultRoomNotificationMode(roomId: String) async throws {
        let settings = try await notificationSettings()
        try await settings.restoreDefaultRoomNotificationMode(roomId: roomId)
    }

    // MARK: - Power Levels

    public func setMemberPowerLevel(roomId: String, userId: String, powerLevel: Int64) async throws {
        guard let sdkRoom = room(id: roomId) else { return }
        let update = UserPowerLevelUpdate(userId: userId, powerLevel: powerLevel)
        try await sdkRoom.updatePowerLevelsForUsers(updates: [update])
    }

    // MARK: - Room Access Settings

    public func updateJoinRule(roomId: String, rule: String) async throws {
        guard let sdkRoom = room(id: roomId) else { return }
        let joinRule: JoinRule = switch rule {
        case "public": .public
        case "invite": .invite
        case "knock": .knock
        default: .invite
        }
        try await sdkRoom.updateJoinRules(newRule: joinRule)
    }

    public func updateHistoryVisibility(roomId: String, visibility: String) async throws {
        guard let sdkRoom = room(id: roomId) else { return }
        let histVis: MatrixRustSDK.RoomHistoryVisibility = switch visibility {
        case "joined": .joined
        case "invited": .invited
        case "shared": .shared
        case "world_readable": .worldReadable
        default: .shared
        }
        try await sdkRoom.updateHistoryVisibility(visibility: histVis)
    }

    public func updateRoomVisibility(roomId: String, isPublic: Bool) async throws {
        guard let sdkRoom = room(id: roomId) else { return }
        let visibility: RoomVisibility = isPublic ? .public : .private
        try await sdkRoom.updateRoomVisibility(visibility: visibility)
    }

    // MARK: - Member Moderation

    public func kickMember(roomId: String, userId: String, reason: String?) async throws {
        guard let sdkRoom = room(id: roomId) else { return }
        try await sdkRoom.kickUser(userId: userId, reason: reason)
    }

    public func banMember(roomId: String, userId: String, reason: String?) async throws {
        guard let sdkRoom = room(id: roomId) else { return }
        try await sdkRoom.banUser(userId: userId, reason: reason)
    }

    public func unbanMember(roomId: String, userId: String) async throws {
        guard let sdkRoom = room(id: roomId) else { return }
        try await sdkRoom.unbanUser(userId: userId, reason: nil)
    }

    // MARK: - Ignore List

    public func isUserIgnored(userId: String) async throws -> Bool {
        guard let client else { return false }
        let ignored = try await client.ignoredUsers()
        return ignored.contains(userId)
    }

    public func ignoreUser(userId: String) async throws {
        guard let client else { throw RelayError.notLoggedIn }
        try await client.ignoreUser(userId: userId)
    }

    public func unignoreUser(userId: String) async throws {
        guard let client else { throw RelayError.notLoggedIn }
        try await client.unignoreUser(userId: userId)
    }

    // MARK: - Session Verification

    public func makeSessionVerificationViewModel() async throws -> (any SessionVerificationViewModelProtocol)? {
        guard let controller = verificationController else { return nil }
        isVerificationFlowActive = true
        let viewModel = SessionVerificationViewModel(controller: controller, errorReporter: errorReporter)
        // Reset the flag when the view model is deallocated (sheet dismissed).
        Task { [weak self, weak viewModel] in
            // Wait until the view model is released.
            while viewModel != nil {
                try? await Task.sleep(for: .milliseconds(500))
            }
            self?.isVerificationFlowActive = false
        }
        return viewModel
    }

    public func makeCallViewModel(roomId: String) -> (any CallViewModelProtocol)? {
        guard let client else { return nil }
        do {
            let session = try client.session()
            let sdkRoom = room(id: roomId)
            let context = CallViewModel.EncryptionContext(
                homeserver: client.homeserver,
                accessToken: session.accessToken,
                userID: client.userID,
                deviceID: client.deviceID,
                roomID: roomId,
                matrixRoom: sdkRoom
            )
            return CallViewModel(encryptionContext: context)
        } catch {
            logger.warning("Could not create encryption context, falling back to unencrypted call: \(error.localizedDescription)")
            return CallViewModel()
        }
    }

    public func callCredentials(for roomId: String) async throws -> (livekitURL: String, token: String) {
        guard let client else {
            throw LiveKitCredentialError.serverError
        }
        let session = try client.session()
        let service = LiveKitCredentialService(
            homeserver: client.homeserver,
            accessToken: session.accessToken,
            userID: client.userID,
            deviceID: client.deviceID
        )
        let result = try await service.credentials(for: roomId)
        return (livekitURL: result.url, token: result.token)
    }

    public func declinePendingVerificationRequest() async {
        pendingVerificationRequest = nil
        try? await verificationController?.cancelVerification()
    }

    public func isCurrentSessionVerified() async -> Bool {
        guard let client else { return false }
        return client.encryption().verificationState() == .verified
    }

    public func encryptionState() async -> EncryptionStatus {
        guard let client else { return EncryptionStatus() }
        let encryption = client.encryption()
        return EncryptionStatus(
            backupEnabled: encryption.backupState() == .enabled,
            recoveryEnabled: encryption.recoveryState() == .enabled
        )
    }

    // MARK: - Devices

    // swiftlint:disable nesting
    private struct DevicesResponse: Decodable {
        struct Device: Decodable {
            let deviceId: String
            let displayName: String?
            let lastSeenIP: String?
            let lastSeenTS: UInt64?

            enum CodingKeys: String, CodingKey {
                case deviceId = "device_id"
                case displayName = "display_name"
                case lastSeenIP = "last_seen_ip"
                case lastSeenTS = "last_seen_ts"
            }
        }
        let devices: [Device]
    }
    // swiftlint:enable nesting

    public func getDevices() async throws -> [DeviceInfo] {
        guard let client else { throw RelayError.notLoggedIn }

        let currentDeviceId = client.deviceID
        let session = try client.session()

        var request = URLRequest(url: URL(string: "\(client.homeserver)_matrix/client/v3/devices")!)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(DevicesResponse.self, from: data)

        return response.devices.map { device in
            let lastSeen: Date? = device.lastSeenTS.map {
                Date(timeIntervalSince1970: TimeInterval($0) / 1000)
            }
            return DeviceInfo(
                id: device.deviceId,
                displayName: device.displayName,
                lastSeenIP: device.lastSeenIP,
                lastSeenTimestamp: lastSeen,
                isCurrentDevice: device.deviceId == currentDeviceId
            )
        }
    }
}
