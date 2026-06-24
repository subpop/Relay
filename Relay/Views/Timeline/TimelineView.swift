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
import Translation
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
    @Environment(\.composeDraftStore) private var composeDraftStore
    @Environment(\.scrollAnchorStore) private var scrollAnchorStore

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

    /// The compose view model for this room, retrieved from the draft store
    /// so unsent drafts survive room switches. Initialized as a temporary
    /// placeholder; the actual draft is loaded from the store in `.task`.
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
    @State private var roomPermissions: RoomPermissions?
    @State private var highlightedMessageId: String?
    @State private var memberRefreshTask: Task<Void, Never>?
    @State private var cachedMessageRows: [MessageRow]
    @State private var isTimelineDropTargeted = false
    /// Number of parallel translation slots. Each slot owns its own
    /// `TranslationSession` via `.translationTask`, so up to this many
    /// translations can run at once. 3 is a reasonable balance — the
    /// Translation framework will happily run several sessions
    /// concurrently, but we don't want to spam the system if the user
    /// triggers Translate-all someday.
    private static let translationSlotCount = 3
    @State private var timelineActionsRef = TimelineActions()
    @State private var successorRoomId: String?
    @State private var reactionPickerMessageId: String?
    @State private var reactionPickerBubbleFrame: CGRect = .zero
    @State private var reactionPickerIsOutgoing = false
    init(
        roomId: String,
        roomName: String,
        roomAvatarURL: String? = nil,
        viewModel: any TimelineViewModelProtocol,
        focusedMessageId: Binding<String?>,
        onUserTap: ((UserProfile) -> Void)? = nil,
        onRoomTap: ((String) -> Void)? = nil,
        readOnly: Bool = false
    ) {
        self.roomId = roomId
        self.roomName = roomName
        self.roomAvatarURL = roomAvatarURL
        _viewModel = State(wrappedValue: viewModel)
        _focusedMessageId = focusedMessageId
        self.onUserTap = onUserTap
        self.onRoomTap = onRoomTap
        self.readOnly = readOnly

        // Seed the row cache from the view model's cached messages so
        // the first body evaluation already has content to render.
        // This avoids the empty frame that occurs when the table is
        // created before .task has a chance to call rebuildCachedRows().
        // The messages are passed unfiltered; .task applies the full
        // filter (membership/state event preferences) immediately after.
        _cachedMessageRows = State(initialValue: MessageRowBuilder.buildRows(
            for: viewModel.messages,
            hasReachedStart: viewModel.hasReachedStart
        ))
    }

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
    @AppStorage("labs.timelineUseLazyVStack") private var timelineUseLazyVStack = false

    @State private var lazyVStackScrollPosition = ScrollPosition(idType: String.self, edge: .bottom)

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
            .opacity(successorRoomId != nil ? 0.5 : 1)
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
                            showSenderName: !reply.isOutgoing
                        )
                        .environment(\.timelineActions, timelineActionsRef)
                        .allowsHitTesting(false)
                        .padding(.horizontal, 16)
                    }
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if successorRoomId != nil || (!readOnly && (roomPermissions?.canSendMessages ?? true)) {
                    TimelineBottomBar(
                        compose: compose,
                        viewModel: viewModel,
                        roomId: roomId,
                        successorRoomId: successorRoomId,
                        onRoomTap: onRoomTap,
                        onSendWillScroll: { pendingScrollToBottom = true },
                        onHeightChanged: { height in
                            let changed = height != composeBarHeight
                            composeBarHeight = height
                            if !timelineUseLazyVStack {
                                tableProxy.setContentInsets(NSEdgeInsets(
                                    top: 0, left: 0, bottom: height + 4, right: 0
                                ))
                            }
                            if changed, isNearBottom {
                                if timelineUseLazyVStack {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        lazyVStackScrollPosition.scrollTo(edge: .bottom)
                                    }
                                } else {
                                    tableProxy.scrollToBottom(animated: true)
                                }
                            }
                        }
                    )
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
        // MARK: Translation driver pool
        //
        // `.translationTask` is the only public entry point that handles
        // model downloads, but it accepts only one `Configuration` per
        // modifier. To run translations in parallel we render a fixed
        // pool of `TranslationSlot` subviews, each carrying its own
        // configuration state and its own `.translationTask`. Each slot
        // pulls the next pending request from the view model when idle,
        // so user-triggered translations never queue behind one another.
        .background {
            ZStack {
                ForEach(0..<Self.translationSlotCount, id: \.self) { _ in
                    TranslationSlot(viewModel: viewModel)
                }
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .task {
            // Restore the compose view model from the draft store so unsent
            // text, reply/edit context, and staged attachments survive room
            // switches.
            if !readOnly {
                compose = composeDraftStore.draft(for: roomId)
            }

            // Bind the timeline action callbacks once. The closures capture
            // @State / @Environment references which remain valid for the
            // lifetime of this view.
            configureTimelineActions()
            timelineActionsRef.highlightKeywords = (try? await matrixService.getNotificationKeywords()) ?? []

            // Cache room summary properties — avoids O(n) room scan on every body evaluation.
            let roomSummary = matrixService.rooms.first(where: { $0.id == roomId })
            isDirectRoom = roomSummary?.isDirect ?? false
            successorRoomId = roomSummary?.successorRoomId

            // Fetch room permissions to determine moderator capabilities.
            let details = await matrixService.roomDetails(roomId: roomId)
            roomPermissions = details?.permissions
            timelineActionsRef.permissions = roomPermissions

            // Seed the row cache immediately so cached messages from a
            // previously visited room render in the first frame, before
            // the async loadTimeline call reconnects to the SDK.
            rebuildCachedRows()

            // Load focused on the fully-read marker if the user has opted out of "always load newest"
            var focusEventId: String?
            if !readOnly, !alwaysLoadNewest {
                focusEventId = await matrixService.fullyReadEventId(roomId: roomId)
            }
            await viewModel.loadTimeline(focusedOnEventId: focusEventId)

            // Restore scroll position from a previous visit to this room.
            // If the user was scrolled up reading history, jump back to
            // that position instead of snapping to the bottom.
            let savedAnchor = scrollAnchorStore.take(roomId: roomId)
            if let savedAnchor, !savedAnchor.isNearBottom, focusEventId == nil {
                // Yield briefly so the table view has applied its initial
                // snapshot before we attempt the scroll.
                try? await Task.sleep(for: .milliseconds(50))
                if !timelineUseLazyVStack {
                    tableProxy.scrollToRow(id: savedAnchor.eventId, animated: false)
                }
                isNearBottom = false
            } else if timelineUseLazyVStack, focusEventId == nil {
                // defaultScrollAnchor(.bottom) handles the initial layout,
                // but async data arrival needs an explicit nudge.
                try? await Task.sleep(for: .milliseconds(50))
                scrollToBottom(animated: false)
            }

            // After loading, scroll to the focused event and briefly highlight it
            if let focusEventId {
                await scrollToEventWhenAvailable(focusEventId)
            }

            guard !readOnly else { return }

            // Only mark as read when the user can see the latest messages.
            // If we restored to a saved scroll position mid-history, wait
            // until they scroll to the bottom (handled by onNearBottomChanged).
            markAsReadIfNeeded()

            // Fetch room members for mention autocomplete
            compose.members = await matrixService.roomMembers(roomId: roomId)

        }
        .onDisappear {
            // Save the scroll anchor before the view is destroyed so
            // returning to this room can restore the scroll position.
            if !timelineUseLazyVStack, let eventId = tableProxy.topVisibleEventId() {
                scrollAnchorStore.save(
                    roomId: roomId,
                    anchor: ScrollAnchor(eventId: eventId, isNearBottom: isNearBottom)
                )
            }

            if !readOnly, sendTypingNotifications {
                Task { await matrixService.sendTypingNotice(roomId: roomId, isTyping: false) }
            }
            memberRefreshTask?.cancel()
            unreadMarkerDismissTask?.cancel()
        }
        .onChange(of: matrixService.rooms.first(where: { $0.id == roomId })?.successorRoomId) { _, newValue in
            successorRoomId = newValue
        }
        .onChange(of: viewModel.firstUnreadMessageId) { oldValue, newValue in
            // When the unread marker position is first computed (nil -> value),
            // start a 5-second auto-dismiss timer. This avoids the race where
            // the old .task check fired before the diff pipeline had set the ID.
            guard oldValue == nil, newValue != nil else { return }
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

            if let message = viewModel.messages.first(where: { $0.eventID == eventId }) {
                // Message is already loaded — scroll to it and highlight
                scrollToRow(id: message.id)
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
                    Task { await viewModel.redact(messageId: message.eventID, reason: nil) }
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
        let newRows = MessageRowBuilder.buildRows(
            for: filteredMessages,
            hasReachedStart: viewModel.hasReachedStart,
            translationState: { messageId in
                viewModel.translationState(for: messageId)
            }
        )
        if newRows != cachedMessageRows {
            cachedMessageRows = newRows
        }
    }

    /// The message list area containing the timeline renderer, overlays,
    /// and shared scroll/pagination change handlers.
    private var messageList: some View {
        timelineRenderer
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: "timeline")
            .overlay(alignment: .top) { loadingMoreOverlay }
            .onChange(of: viewModel.messagesVersion) {
                let previousLastID = cachedMessageRows.last?.id
                rebuildCachedRows()

                // Scroll-to-bottom: check if the last message changed
                // *after* rebuilding rows so the target row already
                // exists in the renderer's data source.
                let newLastID = cachedMessageRows.last?.id
                if newLastID != previousLastID {
                    if viewModel.timelineFocus == .live, !viewModel.isLoadingMore {
                        if isNearBottom || pendingScrollToBottom {
                            pendingScrollToBottom = false
                            scrollToBottom()
                        }
                    }
                    markAsReadIfNeeded()
                }
            }
            .onChange(of: viewModel.translationsVersion) {
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
            .onChange(of: viewModel.timelineFocus) {
                if viewModel.timelineFocus == .live {
                    pendingScrollToBottom = true
                    markAsReadIfNeeded()
                }
            }
            .onChange(of: viewModel.isLoadingMore) {
                // After back-pagination settles, re-check whether a read
                // receipt is needed. During pagination the scroll geometry
                // may report nearBottom = false due to content size changes,
                // causing markAsRead calls to be skipped. Once loading
                // finishes and the scroll settles back at the bottom, this
                // handler ensures the room is marked as read.
                if !viewModel.isLoadingMore {
                    markAsReadIfNeeded()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                markAsReadIfNeeded()
            }
            .overlay(alignment: .bottomTrailing) { scrollToBottomButton }
            .overlay { loadingOrEmptyOverlay }
            .overlay {
                if reactionPickerMessageId != nil {
                    ReactionPickerOverlay(
                        bubbleFrame: reactionPickerBubbleFrame,
                        isOutgoing: reactionPickerIsOutgoing,
                        onSelect: { emoji in
                            if let messageId = reactionPickerMessageId {
                                RecentEmojiStore.shared.recordUsage(emoji)
                                timelineActionsRef.toggleReaction(messageId, emoji)
                            }
                        },
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.15)) {
                                reactionPickerMessageId = nil
                            }
                        }
                    )
                }
            }
    }

    /// Populates the stable ``TimelineActions`` instance with the current
    /// closures and values. Called once from `.task` to bind the callbacks
    /// that capture `@State` / `@Environment` references. Because the
    /// instance identity is stable, re-injecting it into the environment
    /// does not invalidate child views.
    private func configureTimelineActions() {
        let actions = timelineActionsRef
        actions.toggleReaction = { messageId, key in
            Task { await self.viewModel.toggleReaction(messageId: messageId, key: key) }
        }
        actions.tapReply = { eventID in
            if let message = self.viewModel.messages.first(where: { $0.eventID == eventID }) {
                self.scrollToRow(id: message.id)
                self.highlightedMessageId = eventID
            } else {
                self.focusedMessageId = eventID
            }
        }
        actions.reply = { message in
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                self.compose.replyingTo = message
            }
        }
        actions.avatarDoubleTap = { message in
            self.onUserTap?(UserProfile(message: message))
        }
        actions.userTap = { userId in
            let member = self.compose.members.first(where: { $0.userId == userId })
            let profile = member.map { UserProfile(member: $0) }
                ?? UserProfile(userId: userId)
            self.onUserTap?(profile)
        }
        actions.roomTap = onRoomTap
        actions.contextAction = { action in
            self.handleContextAction(action)
        }
        actions.presentReactionPicker = { messageId, bubbleFrame, isOutgoing in
            self.reactionPickerBubbleFrame = bubbleFrame
            self.reactionPickerIsOutgoing = isOutgoing
            withAnimation(.easeOut(duration: 0.15)) {
                self.reactionPickerMessageId = messageId
            }
        }
        actions.highlightDismissed = {
            self.highlightedMessageId = nil
        }
        actions.permissions = roomPermissions
        actions.currentUserID = matrixService.userId()
    }

    /// Marks the room as read when the user can see the latest messages.
    /// Guards on near-bottom, app-active, and non-read-only state.
    private func markAsReadIfNeeded() {
        guard !readOnly, isNearBottom, NSApp.isActive else { return }
        Task { await matrixService.markAsRead(roomId: roomId, sendPublicReceipt: sendReadReceipts) }
    }

    @ViewBuilder
    private var timelineRenderer: some View {
        if timelineUseLazyVStack {
            TimelineLazyVStackView(
                rows: cachedMessageRows,
                showUnreadMarker: showUnreadMarker,
                firstUnreadMessageId: viewModel.firstUnreadMessageId,
                highlightedMessageId: highlightedMessageId,
                showURLPreviews: showURLPreviews,
                actions: timelineActionsRef,
                onNearBottomChanged: { nearBottom in
                    isNearBottom = nearBottom
                    markAsReadIfNeeded()
                },
                onPaginateBackward: {
                    guard !viewModel.isLoadingMore, !viewModel.hasReachedStart else { return }
                    Task { await viewModel.loadMoreHistory() }
                },
                onPaginateForward: { Task { await viewModel.loadMoreFuture() } },
                onVisibleMessagesChanged: { visibleIDs in
                    guard let newestVisibleID = visibleIDs.last,
                          let row = cachedMessageRows.first(where: { $0.id == newestVisibleID })
                    else { return }
                    advanceFullyReadMarker(to: row.message.eventID)
                },
                onScrollSettled: { markAsReadIfNeeded() },
                isLoadingMore: viewModel.isLoadingMore,
                hasReachedEnd: viewModel.hasReachedEnd,
                isLive: viewModel.timelineFocus == .live,
                viewModel: viewModel,
                bottomContentMargin: composeBarHeight + 4,
                scrollPosition: $lazyVStackScrollPosition
            )
        } else {
            TimelineTableViewRepresentable(
                rows: cachedMessageRows,
                hasReachedEnd: viewModel.hasReachedEnd,
                isLive: viewModel.timelineFocus == .live,
                showUnreadMarker: showUnreadMarker,
                firstUnreadMessageId: viewModel.firstUnreadMessageId,
                highlightedMessageId: highlightedMessageId,
                showURLPreviews: showURLPreviews,
                actions: timelineActionsRef,
                viewModel: viewModel,
                onAppear: { row in advanceFullyReadMarker(to: row.message.eventID) },
                onNearBottomChanged: { nearBottom in
                    isNearBottom = nearBottom
                    markAsReadIfNeeded()
                },
                onPaginateBackward: {
                    guard !viewModel.isLoadingMore, !viewModel.hasReachedStart else { return }
                    Task { await viewModel.loadMoreHistory() }
                },
                onPaginateForward: { Task { await viewModel.loadMoreFuture() } },
                scrollProxy: tableProxy
            )
            .ignoresSafeArea()
        }
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
                    scrollToBottom()
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

    @ViewBuilder
    private var loadingOrEmptyOverlay: some View {
        if viewModel.isLoading && viewModel.messages.isEmpty {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !viewModel.isLoading && viewModel.messages.isEmpty {
            ContentUnavailableView(
                "No Messages Yet",
                systemImage: "text.bubble",
                description: Text("Send a message to get the conversation started.")
            )
        }
    }

    // MARK: - Scroll Dispatch

    /// Scrolls to the bottom of the timeline, dispatching to the active
    /// renderer (NSTableView or LazyVStack).
    private func scrollToBottom(animated: Bool = true) {
        if timelineUseLazyVStack {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    lazyVStackScrollPosition.scrollTo(edge: .bottom)
                }
            } else {
                lazyVStackScrollPosition.scrollTo(edge: .bottom)
            }
        } else {
            tableProxy.scrollToBottom(animated: animated)
        }
    }

    /// Scrolls to a specific row by message ID, dispatching to the active
    /// renderer.
    private func scrollToRow(id: String, animated: Bool = true) {
        if timelineUseLazyVStack {
            if animated {
                withAnimation(.easeOut(duration: 0.3)) {
                    lazyVStackScrollPosition.scrollTo(id: id, anchor: .center)
                }
            } else {
                lazyVStackScrollPosition.scrollTo(id: id, anchor: .center)
            }
        } else {
            tableProxy.scrollToRow(id: id, animated: animated)
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
        if let message = viewModel.messages.first(where: { $0.eventID == eventId }) {
            // Allow the renderer one layout pass to apply the update.
            try? await Task.sleep(for: .milliseconds(100))
            scrollToRow(id: message.id)
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
            if let message = viewModel.messages.first(where: { $0.eventID == eventId }) {
                // Give the renderer time to lay out the new content.
                try? await Task.sleep(for: .milliseconds(100))
                scrollToRow(id: message.id)
                highlightedMessageId = eventId
                return
            }
        }

        // Best-effort fallback: if the message never appeared within the
        // timeout, try scrolling anyway in case it arrived just now.
        if let message = viewModel.messages.first(where: { $0.eventID == eventId }) {
            scrollToRow(id: message.id)
        }
        highlightedMessageId = eventId
    }

    // MARK: - Fully-Read Marker

    /// Debounces fully-read receipt advancement as messages appear on screen.
    /// Only advances forward (to later messages in the timeline), never backward.
    ///
    /// This sends the `m.fully_read` receipt which tracks the user's read position
    /// across devices. It is separate from `markAsRead` which sends `m.read` to
    /// clear the room's unread badge.
    private func advanceFullyReadMarker(to eventId: String) {
        // Only advance if this event is later in the timeline than the last marker
        if let lastId = lastFullyReadEventId,
           let lastIndex = viewModel.messages.firstIndex(where: { $0.eventID == lastId }),
           let newIndex = viewModel.messages.firstIndex(where: { $0.eventID == eventId }),
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
        case .translate(let message):
            Task { await viewModel.translateMessage(message.id) }
        case .showOriginal(let message):
            viewModel.clearTranslation(message.id)
        }
    }

    // (Backward pagination is now handled by TimelineTableViewController's
    // scroll detection, not by a sentinel view.)

    // MARK: - Filtering

    /// The messages to display, with system events filtered based on user preferences.
    private var filteredMessages: [TimelineMessage] {
        if showMembershipEvents && showStateEvents { return viewModel.messages }
        return viewModel.messages.filter { message in
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

/// A single slot in the timeline's parallel translation pool. Each slot
/// owns one `TranslationSession.Configuration` (cached in `@State` so
/// its identity is stable across body re-evaluations) and one
/// `.translationTask`. While idle, the slot watches the view model's
/// queue version; whenever it bumps the slot tries to claim the next
/// pending request and start translating it. Multiple slots running in
/// parallel can each be in different stages (downloading model, mid-
/// translation, idle) without interfering.
private struct TranslationSlot: View {
    let viewModel: any TimelineViewModelProtocol

    @State private var configuration: TranslationSession.Configuration?
    @State private var currentRequest: PendingTranslationRequest?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(configuration) { session in
                guard let request = currentRequest else { return }
                // `TranslationSession` isn't `Sendable`. We only call it
                // from this MainActor-isolated context.
                nonisolated(unsafe) let activeSession = session
                await viewModel.runTranslation(for: request) { body in
                    let response = try await activeSession.translate(body)
                    return response.targetText
                }
                // Done. Clear the busy flag and try to pick up the next
                // queued request immediately. We intentionally do NOT nil
                // `configuration` — keeping it lets `tryClaimNext` detect a
                // repeat language pair and re-run via `invalidate()`.
                currentRequest = nil
                tryClaimNext()
            }
            .onAppear {
                tryClaimNext()
            }
            .onChange(of: viewModel.pendingTranslationQueueVersion) { _, _ in
                tryClaimNext()
            }
    }

    /// If this slot is idle, pulls the next queued request and drives
    /// SwiftUI's `.translationTask` to run for it. No-op if already busy
    /// or the queue is empty.
    ///
    /// `.translationTask` only re-fires when the `Configuration` value
    /// changes. If the next request uses the same source→target pair as
    /// the slot's last run (e.g. the user re-translates a message after
    /// reverting to the original), assigning an equal configuration would
    /// be a no-op and the task would never run — leaving the row stuck on
    /// the loading spinner. In that case we call `invalidate()`, Apple's
    /// mechanism for re-running with an unchanged configuration.
    @MainActor private func tryClaimNext() {
        guard currentRequest == nil else { return }
        guard let request = viewModel.claimNextTranslation() else { return }
        currentRequest = request
        let newConfiguration = TranslationSession.Configuration(
            source: Locale.Language(identifier: request.sourceLanguageTag),
            target: Locale.Language(identifier: request.targetLanguageTag)
        )
        if configuration == newConfiguration {
            configuration?.invalidate()
        } else {
            configuration = newConfiguration
        }
    }
}


