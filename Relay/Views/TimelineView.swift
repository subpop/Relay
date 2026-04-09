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

import OSLog
import RelayInterface
import SwiftUI
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "Relay", category: "Timeline")

/// The main chat view for a selected room, displaying the message timeline and compose bar.
///
/// ``TimelineView`` loads the room timeline, supports backward pagination, manages
/// scroll anchoring, handles typing notifications, and provides context menus and
/// emoji reaction popovers for individual messages.
struct TimelineView: View { // swiftlint:disable:this type_body_length
    @Environment(\.matrixService) private var matrixService
    @Environment(\.errorReporter) private var errorReporter
    @Environment(\.gifSearchService) private var gifSearchService

    /// The Matrix room identifier for the displayed room.
    let roomId: String

    /// The display name of the room, shown in navigation context.
    let roomName: String

    /// The `mxc://` URL of the room's avatar, if available.
    var roomAvatarURL: String?

    /// The view model managing the room's timeline state and actions.
    @State var viewModel: any TimelineViewModelProtocol

    /// A binding that, when set to a message event ID, causes the timeline to scroll
    /// to that message. Used by ``PinnedMessagesView`` to jump to pinned messages.
    @Binding var focusedMessageId: String?

    /// Called when a user's profile should be shown (e.g. after double-tapping an avatar).
    var onUserTap: ((UserProfile) -> Void)?

    /// Called when the user clicks a `matrix.to` room link, with the room ID or alias.
    var onRoomTap: ((String) -> Void)?

    @State private var draftMessage = ""
    @State private var replyingTo: TimelineMessage?
    @State private var editingMessage: TimelineMessage?
    @State private var stagedAttachments: [StagedAttachment] = []
    @State private var roomMembers: [RoomMemberDetails] = []
    @State private var draftMentions: [Mention] = []
    @State private var mentionQuery: String?
    @State private var mentionSelectedIndex: Int = 0
    @State private var mentionSuggestionsHeight: CGFloat = 0
    @State private var messageToDelete: TimelineMessage?

    @State private var tableProxy = TimelineTableProxy()
    @State private var isNearBottom = true
    @State private var composeBarHeight: CGFloat = 0
    @State private var pendingScrollToBottom = false
    @State private var showUnreadMarker = true
    @State private var unreadMarkerDismissTask: Task<Void, Never>?
    @State private var fullyReadDebounceTask: Task<Void, Never>?
    @State private var lastFullyReadEventId: String?
    @State private var isDirectRoom = false
    @State private var highlightedMessageId: String?
    @State private var memberRefreshTask: Task<Void, Never>?
    @State private var cachedMessageRows: [MessageRow] = []

    /// Number of membership events observed in the timeline, used to trigger
    /// a member list refresh when new joins/leaves arrive.
    private var membershipEventCount: Int {
        viewModel.messages.lazy.filter { $0.kind == .membership }.count
    }

    @AppStorage("safety.sendReadReceipts") private var sendReadReceipts = true
    @AppStorage("safety.sendTypingNotifications") private var sendTypingNotifications = true
    @AppStorage("safety.mediaPreviewMode") private var mediaPreviewMode = "privateOnly"
    @AppStorage("behavior.showURLPreviews") private var showURLPreviews = true
    @AppStorage("behavior.alwaysLoadNewest") private var alwaysLoadNewest = true
    @AppStorage("behavior.showMembershipEvents") private var showMembershipEvents = true
    @AppStorage("behavior.showStateEvents") private var showStateEvents = true

    private var shouldAutoRevealMedia: Bool {
        if mediaPreviewMode == "allRooms" { return true }
        return isDirectRoom
    }

    var body: some View {
        messageList
            .environment(\.mediaAutoReveal, shouldAutoRevealMedia)
            .overlay {
                if let reply = replyingTo {
                    ZStack {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                                    replyingTo = nil
                                }
                            }

                        MessageView(
                            message: reply,
                            isLastInGroup: true,
                            showSenderName: !reply.isOutgoing,
                            currentUserID: matrixService.userId()
                        )
                        .allowsHitTesting(false)
                        .padding(.horizontal, 16)
                    }
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                composeBar
            }
            .navigationTitle("")
        .task {
            // Cache isDirect once — avoids O(n) room scan on every body evaluation.
            isDirectRoom = matrixService.rooms.first(where: { $0.id == roomId })?.isDirect ?? false

            // Load focused on the fully-read marker if the user has opted out of "always load newest"
            var focusEventId: String?
            if !alwaysLoadNewest {
                focusEventId = await matrixService.fullyReadEventId(roomId: roomId)
            }
            await viewModel.loadTimeline(focusedOnEventId: focusEventId)

            // Seed the row cache now that messages are available.
            rebuildCachedRows()

            // After loading, scroll to the focused event and briefly highlight it
            if let focusEventId {
                await scrollToEventWhenAvailable(focusEventId)
            }

            await matrixService.markAsRead(roomId: roomId, sendPublicReceipt: sendReadReceipts)

            // Fetch room members for mention autocomplete
            roomMembers = await matrixService.roomMembers(roomId: roomId)

            // Auto-dismiss the "New" marker after 5 seconds, then clear it
            if viewModel.firstUnreadMessageId != nil {
                showUnreadMarker = true
                unreadMarkerDismissTask?.cancel()
                unreadMarkerDismissTask = Task {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.4)) {
                        showUnreadMarker = false
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    viewModel.firstUnreadMessageId = nil
                }
            }
        }
        .onDisappear {
            if sendTypingNotifications {
                Task { await matrixService.sendTypingNotice(roomId: roomId, isTyping: false) }
            }
            memberRefreshTask?.cancel()
        }
        .onChange(of: membershipEventCount) {
            // A membership event appeared in the timeline (join, leave, etc.).
            // Debounce slightly so rapid-fire events (e.g. a server burst) only
            // trigger one refresh.
            memberRefreshTask?.cancel()
            memberRefreshTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                roomMembers = await matrixService.roomMembers(roomId: roomId)
            }
        }
        .onChange(of: draftMessage) { oldValue, newValue in
            guard sendTypingNotifications else { return }
            let wasEmpty = oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let isEmpty = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if wasEmpty && !isEmpty {
                Task { await matrixService.sendTypingNotice(roomId: roomId, isTyping: true) }
            } else if !wasEmpty && isEmpty {
                Task { await matrixService.sendTypingNotice(roomId: roomId, isTyping: false) }
            }
        }
        .onChange(of: focusedMessageId) {
            guard let eventId = focusedMessageId else { return }
            focusedMessageId = nil

            if viewModel.messages.contains(where: { $0.id == eventId }) {
                // Message is already loaded — scroll to it and highlight
                tableProxy.scrollToRow(id: eventId)
                highlightedMessageId = eventId
            } else {
                // Message is not in the loaded timeline — load an event-focused timeline
                Task {
                    await viewModel.focusOnEvent(eventId: eventId)
                    await scrollToEventWhenAvailable(eventId)
                }
            }
        }
        .alert("Delete Message", isPresented: Binding(
            get: { messageToDelete != nil },
            set: { if !$0 { messageToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let message = messageToDelete {
                    Task { await viewModel.redact(messageId: message.id, reason: nil) }
                }
                messageToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                messageToDelete = nil
            }
        } message: {
            Text("Are you sure you want to delete this message? This cannot be undone.")
        }
    }

    // MARK: - Message List

    /// Rebuilds the cached `messageRows` from the current messages and user
    /// preferences.  Called from `onChange` handlers so the expensive
    /// `filteredMessages` + `buildRows` pipeline only runs when the underlying
    /// data actually changes, not on every `body` evaluation.
    private func rebuildCachedRows() {
        cachedMessageRows = Self.buildRows(
            for: filteredMessages,
            hasReachedStart: viewModel.hasReachedStart
        )
    }

    /// The message list backed by an `NSTableView` for cell recycling and
    /// stable scroll position during backward pagination.
    private var messageList: some View {
        timelineTable
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) { loadingMoreOverlay }
            .onChange(of: viewModel.messages) {
                rebuildCachedRows()
            }
            .onChange(of: viewModel.hasReachedStart) {
                rebuildCachedRows()
            }
            .onChange(of: showMembershipEvents) {
                rebuildCachedRows()
            }
            .onChange(of: showStateEvents) {
                rebuildCachedRows()
            }
            .onChange(of: viewModel.messages.last?.id) {
                guard viewModel.timelineFocus == .live else { return }
                guard !viewModel.isLoadingMore else { return }
                if isNearBottom || pendingScrollToBottom {
                    pendingScrollToBottom = false
                    tableProxy.scrollToBottom()
                }
                if isNearBottom {
                    Task { await matrixService.markAsRead(roomId: roomId, sendPublicReceipt: sendReadReceipts) }
                }
            }
            .onChange(of: viewModel.timelineFocus) {
                if viewModel.timelineFocus == .live {
                    pendingScrollToBottom = true
                    Task { await matrixService.markAsRead(roomId: roomId, sendPublicReceipt: sendReadReceipts) }
                }
            }
            .overlay(alignment: .bottom) {
                TypingIndicatorOverlay(viewModel: viewModel)
                    .padding(.bottom, 44)
            }
            .overlay(alignment: .bottomTrailing) { scrollToBottomButton }
            .overlay { loadingOrEmptyOverlay }
    }

    private var timelineTable: some View {
        TimelineTableViewRepresentable(
            rows: cachedMessageRows,
            hasReachedEnd: viewModel.hasReachedEnd,
            isLive: viewModel.timelineFocus == .live,
            showUnreadMarker: showUnreadMarker,
            firstUnreadMessageId: viewModel.firstUnreadMessageId,
            highlightedMessageId: highlightedMessageId,
            showURLPreviews: showURLPreviews,
            currentUserID: matrixService.userId(),
            onToggleReaction: { messageId, key in
                Task { await viewModel.toggleReaction(messageId: messageId, key: key) }
            },
            onTapReply: { eventID in
                if viewModel.messages.contains(where: { $0.id == eventID }) {
                    tableProxy.scrollToRow(id: eventID)
                    highlightedMessageId = eventID
                } else {
                    focusedMessageId = eventID
                }
            },
            onReply: { message in
                withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                    replyingTo = message
                }
            },
            onAvatarDoubleTap: { message in
                onUserTap?(UserProfile(message: message))
            },
            onUserTap: { userId in
                let member = roomMembers.first(where: { $0.userId == userId })
                let profile = member.map { UserProfile(member: $0) }
                    ?? UserProfile(userId: userId)
                onUserTap?(profile)
            },
            onRoomTap: onRoomTap,
            onAppear: { row in
                advanceFullyReadMarker(to: row.message.id)
            },
            onContextAction: { action in
                handleContextAction(action)
            },
            onHighlightDismissed: {
                highlightedMessageId = nil
            },
            onNearBottomChanged: { nearBottom in
                isNearBottom = nearBottom
                if nearBottom {
                    Task { await matrixService.markAsRead(roomId: roomId, sendPublicReceipt: sendReadReceipts) }
                }
            },
            onPaginateBackward: {
                guard !viewModel.isLoadingMore, !viewModel.hasReachedStart else { return }
                Task { await viewModel.loadMoreHistory() }
            },
            onPaginateForward: {
                Task { await viewModel.loadMoreFuture() }
            },
            scrollProxy: tableProxy
        )
    }

    @ViewBuilder
    private var loadingMoreOverlay: some View {
        if viewModel.isLoadingMore {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.bar)
        }
    }

    // MARK: - Scroll to bottom button

    @ViewBuilder
    private var scrollToBottomButton: some View {
        if viewModel.timelineFocus != .live || !isNearBottom {
            Button {
                if viewModel.timelineFocus != .live {
                    Task { await viewModel.returnToLive() }
                } else {
                    tableProxy.scrollToBottom()
                }
            } label: {
                Image(systemName: viewModel.timelineFocus != .live ? "arrow.uturn.down" : "arrow.down")
                    .font(.title)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                    .glassEffect(in: .circle)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 56)
            .padding(.trailing, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Compose Bar

    private var composeBar: some View {
        VStack(spacing: 0) {
            if let reply = replyingTo {
                HStack {
                    Label("Replying to \(reply.displayName)", systemImage: "arrowshape.turn.up.left")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                            replyingTo = nil
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if editingMessage != nil {
                HStack {
                    Label("Editing Message", systemImage: "pencil")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                            editingMessage = nil
                            draftMessage = ""
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ComposeView(
                text: $draftMessage,
                replyingTo: $replyingTo,
                attachments: $stagedAttachments,
                members: roomMembers,
                mentions: $draftMentions,
                onSend: sendMessage,
                onAttach: stageAttachments,
                onGIFSelected: sendGIF,
                mentionQuery: $mentionQuery,
                mentionSelectedIndex: $mentionSelectedIndex
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .overlay(alignment: .topLeading) {
            if mentionQuery != nil {
                mentionSuggestions
                    .padding(.leading, 16)
                    .padding(.trailing, 96)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .offset(y: -mentionSuggestionsHeight - 4)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        mentionSuggestionsHeight = height
                    }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            composeBarHeight = height
            tableProxy.setContentInsets(NSEdgeInsets(
                top: 0, left: 0, bottom: height + 4, right: 0
            ))
        }
        .onChange(of: mentionQuery) { _, _ in
            mentionSelectedIndex = 0
        }
    }

    // MARK: - Mention Suggestions

    private var mentionSuggestions: some View {
        MentionSuggestionView(
            members: roomMembers,
            query: mentionQuery ?? "",
            selectedIndex: $mentionSelectedIndex,
            onSelect: { member in
                insertMention(member)
            },
            onDismiss: {
                mentionQuery = nil
            }
        )
    }

    private func insertMention(_ member: RoomMemberDetails) {
        NotificationCenter.default.post(
            name: .insertMention,
            object: nil,
            userInfo: [
                "userId": member.userId,
                "displayName": member.displayName ?? member.userId
            ]
        )
    }

    @ViewBuilder
    private var loadingOrEmptyOverlay: some View {
        if !viewModel.isLoading && viewModel.messages.isEmpty {
            ContentUnavailableView(
                "No Messages Yet",
                systemImage: "text.bubble",
                description: Text("Send a message to get the conversation started.")
            )
        }
    }

    // MARK: - Scroll-to-Event Helpers

    /// Waits until a message with the given event ID appears in the view
    /// model's `messages` array, then scrolls to it and highlights it.
    ///
    /// Uses `withObservationTracking` to react as soon as the `@Observable`
    /// view model publishes the target message, avoiding a fixed-duration
    /// sleep that may fire before or after the data is ready.
    private func scrollToEventWhenAvailable(_ eventId: String) async {
        // If the message is already present, scroll immediately.
        if viewModel.messages.contains(where: { $0.id == eventId }) {
            // Allow the table one layout pass to apply the snapshot.
            try? await Task.sleep(for: .milliseconds(100))
            tableProxy.scrollToRow(id: eventId)
            highlightedMessageId = eventId
            return
        }

        // Poll via observation tracking until the message appears or we time out.
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let found = await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = viewModel.messages   // Access to register tracking
                } onChange: {
                    continuation.resume(returning: true)
                }
            }
            guard found else { break }
            if viewModel.messages.contains(where: { $0.id == eventId }) {
                // Give the table time to apply the snapshot and measure row heights.
                try? await Task.sleep(for: .milliseconds(100))
                tableProxy.scrollToRow(id: eventId)
                highlightedMessageId = eventId
                return
            }
        }

        // Best-effort fallback: if the message never appeared within the
        // timeout, try scrolling anyway in case it arrived just now.
        tableProxy.scrollToRow(id: eventId)
        highlightedMessageId = eventId
    }

    // MARK: - Fully-Read Marker

    /// Debounces fully-read receipt advancement as messages appear on screen.
    /// Only advances forward (to later messages in the timeline), never backward.
    private func advanceFullyReadMarker(to eventId: String) {
        guard !alwaysLoadNewest || !isNearBottom else {
            // When "always load newest" is on and we're at the bottom,
            // markAsRead already handles receipts via the bottom sentinel.
            return
        }

        // Only advance if this event is later in the timeline than the last marker
        if let lastId = lastFullyReadEventId,
           let lastIndex = viewModel.messages.firstIndex(where: { $0.id == lastId }),
           let newIndex = viewModel.messages.firstIndex(where: { $0.id == eventId }),
           newIndex <= lastIndex {
            return
        }

        lastFullyReadEventId = eventId
        fullyReadDebounceTask?.cancel()
        fullyReadDebounceTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await viewModel.sendFullyReadReceipt(upTo: eventId)
        }
    }

    // MARK: - Context Action Handler

    private func handleContextAction(_ action: TimelineRowContextAction) {
        switch action {
        case .reply(let message):
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                replyingTo = message
            }
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .togglePin(let eventId):
            let isPinned = matrixService.rooms
                .first(where: { $0.id == roomId })?
                .pinnedEventIds.contains(eventId) ?? false
            Task {
                if isPinned {
                    await viewModel.unpin(eventId: eventId)
                } else {
                    await viewModel.pin(eventId: eventId)
                }
            }
        case .edit(let message):
            replyingTo = nil
            editingMessage = message
            draftMessage = message.body
        case .delete(let message):
            messageToDelete = message
        }
    }

    // (Backward pagination is now handled by TimelineTableViewController's
    // scroll detection, not by a sentinel view.)

    // MARK: - URL Extraction

    /// Cache for `firstPreviewURL` results to avoid running `NSDataDetector` on
    /// every SwiftUI body evaluation.
    static let urlCache = ParseCache<String, URL?>(capacity: 256)

    /// Returns the first HTTP(S) URL found in the given string, excluding `matrix.to` links.
    static func firstPreviewURL(in body: String) -> URL? {
        urlCache.value(forKey: body) {
            guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
                return nil
            }
            let matches = detector.matches(in: body, range: NSRange(body.startIndex..., in: body))
            for match in matches {
                guard let url = match.url,
                      let scheme = url.scheme?.lowercased(),
                      scheme == "https" || scheme == "http",
                      url.host?.lowercased() != "matrix.to" else { continue }
                return url
            }
            return nil
        }
    }

    // MARK: - Filtering

    /// The messages to display, with system events filtered based on user preferences.
    private var filteredMessages: [TimelineMessage] {
        viewModel.messages.filter { message in
            switch message.kind {
            case .membership, .profileChange:
                return showMembershipEvents
            case .stateEvent:
                return showStateEvents
            default:
                return true
            }
        }
    }

    // MARK: - Grouping Info

    /// Precomputed layout metadata for a single message within the timeline.
    /// Built once per body evaluation by ``buildGroupInfo(for:)`` so the
    /// `ForEach` body doesn't need index-based lookups.
    struct MessageGroupInfo: Equatable, Sendable {
        var isFirst = false
        var showDateHeader = false
        var showGroupSpacer = false
        var isLastInGroup = true
        var showSenderName = false

        nonisolated static func == (lhs: MessageGroupInfo, rhs: MessageGroupInfo) -> Bool {
            lhs.isFirst == rhs.isFirst
                && lhs.showDateHeader == rhs.showDateHeader
                && lhs.showGroupSpacer == rhs.showGroupSpacer
                && lhs.isLastInGroup == rhs.isLastInGroup
                && lhs.showSenderName == rhs.showSenderName
        }

        static let `default` = MessageGroupInfo()
    }

    /// A message bundled with its precomputed layout metadata, used as the
    /// element type for the `ForEach` to avoid capturing the full groupInfo
    /// dictionary or messages array in each row's closure.
    struct MessageRow: Identifiable, Equatable {
        let message: TimelineMessage
        let info: MessageGroupInfo
        let isPaginationTrigger: Bool

        var id: String { message.id }

        nonisolated static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
            lhs.message == rhs.message
                && lhs.info == rhs.info
                && lhs.isPaginationTrigger == rhs.isPaginationTrigger
        }
    }

    /// Builds an array of ``MessageRow`` values, pairing each message with its
    /// precomputed grouping metadata. The result is passed to the table view
    /// representable so each cell receives its own lightweight `MessageRow`.
    static func buildRows(
        for messages: [TimelineMessage],
        hasReachedStart: Bool
    ) -> [MessageRow] {
        guard !messages.isEmpty else { return [] }
        let calendar = Calendar.current
        var result = [MessageRow]()
        result.reserveCapacity(messages.count)

        for index in messages.indices {
            let message = messages[index]
            var info = MessageGroupInfo()

            info.isFirst = index == 0

            // Date header
            if index == 0 {
                info.showDateHeader = true
            } else {
                info.showDateHeader = !calendar.isDate(
                    message.timestamp,
                    equalTo: messages[index - 1].timestamp,
                    toGranularity: .hour
                )
            }

            // Group spacer (between different sender groups, excluding system events)
            if index > 0 && !messages[index - 1].isSystemEvent && !message.isSystemEvent
                && messages[index - 1].senderID != message.senderID
                && !info.showDateHeader {
                info.showGroupSpacer = true
            }

            // Last in group
            if index < messages.count - 1 {
                let next = messages[index + 1]
                if message.isSystemEvent || next.isSystemEvent {
                    info.isLastInGroup = true
                } else {
                    let nextHasDateHeader: Bool
                    if index + 1 == 0 {
                        nextHasDateHeader = true
                    } else {
                        nextHasDateHeader = !calendar.isDate(
                            next.timestamp,
                            equalTo: message.timestamp,
                            toGranularity: .hour
                        )
                    }
                    info.isLastInGroup = next.senderID != message.senderID || nextHasDateHeader
                }
            } else {
                info.isLastInGroup = true
            }

            // Show sender name
            if !message.isOutgoing && !message.isSystemEvent {
                if index == 0 || info.showDateHeader {
                    info.showSenderName = true
                } else {
                    let prev = messages[index - 1]
                    info.showSenderName = prev.isSystemEvent || prev.senderID != message.senderID
                }
            }

            result.append(MessageRow(
                message: message,
                info: info,
                isPaginationTrigger: false
            ))
        }
        return result
    }

    // MARK: - Send

    private func sendMessage() {
        let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingAttachments = stagedAttachments
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }

        // Capture mentions and convert to markdown with Matrix.to links
        let currentMentions = draftMentions
        let mentionedUserIds = currentMentions.map(\.userId)
        let messageText = ComposeView.markdownWithMentions(text: draftMessage, mentions: currentMentions)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if we're in edit mode
        if let editing = editingMessage {
            let editId = editing.id
            draftMessage = ""
            draftMentions = []
            withAnimation(.easeOut(duration: 0.2)) { editingMessage = nil }
            Task {
                if sendTypingNotifications {
                    await matrixService.sendTypingNotice(roomId: roomId, isTyping: false)
                }
                await viewModel.edit(messageId: editId, newText: messageText, mentionedUserIds: mentionedUserIds)
            }
            return
        }

        let replyEventId = replyingTo?.id
        draftMessage = ""
        draftMentions = []
        withAnimation(.easeOut(duration: 0.2)) { replyingTo = nil }
        stagedAttachments = []
        pendingScrollToBottom = true
        Task {
            if sendTypingNotifications {
                await matrixService.sendTypingNotice(roomId: roomId, isTyping: false)
            }
            if !messageText.isEmpty {
                await viewModel.send(text: messageText, inReplyTo: replyEventId, mentionedUserIds: mentionedUserIds)
            }
            for attachment in pendingAttachments {
                let caption = attachment.caption.trimmingCharacters(in: .whitespacesAndNewlines)
                await viewModel.sendAttachment(url: attachment.url, caption: caption.isEmpty ? nil : caption)
            }
        }
    }

    /// Stages selected files as ``StagedAttachment`` capsules in the compose bar
    /// instead of sending them immediately. Files are copied to a temp directory
    /// so the security-scoped bookmark can be released right away.
    ///
    /// Works for file-picker URLs (security-scoped), drag-and-drop URLs, and
    /// pasted temp-file URLs. Security-scoped access is attempted but not required
    /// since drag/paste URLs are not sandboxed.
    private func stageAttachments(_ urls: [URL]) {
        let tempDir = FileManager.default.temporaryDirectory
        for url in urls {
            // Attempt security-scoped access (required for file-picker URLs,
            // returns false harmlessly for drag-and-drop / paste URLs).
            let didAccessScope = url.startAccessingSecurityScopedResource()
            defer { if didAccessScope { url.stopAccessingSecurityScopedResource() } }

            // If the file is already in our temp directory (e.g. pasted data),
            // use it directly instead of copying again.
            if url.path.hasPrefix(tempDir.path) {
                let thumbnail = generateThumbnail(for: url)
                let staged = StagedAttachment(url: url, filename: url.lastPathComponent, thumbnail: thumbnail)
                withAnimation(.easeOut(duration: 0.15)) {
                    stagedAttachments.append(staged)
                }
                continue
            }

            let dest = tempDir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
            } catch {
                logger.error("Failed to copy file \(url.lastPathComponent): \(error)")
                errorReporter.report(
                    .fileCopyFailed(filename: url.lastPathComponent, reason: error.localizedDescription)
                )
                continue
            }

            let thumbnail = generateThumbnail(for: dest)
            let staged = StagedAttachment(url: dest, filename: url.lastPathComponent, thumbnail: thumbnail)
            withAnimation(.easeOut(duration: 0.15)) {
                stagedAttachments.append(staged)
            }
        }
    }

    /// Downloads the selected GIF and sends it as an image attachment.
    ///
    /// The GIF is downloaded to a temporary file and sent directly via the
    /// view model's attachment pipeline. Analytics pingbacks are fired for
    /// click and send events.
    private func sendGIF(_ gif: GIFSearchResult) {
        pendingScrollToBottom = true
        Task {
            // Fire analytics
            if let url = gif.onsentURL {
                await gifSearchService.registerAction(url: url)
            }

            // Download GIF data
            let data: Data
            do {
                data = try await gifSearchService.downloadGIF(url: gif.originalURL)
            } catch {
                errorReporter.report(.fileCopyFailed(filename: "GIF", reason: error.localizedDescription))
                return
            }

            // Write to temp file
            let filename = "\(gif.id).gif"
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            do {
                try data.write(to: tempURL)
            } catch {
                errorReporter.report(.fileCopyFailed(filename: filename, reason: error.localizedDescription))
                return
            }

            // Send via existing attachment pipeline
            await viewModel.sendAttachment(url: tempURL, caption: nil)
        }
    }

    /// Generates a small thumbnail for image files, or `nil` for other types.
    private func generateThumbnail(for url: URL) -> NSImage? {
        let utType = UTType(filenameExtension: url.pathExtension) ?? .data
        guard utType.conforms(to: .image) else { return nil }
        guard let image = NSImage(contentsOf: url) else { return nil }
        let maxDimension: CGFloat = 56
        let size = image.size
        let scale = min(maxDimension / size.width, maxDimension / size.height, 1.0)
        let targetSize = NSSize(width: size.width * scale, height: size.height * scale)
        let thumbnail = NSImage(size: targetSize)
        thumbnail.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: targetSize))
        thumbnail.unlockFocus()
        return thumbnail
    }
}

// MARK: - Typing Indicator Overlay

/// A lightweight view that observes only `viewModel.typingUserDisplayNames`,
/// isolating typing-state changes from ``TimelineView/body`` re-evaluation.
/// Without this, every typing notification would trigger a full `body`
/// recompute, rebuilding `messageRows` and passing them through the
/// representable boundary — even though the message data hasn't changed.
private struct TypingIndicatorOverlay: View {
    let viewModel: any TimelineViewModelProtocol

    var body: some View {
        let names = viewModel.typingUserDisplayNames
        if !names.isEmpty {
            HStack(spacing: 6) {
                TypingBubble()
                Text(typingLabel(for: names))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 4)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func typingLabel(for names: [String]) -> String {
        switch names.count {
        case 1:
            return "\(names[0]) is typing…"
        case 2:
            return "\(names[0]) and \(names[1]) are typing…"
        default:
            return "\(names[0]) and \(names.count - 1) others are typing…"
        }
    }
}

// MARK: - Typing Bubble Animation

private struct TypingBubble: View {
    private let startDate = Date()

    var body: some View {
        SwiftUI.TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(startDate)
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = dotPhase(elapsed: elapsed, index: index)
                    Circle()
                        .fill(.secondary)
                        .frame(width: 6, height: 6)
                        .scaleEffect(0.6 + 0.4 * phase)
                        .opacity(0.4 + 0.6 * phase)
                }
            }
        }
    }

    /// Returns a 0...1 pulsing value for each dot, staggered by index.
    private func dotPhase(elapsed: TimeInterval, index: Int) -> Double {
        let period = 1.8 // full cycle duration in seconds
        let delay = Double(index) * 0.15
        // swiftlint:disable:next identifier_name
        let t = (elapsed + delay).truncatingRemainder(dividingBy: period) / period
        return sin(t * .pi)
    }
}

// MARK: - Preview Helpers

/// A SwiftUI-native timeline view used for previews. The NSTableView-backed
/// timeline doesn't render in Xcode's static preview snapshots, so previews
/// use a ScrollView + ForEach fallback to display messages.
private struct PreviewTimeline: View {
    let viewModel: PreviewTimelineViewModel
    let showUnreadMarker: Bool

    init(_ viewModel: PreviewTimelineViewModel, showUnreadMarker: Bool = false) {
        self.viewModel = viewModel
        self.showUnreadMarker = showUnreadMarker
    }

    var body: some View {
        let rows = TimelineView.buildRows(for: viewModel.messages, hasReachedStart: true)
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(rows) { row in
                    TimelineRowView(
                        row: row,
                        isNewlyAppended: false,
                        showUnreadMarker: showUnreadMarker,
                        firstUnreadMessageId: viewModel.firstUnreadMessageId,
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
        .defaultScrollAnchor(.bottom)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                TextField("Message", text: .constant(""))
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .overlay {
            if !viewModel.isLoading && viewModel.messages.isEmpty {
                ContentUnavailableView(
                    "No Messages Yet",
                    systemImage: "text.bubble",
                    description: Text("Send a message to get the conversation started.")
                )
            }
        }
    }
}

#Preview("Messages") {
    PreviewTimeline(PreviewTimelineViewModel())
        .frame(width: 500, height: 600)
}

#Preview("Unread Marker") {
    PreviewTimeline(
        PreviewTimelineViewModel(firstUnreadMessageId: "8"),
        showUnreadMarker: true
    )
    .frame(width: 500, height: 600)
}

#Preview("Typing Indicator") {
    // Typing indicator is an overlay on the NSTableView, so we show it
    // separately here since the preview uses a ScrollView fallback.
    PreviewTimeline(PreviewTimelineViewModel())
        .frame(width: 500, height: 600)
}

#Preview("Empty") {
    PreviewTimeline(PreviewTimelineViewModel(messages: []))
        .frame(width: 500, height: 450)
}
