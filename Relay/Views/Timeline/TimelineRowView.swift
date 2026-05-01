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

import RelayInterface
import SwiftUI

// MARK: - Swipe Offset Environment

private struct SwipeOffsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// The current horizontal swipe offset applied during a swipe-to-reply gesture.
    /// Child views can read this to render swipe-dependent UI (e.g. a reply arrow).
    var swipeOffset: CGFloat {
        get { self[SwipeOffsetKey.self] }
        set { self[SwipeOffsetKey.self] = newValue }
    }
}

/// A single row in the timeline, rendering either a system event or a user message
/// with its date header, group spacer, and link preview.
///
/// Extracted from ``TimelineView`` so that SwiftUI can diff and re-evaluate each
/// row independently based only on its own inputs, rather than re-evaluating the
/// entire parent view's 20+ `@State` properties on every frame.
struct TimelineRowView: View, Equatable {
    let row: MessageRow
    let isNewlyAppended: Bool
    let showUnreadMarker: Bool
    let firstUnreadMessageId: String?
    let highlightedMessageId: String?
    let showURLPreviews: Bool
    let currentUserID: String?

    var onToggleReaction: (String, String) -> Void
    var onTapReply: (String) -> Void
    var onReply: (TimelineMessage) -> Void
    var onAvatarDoubleTap: (TimelineMessage) -> Void
    var onUserTap: (String) -> Void
    var onRoomTap: ((String) -> Void)?
    var onAppear: (MessageRow) -> Void
    var onContextAction: (TimelineRowContextAction) -> Void
    var onHighlightDismissed: () -> Void

    /// Observable swipe state from the table view controller. When the user
    /// swipes this row, the offset and reply arrow are rendered here.
    var swipeState: TimelineSwipeState?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Drives the entry animation for newly appended messages. Starts
    /// `false` for new messages and is set to `true` on appear.
    @State private var didAppear = false

    nonisolated static func == (lhs: TimelineRowView, rhs: TimelineRowView) -> Bool {
        lhs.row.message == rhs.row.message
            && lhs.row.info == rhs.row.info
            && lhs.row.isPaginationTrigger == rhs.row.isPaginationTrigger
            && lhs.isNewlyAppended == rhs.isNewlyAppended
            && lhs.showUnreadMarker == rhs.showUnreadMarker
            && lhs.firstUnreadMessageId == rhs.firstUnreadMessageId
            && lhs.highlightedMessageId == rhs.highlightedMessageId
            && lhs.showURLPreviews == rhs.showURLPreviews
            && lhs.currentUserID == rhs.currentUserID
    }

    private var message: TimelineMessage { row.message }
    private var info: MessageGroupInfo { row.info }

    /// The current swipe offset for this row, or 0 if not being swiped.
    private var currentSwipeOffset: CGFloat {
        guard let swipeState, swipeState.swipingMessageId == row.message.id else { return 0 }
        return swipeState.offset
    }

    /// Whether this row should animate in.
    private var shouldAnimate: Bool { isNewlyAppended && !didAppear }

    var body: some View {
        rowContent
            .padding(.horizontal, 16)
            .environment(\.swipeOffset, currentSwipeOffset)
            .offset(x: currentSwipeOffset)
            .opacity(shouldAnimate ? 0 : 1)
            .animation(
                isNewlyAppended ? .easeOut(duration: 0.2) : nil,
                value: didAppear
            )
            .onAppear {
                if isNewlyAppended && !didAppear {
                    didAppear = true
                }
            }
    }

    @ViewBuilder
    private var rowContent: some View {
        if showUnreadMarker && message.id == firstUnreadMessageId {
            unreadMarker
        }

        if info.showDateHeader {
            Text(dateSectionLabel(for: message.timestamp))
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.top, info.isFirst ? 4 : 12)
                .padding(.bottom, 4)
        }

        if info.showGroupSpacer {
            Spacer().frame(height: 8)
        }

        if message.isSystemEvent {
            SystemEventView(message: message)
                .id(message.id)
                .help(message.formattedTime)
                .onAppear { onAppear(row) }
                .messageHighlight(highlightedMessageId == message.eventID) {
                    onHighlightDismissed()
                }
        } else {
            MessageView(
                message: message,
                isLastInGroup: info.isLastInGroup,
                showSenderName: info.showSenderName,
                onToggleReaction: { key in
                    onToggleReaction(message.eventID, key)
                },
                onTapReply: { eventID in
                    onTapReply(eventID)
                },
                onAvatarDoubleTap: {
                    onAvatarDoubleTap(message)
                },
                onUserTap: { userId in
                    onUserTap(userId)
                },
                onRoomTap: onRoomTap,
                currentUserID: currentUserID
            )
            .id(message.id)
            .help(message.formattedTime)
            .onAppear { onAppear(row) }
            .contextMenu {
                contextMenu
            }
            .messageHighlight(highlightedMessageId == message.eventID) {
                onHighlightDismissed()
            }

            if showURLPreviews, message.kind == .text,
               let url = TimelineView.firstPreviewURL(in: message.body) {
                LinkPreviewView(url: url, isOutgoing: message.isOutgoing, messageID: message.id)
                    .padding(.leading, message.isOutgoing ? 0 : 34)
                    .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenu: some View {
        Button {
            onContextAction(.reply(message))
        } label: {
            Label("Reply", systemImage: "arrowshape.turn.up.left")
        }

        Button {
            onContextAction(.copy(message.body))
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }

        if message.eventID.hasPrefix("$") {
            Button {
                onContextAction(.togglePin(message.eventID))
            } label: {
                // The actual pinned state is resolved by the parent
                Label("Pin/Unpin", systemImage: "pin")
            }
        }

        if message.isOutgoing && message.kind == .text {
            Button {
                onContextAction(.edit(message))
            } label: {
                Label("Edit Message", systemImage: "pencil")
            }
        }

        if message.isOutgoing && message.kind != .redacted {
            Divider()

            Button(role: .destructive) {
                onContextAction(.delete(message))
            } label: {
                Label("Delete Message", systemImage: "trash")
            }
        }
    }

    // MARK: - Unread Marker

    private var unreadMarker: some View {
        HStack(spacing: 8) {
            VStack { Divider() }
            Text("New")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.red)
            VStack { Divider() }
        }
        .padding(.vertical, 4)
        .transition(.opacity)
    }

    // MARK: - Date Labels

    private func dateSectionLabel(for date: Date) -> String {
        let calendar = Calendar.current
        let now = Date.now

        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday \(date.formatted(date: .omitted, time: .shortened))"
        } else if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return date.formatted(.dateTime.weekday(.wide).hour().minute())
        } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        } else {
            return date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute())
        }
    }
}

/// Actions that a ``TimelineRowView`` can request from its parent via the
/// `onContextAction` callback. Keeps the row view free of parent state references.
enum TimelineRowContextAction {
    case reply(TimelineMessage)
    case copy(String)
    case togglePin(String)
    case edit(TimelineMessage)
    case delete(TimelineMessage)
}
// MARK: - Previews

private func previewRow(_ message: TimelineMessage, info: MessageGroupInfo = .default) -> TimelineRowView {
    TimelineRowView(
        row: .init(message: message, info: info, isPaginationTrigger: false),
        isNewlyAppended: false,
        showUnreadMarker: false,
        firstUnreadMessageId: nil,
        highlightedMessageId: nil,
        showURLPreviews: true,
        currentUserID: "@me:matrix.org",
        onToggleReaction: { _, _ in },
        onTapReply: { _ in },
        onReply: { _ in },
        onAvatarDoubleTap: { _ in },
        onUserTap: { _ in },
        onRoomTap: nil,
        onAppear: { _ in },
        onContextAction: { _ in },
        onHighlightDismissed: {}
    )
}

#Preview("Conversation") {
    let messages = PreviewTimelineViewModel.sampleMessages
    let rows = TimelineView.buildRows(for: messages, hasReachedStart: true)

    ScrollView {
        VStack(spacing: 2) {
            ForEach(rows) { row in
                TimelineRowView(
                    row: row,
                    isNewlyAppended: false,
                    showUnreadMarker: false,
                    firstUnreadMessageId: nil,
                    highlightedMessageId: nil,
                    showURLPreviews: true,
                    currentUserID: "@me:matrix.org",
                    onToggleReaction: { _, _ in },
                    onTapReply: { _ in },
                    onReply: { _ in },
                    onAvatarDoubleTap: { _ in },
                    onUserTap: { _ in },
                    onRoomTap: nil,
                    onAppear: { _ in },
                    onContextAction: { _ in },
                    onHighlightDismissed: {}
                )
            }
        }
        .padding()
    }
    .frame(width: 500, height: 700)
}

#Preview("Incoming Message") {
    previewRow(
        .init(id: "1", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
              body: "Hey, has anyone tried the **new build**? I heard the timeline loads much faster now.",
              timestamp: .now, isOutgoing: false),
        info: .init(isFirst: true, showDateHeader: true, isLastInGroup: true, showSenderName: true)
    )
    .padding()
    .frame(width: 450)
}

#Preview("Outgoing Message") {
    previewRow(
        .init(id: "2", senderID: "@me:matrix.org",
              body: "Just pushed a fix for the sync issue. The timeline should load instantly from cache now.",
              timestamp: .now, isOutgoing: true),
        info: .init(showDateHeader: false, isLastInGroup: true)
    )
    .padding()
    .frame(width: 450)
}

#Preview("Reply") {
    previewRow(
        .init(id: "3", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
              body: "Nice, rooms are loading *way* faster now.",
              timestamp: .now, isOutgoing: false,
              replyDetail: .init(eventID: "2", senderID: "@me:matrix.org",
                                 senderDisplayName: "Me",
                                 body: "Just pushed a fix for the sync issue.")),
        info: .init(isLastInGroup: true, showSenderName: true)
    )
    .padding()
    .frame(width: 450)
}

#Preview("Reactions") {
    previewRow(
        .init(id: "4", senderID: "@me:matrix.org",
              body: "Check out this new feature!",
              timestamp: .now, isOutgoing: true,
              reactions: [
                .init(key: "🎉", count: 3, senderIDs: ["@alice:matrix.org", "@bob:matrix.org", "@charlie:matrix.org"], highlightedByCurrentUser: false),
                .init(key: "🚀", count: 1, senderIDs: ["@alice:matrix.org"], highlightedByCurrentUser: false),
                .init(key: "👍", count: 2, senderIDs: ["@bob:matrix.org", "@me:matrix.org"], highlightedByCurrentUser: true)
              ]),
        info: .init(isLastInGroup: true)
    )
    .padding()
    .frame(width: 450)
}

#Preview("System Event") {
    previewRow(
        .init(id: "5", senderID: "@charlie:matrix.org", senderDisplayName: "Charlie",
              body: "joined the room.",
              timestamp: .now, isOutgoing: false, kind: .membership)
    )
    .padding()
    .frame(width: 450)
}

#Preview("Unread Marker") {
    let messages = Array(PreviewTimelineViewModel.sampleMessages.prefix(5))
    let rows = TimelineView.buildRows(for: messages, hasReachedStart: true)

    ScrollView {
        VStack(spacing: 2) {
            ForEach(rows) { row in
                TimelineRowView(
                    row: row,
                    isNewlyAppended: false,
                    showUnreadMarker: true,
                    firstUnreadMessageId: "5",
                    highlightedMessageId: nil,
                    showURLPreviews: true,
                    currentUserID: "@me:matrix.org",
                    onToggleReaction: { _, _ in },
                    onTapReply: { _ in },
                    onReply: { _ in },
                    onAvatarDoubleTap: { _ in },
                    onUserTap: { _ in },
                    onRoomTap: nil,
                    onAppear: { _ in },
                    onContextAction: { _ in },
                    onHighlightDismissed: {}
                )
            }
        }
        .padding()
    }
    .frame(width: 500, height: 500)
}

