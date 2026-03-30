import Foundation
import MatrixRustSDK
import os
import RelayCore

private let logger = Logger(subsystem: "RelaySDK", category: "RoomList")

/// Maintains the sorted list of joined rooms by polling the Matrix SDK.
///
/// ``RoomListManager`` periodically fetches all joined rooms from the SDK client,
/// extracts summary information (name, avatar, unread counts, latest message preview),
/// and produces a sorted ``RoomSummary`` array. The polling runs on a background task
/// and can be started/stopped by the caller.
@Observable
@MainActor
final class RoomListManager {
    /// The current sorted list of room summaries.
    private(set) var rooms: [RoomSummary] = []

    /// Whether the initial room list has been loaded.
    private(set) var hasLoadedRooms = false

    private var pollTask: Task<Void, Never>?

    /// Performs an immediate room list refresh and starts background polling.
    ///
    /// The room list is refreshed every 3 seconds in a background task.
    ///
    /// - Parameter client: The authenticated Matrix SDK client.
    func startPolling(client: Client) async {
        await refresh(client: client)
        hasLoadedRooms = true

        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await self?.refresh(client: client)
            }
        }
    }

    /// Stops the background polling task.
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Clears the room list and resets state.
    func reset() {
        stopPolling()
        rooms = []
        hasLoadedRooms = false
    }

    /// Performs a single room list refresh from the SDK.
    ///
    /// - Parameter client: The authenticated Matrix SDK client.
    func refresh(client: Client) async {
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
}
