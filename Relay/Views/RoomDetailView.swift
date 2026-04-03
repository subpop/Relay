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

private let logger = Logger(subsystem: "Relay", category: "RoomDetail")

/// The main chat view for a selected room, displaying the message timeline and compose bar.
///
/// ``RoomDetailView`` loads the room timeline, supports backward pagination, manages
/// scroll anchoring, handles typing notifications, and provides context menus and
/// emoji reaction popovers for individual messages.
struct RoomDetailView: View {
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
    @State var viewModel: any RoomDetailViewModelProtocol

    /// A binding that, when set to a message event ID, causes the timeline to scroll
    /// to that message. Used by ``PinnedMessagesView`` to jump to pinned messages.
    @Binding var focusedMessageId: String?

    /// Called when a user's profile should be shown (e.g. after double-tapping an avatar).
    var onUserTap: ((UserProfile) -> Void)?

    /// Called when the user clicks a `matrix.to` room link, with the room ID or alias.
    var onRoomTap: ((String) -> Void)?

    @State private var draftMessage = ""
    @State private var replyingTo: TimelineMessage?
    @State private var stagedAttachments: [StagedAttachment] = []
    @State private var roomMembers: [RoomMemberDetails] = []
    @State private var draftMentions: [Mention] = []
    @State private var messageToDelete: TimelineMessage?

    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var isNearBottom = true
    @State private var pendingScrollToBottom = false
    @State private var showUnreadMarker = true
    @State private var unreadMarkerDismissTask: Task<Void, Never>?
    @State private var fullyReadDebounceTask: Task<Void, Never>?
    @State private var lastFullyReadEventId: String?

    @AppStorage("safety.sendReadReceipts") private var sendReadReceipts = true
    @AppStorage("safety.sendTypingNotifications") private var sendTypingNotifications = true
    @AppStorage("safety.mediaPreviewMode") private var mediaPreviewMode = "privateOnly"
    @AppStorage("behavior.showURLPreviews") private var showURLPreviews = true
    @AppStorage("behavior.alwaysLoadNewest") private var alwaysLoadNewest = true
    @AppStorage("behavior.showMembershipEvents") private var showMembershipEvents = true
    @AppStorage("behavior.showStateEvents") private var showStateEvents = true

    private var shouldAutoRevealMedia: Bool {
        if mediaPreviewMode == "allRooms" { return true }
        let isDirect = matrixService.rooms.first(where: { $0.id == roomId })?.isDirect ?? false
        return isDirect
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
                            showSenderName: !reply.isOutgoing
                        )
                        .allowsHitTesting(false)
                        .padding(.horizontal, 16)
                    }
                    .transition(.opacity)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
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
                    ComposeView(text: $draftMessage, replyingTo: $replyingTo, attachments: $stagedAttachments, members: roomMembers, mentions: $draftMentions,  onSend: sendMessage, onAttach: stageAttachments, onGIFSelected: sendGIF)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }
            .navigationTitle("")
        .task {
            // Load focused on the fully-read marker if the user has opted out of "always load newest"
            var focusEventId: String?
            if !alwaysLoadNewest {
                focusEventId = await matrixService.fullyReadEventId(roomId: roomId)
            }
            await viewModel.loadTimeline(focusedOnEventId: focusEventId)

            // After loading, scroll to the focused event if applicable
            if let focusEventId {
                try? await Task.sleep(for: .milliseconds(200))
                scrollPosition.scrollTo(id: focusEventId, anchor: .center)
            }

            await matrixService.markAsRead(roomId: roomId, sendPublicReceipt: sendReadReceipts)

            // Fetch room members for mention autocomplete
            if let details = await matrixService.roomDetails(roomId: roomId) {
                roomMembers = details.members
            }

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
                // Message is already loaded — just scroll to it
                withAnimation(.easeInOut(duration: 0.3)) {
                    scrollPosition.scrollTo(id: eventId, anchor: .center)
                }
            } else {
                // Message is not in the loaded timeline — load an event-focused timeline
                Task {
                    await viewModel.focusOnEvent(eventId: eventId)
                    // After the focused timeline loads, scroll to the target event
                    try? await Task.sleep(for: .milliseconds(200))
                    withAnimation(.easeInOut(duration: 0.3)) {
                        scrollPosition.scrollTo(id: eventId, anchor: .center)
                    }
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

    /// The message list always renders the `ScrollView` to preserve SwiftUI view identity.
    /// Loading and empty states are overlaid on top rather than replacing the scroll view,
    /// which prevents `LazyVStack` layout issues during rapid timeline diff cycles.
    private var messageList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if viewModel.isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 4)
                }

                if !viewModel.hasReachedStart {
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            guard !viewModel.isLoadingMore else { return }
                            Task { await viewModel.loadMoreHistory() }
                        }
                }

                let messages = filteredMessages
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                    if showUnreadMarker && message.id == viewModel.firstUnreadMessageId {
                            unreadMarker
                        }

                    if shouldShowDateHeader(at: index, in: messages) {
                        Text(dateSectionLabel(for: message.timestamp))
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .padding(.top, index == 0 ? 4 : 12)
                            .padding(.bottom, 4)
                    }

                    if index > 0 && !messages[index - 1].isSystemEvent && !message.isSystemEvent
                        && messages[index - 1].senderID != message.senderID
                        && !shouldShowDateHeader(at: index, in: messages)
                    {
                        Spacer().frame(height: 8)
                    }

                    if message.isSystemEvent {
                        SystemEventView(message: message)
                            .id(message.id)
                            .help(message.formattedTime)
                            .onAppear { advanceFullyReadMarker(to: message.id) }
                    } else {
                        let isLastInGroup = isLastMessageInGroup(at: index, in: messages)
                        let showSenderName = shouldShowSenderName(at: index, in: messages)

                        MessageSwipeActions {
                            MessageView(
                                message: message,
                                isLastInGroup: isLastInGroup,
                                showSenderName: showSenderName,
                                onToggleReaction: { key in
                                    Task { await viewModel.toggleReaction(messageId: message.id, key: key) }
                                },
                                onTapReply: { eventID in
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        scrollPosition.scrollTo(id: eventID, anchor: .center)
                                    }
                                },
                                onAvatarDoubleTap: {
                                    onUserTap?(UserProfile(message: message))
                                },
                                onUserTap: { userId in
                                    let member = roomMembers.first(where: { $0.userId == userId })
                                    let profile = member.map { UserProfile(member: $0) }
                                        ?? UserProfile(userId: userId)
                                    onUserTap?(profile)
                                },
                                onRoomTap: onRoomTap
                            )
                        } onReply: {
                            withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                                replyingTo = message
                            }
                        }
                        .id(message.id)
                        .help(message.formattedTime)
                        .onAppear { advanceFullyReadMarker(to: message.id) }
                        .contextMenu {
                            messageContextMenu(for: message)
                        }

                        if showURLPreviews, message.kind == .text,
                           let url = Self.firstPreviewURL(in: message.body) {
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

                // Forward pagination sentinel: loads newer messages when scrolling
                // toward the live edge on an event-focused timeline.
                if !viewModel.hasReachedEnd {
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            Task { await viewModel.loadMoreFuture() }
                        }
                }

                if !viewModel.typingUserDisplayNames.isEmpty {
                    typingIndicator
                        .padding(.top, 4)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                // Bottom sentinel: tracks whether the user is scrolled near the bottom.
                // Uses onAppear/onDisappear instead of onScrollGeometryChange to avoid
                // the "tried to update multiple times per frame" warning during content
                // size changes.
                Color.clear
                    .frame(height: 1)
                    .id("bottom-sentinel")
                    .onAppear {
                        isNearBottom = true
                        Task { await matrixService.markAsRead(roomId: roomId, sendPublicReceipt: sendReadReceipts) }
                    }
                    .onDisappear {
                        isNearBottom = false
                    }
            }
            .scrollTargetLayout()
            .padding()
            .contentShape(Rectangle())
        }
        .defaultScrollAnchor(.bottom)
        .scrollPosition($scrollPosition)
        .onChange(of: viewModel.messages.last?.id) {
            // Don't auto-scroll when viewing a focused event context
            guard viewModel.timelineFocus == .live else { return }

            if isNearBottom || pendingScrollToBottom {
                pendingScrollToBottom = false
                withAnimation(.easeOut(duration: 0.2)) {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            }
            // Mark as read when new messages arrive and user is at the bottom
            if isNearBottom {
                Task { await matrixService.markAsRead(roomId: roomId, sendPublicReceipt: sendReadReceipts) }
            }
        }
        .onChange(of: viewModel.timelineFocus) {
            // When the timeline auto-transitions to live (after forward pagination
            // reaches the live edge), scroll to the bottom and mark as read.
            if viewModel.timelineFocus == .live {
                pendingScrollToBottom = true
                Task { await matrixService.markAsRead(roomId: roomId, sendPublicReceipt: sendReadReceipts) }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if viewModel.timelineFocus != .live || !isNearBottom {
                Button {
                    if viewModel.timelineFocus != .live {
                        Task { await viewModel.returnToLive() }
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) {
                            scrollPosition.scrollTo(edge: .bottom)
                        }
                    }
                } label: {
                    Image(systemName: viewModel.timelineFocus != .live ? "arrow.uturn.down" : "arrow.down")
                        .font(.title)
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                        .glassEffect(in: .circle)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
                .padding(.trailing, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            if viewModel.isLoading && viewModel.messages.isEmpty {
                ProgressView("Loading messages…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
            } else if !viewModel.isLoading && viewModel.messages.isEmpty {
                ContentUnavailableView(
                    "No Messages Yet",
                    systemImage: "text.bubble",
                    description: Text("Send a message to get the conversation started.")
                )
            }
        }
    }

    // MARK: - Typing Indicator

    private var typingIndicator: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(typingLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            TypingBubble()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.systemGray).opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var typingLabel: String {
        let names = viewModel.typingUserDisplayNames
        switch names.count {
        case 1:
            return "\(names[0]) is typing…"
        case 2:
            return "\(names[0]) and \(names[1]) are typing…"
        default:
            return "\(names[0]) and \(names.count - 1) others are typing…"
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

    // MARK: - Context Menu

    @ViewBuilder
    private func messageContextMenu(for message: TimelineMessage) -> some View {
        Button {
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                replyingTo = message
            }
        } label: {
            Label("Reply", systemImage: "arrowshape.turn.up.left")
        }

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.body, forType: .string)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }

        if message.isOutgoing && message.kind != .redacted {
            Divider()

            Button(role: .destructive) {
                messageToDelete = message
            } label: {
                Label("Delete Message", systemImage: "trash")
            }
        }
    }

    // MARK: - URL Extraction

    /// Returns the first HTTP(S) URL found in the given string, excluding `matrix.to` links.
    private static func firstPreviewURL(in body: String) -> URL? {
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

    // MARK: - Grouping Helpers

    private func isLastMessageInGroup(at index: Int, in messages: [TimelineMessage]) -> Bool {
        guard index < messages.count - 1 else { return true }
        let current = messages[index]
        let next = messages[index + 1]
        if current.isSystemEvent || next.isSystemEvent { return true }
        return next.senderID != current.senderID
            || shouldShowDateHeader(at: index + 1, in: messages)
    }

    private func shouldShowSenderName(at index: Int, in messages: [TimelineMessage]) -> Bool {
        let current = messages[index]
        guard !current.isOutgoing, !current.isSystemEvent else { return false }
        if index == 0 || shouldShowDateHeader(at: index, in: messages) { return true }
        let prev = messages[index - 1]
        if prev.isSystemEvent { return true }
        return prev.senderID != current.senderID
    }

    private func shouldShowDateHeader(at index: Int, in messages: [TimelineMessage]) -> Bool {
        guard index > 0 else { return true }
        return !Calendar.current.isDate(
            messages[index].timestamp,
            equalTo: messages[index - 1].timestamp,
            toGranularity: .hour
        )
    }

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

    // MARK: - Send

    private func sendMessage() {
        let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingAttachments = stagedAttachments
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }
        let replyEventId = replyingTo?.id

        // Capture mentions and convert to markdown with Matrix.to links
        let currentMentions = draftMentions
        let mentionedUserIds = currentMentions.map(\.userId)
        let messageText = ComposeView.markdownWithMentions(text: draftMessage, mentions: currentMentions)
            .trimmingCharacters(in: .whitespacesAndNewlines)

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
                errorReporter.report(.fileCopyFailed(filename: url.lastPathComponent, reason: error.localizedDescription))
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

// MARK: - Typing Bubble Animation

private struct TypingBubble: View {
    private let startDate = Date()

    var body: some View {
        TimelineView(.animation) { context in
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
        let t = (elapsed + delay).truncatingRemainder(dividingBy: period) / period
        return sin(t * .pi)
    }
}

#Preview("Messages") {
    NavigationStack {
        RoomDetailView(
            roomId: "!preview:matrix.org",
            roomName: "Design Team",
            viewModel: PreviewRoomDetailViewModel(),
            focusedMessageId: .constant(nil)
        )
    }
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 500, height: 450)
}

#Preview("Unread Marker") {
    NavigationStack {
        RoomDetailView(
            roomId: "!preview:matrix.org",
            roomName: "Design Team",
            viewModel: PreviewRoomDetailViewModel(firstUnreadMessageId: "4"),
            focusedMessageId: .constant(nil)
        )
    }
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 500, height: 450)
}

#Preview("Loading") {
    NavigationStack {
        RoomDetailView(
            roomId: "!preview:matrix.org",
            roomName: "Design Team",
            viewModel: PreviewRoomDetailViewModel(messages: [], isLoading: true),
            focusedMessageId: .constant(nil)
        )
    }
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 500, height: 450)
}

#Preview("Typing Indicator") {
    NavigationStack {
        RoomDetailView(
            roomId: "!preview:matrix.org",
            roomName: "Design Team",
            viewModel: PreviewRoomDetailViewModel(typingUserDisplayNames: ["Alice", "Bob"]),
            focusedMessageId: .constant(nil)
        )
    }
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 500, height: 450)
}

#Preview("Empty") {
    NavigationStack {
        RoomDetailView(
            roomId: "!preview:matrix.org",
            roomName: "New Room",
            viewModel: PreviewRoomDetailViewModel(messages: []),
            focusedMessageId: .constant(nil)
        )
    }
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 500, height: 450)
}
