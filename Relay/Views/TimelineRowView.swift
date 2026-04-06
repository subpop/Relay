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

/// A single row in the timeline, rendering either a system event or a user message
/// with its date header, group spacer, and link preview.
///
/// Extracted from ``TimelineView`` so that SwiftUI can diff and re-evaluate each
/// row independently based only on its own inputs, rather than re-evaluating the
/// entire parent view's 20+ `@State` properties on every frame.
struct TimelineRowView: View, Equatable {
    let row: TimelineView.MessageRow
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
    var onAppear: (TimelineView.MessageRow) -> Void
    var onContextAction: (TimelineRowContextAction) -> Void
    var onHighlightDismissed: () -> Void

    nonisolated static func == (lhs: TimelineRowView, rhs: TimelineRowView) -> Bool {
        lhs.row.message == rhs.row.message
            && lhs.row.info == rhs.row.info
            && lhs.row.isPaginationTrigger == rhs.row.isPaginationTrigger
            && lhs.showUnreadMarker == rhs.showUnreadMarker
            && lhs.firstUnreadMessageId == rhs.firstUnreadMessageId
            && lhs.highlightedMessageId == rhs.highlightedMessageId
            && lhs.showURLPreviews == rhs.showURLPreviews
            && lhs.currentUserID == rhs.currentUserID
    }

    private var message: TimelineMessage { row.message }
    private var info: TimelineView.MessageGroupInfo { row.info }

    var body: some View {
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
                .messageHighlight(highlightedMessageId == message.id) {
                    onHighlightDismissed()
                }
        } else {
            MessageSwipeActions {
                MessageView(
                    message: message,
                    isLastInGroup: info.isLastInGroup,
                    showSenderName: info.showSenderName,
                    onToggleReaction: { key in
                        onToggleReaction(message.id, key)
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
            } onReply: {
                onReply(message)
            }
            .id(message.id)
            .help(message.formattedTime)
            .onAppear { onAppear(row) }
            .contextMenu {
                contextMenu
            }
            .messageHighlight(highlightedMessageId == message.id) {
                onHighlightDismissed()
            }

            if showURLPreviews, message.kind == .text,
               let url = TimelineView.firstPreviewURL(in: message.body) {
                LinkPreviewView(url: url, isOutgoing: message.isOutgoing)
                    .frame(maxWidth: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.systemGray).opacity(0.1))
                    )
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

        if message.id.hasPrefix("$") {
            Button {
                onContextAction(.togglePin(message.id))
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
