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

private let logger = Logger(subsystem: "app.subpop.Relay", category: "Timeline")
private nonisolated let timelineViewSignposter = OSSignposter(
    subsystem: "app.subpop.Relay.performance", category: "RoomSwitch")

/// A stable indirection point for the timeline's edit-last-message action.
///
/// The registry closure handed to ``AppActions`` captures this box (whose
/// identity never changes) rather than the view itself, so per-render
/// ``TimelineView`` values are never frozen into a long-lived closure.
/// ``TimelineView`` refreshes `perform` whenever the edit target changes.
final class EditLastMessageBox {
    var perform: (() -> Void)?
}

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
    /// Whether Relay is the frontmost app. `scenePhase` stays `.active` while
    /// the window is visible but another app has focus, so it's tracked
    /// separately from the application activation notifications.
    @State private var isAppActive = NSApp.isActive
    @Environment(AppActions.self) private var appActions

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
    #if DEBUG
    @State private var messageSource: MessageSource?
    #endif
    @State private var isNearEnd = true
    @State private var lastBottomRowId: String?
    @State private var composeBarHeight: CGFloat = 0
    @State private var pendingScrollToEnd = false
    @State private var timelineInitialLoadComplete = false
    @State private var isDirectRoom = false
    @State private var roomPermissions: RoomPermissions?
    @State private var roomPermissionsRoomId: String?
    @State private var highlightedMessageId: String?
    @State private var memberRefreshTask: Task<Void, Never>?
    @State private var memberSnapshotTask: Task<Void, Never>?
    @State private var isTimelineDropTargeted = false
    @State private var timelineActionsRef = TimelineActions()
    @State private var successorRoomId: String?
    @State private var reactionPickerState = ReactionPickerState()
    /// The timeline list's frame in global coordinates, used to tell whether
    /// a reaction target is fully visible when its picker opens.
    @State private var timelineFrame: CGRect = .zero
    @State private var editLastMessageBox = EditLastMessageBox()
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

    private var currentRoomPermissions: RoomPermissions? {
        guard roomPermissionsRoomId == roomId else {
            return RoomPermissions(
                canSendMessages: false,
                canSendReactions: false,
                canSendRedactions: false)
        }
        return roomPermissions
    }

    private var canShowComposeBar: Bool {
        guard roomPermissionsRoomId == roomId else { return true }
        return roomPermissions?.canSendMessages ?? true
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

    /// The unread divider's displayed anchor. Hidden when the user is
    /// actually looking at the live, scrolled-to-bottom timeline with the
    /// app active — in that case there's nothing to catch up on, even if
    /// the debounced read receipt hasn't landed yet. Otherwise mirrors
    /// `viewModel.firstUnreadMessageId` so it stays pinned while scrolled
    /// back, reappearing the moment focus/scroll/activity state changes.
    private var isForeground: Bool { scenePhase == .active && isAppActive }

    private var displayedUnreadMessageId: String? {
        guard let id = viewModel.firstUnreadMessageId else { return nil }
        let isLiveAtBottom = viewModel.timelineFocus == .live && isNearEnd
        if isLiveAtBottom && isForeground { return nil }
        return id
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

        // When the room will open focused on the unread spot rather than
        // the live tail (`behavior.alwaysLoadNewest` off), seed `isNearEnd`
        // to false so the unread-divider gate doesn't briefly think we're
        // at the bottom before the first real scroll-position report.
        let alwaysLoadNewest = UserDefaults.standard.object(forKey: "behavior.alwaysLoadNewest") as? Bool ?? true
        _isNearEnd = State(wrappedValue: alwaysLoadNewest)
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
                if successorRoomId != nil
                    || (!readOnly && canShowComposeBar) {
                    TimelineBottomBar(
                        compose: compose,
                        viewModel: viewModel,
                        roomId: roomId,
                        successorRoomId: successorRoomId,
                        onRoomTap: onRoomTap,
                        onSendWillScroll: {
                            pendingScrollToEnd = true
                            // Focused windows don't render the local echo;
                            // rejoin the live window so the new send shows.
                            if case .focused = viewModel.timelineFocus {
                                Task { await viewModel.returnToLive() }
                            }
                        },
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
                let initialLoadState = timelineViewSignposter.beginInterval(
                    "roomTimelineInitialLoad", id: timelineViewSignposter.makeSignpostID())
                if !readOnly {
                    compose = composeDraftStore.draft(for: roomId)
                }

                timelineActionsRef.configure(
                    viewModel: viewModel,
                    compose: compose,
                    roomPermissions: currentRoomPermissions,
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
                        ensureReactionTargetVisible(messageId: messageId, bubbleFrame: frame)
                    },
                    updateReactionPickerFrame: { [self] messageId, frame in
                        guard messageId == reactionPickerState.messageId else { return }
                        reactionPickerState.bubbleFrame = frame
                    },
                    members: compose.members
                )

                isDirectRoom = viewModel.isDirectRoom
                successorRoomId = viewModel.successorRoomId

                async let loadedRoomPermissions = fetchRoomPermissions()

                let loadTimelineState = timelineViewSignposter.beginInterval(
                    "loadStoredTimeline", id: timelineViewSignposter.makeSignpostID())
                await viewModel.loadTimeline()
                timelineViewSignposter.endInterval("loadStoredTimeline", loadTimelineState)

                if !readOnly, !alwaysLoadNewest,
                   let focusEventId = viewModel.firstUnreadMessageId {
                    await viewModel.focusOnEvent(eventId: focusEventId)
                    await scrollToEventWhenAvailable(focusEventId)
                }

                timelineInitialLoadComplete = true
                scroller.didCompleteInitialLoad()
                timelineViewSignposter.endInterval("roomTimelineInitialLoad", initialLoadState)

                if !readOnly {
                    markAsReadIfNeeded()
                    refreshEditLastMessageTarget()
                }

                roomPermissions = await loadedRoomPermissions
                roomPermissionsRoomId = roomId
                timelineActionsRef.permissions = currentRoomPermissions

                guard !readOnly else { return }
                let membersState = timelineViewSignposter.beginInterval(
                    "refreshRoomMembersAfterLoad", id: timelineViewSignposter.makeSignpostID())
                compose.members = await viewModel.roomMembers()
                timelineViewSignposter.endInterval("refreshRoomMembersAfterLoad", membersState)
                memberRefreshTask?.cancel()
                memberRefreshTask = Task { @MainActor in
                    let refreshState = timelineViewSignposter.beginInterval(
                        "refreshRoomMembersInBackground",
                        id: timelineViewSignposter.makeSignpostID())
                    defer {
                        timelineViewSignposter.endInterval(
                            "refreshRoomMembersInBackground", refreshState)
                    }
                    let members = await viewModel.refreshRoomMembers()
                    guard !Task.isCancelled else { return }
                    compose.members = members
                }
            }
            .onDisappear {
                if !readOnly, sendTypingNotifications {
                    Task { await viewModel.setTyping(false) }
                }
                memberRefreshTask?.cancel()
                memberSnapshotTask?.cancel()
                clearEditLastMessageTarget()
            }
            .onChange(of: viewModel.successorRoomId) { _, newValue in
                successorRoomId = newValue
            }
            .onChange(of: viewModel.events.count) {
                guard !readOnly else { return }
                memberSnapshotTask?.cancel()
                memberSnapshotTask = Task { @MainActor in
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
    }

    // MARK: - Message List

    private var messageList: some View {
        TimelineScrollView(
            rows: viewModel.messageRows,
            config: .init(
                firstUnreadMessageID: displayedUnreadMessageId,
                highlightedMessageID: highlightedMessageId,
                showURLPreviews: showURLPreviews,
                hasReachedBottom: viewModel.hasReachedEnd,
                isLive: viewModel.timelineFocus == .live,
                isLoadingMore: viewModel.isLoadingMore,
                uploadProgress: viewModel.uploadProgress
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
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            timelineFrame = frame
        }
        #if DEBUG
        .sheet(item: $messageSource) { source in
            MessageSourceView(source: source)
        }
        #endif
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
            refreshEditLastMessageTarget()
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
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                isAppActive = true
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didResignActiveNotification) {
                isAppActive = false
            }
        }
        .onChange(of: isForeground) { _, newValue in
            guard newValue else { return }
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

    // MARK: - Initial Load

    private func fetchRoomPermissions() async -> RoomPermissions? {
        let state = timelineViewSignposter.beginInterval(
            "fetchRoomPermissions", id: timelineViewSignposter.makeSignpostID())
        defer { timelineViewSignposter.endInterval("fetchRoomPermissions", state) }
        return await viewModel.roomPermissions()
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

    /// Scrolls a reaction target into full view when it is partially scrolled
    /// out at presentation time, so its picker capsule (anchored above the
    /// bubble) isn't clipped and the dimmed overlay doesn't strand the user
    /// with no way to scroll to it. Fires once per presentation — the picker's
    /// frame streaming keeps it anchored during the animated scroll.
    private func ensureReactionTargetVisible(messageId: String, bubbleFrame: CGRect) {
        guard timelineFrame != .zero else { return }
        // Reserve room for the capsule above the bubble (capsule + gap + margin).
        let reserve: CGFloat = 64
        let clippedTop = bubbleFrame.minY - reserve < timelineFrame.minY
        let clippedBottom = bubbleFrame.maxY > timelineFrame.maxY - bottomContentMargin
        guard clippedTop || clippedBottom else { return }
        scroller.scrollToRow(id: messageId)
    }

    // MARK: - Read Receipts

    private func markAsReadIfNeeded() {
        guard !readOnly else { return }
        readReceiptTracker.markReadIfNeeded(
            isNearEnd: isNearEnd,
            isActive: { [self] in isForeground },
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
            isActive: { [self] in isForeground },
            sendReceipt: { [viewModel] eventId in
                await viewModel.sendFullyReadReceipt(upTo: eventId)
            }
        )
    }

    // MARK: - Edit Last Message

    /// Publishes this timeline's edit-last-message target to ``AppActions``
    /// (consumed by the ⌘E menu command) whenever the target changes. The
    /// registered closure is stable across renders: it funnels through
    /// ``EditLastMessageBox``, whose `perform` is refreshed here, and the
    /// fire-time closure looks the message up by id so it always acts on
    /// the current timeline — never on a stale render's value.
    private func refreshEditLastMessageTarget() {
        guard !readOnly else { return }
        guard let message = viewModel.events.last(where: {
            guard $0.sender.value == viewModel.currentUserId, $0.isEditable else {
                return false
            }
            if case .text = $0.kind { return true }
            return false
        }) else {
            clearEditLastMessageTarget()
            return
        }
        let eventId = message.eventId.value
        editLastMessageBox.perform = { [weak viewModel, compose] in
            guard let message = viewModel?.events.first(where: { $0.eventId.value == eventId }) else { return }
            // Mirrors handleContextAction(.edit(message)); kept inline so the
            // fire-time closure only captures the compose object and the
            // view model instead of the whole view value.
            compose.replyingTo = nil
            compose.editingMessage = message
            compose.text = message.body
        }
        if appActions.editLastMessageTarget?.owner !== editLastMessageBox {
            appActions.editLastMessageTarget = .init(owner: editLastMessageBox) { [editLastMessageBox] in
                editLastMessageBox.perform?()
            }
        }
    }

    /// Withdraws this timeline's registration, but only if it still owns
    /// the slot — a newly focused timeline must not be clobbered.
    private func clearEditLastMessageTarget() {
        if appActions.editLastMessageTarget?.owner === editLastMessageBox {
            appActions.editLastMessageTarget = nil
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
        case .copy(let message):
            copyToPasteboard(message)
        case .react(let eventId, let key):
            QuickReactions.record(key)
            Task { await viewModel.toggleReaction(messageId: eventId, key: key) }
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
        #if DEBUG
        case .showSource(let message):
            messageSource = MessageSource(
                id: message.eventId.value,
                json: client.storedEventJSON(eventId: message.eventId)
                    ?? "Event not found in the local store.")
        #endif
        }
    }

    /// Copies an image message's pixels, a video or audio message's file, or
    /// the message body for any other kind.
    private func copyToPasteboard(_ message: ObservableTimelineEvent) {
        guard let download = message.mediaDownload else {
            copyText(message.body)
            return
        }
        switch message.kind {
        case .image:
            Task {
                guard let data = await MediaFileHelper.fetch(download: download, client: client),
                      let image = NSImage(data: data)
                else {
                    reportCopyFailure(download)
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
        case .video, .audio:
            Task {
                do {
                    let url = try await MediaFileHelper.downloadToTemporaryFile(
                        download: download, client: client
                    )
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([url as NSURL])
                } catch {
                    reportCopyFailure(download)
                }
            }
        default:
            copyText(message.body)
        }
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func reportCopyFailure(_ download: MediaFileHelper.Download) {
        errorReporter.report(.mediaSaveFailed(
            filename: download.filename,
            reason: MediaFileHelper.MediaFileError.downloadFailed.localizedDescription
        ))
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
