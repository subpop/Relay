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

private struct SwipeIsLockedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The current horizontal swipe offset applied during a swipe-to-reply gesture.
    /// Child views can read this to render swipe-dependent UI (e.g. a reply arrow).
    var swipeOffset: CGFloat {
        get { self[SwipeOffsetKey.self] }
        set { self[SwipeOffsetKey.self] = newValue }
    }

    /// Whether the swipe action bar is locked open and awaiting a button tap.
    var swipeIsLocked: Bool {
        get { self[SwipeIsLockedKey.self] }
        set { self[SwipeIsLockedKey.self] = newValue }
    }
}

/// A single row in the timeline, rendering either a system event or a user message
/// with its date header, group spacer, and link preview.
///
/// Extracted from ``TimelineView`` so that SwiftUI can diff and re-evaluate each
/// row independently based only on its own inputs, rather than re-evaluating the
/// entire parent view's 20+ `@State` properties on every frame.
///
/// Interactive callbacks (reply, reaction, context menu, etc.) are read from
/// the ``TimelineActions`` environment value, injected by the renderer.
struct TimelineRowView: View, Equatable {
    let row: MessageRow
    let isNewlyAppended: Bool
    let isHighlighted: Bool
    let isUnreadDivider: Bool
    let showURLPreviews: Bool

    /// Called when this row appears on screen (for read receipt advancement).
    var onAppear: (MessageRow) -> Void
    /// Returns the current per-message translation state. Closure-typed so
    /// the row doesn't need a reference to the whole timeline view model.
    var translationStateProvider: (String) -> MessageTranslationState = { _ in .idle }
    /// Returns whether the Translate item should appear in the context
    /// menu for this message — false for non-text kinds, very short
    /// bodies, or text whose detected language is in the user's
    /// readable set.
    var canTranslateProvider: (String) -> Bool = { _ in false }
    /// Bumped by the view model whenever any translation state changes;
    /// reading it in `body` participates in observation so the row
    /// re-renders on state transitions.
    var translationsVersion: UInt = 0

    /// The horizontal swipe offset for this row, or 0 when not swiped.
    /// Pre-computed by the parent renderer from the shared swipe state so
    /// that `TimelineRowView` does not need to observe the `@Observable`
    /// swipe state object directly (which would invalidate every visible
    /// row on each swipe frame).
    var swipeOffset: CGFloat = 0

    /// Whether the swipe action bar on this row is locked open.
    var swipeIsLocked: Bool = false

    /// Explicitly provided actions (used by the NSTableView renderer where
    /// environment injection isn't possible on the concrete type).
    var injectedActions: TimelineActions?

    @Environment(\.timelineActions) private var environmentActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var actions: TimelineActions { injectedActions ?? environmentActions }

    /// Drives the entry animation for newly appended messages. Starts
    /// `false` for new messages and is set to `true` on appear.
    @State private var didAppear = false

    /// The bubble frame captured from ``MessageView``, used when presenting
    /// the reaction picker from the context menu.
    @State private var lastBubbleFrame: CGRect = .zero

    nonisolated static func == (lhs: TimelineRowView, rhs: TimelineRowView) -> Bool {
        lhs.row.message == rhs.row.message
            && lhs.row.info == rhs.row.info
            && lhs.row.isPaginationTrigger == rhs.row.isPaginationTrigger
            && lhs.row.translation == rhs.row.translation
            && lhs.translationsVersion == rhs.translationsVersion
            && lhs.isNewlyAppended == rhs.isNewlyAppended
            && lhs.swipeOffset == rhs.swipeOffset
            && lhs.swipeIsLocked == rhs.swipeIsLocked
            && lhs.isHighlighted == rhs.isHighlighted
            && lhs.isUnreadDivider == rhs.isUnreadDivider
            && lhs.showURLPreviews == rhs.showURLPreviews
    }

    private var message: TimelineMessage { row.message }
    private var info: MessageGroupInfo { row.info }

    /// Whether this row should animate in.
    private var shouldAnimate: Bool { isNewlyAppended && !didAppear }

    var body: some View {
        VStack(spacing: 0) {
            rowContent
        }
        .padding(.horizontal, 16)
        .environment(\.timelineActions, injectedActions ?? environmentActions)
        .environment(\.swipeOffset, swipeOffset)
        .environment(\.swipeIsLocked, swipeIsLocked)
        .opacity(shouldAnimate ? 0 : 1)
        .animation(
            isNewlyAppended ? .easeOut(duration: 0.1) : nil,
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
        if isUnreadDivider {
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

        if let collapsedEvents = row.collapsedSystemEvents {
            CollapsedSystemEventsView(
                messages: collapsedEvents,
                groupID: message.id,
                expandedGroups: actions.expandedGroups
            )
            .id(message.id)
            .onAppear { onAppear(row) }
        } else if message.isSystemEvent {
            SystemEventView(message: message)
                .id(message.id)
                .help(message.formattedTime)
                .onAppear { onAppear(row) }
                .messageHighlight(isHighlighted) {
                    actions.highlightDismissed()
                }
        } else {
            MessageView(
                message: message,
                isLastInGroup: info.isLastInGroup,
                showSenderName: info.showSenderName,
                replyIsAdjacentAbove: info.replyIsAdjacentAbove,
                // Translation state is baked into `row.translation` by the
                // row builder, so reading it directly keeps the row the
                // single source of truth when the table reloads it after a
                // translation lands.
                translation: row.translation
            )
            .id(message.id)
            // When translated, hover tooltip surfaces the original body
            // (more useful than the timestamp on a translated row).
            .help(row.translation.hoverHelpText(originalBody: message.body, fallback: message.formattedTime))
            .onAppear { onAppear(row) }
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named("timeline"))
            } action: { newFrame in
                lastBubbleFrame = newFrame
            }
            .contextMenu {
                contextMenu
            }
            .messageHighlight(isHighlighted) {
                actions.highlightDismissed()
            }

            if showURLPreviews, message.kind == .text,
               let url = URLPreviewExtractor.firstPreviewURL(in: message.body) {
                LinkPreviewView(url: url, isOutgoing: message.isOutgoing, messageID: message.id)
                    .padding(.leading, message.isOutgoing ? 0 : 34)
                    .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenu: some View {
        ForEach(TimelineMessageContextMenu.entries(for: message, permissions: actions.permissions).enumerated(), id: \.offset) { _, entry in
            contextMenuEntry(entry)
        }
        translationMenuEntry
    }

    /// Translation toggle, appended once at the end of the row's context
    /// menu. Hidden for non-translatable messages (already-readable
    /// language, non-text kinds, very short text). The state determines
    /// the label: idle/failed → "Translate", loading → disabled
    /// "Translating…", translated → "Show Original".
    @ViewBuilder
    private var translationMenuEntry: some View {
        switch row.translation {
        case .idle, .failed:
            if canTranslateProvider(message.id) {
                Divider()
                Button {
                    actions.contextAction(.translate(message))
                } label: {
                    Label("Translate Message", systemImage: "translate")
                }
            }
        case .loading:
            Divider()
            Button { } label: {
                Label("Translating…", systemImage: "translate")
            }
            .disabled(true)
        case .translated:
            Divider()
            Button {
                actions.contextAction(.showOriginal(message))
            } label: {
                Label("Show Original", systemImage: "translate")
            }
        }
    }

    @ViewBuilder
    private func contextMenuEntry(_ entry: TimelineMessageContextMenuEntry) -> some View {
        switch entry {
        case .reply:
            Button {
                actions.contextAction(.reply(message))
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
        case .copyMessage:
            Button {
                actions.contextAction(.copy(message.body))
            } label: {
                Label("Copy Message", systemImage: "doc.on.doc")
            }
        case .addReaction:
            Button {
                actions.presentReactionPicker(message.eventID, lastBubbleFrame, message.isOutgoing)
            } label: {
                Label("Add Reaction\u{2026}", systemImage: "face.smiling")
            }
        case .togglePin:
            Button {
                actions.contextAction(.togglePin(message.eventID))
            } label: {
                Label("Pin/Unpin", systemImage: "pin")
            }
        case .edit:
            Button {
                actions.contextAction(.edit(message))
            } label: {
                Label("Edit Message", systemImage: "pencil")
            }
        case .separatorBeforeDelete:
            Divider()
        case .delete:
            Button(role: .destructive) {
                actions.contextAction(.delete(message))
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

}

// MARK: - Date Labels

/// Formats a date into a human-readable section label for timeline date headers.
/// Used by ``TimelineRowView`` and ``CollapsedSystemEventsView``.
func dateSectionLabel(for date: Date) -> String {
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

extension MessageTranslationState {
    /// Hover tooltip text. When translated we show the original body so
    /// users can compare; otherwise we fall back to the message's
    /// formatted timestamp like normal.
    func hoverHelpText(originalBody: String, fallback: String) -> String {
        if case .translated = self {
            return originalBody
        }
        return fallback
    }
}

// MARK: - Previews

private func previewRow(_ message: TimelineMessage, info: MessageGroupInfo = .default) -> some View {
    TimelineRowView(
        row: .init(message: message, info: info, isPaginationTrigger: false, translation: .idle),
        isNewlyAppended: false,
        isHighlighted: false,
        isUnreadDivider: false,
        showURLPreviews: true,
        onAppear: { _ in }
    )
    .environment(\.timelineActions, TimelineActions(currentUserID: "@me:matrix.org"))
}

#Preview("Conversation") {
    let messages = PreviewTimelineViewModel.sampleMessages
    let rows = MessageRowBuilder.buildRows(for: messages, hasReachedStart: true)

    ScrollView {
        VStack(spacing: 2) {
            ForEach(rows) { row in
                TimelineRowView(
                    row: row,
                    isNewlyAppended: false,
                    isHighlighted: false,
                    isUnreadDivider: false,
                    showURLPreviews: true,
                    onAppear: { _ in }
                )
            }
        }
        .padding()
    }
    .environment(\.timelineActions, TimelineActions(currentUserID: "@me:matrix.org"))
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
                .init(key: "\u{1F389}", count: 3, senderIDs: ["@alice:matrix.org", "@bob:matrix.org", "@charlie:matrix.org"], highlightedByCurrentUser: false),
                .init(key: "\u{1F680}", count: 1, senderIDs: ["@alice:matrix.org"], highlightedByCurrentUser: false),
                .init(key: "\u{1F44D}", count: 2, senderIDs: ["@bob:matrix.org", "@me:matrix.org"], highlightedByCurrentUser: true)
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
    let rows = MessageRowBuilder.buildRows(for: messages, hasReachedStart: true)

    ScrollView {
        VStack(spacing: 2) {
            ForEach(rows) { row in
                TimelineRowView(
                    row: row,
                    isNewlyAppended: false,
                    isHighlighted: false,
                    isUnreadDivider: row.message.id == "5",
                    showURLPreviews: true,
                    onAppear: { _ in }
                )
            }
        }
        .padding()
    }
    .environment(\.timelineActions, TimelineActions(currentUserID: "@me:matrix.org"))
    .frame(width: 500, height: 500)
}

#Preview("Swipe Action Bar") {
    VStack(spacing: 16) {
        TimelineRowView(
            row: .init(
                message: .init(id: "1", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
                      body: "Incoming message with swipe",
                      timestamp: .now, isOutgoing: false),
                info: .init(isLastInGroup: true, showSenderName: true),
                isPaginationTrigger: false
            ),
            isNewlyAppended: false,
            isHighlighted: false,
            isUnreadDivider: false,
            showURLPreviews: true,
            onAppear: { _ in },
            swipeOffset: 80
        )

        TimelineRowView(
            row: .init(
                message: .init(id: "2", senderID: "@me:matrix.org",
                      body: "Outgoing message with swipe",
                      timestamp: .now, isOutgoing: true),
                info: .init(isLastInGroup: true),
                isPaginationTrigger: false
            ),
            isNewlyAppended: false,
            isHighlighted: false,
            isUnreadDivider: false,
            showURLPreviews: true,
            onAppear: { _ in },
            swipeOffset: 80
        )

        TimelineRowView(
            row: .init(
                message: .init(id: "3", senderID: "@me:matrix.org",
                      body: "Short",
                      timestamp: .now, isOutgoing: true),
                info: .init(isLastInGroup: true),
                isPaginationTrigger: false
            ),
            isNewlyAppended: false,
            isHighlighted: false,
            isUnreadDivider: false,
            showURLPreviews: true,
            onAppear: { _ in },
            swipeOffset: 80
        )
    }
    .environment(\.timelineActions, TimelineActions(currentUserID: "@me:matrix.org"))
    .padding()
    .frame(width: 500)
}
