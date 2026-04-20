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

import os
import RelayInterface
import SwiftUI

/// The sidebar list of joined rooms with unread indicators, search filtering, and swipe-to-leave.
///
/// Pending invite rows appear at the top of the list, above joined rooms.
struct RoomListView: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.errorReporter) private var errorReporter
    @Binding var selectedRoomId: String?
    @Binding var searchText: String
    @Binding var selectedSpaceId: String?
    @AppStorage("roomSortOrder") private var sortOrder: RoomSortOrder = .lastMessage
    @AppStorage("roomSortDirection") private var sortDirection: RoomSortDirection = .descending
    @AppStorage("roomTypeFilter") private var typeFilter: RoomTypeFilter = .all
    @State private var roomToLeave: RoomSummary?
    @State private var showLeaveConfirmation = false
    @State private var verificationItem: VerificationItem?
    @Binding var previewingInvite: RoomSummary?
    @State private var inviteToDecline: RoomSummary?
    @State private var showDeclineConfirmation = false

    var body: some View {
        // Compute filtered results once per body evaluation to avoid
        // redundant filter + O(n log n) sort passes. Previously each
        // access to pinnedRooms / unpinnedRooms recomputed filteredRooms.
        let invites = pendingInvites
        let filtered = filteredRooms
        let pinned = filtered.filter(\.isFavourite)
        let unpinned = filtered.filter { !$0.isFavourite }

        List(selection: $selectedRoomId) {
            if !invites.isEmpty {
                Section {
                    ForEach(invites) { invite in
                        InviteListRow(
                            room: invite,
                            onAccept: { acceptInvite(invite) },
                            onDecline: { confirmDecline(invite) },
                            onTap: { previewingInvite = invite }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Decline", systemImage: "xmark", role: .destructive) {
                                confirmDecline(invite)
                            }
                        }
                    }
                } header: {
                    Text("Invites")
                }
            }

            if !pinned.isEmpty {
                Section {
                    ForEach(pinned) { room in
                        roomRow(room)
                    }
                } header: {
                    Text("Pinned")
                }
            }

            Section {
                ForEach(unpinned) { room in
                    roomRow(room)
                }
            } header: {
                if !invites.isEmpty || !pinned.isEmpty {
                    Text("Rooms")
                }
            }
        }
        .animation(.default, value: pinned.map(\.id))
        .animation(.default, value: unpinned.map(\.id))
        .animation(.default, value: invites.map(\.id))
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search rooms")
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                sortMenu
            }
        }
        .overlay {
            if matrixService.rooms.isEmpty {
                if matrixService.hasLoadedRooms {
                    ContentUnavailableView(
                        "No Rooms",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Join a room to start chatting.")
                    )
                } else {
                    ProgressView("Syncing...")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                OfflineBanner()
                SessionVerificationBanner(verificationItem: $verificationItem)
            }
        }
        .sheet(item: $verificationItem) { item in
            VerificationSheet(viewModel: item.viewModel)
        }
        .alert("Leave Room", isPresented: $showLeaveConfirmation, presenting: roomToLeave) { room in
            Button("Cancel", role: .cancel) {}
            Button("Leave", role: .destructive, action: { leaveRoom(room) })
        } message: { room in
            Text("Are you sure you want to leave \"\(room.name)\"? You'll need to be re-invited or rejoin manually.")
        }
        .alert("Decline Invitation", isPresented: $showDeclineConfirmation, presenting: inviteToDecline) { invite in
            Button("Cancel", role: .cancel) {}
            Button("Decline", role: .destructive, action: { declineInvite(invite) })
        } message: { invite in
            Text("Decline the invitation to \"\(invite.name)\"? You'll need to be re-invited to join later.")
        }
    }

    // MARK: - Room Row

    private func roomRow(_ room: RoomSummary) -> some View {
        RoomListRow(room: room)
            .tag(room.id)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Leave", systemImage: "door.right.hand.open", role: .destructive, action: { confirmLeave(room) })
            }
            .contextMenu {
                Button(
                    room.isFavourite ? "Unpin" : "Pin",
                    systemImage: room.isFavourite ? "pin.slash" : "pin",
                    action: { toggleFavourite(room) }
                )
                Divider()
                Button("Leave", systemImage: "door.right.hand.open", role: .destructive, action: { confirmLeave(room) })
            }
    }

    // MARK: - Sort Menu

    private var sortMenu: some View {
        Menu {
            Section("Sort By") {
                ForEach(RoomSortOrder.allCases, id: \.self) { order in
                    Toggle(isOn: Binding(
                        get: { sortOrder == order },
                        set: { isOn in
                            if isOn {
                                withAnimation { sortOrder = order }
                            }
                        }
                    )) {
                        Label(order.label, systemImage: order.icon)
                    }
                }
            }

            Section("Order") {
                Toggle(isOn: Binding(
                    get: { sortDirection == .ascending },
                    set: { _ in withAnimation { sortDirection = .ascending } }
                )) {
                    Label("Ascending", systemImage: "arrow.up")
                }

                Toggle(isOn: Binding(
                    get: { sortDirection == .descending },
                    set: { _ in withAnimation { sortDirection = .descending } }
                )) {
                    Label("Descending", systemImage: "arrow.down")
                }
            }

            Section("Show") {
                ForEach(RoomTypeFilter.allCases, id: \.self) { filter in
                    Toggle(isOn: Binding(
                        get: { typeFilter == filter },
                        set: { isOn in
                            if isOn {
                                withAnimation { typeFilter = filter }
                            }
                        }
                    )) {
                        Label(filter.label, systemImage: filter.icon)
                    }
                }
            }
        } label: {
            Label("Sort and Filter", systemImage: "line.3.horizontal.decrease")
        }
        .menuIndicator(.hidden)
    }
}

// MARK: - Actions

extension RoomListView {
    private func confirmLeave(_ room: RoomSummary) {
        roomToLeave = room
        showLeaveConfirmation = true
    }

    private func leaveRoom(_ room: RoomSummary) {
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

    private func acceptInvite(_ invite: RoomSummary) {
        Task {
            do {
                try await matrixService.acceptInvite(roomId: invite.id)
                // Wait briefly for the room list to sync, then select the room.
                try? await Task.sleep(for: .milliseconds(500))
                if let joined = matrixService.rooms.first(where: { $0.id == invite.id }) {
                    selectedRoomId = joined.id
                }
            } catch {
                errorReporter.report(.roomJoinFailed(error.localizedDescription))
            }
        }
    }

    private func toggleFavourite(_ room: RoomSummary) {
        Task {
            do {
                try await matrixService.setFavourite(roomId: room.id, isFavourite: !room.isFavourite)
            } catch {
                errorReporter.report(.pinFailed(error.localizedDescription))
            }
        }
    }

    private func confirmDecline(_ invite: RoomSummary) {
        inviteToDecline = invite
        showDeclineConfirmation = true
    }

    private func declineInvite(_ invite: RoomSummary) {
        Task {
            do {
                try await matrixService.declineInvite(roomId: invite.id)
            } catch {
                errorReporter.report(.roomLeaveFailed(error.localizedDescription))
            }
        }
    }
}

// MARK: - Filtering & Sorting

extension RoomListView {
    /// Rooms with a pending invitation, shown at the top of the sidebar.
    fileprivate var pendingInvites: [RoomSummary] {
        var invites = matrixService.rooms.filter { $0.isInvited }
        if !searchText.isEmpty {
            invites = invites.filter {
                $0.name.localizedStandardContains(searchText)
            }
        }
        return invites
    }

    private static let perfSignposter = OSSignposter(
        subsystem: "app.subpop.Relay.performance",
        category: "RoomList"
    )

    /// All joined rooms with the current space, type, search filter, and sort applied.
    private var filteredRooms: [RoomSummary] {
        let state = Self.perfSignposter.beginInterval(
            "filterRooms" as StaticString,
            "\(matrixService.rooms.count) total"
        )
        var rooms = matrixService.rooms.filter { !$0.isInvited }

        // Apply space filter.
        if let selectedSpaceId {
            rooms = rooms.filter { $0.parentSpaceIds.contains(selectedSpaceId) }
        }

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
                $0.name.localizedStandardContains(searchText)
            }
        }

        // Apply sort.
        rooms.sort(by: roomComparator)

        Self.perfSignposter.endInterval(
            "filterRooms" as StaticString,
            state,
            "\(rooms.count) after filter+sort"
        )
        return rooms
    }



    /// A reusable comparator for sorting rooms by the current sort settings.
    private var roomComparator: (RoomSummary, RoomSummary) -> Bool {
        { lhs, rhs in
            // Muted rooms always sort to the bottom, regardless of direction.
            if lhs.isMuted != rhs.isMuted {
                return rhs.isMuted
            }

            let result: ComparisonResult
            switch sortOrder {
            case .lastMessage:
                // Muted rooms don't participate in recency sort; order alphabetically.
                if lhs.isMuted {
                    result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                } else {
                    switch (lhs.lastMessageTimestamp, rhs.lastMessageTimestamp) {
                    // swiftlint:disable:next identifier_name
                    case (.some(let l), .some(let r)):
                        result = l < r ? .orderedAscending : (l > r ? .orderedDescending : .orderedSame)
                    case (.some, .none):
                        result = .orderedDescending
                    case (.none, .some):
                        result = .orderedAscending
                    case (.none, .none):
                        result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                    }
                }
            case .name:
                result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            }

            return sortDirection == .ascending
                ? result == .orderedAscending
                : result == .orderedDescending
        }
    }
}

// MARK: - Previews

#Preview("Room Rows") {
    @Previewable @State var sel: String?
    @Previewable @State var search = ""
    @Previewable @State var space: String?
    @Previewable @State var invite: RoomSummary?
    RoomListView(
        selectedRoomId: $sel,
        searchText: $search,
        selectedSpaceId: $space,
        previewingInvite: $invite
    )
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 300, height: 400)
}

#Preview("Empty State") {
    RoomListView(
        selectedRoomId: .constant(nil),
        searchText: .constant(""),
        selectedSpaceId: .constant(nil),
        previewingInvite: .constant(nil)
    )
    .frame(width: 300, height: 400)
}
