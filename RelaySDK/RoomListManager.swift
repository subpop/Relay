import AsyncAlgorithms
import Foundation
import MatrixRustSDK
import os
import RelayCore

private let logger = Logger(subsystem: "RelaySDK", category: "RoomList")

/// Maintains the sorted list of joined rooms using the SDK's reactive `RoomListService`.
///
/// ``RoomListManager`` subscribes to `RoomListService.allRooms().entriesWithDynamicAdapters()`
/// for incremental room list diffs, and each room subscribes to `Room.subscribeToRoomInfoUpdates()`
/// for live unread counts, display names, and latest message previews. This replaces the
/// previous polling approach with event-driven updates from the Matrix Rust SDK.
@Observable
@MainActor
final class RoomListManager {
    /// The current list of room summaries, updated reactively via SDK diffs.
    private(set) var rooms: [RoomSummary] = []

    /// Whether the initial room list has been loaded.
    private(set) var hasLoadedRooms = false

    /// The current state of the room list service.
    private(set) var roomListServiceState: RoomListServiceState?

    private var roomListService: RoomListService?
    private var entriesHandle: RoomListEntriesWithDynamicAdaptersResult?
    private var serviceStateHandle: TaskHandle?
    private var entriesTask: Task<Void, Never>?

    /// Internal room entries that wrap SDK `Room` objects and manage `subscribeToRoomInfoUpdates`.
    private var roomEntries: [RoomEntry] = []

    /// Debounce task for re-sorting after room info updates.
    private var resortTask: Task<Void, Never>?

    /// Starts the reactive room list using the sync service's `RoomListService`.
    ///
    /// This method subscribes to room list entry diffs and applies them incrementally.
    /// Each room entry subscribes to `subscribeToRoomInfoUpdates` for live property changes.
    ///
    /// - Parameter syncService: The active SDK sync service.
    func start(syncService: SyncService) async throws {
        let rls = syncService.roomListService()
        roomListService = rls

        // Observe room list service state
        let stateListener = AsyncSDKListener<RoomListServiceState>()
        serviceStateHandle = rls.state(listener: stateListener)
        Task { [weak self] in
            for await state in stateListener {
                guard let self else { break }
                self.roomListServiceState = state
            }
        }

        // Subscribe to room list entries with dynamic adapters
        let entriesListener = AsyncSDKListener<[RoomListEntriesUpdate]>()
        let allRooms = try await rls.allRooms()
        let handle = allRooms.entriesWithDynamicAdapters(pageSize: 100, listener: entriesListener)
        _ = handle.controller().setFilter(kind: .all(filters: [.nonLeft, .nonSpace]))
        entriesHandle = handle

        hasLoadedRooms = true

        entriesTask = Task { [weak self] in
            // Throttle rapid entry updates to 500ms batches
            let throttled = entriesListener._throttle(for: .milliseconds(500), reducing: { result, next in
                (result ?? []) + next
            })

            for await updates in throttled {
                guard let self else { break }
                self.applyEntryUpdates(updates)
            }
        }
    }

    /// Stops listening and clears state.
    func reset() {
        entriesTask?.cancel()
        entriesTask = nil
        entriesHandle = nil
        serviceStateHandle = nil
        roomListService = nil
        roomEntries = []
        rooms = []
        hasLoadedRooms = false
        roomListServiceState = nil
    }

    // MARK: - Room Lookup

    /// Returns the SDK `Room` for a given room ID, if known.
    func sdkRoom(id: String) -> Room? {
        roomEntries.first { $0.id == id }?.room
    }

    // MARK: - Private

    /// Called by individual `RoomEntry` instances when their room info updates.
    /// Debounces re-sorting to avoid excessive work when many rooms update at once.
    fileprivate func scheduleResort() {
        resortTask?.cancel()
        resortTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.rebuildRoomSummaries()
        }
    }

    private func makeEntry(room: Room) -> RoomEntry {
        RoomEntry(room: room, onInfoUpdated: { [weak self] in self?.scheduleResort() })
    }

    private func applyEntryUpdates(_ updates: [RoomListEntriesUpdate]) {
        for update in updates {
            switch update {
            case .append(let values):
                let entries = values.map { makeEntry(room: $0) }
                roomEntries.append(contentsOf: entries)
            case .clear:
                roomEntries.removeAll()
            case .pushFront(let value):
                roomEntries.insert(makeEntry(room: value), at: 0)
            case .pushBack(let value):
                roomEntries.append(makeEntry(room: value))
            case .popFront:
                if !roomEntries.isEmpty { roomEntries.removeFirst() }
            case .popBack:
                if !roomEntries.isEmpty { roomEntries.removeLast() }
            case .insert(let index, let value):
                let i = Int(index)
                if i <= roomEntries.count {
                    roomEntries.insert(makeEntry(room: value), at: i)
                }
            case .set(let index, let value):
                let i = Int(index)
                if i < roomEntries.count {
                    let existing = roomEntries[i]
                    if existing.id == value.id() {
                        existing.updateRoom(value)
                    } else {
                        roomEntries[i] = makeEntry(room: value)
                    }
                }
            case .remove(let index):
                let i = Int(index)
                if i < roomEntries.count {
                    roomEntries.remove(at: i)
                }
            case .truncate(let length):
                let len = Int(length)
                if len < roomEntries.count {
                    roomEntries.removeSubrange(len..<roomEntries.count)
                }
            case .reset(let values):
                let existingById = Dictionary(roomEntries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                roomEntries = values.map { room in
                    if let existing = existingById[room.id()] {
                        existing.updateRoom(room)
                        return existing
                    }
                    return makeEntry(room: room)
                }
            }
        }

        // Rebuild the sorted room summaries from room entries
        rebuildRoomSummaries()
    }

    private func rebuildRoomSummaries() {
        rooms = roomEntries.map(\.summary).sorted { lhs, rhs in
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
}

// MARK: - Room Entry

/// Wraps a Matrix SDK `Room` and subscribes to `subscribeToRoomInfoUpdates` for live property changes.
///
/// Each ``RoomEntry`` owns a ``RoomSummary`` that it updates reactively when the SDK delivers
/// room info updates. This preserves object identity so SwiftUI can efficiently diff the room list.
@Observable
@MainActor
private final class RoomEntry: Identifiable {
    let id: String
    private(set) var room: Room
    let summary: RoomSummary

    @ObservationIgnored private var roomInfoHandle: TaskHandle?
    @ObservationIgnored private var listenerTask: Task<Void, Never>?
    @ObservationIgnored private var onInfoUpdated: (() -> Void)?

    init(room: Room, onInfoUpdated: (() -> Void)? = nil) {
        self.id = room.id()
        self.room = room
        self.onInfoUpdated = onInfoUpdated
        self.summary = RoomSummary(
            id: room.id(),
            name: room.displayName() ?? room.id()
        )

        // Fetch initial room info and start listening
        Task { [weak self] in
            guard let self else { return }
            await self.fetchAndApplyRoomInfo()
            self.listenToRoomInfo()
        }
    }

    /// Updates the underlying room reference in-place without replacing this entry.
    func updateRoom(_ newRoom: Room) {
        assert(id == newRoom.id())
        room = newRoom
        listenerTask?.cancel()
        roomInfoHandle = nil

        // Re-fetch info and re-subscribe on the new room reference
        Task { [weak self] in
            guard let self else { return }
            await self.fetchAndApplyRoomInfo()
            self.listenToRoomInfo()
        }
    }

    private func fetchAndApplyRoomInfo() async {
        guard let info = try? await room.roomInfo() else { return }
        applyRoomInfo(info)
    }

    private func listenToRoomInfo() {
        let listener = AsyncSDKListener<RoomInfo>()
        roomInfoHandle = room.subscribeToRoomInfoUpdates(listener: listener)

        listenerTask = Task { [weak self] in
            let throttled = listener._throttle(for: .milliseconds(500))
            for await info in throttled {
                guard let self, !Task.isCancelled else { break }
                self.applyRoomInfo(info)
            }
        }
    }

    private func applyRoomInfo(_ info: RoomInfo) {
        summary.name = info.displayName ?? room.displayName() ?? id
        summary.topic = info.topic
        summary.avatarURL = info.avatarUrl
        summary.unreadMessages = UInt(info.numUnreadMessages)
        summary.unreadMentions = UInt(info.numUnreadMentions)
        summary.isDirect = info.isDirect

        // Extract latest message preview and notify the manager to re-sort
        Task { [weak self] in
            guard let self else { return }
            let (msg, ts) = await self.latestMessagePreview()
            self.summary.lastMessage = msg
            self.summary.lastMessageTimestamp = ts
            self.onInfoUpdated?()
        }
    }

    private func latestMessagePreview() async -> (AttributedString?, Date?) {
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

    private func contentPreview(_ content: TimelineItemContent) -> AttributedString? {
        switch content {
        case .msgLike(let msgLike):
            switch msgLike.kind {
            case .message(let mc):
                switch mc.msgType {
                case .text(let t): return Self.parseMarkdown(t.body)
                case .image: return AttributedString("Sent an image")
                case .video: return AttributedString("Sent a video")
                case .audio: return AttributedString("Sent audio")
                case .file: return AttributedString("Sent a file")
                case .emote(let e): return Self.parseMarkdown("* \(e.body)")
                case .notice(let n): return Self.parseMarkdown(n.body)
                case .location: return AttributedString("Shared a location")
                case .gallery: return AttributedString("Sent a gallery")
                case .other: return nil
                }
            case .sticker: return AttributedString("Sent a sticker")
            case .poll: return AttributedString("Started a poll")
            case .redacted: return AttributedString("Message deleted")
            case .unableToDecrypt: return AttributedString("Encrypted message")
            case .other: return nil
            }
        case .roomMembership: return AttributedString("Membership changed")
        case .profileChange: return AttributedString("Profile updated")
        default: return nil
        }
    }

    /// Parses a raw message body as inline Markdown, falling back to plain text on failure.
    private static func parseMarkdown(_ body: String) -> AttributedString {
        if let md = try? AttributedString(
            markdown: body,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return md
        }
        return AttributedString(body)
    }
}
