import OSLog
import RelayCore
import SwiftUI

private let logger = Logger(subsystem: "Relay", category: "RoomDetail")

struct RoomDetailView: View {
    @Environment(\.matrixService) private var matrixService
    let roomId: String
    let roomName: String
    var roomAvatarURL: String?
    @State var viewModel: any RoomDetailViewModelProtocol

    @State private var draftMessage = ""
    @State private var replyingTo: TimelineMessage?
    @State private var emojiPickerMessageId: String?

    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var isNearBottom = true
    @State private var pendingScrollToBottom = false
    @State private var hasTriggeredPagination = false

    private var showErrorAlert: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    var body: some View {
        messageList
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposeView(text: $draftMessage, replyingTo: $replyingTo, onSend: sendMessage, onAttach: sendAttachments)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            .navigationTitle("")
        .task {
            await viewModel.loadTimeline()
            await matrixService.markAsRead(roomId: roomId)
        }
        .alert("Error", isPresented: showErrorAlert) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Message List

    @ViewBuilder
    private var messageList: some View {
        if viewModel.isLoading && viewModel.messages.isEmpty {
            ProgressView("Loading messages…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !viewModel.isLoading && viewModel.messages.isEmpty {
            ContentUnavailableView(
                "No Messages Yet",
                systemImage: "text.bubble",
                description: Text("Send a message to get the conversation started.")
            )
        } else {
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
                                guard !hasTriggeredPagination, !viewModel.isLoadingMore else { return }
                                hasTriggeredPagination = true
                                Task { await viewModel.loadMoreHistory() }
                            }
                            .onDisappear {
                                hasTriggeredPagination = false
                            }
                    }

                    let messages = viewModel.messages
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if message.id == viewModel.firstUnreadMessageId {
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

                        MessageView(
                            message: message,
                            isLastInGroup: isLastInGroup,
                            showSenderName: showSenderName,
                            onToggleReaction: { key in
                                Task { await viewModel.toggleReaction(messageId: message.id, key: key) }
                            },
                            onAddReaction: {
                                emojiPickerMessageId = message.id
                            },
                            onTapReply: { eventID in
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    scrollPosition.scrollTo(id: eventID, anchor: .center)
                                }
                            },
                            onReply: {
                                replyingTo = message
                            }
                        )
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
            }
            .onChange(of: viewModel.messages.last?.id) {
                if isNearBottom || pendingScrollToBottom {
                    pendingScrollToBottom = false
                    withAnimation(.easeOut(duration: 0.2)) {
                        scrollPosition.scrollTo(edge: .bottom)
                    }
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
        Task { await viewModel.send(text: text, inReplyTo: replyEventId) }
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
