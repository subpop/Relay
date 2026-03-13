import RelayCore
import SwiftUI

struct RoomListView: View {
    @Environment(\.matrixService) private var matrixService
    @Binding var selectedRoomId: String?
    @Binding var searchText: String

    private var filteredRooms: [RoomSummary] {
        if searchText.isEmpty {
            return matrixService.rooms
        }
        return matrixService.rooms.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    @State private var roomToLeave: RoomSummary?
    @State private var showLeaveConfirmation = false

    var body: some View {
        List(selection: $selectedRoomId) {
            ForEach(filteredRooms) { room in
                RoomRowView(room: room)
                    .tag(room.id)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            roomToLeave = room
                            showLeaveConfirmation = true
                        } label: {
                            Label("Leave", systemImage: "door.right.hand.open")
                        }
                    }
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search rooms")
        .overlay {
            if matrixService.rooms.isEmpty {
                if matrixService.isSyncing {
                    ProgressView("Syncing…")
                } else {
                    ContentUnavailableView(
                        "No Rooms",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Join a room to start chatting.")
                    )
                }
            }
        }
        .alert("Leave Room", isPresented: $showLeaveConfirmation, presenting: roomToLeave) { room in
            Button("Cancel", role: .cancel) {}
            Button("Leave", role: .destructive) {
                if selectedRoomId == room.id {
                    selectedRoomId = nil
                }
                Task { try? await matrixService.leaveRoom(id: room.id) }
            }
        } message: { room in
            Text("Are you sure you want to leave \"\(room.name)\"? You'll need to be re-invited or rejoin manually.")
        }
    }
}

// MARK: - Room Row

private struct RoomRowView: View {
    let room: RoomSummary

    private static func formatTimestamp(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else if let daysAgo = calendar.dateComponents([.day], from: date, to: .now).day, daysAgo < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        } else {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(name: room.name, mxcURL: room.avatarURL, size: 48)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(room.name)
                        .font(.headline)
                        .fontWeight(room.unreadCount > 0 ? .semibold : .regular)
                        .lineLimit(1)

                    Spacer()

                    if let ts = room.lastMessageTimestamp {
                        Text(Self.formatTimestamp(ts))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    if let msg = room.lastMessage {
                        Text(msg)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if room.unreadCount > 0 {
                        Text("\(room.unreadCount)")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                    }
                }
            }
            .padding(4)

        }
        .padding(.vertical, 8)
    }
}

// MARK: - Previews

#Preview("Room Rows") {
    List {
        RoomRowView(room: RoomSummary(
            id: "1",
            name: "Design Team",
            avatarURL: nil,
            lastMessage: "Let's finalize the mockups tomorrow",
            lastMessageTimestamp: .now.addingTimeInterval(-300),
            unreadCount: 3,
            isDirect: false
        ))
        RoomRowView(room: RoomSummary(
            id: "2",
            name: "Alice",
            avatarURL: nil,
            lastMessage: "Sounds good, talk soon!",
            lastMessageTimestamp: .now.addingTimeInterval(-7200),
            unreadCount: 0,
            isDirect: true
        ))
        RoomRowView(room: RoomSummary(
            id: "3",
            name: "Matrix HQ",
            avatarURL: nil,
            lastMessage: nil,
            lastMessageTimestamp: nil,
            unreadCount: 0,
            isDirect: false
        ))
        RoomRowView(room: RoomSummary(
            id: "4",
            name: "Bob Chen",
            avatarURL: nil,
            lastMessage: "Sent an image",
            lastMessageTimestamp: .now.addingTimeInterval(-86400 * 2),
            unreadCount: 12,
            isDirect: true
        ))
    }
    .frame(width: 300, height: 400)
}

#Preview("Empty State") {
    RoomListView(selectedRoomId: .constant(nil), searchText: .constant(""))
        .frame(width: 300, height: 400)
}
