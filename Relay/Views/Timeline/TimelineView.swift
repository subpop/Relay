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

    /// When `true`, the timeline is displayed in a read-only mode suitable for
    /// room previews. The compose bar, reply/edit overlays, typing notifications,
    /// read receipts, and drag-and-drop are all disabled.
    var readOnly: Bool = false

    @State private var compose = ComposeViewModel()
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
    @State private var isTimelineDropTargeted = false

    /// Number of membership events observed in the timeline, used to trigger
    /// a member list refresh when new joins/leaves arrive.
    private var membershipEventCount: Int {
        viewModel.messages.lazy.filter { $0.kind == .membership }.count
    }

    @AppStorage("safety.sendReadReceipts") private var sendReadReceipts = true
    @AppStorage("safety.sendTypingNotifications") private var sendTypingNotifications = true
    @AppStorage("safety.mediaPreviewMode") private var mediaPreviewMode = "privateOnly"
    @AppStorage("behavior.showURLPreviews") private var globalShowURLPreviews = true
    @AppStorage("behavior.alwaysLoadNewest") private var alwaysLoadNewest = true
    @AppStorage("behavior.showMembershipEvents") private var globalShowMembershipEvents = true
    @AppStorage("behavior.showStateEvents") private var globalShowStateEvents = true

    private var roomOverrides: RoomBehaviorOverrides {
        RoomBehaviorStore.shared.overrides(for: roomId)
    }

    private var showURLPreviews: Bool {
        roomOverrides.showURLPreviews ?? globalShowURLPreviews
    }

    private var showMembershipEvents: Bool {
        roomOverrides.showMembershipEvents ?? globalShowMembershipEvents
    }

    private var showStateEvents: Bool {
        roomOverrides.showStateEvents ?? globalShowStateEvents
    }

    private var shouldAutoRevealMedia: Bool {
        if let override = roomOverrides.showMediaPreviews { return override }
        if mediaPreviewMode == "allRooms" { return true }
        return isDirectRoom
    }

    var body: some View {
        messageList
            .environment(\.mediaAutoReveal, shouldAutoRevealMedia)
            .environment(\.gifAnimationOverride, roomOverrides.animateGIFs)
            .overlay {
                if !readOnly, let reply = compose.replyingTo {
                    ZStack {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                                    compose.cancelReply()
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
                if !readOnly {
                    composeBarSection
                }
            }
            .onDrop(
                of: ComposeViewModel.dropTypes,
                isTargeted: Binding(
                    get: { isTimelineDropTargeted },
                    set: { targeted in
                        guard !readOnly else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            isTimelineDropTargeted = targeted
                        }
                    }
                )
            ) { providers in
                guard !readOnly else { return false }
                guard !providers.isEmpty else { return false }
                compose.handleDropProviders(providers, errorReporter: errorReporter)
                return true
            }
            .overlay {
                if !readOnly, isTimelineDropTargeted {
                    ZStack {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .ignoresSafeArea()

                        VStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("Drop files to attach")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
        .task {
            // Cache isDirect once — avoids O(n) room scan on every body evaluation.
            isDirectRoom = matrixService.rooms.first(where: { $0.id == roomId })?.isDirect ?? false

            // Load focused on the fully-read marker if the user has opted out of "always load newest"
            var focusEventId: String?
            if !readOnly, !alwaysLoadNewest {
                focusEventId = await matrixService.fullyReadEventId(roomId: roomId)
            }
            await viewModel.loadTimeline(focusedOnEventId: focusEventId)

            // Seed the row cache now that messages are available.
            rebuildCachedRows()

            // After loading, scroll to the focused event and briefly highlight it
            if let focusEventId {
                await scrollToEventWhenAvailable(focusEventId)
            }

            guard !readOnly else { return }

            await matrixService.markAsRead(roomId: roomId, sendPublicReceipt: sendReadReceipts)

            // Fetch room members for mention autocomplete
            compose.members = await matrixService.roomMembers(roomId: roomId)

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
            if !readOnly, sendTypingNotifications {
                Task { await matrixService.sendTypingNotice(roomId: roomId, isTyping: false) }
            }
            memberRefreshTask?.cancel()
        }
        .onChange(of: membershipEventCount) {
            guard !readOnly else { return }
            // A membership event appeared in the timeline (join, leave, etc.).
            // Debounce slightly so rapid-fire events (e.g. a server burst) only
            // trigger one refresh.
            memberRefreshTask?.cancel()
            memberRefreshTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                compose.members = await matrixService.roomMembers(roomId: roomId)
            }
        }
        .onChange(of: compose.text) { oldValue, newValue in
            guard !readOnly, sendTypingNotifications else { return }
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
        .focusedValue(\.editLastMessage, editLastMessageAction)
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
            .onChange(of: viewModel.messagesVersion) {
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
                if isNearBottom, NSApp.isActive {
                    Task { await matrixService.markAsRead(roomId: roomId, sendPublicReceipt: sendReadReceipts) }
                }
            }
            .onChange(of: viewModel.timelineFocus) {
                if viewModel.timelineFocus == .live, NSApp.isActive {
                    pendingScrollToBottom = true
                    Task { await matrixService.markAsRead(roomId: roomId, sendPublicReceipt: sendReadReceipts) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if isNearBottom {
                    Task { await matrixService.markAsRead(roomId: roomId, sendPublicReceipt: sendReadReceipts) }
                }
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
                    compose.replyingTo = message
                }
            },
            onAvatarDoubleTap: { message in
                onUserTap?(UserProfile(message: message))
            },
            onUserTap: { userId in
                let member = compose.members.first(where: { $0.userId == userId })
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
                if nearBottom, NSApp.isActive {
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

    private var composeBarSection: some View {
        VStack(spacing: 0) {
            TypingIndicatorOverlay(viewModel: viewModel)

            ComposeBar(
                compose: compose,
                onSend: {
                    await compose.send(
                        using: viewModel,
                        matrixService: matrixService,
                        roomId: roomId,
                        sendTypingNotifications: sendTypingNotifications
                    ) {
                        pendingScrollToBottom = true
                    }
                },
                onAttach: { urls in
                    compose.stageAttachments(urls, errorReporter: errorReporter)
                },
                onGIFSelected: { gif in
                    await compose.sendGIF(
                        gif,
                        using: viewModel,
                        gifSearchService: gifSearchService,
                        errorReporter: errorReporter
                    ) {
                        pendingScrollToBottom = true
                    }
                }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            composeBarHeight = height
            tableProxy.setContentInsets(NSEdgeInsets(
                top: 0, left: 0, bottom: height + 4, right: 0
            ))
        }
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

    // MARK: - Edit Last Message

    /// Returns a closure that starts editing the current user's most recent
    /// text message, or `nil` when the compose bar is hidden or no editable
    /// message exists.
    private var editLastMessageAction: (() -> Void)? {
        guard !readOnly else { return nil }
        guard let message = viewModel.messages.last(where: { $0.isOutgoing && $0.kind == .text }) else {
            return nil
        }
        return {
            handleContextAction(.edit(message))
        }
    }

    // MARK: - Context Action Handler

    private func handleContextAction(_ action: TimelineRowContextAction) {
        switch action {
        case .reply(let message):
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                compose.replyingTo = message
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
            compose.replyingTo = nil
            compose.editingMessage = message
            compose.text = message.body
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

    /// Regex matching Matrix identifiers (`@user:server`, `#room:server`,
    /// `!id:server`) whose server portion `NSDataDetector` misidentifies as
    /// a standalone URL.
    private static let matrixIdentifierPattern =
        /[#@!][a-zA-Z0-9._=\-\/]+:[a-zA-Z0-9.\-]+(:[0-9]+)?/

    /// Returns the first HTTP(S) URL found in the given string, excluding
    /// `matrix.to` links and false positives from Matrix identifiers.
    static func firstPreviewURL(in body: String) -> URL? {
        urlCache.value(forKey: body) {
            guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
                return nil
            }
            let matches = detector.matches(in: body, range: NSRange(body.startIndex..., in: body))

            // Collect ranges of Matrix identifiers so we can discard any URL
            // that NSDataDetector extracted from the server portion of one.
            let identifierRanges = body.matches(of: matrixIdentifierPattern).map(\.range)

            for match in matches {
                guard let url = match.url,
                      let scheme = url.scheme?.lowercased(),
                      scheme == "https" || scheme == "http",
                      url.host?.lowercased() != "matrix.to" else { continue }

                // Skip URLs whose detected range overlaps a Matrix identifier.
                if let matchRange = Range(match.range, in: body),
                   identifierRanges.contains(where: { $0.overlaps(matchRange) }) {
                    continue
                }

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

}


