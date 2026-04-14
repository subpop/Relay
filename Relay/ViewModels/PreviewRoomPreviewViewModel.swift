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

/// A mock implementation of ``RoomPreviewViewModelProtocol`` for use in SwiftUI previews.
///
/// Returns static sample room metadata and messages. All actions are no-ops.
@Observable
final class PreviewRoomPreviewViewModel: RoomPreviewViewModelProtocol, TimelineViewModelProtocol {
    var roomName: String?
    var roomTopic: String?
    var roomAvatarURL: String?
    var memberCount: UInt64
    var canonicalAlias: String?
    var messages: [TimelineMessage]
    var isLoading = false
    let roomId: String

    // MARK: - TimelineViewModelProtocol stubs

    var messagesVersion: UInt = 0
    var isLoadingMore = false
    var hasReachedStart = true
    var hasReachedEnd = true
    var firstUnreadMessageId: String?
    var typingUserDisplayNames: [String] = []
    var timelineFocus: TimelineFocusState = .live

    init(
        roomId: String = "!preview:matrix.org",
        roomName: String? = "Swift Developers",
        roomTopic: String? = "All things Swift programming language",
        canonicalAlias: String? = "#swift:matrix.org",
        memberCount: UInt64 = 1200,
        messages: [TimelineMessage]? = nil
    ) {
        self.roomId = roomId
        self.roomName = roomName
        self.roomTopic = roomTopic
        self.canonicalAlias = canonicalAlias
        self.memberCount = memberCount
        self.messages = messages ?? Self.sampleMessages
    }

    func loadPreview() async {
        // No-op for previews; data is already populated.
    }

    // MARK: - TimelineViewModelProtocol (no-op)

    func loadTimeline(focusedOnEventId fullyReadEventId: String?) async {
        // Bump version so TimelineView rebuilds its cached rows from pre-populated messages.
        messagesVersion &+= 1
    }
    func loadMoreHistory() async {}
    func loadMoreFuture() async {}
    func focusOnEvent(eventId: String) async {}
    func returnToLive() async {}
    func sendFullyReadReceipt(upTo eventId: String) async {}
    func send(text: String, inReplyTo eventId: String?, mentionedUserIds: [String]) async {}
    func sendAttachment(url: URL, caption: String?) async {}
    func toggleReaction(messageId: String, key: String) async {}
    func edit(messageId: String, newText: String, mentionedUserIds: [String]) async {}
    func redact(messageId: String, reason: String?) async {}
    func pin(eventId: String) async {}
    func unpin(eventId: String) async {}

    static let sampleMessages: [TimelineMessage] = [
        TimelineMessage(
            id: "$msg1",
            senderID: "@alice:matrix.org",
            senderDisplayName: "Alice Smith",
            body: "Has anyone tried the new Swift concurrency features in 6.0?",
            timestamp: .now.addingTimeInterval(-3600),
            isOutgoing: false
        ),
        TimelineMessage(
            id: "$msg2",
            senderID: "@bob:matrix.org",
            senderDisplayName: "Bob Chen",
            body: "Yes! Typed throws are really useful for library APIs.",
            timestamp: .now.addingTimeInterval(-3500),
            isOutgoing: false
        ),
        TimelineMessage(
            id: "$msg3",
            senderID: "@charlie:matrix.org",
            senderDisplayName: "Charlie Davis",
            body: "I've been using them in my networking layer. The error handling is much cleaner now.",
            timestamp: .now.addingTimeInterval(-3400),
            isOutgoing: false
        )
    ]
}
