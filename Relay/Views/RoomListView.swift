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

import RelayInterface
import SwiftUI

/// The sidebar list of joined rooms with unread indicators, search filtering, and swipe-to-leave.
struct RoomListView: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.errorReporter) private var errorReporter
    @Binding var selectedRoomId: String?
    @Binding var searchText: String
    var sortOrder: RoomSortOrder
    var sortDirection: RoomSortDirection
    var typeFilter: RoomTypeFilter

    private var filteredRooms: [RoomSummary] {
        var rooms = matrixService.rooms

        // Apply type filter.
        switch typeFilter {
        case .all:
            break
        case .rooms:
            rooms = rooms.filter { !$0.isDirect }
        case .directMessages:
            rooms = rooms.filter { $0.isDirect }
        }

        // Apply search filter.
        if !searchText.isEmpty {
            rooms = rooms.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
        }

        // Apply sort.
        rooms.sort { lhs, rhs in
            let result: ComparisonResult
            switch sortOrder {
            case .lastMessage:
                switch (lhs.lastMessageTimestamp, rhs.lastMessageTimestamp) {
                case (.some(let l), .some(let r)):
                    result = l < r ? .orderedAscending : (l > r ? .orderedDescending : .orderedSame)
                case (.some, .none):
                    result = .orderedDescending
                case (.none, .some):
                    result = .orderedAscending
                case (.none, .none):
                    result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                }
            case .name:
                result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            }

            return sortDirection == .ascending
                ? result == .orderedAscending
                : result == .orderedDescending
        }

        return rooms
    }

    @State private var roomToLeave: RoomSummary?
    @State private var showLeaveConfirmation = false

    var body: some View {
        List(selection: $selectedRoomId) {
            ForEach(filteredRooms) { room in
                HStack(spacing: 10) {
                    Circle()
                        .fill(room.unreadMentions > 0 ? Color.red : Color.accentColor)
                        .frame(width: 8, height: 8)
                        .opacity(room.unreadMessages > 0 || room.unreadMentions > 0 ? 1 : 0)

                    AvatarView(name: room.name, mxcURL: room.avatarURL, size: 48)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(room.name)
                                .font(.headline)
                                .fontWeight(room.unreadMessages > 0 || room.unreadMentions > 0 ? .semibold : .regular)
                                .lineLimit(1)

                            Spacer()

                            if let ts = room.lastMessageTimestamp {
                                Text(Self.formatTimestamp(ts))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let msg = room.lastMessage {
                            Text(msg)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .padding(4)
                }
                .padding(.vertical, 8)
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
                if matrixService.hasLoadedRooms {
                    ContentUnavailableView(
                        "No Rooms",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Join a room to start chatting.")
                    )
                } else {
                    ProgressView("Syncing…")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SessionVerificationBanner()
        }
        .alert("Leave Room", isPresented: $showLeaveConfirmation, presenting: roomToLeave) { room in
            Button("Cancel", role: .cancel) {}
            Button("Leave", role: .destructive) {
                if selectedRoomId == room.id {
                    selectedRoomId = nil
                }
                Task {
                    do {
                        try await matrixService.leaveRoom(id: room.id)
                    } catch {
                        errorReporter.report(.roomLeaveFailed(error.localizedDescription))
                    }
                }
            }
        } message: { room in
            Text("Are you sure you want to leave \"\(room.name)\"? You'll need to be re-invited or rejoin manually.")
        }
    }
}

// MARK: - Helpers

extension RoomListView {
    fileprivate static func formatTimestamp(_ date: Date) -> String {
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
}

// MARK: - Previews

#Preview("Room Rows") {
    @Previewable @State var sel: String? = nil
    @Previewable @State var search = ""
    RoomListView(
        selectedRoomId: $sel,
        searchText: $search,
        sortOrder: .lastMessage,
        sortDirection: .descending,
        typeFilter: .all
    )
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 300, height: 400)
}

#Preview("Empty State") {
    RoomListView(
        selectedRoomId: .constant(nil),
        searchText: .constant(""),
        sortOrder: .lastMessage,
        sortDirection: .descending,
        typeFilter: .all
    )
    .frame(width: 300, height: 400)
}
