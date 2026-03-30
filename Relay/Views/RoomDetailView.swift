import OSLog
import RelayCore
import SwiftUI

private let logger = Logger(subsystem: "Relay", category: "RoomDetail")

/// The main chat view for a selected room, displaying the message timeline and compose bar.
///
/// ``RoomDetailView`` loads the room timeline, supports backward pagination, manages
/// scroll anchoring, handles typing notifications, and provides context menus and
/// emoji reaction popovers for individual messages.
struct RoomDetailView: View {
    @Environment(\.matrixService) private var matrixService

    /// The Matrix room identifier for the displayed room.
    let roomId: String

    /// The display name of the room, shown in navigation context.
    let roomName: String

    /// The `mxc://` URL of the room's avatar, if available.
    var roomAvatarURL: String?

    /// The view model managing the room's timeline state and actions.
    @State var viewModel: any RoomDetailViewModelProtocol

    /// Called when a user's profile should be shown (e.g. after double-tapping an avatar).
    var onUserTap: ((UserProfile) -> Void)?

    @State private var draftMessage = ""
    @State private var replyingTo: TimelineMessage?
    @State private var emojiPickerMessageId: String?
    @State private var revealedMessageId: String?

    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var isNearBottom = true
    @State private var pendingScrollToBottom = false
    @State private var showUnreadMarker = true
    @State private var unreadMarkerDismissTask: Task<Void, Never>?

    @AppStorage("safety.sendReadReceipts") private var sendReadReceipts = true
    @AppStorage("safety.sendTypingNotifications") private var sendTypingNotifications = true
    @AppStorage("safety.mediaPreviewMode") private var mediaPreviewMode = "privateOnly"

    private var showErrorAlert: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    private var shouldAutoRevealMedia: Bool {
        if mediaPreviewMode == "allRooms" { return true }
        let isDirect = matrixService.rooms.first(where: { $0.id == roomId })?.isDirect ?? false
        return isDirect
    }

    var body: some View {
        messageList
            .environment(\.mediaAutoReveal, shouldAutoRevealMedia)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if !viewModel.typingUserDisplayNames.isEmpty {
                        typingIndicator
                            .padding(.horizontal, 16)
                            .padding(.bottom, 4)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    ComposeView(text: $draftMessage, replyingTo: $replyingTo, onSend: sendMessage, onAttach: sendAttachments)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }
            .navigationTitle("")
        .task {
            await viewModel.loadTimeline()
            await matrixService.markAsRead(roomId: roomId, sendPublicReceipt: sendReadReceipts)

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
        .alert("Error", isPresented: showErrorAlert) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
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

                let messages = viewModel.messages
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

                    if index > 0 && messages[index - 1].senderID != message.senderID
                        && !shouldShowDateHeader(at: index, in: messages)
                    {
                        Spacer().frame(height: 8)
                    }

                    let isLastInGroup = isLastMessageInGroup(at: index, in: messages)
                    let showSenderName = shouldShowSenderName(at: index, in: messages)

                    MessageSwipeActions(
                        messageId: message.id,
                        revealedMessageId: $revealedMessageId
                    ) {
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
                            }
                        )
                    } onReply: {
                        replyingTo = message
                    } onAddReaction: {
                        emojiPickerMessageId = message.id
                    }
                    .id(message.id)
                    .help(message.formattedTime)
                    .contextMenu {
                        messageContextMenu(for: message)
                    }
                    .popover(
                        isPresented: Binding(
                            get: { emojiPickerMessageId == message.id },
                            set: { if !$0 { emojiPickerMessageId = nil } }
                        ),
                        arrowEdge: message.isOutgoing ? .trailing : .leading
                    ) {
                        EmojiPickerPopover { emoji in
                            Task { await viewModel.toggleReaction(messageId: message.id, key: emoji) }
                            emojiPickerMessageId = nil
                        }
                    }
                }
            }
            .scrollTargetLayout()
            .padding()
            .contentShape(Rectangle())
            .onTapGesture {
                if revealedMessageId != nil {
                    withAnimation(.snappy(duration: 0.25)) {
                        revealedMessageId = nil
                    }
                }
            }
        }
        .defaultScrollAnchor(.bottom)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let distanceFromBottom = geometry.contentSize.height
                - geometry.visibleRect.maxY
            return distanceFromBottom < 50
        } action: { _, newValue in
            guard isNearBottom != newValue else { return }
            isNearBottom = newValue
            if newValue {
                Task { await matrixService.markAsRead(roomId: roomId, sendPublicReceipt: sendReadReceipts) }
            }
        }
        .onChange(of: viewModel.messages.last?.id) {
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
        .overlay(alignment: .bottomTrailing) {
            if !isNearBottom {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        scrollPosition.scrollTo(edge: .bottom)
                    }
                } label: {
                    Image(systemName: "arrow.down")
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
        HStack(spacing: 4) {
            TypingBubble()
            Text(typingLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
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

    // MARK: - Context Menu

    @ViewBuilder
    private func messageContextMenu(for message: TimelineMessage) -> some View {
        Button {
            replyingTo = message
        } label: {
            Label("Reply", systemImage: "arrowshape.turn.up.left")
        }

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.body, forType: .string)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
    }

    // MARK: - Grouping Helpers

    private func isLastMessageInGroup(at index: Int, in messages: [TimelineMessage]) -> Bool {
        guard index < messages.count - 1 else { return true }
        let next = messages[index + 1]
        return next.senderID != messages[index].senderID
            || shouldShowDateHeader(at: index + 1, in: messages)
    }

    private func shouldShowSenderName(at index: Int, in messages: [TimelineMessage]) -> Bool {
        guard !messages[index].isOutgoing else { return false }
        if index == 0 || shouldShowDateHeader(at: index, in: messages) { return true }
        return messages[index - 1].senderID != messages[index].senderID
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
        guard !text.isEmpty else { return }
        let replyEventId = replyingTo?.id
        draftMessage = ""
        replyingTo = nil
        pendingScrollToBottom = true
        Task {
            if sendTypingNotifications {
                await matrixService.sendTypingNotice(roomId: roomId, isTyping: false)
            }
            await viewModel.send(text: text, inReplyTo: replyEventId)
        }
    }

    private func sendAttachments(_ urls: [URL]) {
        pendingScrollToBottom = true
        let tempDir = FileManager.default.temporaryDirectory
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else {
                logger.error("Failed to access security-scoped resource: \(url.lastPathComponent)")
                viewModel.errorMessage = "Could not access \(url.lastPathComponent). Check file permissions."
                continue
            }
            defer { url.stopAccessingSecurityScopedResource() }

            let dest = tempDir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
            } catch {
                logger.error("Failed to copy file \(url.lastPathComponent): \(error)")
                viewModel.errorMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
                continue
            }
            Task { await viewModel.sendAttachment(url: dest) }
        }
    }
}

// MARK: - Typing Bubble Animation

private struct TypingBubble: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: 4, height: 4)
                    .scaleEffect(dotScale(for: index))
                    .opacity(dotOpacity(for: index))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                phase = 1.0
            }
        }
    }

    private func dotScale(for index: Int) -> Double {
        let offset = Double(index) * 0.15
        let t = (phase + offset).truncatingRemainder(dividingBy: 1.0)
        return 0.6 + 0.4 * sin(t * .pi)
    }

    private func dotOpacity(for index: Int) -> Double {
        let offset = Double(index) * 0.15
        let t = (phase + offset).truncatingRemainder(dividingBy: 1.0)
        return 0.4 + 0.6 * sin(t * .pi)
    }
}

#Preview("Messages") {
    NavigationStack {
        RoomDetailView(
            roomId: "!preview:matrix.org",
            roomName: "Design Team",
            viewModel: PreviewRoomDetailViewModel()
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
            viewModel: PreviewRoomDetailViewModel(firstUnreadMessageId: "4")
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
            viewModel: PreviewRoomDetailViewModel(messages: [], isLoading: true)
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
            viewModel: PreviewRoomDetailViewModel(typingUserDisplayNames: ["Alice", "Bob"])
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
            viewModel: PreviewRoomDetailViewModel(messages: [])
        )
    }
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 500, height: 450)
}
