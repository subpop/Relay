import RelayCore
import SwiftUI

struct RoomDetailView: View {
    @Environment(\.matrixService) private var matrixService
    let roomId: String
    let roomName: String
    var roomAvatarURL: String?
    @State var viewModel: any RoomDetailViewModelProtocol

    @State private var draftMessage = ""
    @State private var showingRoomInfo = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                messageList

                Divider()

                ComposeView(text: $draftMessage, onSend: sendMessage)
            }
            .frame(maxWidth: .infinity)

            if showingRoomInfo {
                Divider()

                RoomInfoView(roomId: roomId)
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingRoomInfo.toggle()
                    }
                } label: {
                    AvatarView(name: roomName, mxcURL: roomAvatarURL, size: 36)
                }
                .buttonStyle(.plain)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Sign Out", role: .destructive) {
                        Task { await matrixService.logout() }
                    }
                } label: {
                    Image(systemName: "person.circle")
                }
            }
        }
        .task {
            await viewModel.loadTimeline()
            await matrixService.markAsRead(roomId: roomId)
        }
    }

    // MARK: - Message List

    @ViewBuilder
    private var messageList: some View {
        if viewModel.isLoading {
            ProgressView("Loading messages…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.messages.isEmpty {
            ContentUnavailableView(
                "No Messages Yet",
                systemImage: "text.bubble",
                description: Text("Send a message to get the conversation started.")
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if !viewModel.hasReachedStart {
                            Button {
                                Task { await viewModel.loadMoreHistory() }
                            } label: {
                                if viewModel.isLoadingMore {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text("Load earlier messages")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 4)
                        }

                        let messages = viewModel.messages
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            if message.id == viewModel.firstUnreadMessageId {
                                unreadMarker
                            }

                            // Date header when the date changes between messages
                            if shouldShowDateHeader(at: index, in: messages) {
                                Text(dateSectionLabel(for: message.timestamp))
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, index == 0 ? 4 : 12)
                                    .padding(.bottom, 4)
                            }

                            // Add extra spacing when sender changes
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
                                showSenderName: showSenderName
                            )
                            .id(message.id)
                            .help(message.formattedTime)
                        }
                    }
                    .padding()
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: viewModel.messages.count) {
                    if let lastId = viewModel.messages.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
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
        draftMessage = ""
        Task { await viewModel.send(text: text) }
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
