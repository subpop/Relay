import Foundation
import RelayCore

@Observable
final class PreviewRoomDetailViewModel: RoomDetailViewModelProtocol {
    var messages: [TimelineMessage]
    var isLoading: Bool
    var isLoadingMore = false
    var hasReachedStart: Bool
    var firstUnreadMessageId: String?

    init(
        messages: [TimelineMessage]? = nil,
        isLoading: Bool = false,
        hasReachedStart: Bool = false,
        firstUnreadMessageId: String? = nil
    ) {
        self.messages = messages ?? Self.sampleMessages
        self.isLoading = isLoading
        self.hasReachedStart = hasReachedStart
        self.firstUnreadMessageId = firstUnreadMessageId
    }

    func loadTimeline() async {}
    func loadMoreHistory() async {}
    func send(text: String) async {}

    nonisolated static let sampleMessages: [TimelineMessage] = [
        .init(id: "1", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
              body: "Hey, has anyone tried the **new build**?",
              timestamp: .now.addingTimeInterval(-600), isOutgoing: false),
        .init(id: "2", senderID: "@bob:matrix.org", senderDisplayName: "Bob",
              body: "Not yet — pulling it now.",
              timestamp: .now.addingTimeInterval(-540), isOutgoing: false),
        .init(id: "3", senderID: "@me:matrix.org",
              body: "Just pushed a fix for the sync issue. Check https://matrix.org for details!",
              timestamp: .now.addingTimeInterval(-300), isOutgoing: true),
        .init(id: "4", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
              body: "Nice, rooms are loading *way* faster now.",
              timestamp: .now.addingTimeInterval(-120), isOutgoing: false),
        .init(id: "4b", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
              body: "Image", timestamp: .now.addingTimeInterval(-90), isOutgoing: false, kind: .image),
        .init(id: "5", senderID: "@bob:matrix.org", senderDisplayName: "Bob",
              body: "Confirmed, looks great 👍",
              timestamp: .now.addingTimeInterval(-60), isOutgoing: false),
        .init(id: "6", senderID: "@bob:matrix.org", senderDisplayName: "Bob",
              body: "This message was deleted",
              timestamp: .now.addingTimeInterval(-30), isOutgoing: false, kind: .redacted),
    ]
}
