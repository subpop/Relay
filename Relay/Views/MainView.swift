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
import SwiftUI

/// The primary navigation view shown after login, with a room list sidebar and detail area.
struct MainView: View {
    @Environment(RelayClient.self) private var client
    @Environment(\.errorReporter) private var errorReporter
    @Environment(\.callManager) private var callManager
    @Environment(\.openWindow) private var openWindow
    @Environment(AppActions.self) private var appActions
    @AppStorage("selectedRoomId") private var selectedRoomId: String?
    @State private var selectedSpaceId: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showQuickSwitch = false
    @State private var timelineViewModel: TimelineViewModel?
    @State private var focusedMessageId: String?
    @State private var showInspector = false
    @State private var inspectorProfile: UserProfile?
    @State private var inspectorTab: InspectorTab?
    @State private var searchModel = SearchViewModel()
    @FocusState private var isSearchFocused: Bool
    @State private var verificationModel: SessionVerificationViewModel?
    @Namespace private var toolbarNamespace

    var body: some View {
        navigationContent
        .overlay {
            if showQuickSwitch {
                quickSwitchOverlay
            }
        }
        .onChange(of: appActions.showQuickSwitch) { _, shouldShow in
            if shouldShow {
                appActions.showQuickSwitch = false
                showQuickSwitch = true
            }
        }
        .onChange(of: client.shouldPresentVerificationSheet) { _, shouldPresent in
            guard shouldPresent else { return }
            client.shouldPresentVerificationSheet = false
            presentVerificationSheet()
        }
        .onChange(of: client.pendingVerificationRequest) { _, request in
            guard request != nil, verificationModel == nil else { return }
            presentVerificationSheet()
        }
        .sheet(item: $verificationModel) { model in
            VerificationSheet(viewModel: model)
        }
    }

    /// Presents the session verification sheet, acknowledging a pending
    /// incoming request when one exists.
    private func presentVerificationSheet() {
        if let request = client.pendingVerificationRequest {
            verificationModel = SessionVerificationViewModel(client: client, incoming: request)
        } else {
            verificationModel = client.makeSessionVerificationViewModel()
        }
    }

    private var quickSwitchOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { showQuickSwitch = false }

            VStack {
                QuickRoomSwitchView(
                    rooms: roomRows,
                    selectedRoomId: $selectedRoomId,
                    isPresented: $showQuickSwitch
                )
                .padding(.top, 80)
                Spacer()
            }
        }
    }

    private var navigationContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarColumn
                .navigationSplitViewColumnWidth(
                    min: 110 + spaceRailInset,
                    ideal: 250 + spaceRailInset,
                    max: 310 + spaceRailInset
                )
        } detail: {
            detailContent
                .navigationSplitViewColumnWidth(min: 440, ideal: 540)
                .frame(minHeight: 340)
        }
        .navigationTitle("")
        .toolbar { windowToolbarContent }
        .searchable(text: $searchModel.searchText, placement: .sidebar, prompt: "Search…")
        .searchFocused($isSearchFocused)
        .onSubmit(of: .search) {
            searchModel.errorReporter = errorReporter
            searchModel.searchMessages(client: client)
        }
        .onChange(of: searchModel.searchText) {
            if searchModel.isActive {
                searchModel.errorReporter = errorReporter
                searchModel.searchMessages(client: client)
            } else {
                searchModel.messageResults = []
            }
        }
        .onChange(of: searchModel.isActive) { _, active in
            if active {
                // Capture the current selection so we can restore it on dismiss.
                if searchModel.previousSelectedRoomId == nil {
                    searchModel.previousSelectedRoomId = selectedRoomId
                }
            } else if let previousId = searchModel.previousSelectedRoomId {
                selectedRoomId = previousId
                searchModel.previousSelectedRoomId = nil
            }
        }
        .onChange(of: appActions.focusSearch) { _, shouldFocus in
            if shouldFocus {
                appActions.focusSearch = false
                isSearchFocused = true
            }
        }
        .sheet(isPresented: Binding(
            get: { appActions.showCreateRoom },
            set: { appActions.showCreateRoom = $0 }
        )) {
            CreateEntitySheet(kind: .room, selectedRoomId: $selectedRoomId)
        }
        .sheet(isPresented: Binding(
            get: { appActions.showCreateSpace },
            set: { appActions.showCreateSpace = $0 }
        )) {
            CreateEntitySheet(kind: .space, selectedRoomId: $selectedRoomId)
        }
        .sheet(isPresented: Binding(
            get: { appActions.showJoinRoom },
            set: { appActions.showJoinRoom = $0 }
        )) {
            JoinRoomSheet(selectedRoomId: $selectedRoomId)
        }
        .sheet(isPresented: Binding(
            get: { appActions.showRoomDirectory },
            set: { appActions.showRoomDirectory = $0 }
        )) {
            RoomDirectoryView(selectedRoomId: $selectedRoomId)
        }
        .onChange(of: selectedSpaceId) {
            if selectedSpaceId != nil {
                selectedRoomId = nil
            }
        }
        .onChange(of: client.spaces.map(\.roomId.value)) {
            if let selectedSpaceId,
                !client.spaces.contains(where: { $0.roomId.value == selectedSpaceId })
            {
                self.selectedSpaceId = nil
            }
        }
        .onChange(of: client.pendingDeepLink) { _, deepLink in
            guard let deepLink else { return }
            handleDeepLink(deepLink)
        }
        .onAppear {
            if let deepLink = client.pendingDeepLink {
                handleDeepLink(deepLink)
            }
        }
    }

    // MARK: - Rows

    /// Joined rooms mapped for rows and the quick switcher.
    private var roomRows: [RoomRowData] {
        client.rooms
            .filter { $0.membership == .join }
            .map { RoomRowData.from(room: $0, isMuted: client.isMuted(roomId: $0.roomId.value), client: client) }
    }

    /// Joined spaces mapped for the rail.
    private var spaceRows: [RoomRowData] {
        client.spaces.map { RoomRowData.from(room: $0, isMuted: false) }
    }

    // MARK: - Space Rail

    /// Extra width the sidebar column needs when the space rail is visible.
    private var spaceRailInset: CGFloat {
        client.spaces.isEmpty ? 0 : SpaceRail.width
    }

    private var spaceRailView: some View {
        SpaceRail(
            spaces: spaceRows,
            rooms: roomRows,
            selectedSpaceId: $selectedSpaceId,
            onSpaceTapped: {
                selectedRoomId = nil
            },
            onCreateSpace: {
                appActions.showCreateSpace = true
            },
            onLeaveSpace: { space in
                Task {
                    do {
                        try await client.leaveRoom(id: space.roomId)
                    } catch {
                        errorReporter.report(.roomLeaveFailed(error.localizedDescription))
                    }
                }
            }
        )
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebarColumn: some View {
        Group {
            if searchModel.isActive {
                SearchResultsList(
                    rooms: searchModel.filteredRooms(
                        from: roomRows, spaceId: selectedSpaceId),
                    searchModel: searchModel,
                    selectedRoomId: $selectedRoomId,
                    onMessageSelected: { roomId, eventId in
                        searchModel.dismiss()
                        isSearchFocused = false
                        selectedRoomId = roomId
                        Task {
                            try? await Task.sleep(for: .milliseconds(300))
                            focusedMessageId = eventId
                        }
                    }
                )
            } else {
                RoomListView(
                    selectedRoomId: $selectedRoomId,
                    selectedSpaceId: $selectedSpaceId
                )
            }
        }
        .environment(\.hasSpaceRail, !client.spaces.isEmpty)
        .safeAreaInset(edge: .leading, spacing: 0) {
            if !client.spaces.isEmpty {
                spaceRailView
            }
        }
    }

    // MARK: - Detail

    /// The currently selected room, if any.
    private var currentRoom: ObservableRoom? {
        guard let selectedRoomId else { return nil }
        return client.rooms.first { $0.roomId.value == selectedRoomId }
            ?? client.invitedRooms.first { $0.roomId.value == selectedRoomId }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let room = currentRoom, room.membership == .invite {
            inviteCard(for: room)
        } else if let room = currentRoom {
            timelineView(for: room)
                .id(room.roomId.value)
                .inspector(isPresented: $showInspector) {
                    inspectorPanel(roomId: room.roomId.value)
                        .id(room.roomId.value)
                        .inspectorColumnWidth(min: 240, ideal: 260, max: 320)
                }
        } else if let selectedSpaceId, let space = client.spaces.first(where: {
            $0.roomId.value == selectedSpaceId
        }) {
            SpaceDetailView(
                spaceId: selectedSpaceId,
                spaceSummary: RoomRowData.from(room: space, isMuted: false),
                selectedRoomId: $selectedRoomId,
                onOpenSettings: {
                    inspectorTab = .general
                    showInspector.toggle()
                }
            )
            .inspector(isPresented: $showInspector) {
                spaceInspectorPanel(spaceId: selectedSpaceId)
                    .id(selectedSpaceId)
                    .inspectorColumnWidth(min: 240, ideal: 260, max: 320)
            }
        } else {
            ContentUnavailableView(
                "No Conversation Selected",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Pick a room from the sidebar to start chatting.")
            )
        }
    }

    /// The inspector panel for the selected room.
    @ViewBuilder
    private func inspectorPanel(roomId: String) -> some View {
        TimelineInspectorView(
            roomId: roomId,
            selectedProfile: $inspectorProfile,
            initialTab: $inspectorTab,
            onMessageUser: messageUser,
            onScrollToMessage: { [self] eventId in
                focusedMessageId = eventId
            }
        )
    }

    /// The inspector panel for the selected space.
    @ViewBuilder
    private func spaceInspectorPanel(spaceId: String) -> some View {
        TimelineInspectorView(
            roomId: spaceId,
            context: .space,
            selectedProfile: $inspectorProfile,
            initialTab: $inspectorTab,
            onMessageUser: messageUser
        )
    }

    /// Opens (or creates) a DM with the given user, selects it, and
    /// closes the inspector.
    private func messageUser(_ userId: String) {
        Task {
            do {
                selectedRoomId = try await client.createDirectMessage(userId: userId)
                showInspector = false
            } catch {
                errorReporter.report(.dmCreationFailed(error.localizedDescription))
            }
        }
    }

    /// Inline invite card. The full room preview returns with the
    /// directory UI.
    private func inviteCard(for room: ObservableRoom) -> some View {
        let invite = InviteRowData.from(room: room)
        return VStack(spacing: 24) {
            Spacer()
            AvatarView(name: invite.name, mxcURL: invite.avatarURL, size: 80)
            VStack(spacing: 8) {
                Text(invite.name)
                    .font(.title)
                    .bold()
                if let inviterName = invite.inviterName {
                    Text("Invited by \(inviterName)")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 12) {
                Button("Decline", role: .destructive) {
                    declineInvite(roomId: invite.roomId)
                }
                .controlSize(.large)
                Button("Accept & Join") {
                    acceptInvite(roomId: invite.roomId)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The timeline for the selected room, backed by a per-room view model
    /// built when the selection changes.
    @ViewBuilder
    private func timelineView(for room: ObservableRoom) -> some View {
        if let timelineViewModel, timelineViewModel.roomId == room.roomId.value {
            TimelineView(
                roomId: room.roomId.value,
                roomName: room.displayName,
                roomAvatarURL: room.avatarURL?.value,
                viewModel: timelineViewModel,
                focusedMessageId: $focusedMessageId,
                onUserTap: { [self] profile in
                    inspectorProfile = profile
                    showInspector = true
                },
                onRoomTap: { [self] identifier in handleRoomTap(identifier) }
            )
            .id(room.roomId.value)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: room.roomId.value) {
                    timelineViewModel = await client.makeTimelineViewModel(
                        roomId: room.roomId.value)
                }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var windowToolbarContent: some ToolbarContent {
        if let room = currentRoom, room.membership == .invite {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") {
                    self.selectedRoomId = nil
                }
                .help("Back to Room List")
            }
            ToolbarItem(placement: .secondaryAction) {
                inviteToolbarCapsule(for: room)
            }
        } else if let room = currentRoom, room.membership == .join {
            ToolbarItem(placement: .principal) {
                toolbarTitleCapsule
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Start Call", systemImage: "phone.fill") {
                    Task {
                        await callManager.startCall(
                            roomId: room.roomId.value,
                            client: client,
                            openWindow: openWindow,
                            errorReporter: errorReporter)
                    }
                }
                .help("Start a call")
                .disabled(callManager.hasActiveCall || callManager.isPreparingCredentials)
            }
        } else if currentRoom != nil {
            ToolbarItem(placement: .principal) {
                toolbarTitleCapsule
            }
        }
    }

    private var toolbarTitleCapsule: some View {
        GlassEffectContainer {
            HStack(spacing: 8) {
                Button {
                    showInspector.toggle()
                } label: {
                    ToolbarRoomLabel(
                        room: currentRoom,
                        showingInspector: showInspector
                    )
                }
                .help(showInspector ? "Hide Inspector" : "Show Inspector")
            }
        }
    }

    private func inviteToolbarCapsule(for room: ObservableRoom) -> some View {
        HStack(spacing: 0) {
            AvatarView(
                name: room.displayName,
                mxcURL: room.avatarURL?.value,
                size: 28)
            .padding(.leading, 4)
            Text(room.displayName)
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        }
    }

    // MARK: - Deep Link Handling

    /// Handles an incoming ``MatrixURI`` deep link by navigating to the referenced entity.
    private func handleDeepLink(_ uri: MatrixURI) {
        client.pendingDeepLink = nil

        switch uri {
        case .room(let alias, _), .roomId(let alias, _):
            handleRoomTap(alias)
        case .event(let roomId, let eventId, _):
            selectedRoomId = roomId
            focusedMessageId = eventId
        case .user:
            // User deep links have no destination in the main view.
            break
        }
    }

    // MARK: - Room Link Handling

    /// Handles a tap on a `matrix.to` room link.
    ///
    /// If the user is already a member of the room, the sidebar selection
    /// navigates to it directly. Joining unjoined rooms returns with the
    /// directory UI.
    private func handleRoomTap(_ identifier: String) {
        if let joined = client.rooms.first(where: {
            $0.roomId.value == identifier || $0.canonicalAlias == identifier
        }) {
            selectedRoomId = joined.roomId.value
        }
    }

    // MARK: - Invite Actions

    /// Accepts an invitation and keeps the room selected so the detail
    /// transitions once the membership changes to `.joined`.
    private func acceptInvite(roomId: String) {
        Task {
            do {
                try await client.acceptInvite(roomId: roomId)
            } catch {
                errorReporter.report(.roomJoinFailed(error.localizedDescription))
            }
        }
    }

    /// Declines an invitation and deselects the room.
    private func declineInvite(roomId: String) {
        selectedRoomId = nil
        Task {
            do {
                try await client.declineInvite(roomId: roomId)
            } catch {
                errorReporter.report(.roomLeaveFailed(error.localizedDescription))
            }
        }
    }
}

private struct ToolbarRoomLabel: View {
    let room: ObservableRoom?
    let showingInspector: Bool

    @Environment(\.controlSize) private var controlSize

    private var avatarSize: CGFloat {
        controlSize == .regular ? 36 : 28
    }

    var body: some View {
        HStack(spacing: 0) {
            if let room {
                AvatarView(
                    name: room.displayName,
                    mxcURL: room.avatarURL?.value,
                    size: avatarSize)
                .fixedSize()
                .padding(.leading, 6)

                Text(room.displayName)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 280)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)

                Image(systemName: showingInspector ? "xmark" : "chevron.right")
                    .font(.system(size: 12, weight: showingInspector ? .bold : .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
            }
        }
        .contentShape(.capsule)
    }
}

#Preview {
    MainView()
        .environment(RelayClient())
        .environment(AppActions())
        .frame(width: 900, height: 600)
}
