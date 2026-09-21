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

import MatrixKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "Relay", category: "Timeline")

/// The main chat view for a selected room, displaying the message timeline and compose bar.
///
/// ``TimelineView`` is a composition root that assembles the scroll view, overlays,
/// compose bar, and interaction handlers from focused subviews.
struct TimelineView: View {
    @Environment(RelayClient.self) private var client
    @Environment(\.errorReporter) private var errorReporter
    @Environment(\.gifSearchService) private var gifSearchService
    @Environment(\.composeDraftStore) private var composeDraftStore
    @Environment(\.scenePhase) private var scenePhase

    let roomId: String
    let roomName: String
    var roomAvatarURL: String?

    @State var viewModel: TimelineViewModel
    @Binding var focusedMessageId: String?
    var onUserTap: ((UserProfile) -> Void)?
    var onRoomTap: ((String) -> Void)?
    var readOnly: Bool = false

    @State private var compose = ComposeViewModel()
    @State private var messageToDelete: ObservableTimelineEvent?
    @State private var isNearEnd = true
    @State private var lastBottomRowId: String?
    @State private var composeBarHeight: CGFloat = 0
    @State private var pendingScrollToEnd = false
    @State private var timelineInitialLoadComplete = false
    @State private var isDirectRoom = false
    @State private var roomPermissions: RoomPermissions?
    @State private var highlightedMessageId: String?
    @State private var memberRefreshTask: Task<Void, Never>?
    @State private var isTimelineDropTargeted = false
    @State private var timelineActionsRef = TimelineActions()
    @State private var successorRoomId: String?
    @State private var reactionPickerState = ReactionPickerState()
    /// Owns the timeline's scroll position and commands.
    @State private var scroller = TimelineScroller()
    /// Tracks read progress and issues read receipts.
    @State private var readReceiptTracker = TimelineReadReceiptTracker()

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

    private var bottomContentMargin: CGFloat {
        composeBarHeight + 6
    }

    init(
        roomId: String,
        roomName: String,
        roomAvatarURL: String? = nil,
        viewModel: TimelineViewModel,
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
    }

    var body: some View {
        messageList
            .opacity(successorRoomId != nil ? 0.5 : 1)
            .environment(\.mediaAutoReveal, shouldAutoRevealMedia)
            .environment(\.gifAnimationOverride, roomOverrides.animateGIFs)
            .overlay {
                ReplyPreviewOverlay(
                    compose: compose,
                    actions: timelineActionsRef,
                    readOnly: readOnly
                )
            }
            .overlay(alignment: .bottom) {
                if successorRoomId != nil || (!readOnly && (roomPermissions?.canSendMessages ?? true)) {
                    TimelineBottomBar(
                        compose: compose,
                        viewModel: viewModel,
                        roomId: roomId,
                        successorRoomId: successorRoomId,
                        onRoomTap: onRoomTap,
                        onSendWillScroll: { pendingScrollToEnd = true },
                        onHeightChanged: { height in
                            let previous = composeBarHeight
                            let changed = height != previous
                            composeBarHeight = height
                            if changed, height > previous, isNearEnd {
                                scroller.scrollToEnd()
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
        // MARK: Drop Target Overlay
            .overlay {
                DropTargetOverlay(readOnly: readOnly, isTargeted: isTimelineDropTargeted)
            }
            .task {
                if !readOnly {
                    compose = composeDraftStore.draft(for: roomId)
                }

                timelineActionsRef.configure(
                    viewModel: viewModel,
                    compose: compose,
                    roomPermissions: roomPermissions,
                    currentUserID: viewModel.currentUserId,
                    onUserTap: onUserTap,
                    onRoomTap: onRoomTap,
                    scrollToRow: { [self] id in scroller.scrollToRow(id: id) },
                    setHighlightedMessage: { [self] id in highlightedMessageId = id },
                    setFocusedMessage: { [self] id in focusedMessageId = id },
                    handleContextAction: { [self] action in handleContextAction(action) },
                    presentReactionPicker: { [self] messageId, frame, isOutgoing in
                        reactionPickerState.bubbleFrame = frame
                        reactionPickerState.isOutgoing = isOutgoing
                        withAnimation(.easeOut(duration: 0.15)) {
                            reactionPickerState.messageId = messageId
                        }
                    },
                    updateReactionPickerFrame: { [self] messageId, frame in
                        guard messageId == reactionPickerState.messageId else { return }
                        reactionPickerState.bubbleFrame = frame
                    },
                    members: compose.members
                )

                isDirectRoom = viewModel.isDirectRoom
                successorRoomId = viewModel.successorRoomId

                roomPermissions = await viewModel.roomPermissions()
                timelineActionsRef.permissions = roomPermissions

                await viewModel.loadTimeline()

                if !readOnly, !alwaysLoadNewest,
                   let focusEventId = viewModel.firstUnreadMessageId {
                    await viewModel.focusOnEvent(eventId: focusEventId)
                    await scrollToEventWhenAvailable(focusEventId)
                }

                timelineInitialLoadComplete = true
                scroller.didCompleteInitialLoad()

                guard !readOnly else { return }
                markAsReadIfNeeded()
                compose.members = await viewModel.roomMembers()
            }
            .onDisappear {
                if !readOnly, sendTypingNotifications {
                    Task { await viewModel.setTyping(false) }
                }
                memberRefreshTask?.cancel()
            }
            .onChange(of: viewModel.successorRoomId) { _, newValue in
                successorRoomId = newValue
            }
            .onChange(of: viewModel.events.count) {
                guard !readOnly else { return }
                memberRefreshTask?.cancel()
                memberRefreshTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    compose.members = await viewModel.roomMembers()
                }
            }
            .onChange(of: compose.text) { oldValue, newValue in
                guard !readOnly, sendTypingNotifications else { return }
                let wasEmpty = oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let isEmpty = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if wasEmpty && !isEmpty {
                    Task { await viewModel.setTyping(true) }
                } else if !wasEmpty && isEmpty {
                    Task { await viewModel.setTyping(false) }
                }
            }
            .onChange(of: showMembershipEvents) { _, enabled in
                viewModel.updateEventFiltering(showMembership: enabled, showState: showStateEvents)
            }
            .onChange(of: showStateEvents) { _, enabled in
                viewModel.updateEventFiltering(showMembership: showMembershipEvents, showState: enabled)
            }
            .onChange(of: focusedMessageId) {
                guard let eventId = focusedMessageId else { return }
                focusedMessageId = nil

                if let message = viewModel.events.first(where: { $0.eventId.value == eventId }) {
                    scroller.scrollToRow(id: message.eventId.value)
                    highlightedMessageId = eventId
                } else {
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
                        Task { await viewModel.redact(messageId: message.eventId.value) }
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

    private var messageList: some View {
        TimelineScrollView(
            rows: viewModel.messageRows,
            config: .init(
                firstUnreadMessageID: viewModel.firstUnreadMessageId,
                highlightedMessageID: highlightedMessageId,
                showURLPreviews: showURLPreviews,
                hasReachedBottom: viewModel.hasReachedEnd,
                isLive: viewModel.timelineFocus == .live,
                isLoadingMore: viewModel.isLoadingMore
            ),
            bottomInset: bottomContentMargin,
            actions: timelineActionsRef,
            typingUsers: Binding(get: { viewModel.typingUsers }, set: { _ in }),
            scroller: scroller,
            onNearEndChanged: { nearEnd in
                isNearEnd = nearEnd
                markAsReadIfNeeded()
            }, onPaginateBackward: {
                guard !viewModel.isLoadingMore, !viewModel.hasReachedStart else { return }
                Task { await viewModel.loadMoreHistory() }
            },
            onPaginateForward: {
                guard !viewModel.isLoadingMore, !viewModel.hasReachedEnd else { return }
                Task { await viewModel.loadMoreFuture() } },
            onBottomMostVisibleMessageChanged: { rowID in
                lastBottomRowId = rowID
                guard let rowID,
                      let row = viewModel.messageRows.first(where: { $0.id == rowID })
                else { return }
                advanceFullyReadMarker(to: row.message.eventId.value)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: "timeline")
        .overlay {
            TimelinePaginationOverlay(
                isLoading: viewModel.isLoading,
                isLoadingMore: viewModel.isLoadingMore,
                isEmpty: viewModel.messageRows.isEmpty,
                isLive: viewModel.timelineFocus == .live,
                isNearEnd: isNearEnd,
                onScrollToEnd: { scroller.scrollToEnd() },
                onReturnToLive: { Task { await viewModel.returnToLive() } }
            )
        }
        .overlay {
            TimelineReactionPickerOverlay(
                state: $reactionPickerState,
                actions: timelineActionsRef
            )
        }
        .onChange(of: viewModel.messageRows.map(\.id)) {
            guard timelineInitialLoadComplete else { return }

            if pendingScrollToEnd {
                if scroller.isInitialLoad && !scroller.isScrollable {
                    // Defer until content is scrollable.
                } else {
                    pendingScrollToEnd = false
                    scroller.scrollToEnd()
                }
            } else if viewModel.timelineFocus == .live, !viewModel.isLoadingMore {
                if isNearEnd {
                    scroller.scrollToEnd()
                }
            }

            markAsReadIfNeeded()
        }
        .onChange(of: scroller.isScrollable) { _, isScrollable in
            guard isScrollable else { return }
            if pendingScrollToEnd {
                pendingScrollToEnd = false
                scroller.scrollToEnd()
            }
        }
        .onChange(of: viewModel.timelineFocus) {
            if viewModel.timelineFocus == .live {
                pendingScrollToEnd = true
                markAsReadIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            // App regained focus: resume read marking after the dwell, and
            // catch up the fully-read marker to the last visible row (its
            // change handler doesn't refire on reactivation alone).
            markAsReadIfNeeded()
            if let rowID = lastBottomRowId,
               let row = viewModel.messageRows.first(where: { $0.id == rowID }) {
                advanceFullyReadMarker(to: row.message.eventId.value)
            }
        }
    }

    // MARK: - Scroll Management

    private func scrollToEventWhenAvailable(_ eventId: String) async {
        if let message = viewModel.events.first(where: { $0.eventId.value == eventId }) {
            try? await Task.sleep(for: .milliseconds(100))
            scroller.scrollToRow(id: message.eventId.value)
            highlightedMessageId = eventId
            return
        }

        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let found = await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = viewModel.events
                } onChange: {
                    continuation.resume(returning: true)
                }
            }
            guard found else { break }
            if let message = viewModel.events.first(where: { $0.eventId.value == eventId }) {
                try? await Task.sleep(for: .milliseconds(100))
                scroller.scrollToRow(id: message.eventId.value)
                highlightedMessageId = eventId
                return
            }
        }

        if let message = viewModel.events.first(where: { $0.eventId.value == eventId }) {
            scroller.scrollToRow(id: message.eventId.value)
        }
        highlightedMessageId = eventId
    }

    // MARK: - Read Receipts

    private func markAsReadIfNeeded() {
        guard !readOnly else { return }
        readReceiptTracker.markReadIfNeeded(
            isNearEnd: isNearEnd,
            isActive: scenePhase == .active,
            markAsRead: { [self] in
                await client.markAsRead(roomId: roomId, sendReceipt: sendReadReceipts)
            }
        )
    }

    private func advanceFullyReadMarker(to eventId: String) {
        // `m.fully_read` is same-account account data (invisible to other
        // members), so reading always advances it even with Send Read
        // Receipts off — only public room receipts are gated by that
        // setting (a private receipt is sent instead).
        readReceiptTracker.updateHighWaterMark(
            eventId: eventId,
            in: viewModel.events,
            isActive: scenePhase == .active,
            sendReceipt: { [viewModel] eventId in
                await viewModel.sendFullyReadReceipt(upTo: eventId)
            }
        )
    }

    // MARK: - Edit Last Message

    private var editLastMessageAction: (() -> Void)? {
        guard !readOnly else { return nil }
        guard let message = viewModel.events.last(where: {
            guard $0.sender.value == viewModel.currentUserId, $0.isEditable else {
                return false
            }
            if case .text = $0.kind { return true }
            return false
        }) else {
            return nil
        }
        return {
            handleContextAction(.edit(message))
        }
    }

    // MARK: - Context Actions

    private func handleContextAction(_ action: TimelineRowContextAction) {
        switch action {
        case .reply(let message):
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                compose.replyingTo = message
            }
            compose.shouldFocusTextField = true
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .togglePin(let eventId):
            Task {
                if viewModel.isPinned(eventId: eventId) {
                    await viewModel.unpin(eventId: eventId)
                } else {
                    await viewModel.pin(eventId: eventId)
                }
            }
        case .edit(let message):
            compose.replyingTo = nil
            compose.editingMessage = message
            compose.text = message.body
        case .saveMedia(let message):
            guard let download = message.mediaDownload else { break }
            Task {
                do {
                    try await MediaFileHelper.saveToFile(
                        download: download, client: client,
                        contentTypes: Self.contentTypes(for: message)
                    )
                } catch {
                    errorReporter.report(.mediaSaveFailed(
                        filename: download.filename,
                        reason: error.localizedDescription
                    ))
                }
            }
        case .delete(let message):
            messageToDelete = message
        }
    }

    private static func contentTypes(for message: ObservableTimelineEvent) -> [UTType] {
        switch message.kind {
        case .image:
            return [.image]
        case .video:
            return [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        case .audio:
            return [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        default:
            let download = message.mediaDownload
            if let mime = download?.mimetype, let type = UTType(mimeType: mime) {
                return [type]
            }
            let ext = ((download?.filename ?? "") as NSString).pathExtension
            if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
                return [type]
            }
            return [.data]
        }
    }
}
