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
/// ``TimelineView`` is a composition root that assembles the scroll view, overlays,
/// compose bar, and interaction handlers from focused subviews.
struct TimelineView: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.errorReporter) private var errorReporter
    @Environment(\.gifSearchService) private var gifSearchService
    @Environment(\.composeDraftStore) private var composeDraftStore

    let roomId: String
    let roomName: String
    var roomAvatarURL: String?

    @State var viewModel: any TimelineStateProviding
    @Binding var focusedMessageId: String?
    var onUserTap: ((UserProfile) -> Void)?
    var onRoomTap: ((String) -> Void)?
    var readOnly: Bool = false

    @State private var compose = ComposeViewModel()
    @State private var messageToDelete: TimelineMessage?
    @State private var isNearEnd = true
    @State private var composeBarHeight: CGFloat = 0
    @State private var pendingScrollToEnd = false
    @State private var showUnreadMarker = true
    @State private var timelineInitialLoadComplete = false
    @State private var unreadMarkerDismissTask: Task<Void, Never>?
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
        viewModel: any TimelineStateProviding,
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
                if successorRoomId != nil || (!readOnly && (roomPermissions?.canSendMessages ?? true)),
                   let actionsVM = viewModel as? any TimelineViewModelProtocol {
                    TimelineBottomBar(
                        compose: compose,
                        viewModel: actionsVM,
                        roomId: roomId,
                        successorRoomId: successorRoomId,
                        onRoomTap: onRoomTap,
                        onSendWillScroll: { pendingScrollToEnd = true },
                        onHeightChanged: { height in
                            let previous = composeBarHeight
                            let changed = height != previous
                            composeBarHeight = height
                            if changed, height > previous, isNearEnd {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    scroller.position.scrollTo(edge: .bottom)
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
                    currentUserID: matrixService.userId(),
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

                let roomSummary = matrixService.rooms.first(where: { $0.id == roomId })
                isDirectRoom = roomSummary?.isDirect ?? false
                successorRoomId = roomSummary?.successorRoomId

                let details = await matrixService.roomDetails(roomId: roomId)
                roomPermissions = details?.permissions
                timelineActionsRef.permissions = roomPermissions

                await viewModel.loadTimeline()

                if !readOnly, !alwaysLoadNewest {
                    let focusEventId = await matrixService.fullyReadEventId(roomId: roomId)
                    if let focusEventId {
                        await viewModel.focusOnEvent(eventId: focusEventId)
                        await scrollToEventWhenAvailable(focusEventId)
                    }
                }

                timelineInitialLoadComplete = true
                scroller.didCompleteInitialLoad()

                guard !readOnly else { return }
                markAsReadIfNeeded()
                compose.members = await matrixService.roomMembers(roomId: roomId)
            }
            .onDisappear {
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
            .onChange(of: viewModel.messages.count) {
                guard !readOnly else { return }
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
            .onChange(of: showMembershipEvents) { _, enabled in
                viewModel.updateEventFiltering(showMembership: enabled, showState: showStateEvents)
            }
            .onChange(of: showStateEvents) { _, enabled in
                viewModel.updateEventFiltering(showMembership: showMembershipEvents, showState: enabled)
            }
            .onChange(of: focusedMessageId) {
                guard let eventId = focusedMessageId else { return }
                focusedMessageId = nil

                if let message = viewModel.messages.first(where: { $0.eventID == eventId }) {
                    scroller.scrollToRow(id: message.id)
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
                    if let message = messageToDelete, let actionsVM = viewModel as? any TimelineActionsProviding {
                        Task { await actionsVM.redact(messageId: message.eventID, reason: nil) }
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
                showUnreadMarker: showUnreadMarker,
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
            },            onPaginateBackward: {
                guard !viewModel.isLoadingMore, !viewModel.hasReachedStart else { return }
                Task { await viewModel.loadMoreHistory() }
            },
            onPaginateForward: {
                guard !viewModel.isLoadingMore, !viewModel.hasReachedEnd else { return }
                Task { await viewModel.loadMoreFuture() } },
            onBottomMostVisibleMessageChanged: { rowID in
                guard let rowID,
                      let row = viewModel.messageRows.first(where: { $0.id == rowID })
                else { return }
                advanceFullyReadMarker(to: row.message.eventID)
            },
            onScrollSettled: { markAsReadIfNeeded() }
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
        .onChange(of: viewModel.messageRowsVersion) {
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
        .onChange(of: viewModel.isLoadingMore) {
            if !viewModel.isLoadingMore {
                markAsReadIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            markAsReadIfNeeded()
        }
    }

    // MARK: - Scroll Management

    private func scrollToEventWhenAvailable(_ eventId: String) async {
        if let message = viewModel.messages.first(where: { $0.eventID == eventId }) {
            try? await Task.sleep(for: .milliseconds(100))
            scroller.scrollToRow(id: message.id)
            highlightedMessageId = eventId
            return
        }

        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let found = await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = viewModel.messages
                } onChange: {
                    continuation.resume(returning: true)
                }
            }
            guard found else { break }
            if let message = viewModel.messages.first(where: { $0.eventID == eventId }) {
                try? await Task.sleep(for: .milliseconds(100))
                scroller.scrollToRow(id: message.id)
                highlightedMessageId = eventId
                return
            }
        }

        if let message = viewModel.messages.first(where: { $0.eventID == eventId }) {
            scroller.scrollToRow(id: message.id)
        }
        highlightedMessageId = eventId
    }

    // MARK: - Read Receipts

    private func markAsReadIfNeeded() {
        guard !readOnly else { return }
        readReceiptTracker.markReadIfNeeded(
            isNearEnd: isNearEnd,
            isActive: NSApp.isActive,
            markAsRead: { [self] in
                await matrixService.markAsRead(roomId: roomId, sendPublicReceipt: sendReadReceipts)
            }
        )
    }

    private func advanceFullyReadMarker(to eventId: String) {
        readReceiptTracker.updateHighWaterMark(
            eventId: eventId,
            in: viewModel.messages,
            sendReceipt: { [viewModel] eventId in
                await viewModel.sendFullyReadReceipt(upTo: eventId)
            }
        )
    }

    // MARK: - Edit Last Message

    private var editLastMessageAction: (() -> Void)? {
        guard !readOnly else { return nil }
        guard let message = viewModel.messages.last(where: { $0.isOutgoing && $0.kind == .text }) else {
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
            guard let actionsVM = viewModel as? any TimelineActionsProviding else { break }
            let isPinned = matrixService.rooms
                .first(where: { $0.id == roomId })?
                .pinnedEventIds.contains(eventId) ?? false
            Task {
                if isPinned {
                    await actionsVM.unpin(eventId: eventId)
                } else {
                    await actionsVM.pin(eventId: eventId)
                }
            }
        case .edit(let message):
            compose.replyingTo = nil
            compose.editingMessage = message
            compose.text = message.body
        case .saveMedia(let message):
            guard let mediaInfo = message.mediaInfo else { break }
            Task {
                do {
                    try await MediaFileHelper.saveToFile(
                        mediaInfo: mediaInfo, matrixService: matrixService,
                        contentTypes: Self.contentTypes(for: message)
                    )
                } catch {
                    errorReporter.report(.mediaSaveFailed(
                        filename: mediaInfo.filename,
                        reason: error.localizedDescription
                    ))
                }
            }
        case .delete(let message):
            messageToDelete = message
        }
    }

    private static func contentTypes(for message: TimelineMessage) -> [UTType] {
        switch message.kind {
        case .image(_):
            return [.image]
        case .video(_):
            return [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        case .audio(_):
            return [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        default:
            if let mime = message.mediaInfo?.mimetype, let type = UTType(mimeType: mime) {
                return [type]
            }
            let ext = ((message.mediaInfo?.filename ?? "") as NSString).pathExtension
            if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
                return [type]
            }
            return [.data]
        }
    }
}
