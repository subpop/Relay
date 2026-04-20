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
import RelayInterface

/// A mock implementation of ``TimelineViewModelProtocol`` for use in SwiftUI previews.
///
/// All actions are no-ops. The view model is initialized with configurable sample data
/// to allow previewing different states (loaded, loading, empty, with typing indicators, etc.).
@Observable
final class PreviewTimelineViewModel: TimelineViewModelProtocol {
    var messages: [TimelineMessage]
    var messagesVersion: UInt = 0
    var isLoading: Bool
    var isLoadingMore = false
    var hasReachedStart: Bool
    var hasReachedEnd: Bool = true
    var firstUnreadMessageId: String?
    var typingUserDisplayNames: [String]
    var timelineFocus: TimelineFocusState = .live

    init(
        messages: [TimelineMessage]? = nil,
        isLoading: Bool = false,
        hasReachedStart: Bool = false,
        firstUnreadMessageId: String? = nil,
        typingUserDisplayNames: [String] = []
    ) {
        self.messages = messages ?? Self.sampleMessages
        self.isLoading = isLoading
        self.hasReachedStart = hasReachedStart
        self.firstUnreadMessageId = firstUnreadMessageId
        self.typingUserDisplayNames = typingUserDisplayNames
    }

    func loadTimeline(focusedOnEventId fullyReadEventId: String? = nil) async {}
    func loadMoreHistory() async {}
    func loadMoreFuture() async {}
    func focusOnEvent(eventId: String) async { timelineFocus = .focusedOnEvent(eventId) }
    func returnToLive() async { timelineFocus = .live }
    func sendFullyReadReceipt(upTo eventId: String) async {}
    func send(text: String, inReplyTo eventId: String?, mentionedUserIds: [String]) async {}
    func sendAttachment(url: URL, caption: String?) async {}
    func edit(messageId: String, newText: String, mentionedUserIds: [String]) async {}
    func toggleReaction(messageId: String, key: String) async {}
    func redact(messageId: String, reason: String?) async {}
    func pin(eventId: String) async {}
    func unpin(eventId: String) async {}

    nonisolated static let sampleMessages: [TimelineMessage] = [
        .init(id: "1", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
              body: "Hey, has anyone tried the **new build**?",
              timestamp: .now.addingTimeInterval(-3600), isOutgoing: false),
        .init(id: "2", senderID: "@bob:matrix.org", senderDisplayName: "Bob",
              body: "Not yet — pulling it now.",
              timestamp: .now.addingTimeInterval(-3540), isOutgoing: false),
        .init(id: "3", senderID: "@me:matrix.org",
              body: "Just pushed a fix for the sync issue. Check https://matrix.org for details!",
              timestamp: .now.addingTimeInterval(-3300), isOutgoing: true,
              reactions: [
                .init(
                    key: "🎉", count: 2,
                    senderIDs: ["@alice:matrix.org", "@bob:matrix.org"],
                    highlightedByCurrentUser: false
                ),
                .init(
                    key: "🚀", count: 1,
                    senderIDs: ["@alice:matrix.org"],
                    highlightedByCurrentUser: false
                )
              ]),
        .init(id: "4", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
              body: "Nice, rooms are loading *way* faster now.",
              timestamp: .now.addingTimeInterval(-3120), isOutgoing: false,
              reactions: [
                .init(key: "👍", count: 1, senderIDs: ["@me:matrix.org"], highlightedByCurrentUser: true)
              ],
              replyDetail: .init(
                eventID: "3", senderID: "@me:matrix.org",
                senderDisplayName: "Me",
                body: "Just pushed a fix for the sync issue."
              )),
        .init(id: "5", senderID: "@bob:matrix.org", senderDisplayName: "Bob",
              body: "I've been testing for about 20 minutes now and the timeline loads almost instantly. The scroll performance is way better too — no more stuttering when scrolling through history.",
              timestamp: .now.addingTimeInterval(-2400), isOutgoing: false),
        .init(id: "6", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
              body: "Agreed! The typing indicator looks great in that little capsule. Much cleaner than the old layout.",
              timestamp: .now.addingTimeInterval(-1800), isOutgoing: false),
        .init(id: "7", senderID: "@me:matrix.org",
              body: "Thanks! The NSTableView migration made a huge difference for cell recycling.",
              timestamp: .now.addingTimeInterval(-1200), isOutgoing: true),
        .init(id: "7b", senderID: "@charlie:matrix.org", senderDisplayName: "Charlie",
              body: "joined the room.",
              timestamp: .now.addingTimeInterval(-900), isOutgoing: false, kind: .membership),
        .init(id: "8", senderID: "@charlie:matrix.org", senderDisplayName: "Charlie",
              body: "Hey everyone! Just joined. What did I miss?",
              timestamp: .now.addingTimeInterval(-600), isOutgoing: false),
        .init(id: "9", senderID: "@bob:matrix.org", senderDisplayName: "Bob",
              body: "Hey [Johnny Appleseed](https://matrix.to/#/@jappleseed:matrix.org), check this out — the sync is way faster now!",
              timestamp: .now.addingTimeInterval(-300), isOutgoing: false,
              isHighlighted: true),
        .init(id: "10", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
              body: "One more thing — has anyone noticed the reply threading? It looks really polished.",
              timestamp: .now.addingTimeInterval(-120), isOutgoing: false),
        .init(id: "11", senderID: "@me:matrix.org",
              body: "Yeah, we extracted it into its own view. Much easier to maintain now.",
              timestamp: .now.addingTimeInterval(-60), isOutgoing: true)
    ]
}
