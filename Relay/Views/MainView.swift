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

/// The primary navigation view shown after login, with a room list sidebar and detail area.
///
/// ``MainView`` uses a `NavigationSplitView` with the room list in the sidebar and the
/// selected room's detail view (or compose view) in the detail area. An optional inspector
/// panel on the trailing edge shows room info or a selected user's profile.
/// Identifies a space the user wants to leave, carrying the children for confirmation.
struct LeaveSpaceItem: Identifiable {
    let id: String
    let name: String
    let children: [LeaveSpaceChild]
}

struct MainView: View { // swiftlint:disable:this type_body_length
    @Environment(\.matrixService) private var matrixService
    @Environment(\.errorReporter) private var errorReporter
    @Environment(AppActions.self) private var appActions
    @AppStorage("selectedRoomId") private var selectedRoomId: String?
    @State private var selectedSpaceId: String?
    @State private var leaveSpaceItem: LeaveSpaceItem?
    @State private var searchText = ""
    @State private var showingInspector = false
    @State private var showingPinnedMessages = false
    @State private var focusedMessageId: String?
    @State private var incomingVerificationItem: VerificationItem?
    @State private var previewingLinkedRoom: DirectoryRoom?
    @State private var previewingDirectoryRoom: DirectoryRoom?
    @State private var previewingInvite: RoomSummary?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var isJoiningLinkedRoom = false
    @State private var inspectorSelectedProfile: UserProfile?
    @State private var inspectorInitialTab: InspectorTab?

    private func scrollToMessage(_ eventId: String) {
        showingPinnedMessages = false
        focusedMessageId = eventId
    }

    private func showUserProfile(_ profile: UserProfile) {
        inspectorSelectedProfile = profile
        withAnimation(.easeInOut(duration: 0.25)) {
            showingInspector = true
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            HStack(spacing: 0) {
                if !matrixService.spaces.isEmpty {
                    SpaceRail(selectedSpaceId: $selectedSpaceId, onSpaceTapped: {
                        selectedRoomId = nil
                    }, onCreateSpace: {
                        appActions.showCreateSpace = true
                    }, onLeaveSpace: { space in
                        Task {
                            do {
                                let children = try await matrixService.leaveSpace(spaceId: space.id)
                                leaveSpaceItem = LeaveSpaceItem(
                                    id: space.id,
                                    name: space.name,
                                    children: children
                                )
                            } catch {
                                errorReporter.report(.roomLeaveFailed(error.localizedDescription))
                            }
                        }
                    })
                    Divider()
                }
                RoomListView(
                    selectedRoomId: $selectedRoomId,
                    searchText: $searchText,
                    selectedSpaceId: $selectedSpaceId,
                    previewingInvite: $previewingInvite
                )
            }
                .navigationSplitViewColumnWidth(
                    min: matrixService.spaces.isEmpty ? 116 : 168,
                    ideal: matrixService.spaces.isEmpty ? 240 : 280,
                    max: matrixService.spaces.isEmpty ? 340 : 380
                )
                .onChange(of: selectedRoomId) { oldRoomId, newRoomId in
                    if let oldRoomId {
                        matrixService.suspendTimeline(roomId: oldRoomId)
                    }
                    if newRoomId != nil {
                        appActions.showRoomDirectory = false
                        previewingDirectoryRoom = nil
                        previewingInvite = nil
                        showingPinnedMessages = false
                    }
                }
                .onChange(of: selectedSpaceId) {
                    if selectedSpaceId != nil {
                        selectedRoomId = nil
                    }
                }
        } detail: {
            if let previewingInvite, previewingInvite.isSpace {
                SpaceInvitePreview(
                    invite: previewingInvite,
                    onAccept: { acceptInviteFromPreview(previewingInvite) },
                    onDecline: {
                        let invite = previewingInvite
                        self.previewingInvite = nil
                        declineInviteFromPreview(invite)
                    }
                )
            } else if let previewingInvite {
                RoomPreviewView(
                    room: DirectoryRoom(
                        roomId: previewingInvite.id,
                        name: previewingInvite.name,
                        topic: previewingInvite.topic,
                        alias: previewingInvite.canonicalAlias,
                        avatarURL: previewingInvite.avatarURL
                    ),
                    onJoin: { acceptInviteFromPreview(previewingInvite) },
                    onClose: { self.previewingInvite = nil },
                    inviterName: previewingInvite.inviterName,
                    inviterAvatarURL: previewingInvite.inviterAvatarURL,
                    onDecline: {
                        let invite = previewingInvite
                        self.previewingInvite = nil
                        declineInviteFromPreview(invite)
                    },
                    showsHeader: false
                )
            } else if appActions.showRoomDirectory, let previewingDirectoryRoom {
                RoomPreviewView(
                    room: previewingDirectoryRoom,
                    onJoin: { joinDirectoryRoom(previewingDirectoryRoom) },
                    onClose: { self.previewingDirectoryRoom = nil },
                    showsHeader: false
                )
            } else if appActions.showRoomDirectory {
                RoomDirectoryView(
                    previewingRoom: $previewingDirectoryRoom,
                    onRoomJoined: { roomId in
                        selectedRoomId = roomId
                    }
                )
            } else if let selectedRoomId,
                      let summary = matrixService.rooms.first(where: { $0.id == selectedRoomId }),
                      let viewModel = matrixService.makeTimelineViewModel(roomId: selectedRoomId) {
                TimelineView(
                    roomId: selectedRoomId,
                    roomName: summary.name,
                    roomAvatarURL: summary.avatarURL,
                    viewModel: viewModel,
                    focusedMessageId: $focusedMessageId,
                    onUserTap: { profile in showUserProfile(profile) },
                    onRoomTap: { identifier in handleRoomTap(identifier) }
                )
                .id(selectedRoomId)
                .inspector(isPresented: $showingInspector) {
                    inspectorPanel(roomId: selectedRoomId)
                        .id(selectedRoomId)
                        .inspectorColumnWidth(min: 200, ideal: 260, max: 320)
                }
            } else if let selectedSpaceId,
                      let spaceSummary = matrixService.spaces.first(where: { $0.id == selectedSpaceId }) {
                SpaceDetailView(
                    spaceId: selectedSpaceId,
                    spaceSummary: spaceSummary,
                    selectedRoomId: $selectedRoomId,
                    onOpenSettings: {
                        inspectorInitialTab = .settings
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showingInspector = true
                        }
                    }
                )
                .inspector(isPresented: $showingInspector) {
                    spaceInspectorPanel(spaceId: selectedSpaceId)
                        .id(selectedSpaceId)
                        .inspectorColumnWidth(min: 200, ideal: 260, max: 320)
                }
            } else {
                ContentUnavailableView(
                    "No Conversation Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Pick a room from the sidebar to start chatting.")
                )
            }
        }
        .navigationTitle("")
        .toolbar { windowToolbarContent }
        .onChange(of: matrixService.shouldPresentVerificationSheet) { _, shouldPresent in
            guard shouldPresent else { return }
            matrixService.shouldPresentVerificationSheet = false
            Task {
                // swiftlint:disable:next identifier_name
            if let vm = try? await matrixService.makeSessionVerificationViewModel() {
                    matrixService.pendingVerificationRequest = nil
                    incomingVerificationItem = VerificationItem(viewModel: vm)
                }
            }
        }
        .sheet(item: $incomingVerificationItem) { item in
            VerificationSheet(viewModel: item.viewModel)
        }
        .sheet(isPresented: Bindable(appActions).showCreateRoom) {
            CreateRoomSheet(selectedRoomId: $selectedRoomId)
        }
        .sheet(isPresented: Bindable(appActions).showCreateSpace) {
            CreateSpaceSheet()
        }
        .sheet(isPresented: Bindable(appActions).showJoinRoom) {
            JoinRoomSheet(selectedRoomId: $selectedRoomId)
        }
        .sheet(item: $previewingLinkedRoom) { room in
            RoomPreviewView(
                room: room,
                onJoin: { joinLinkedRoom(room) },
                onClose: { previewingLinkedRoom = nil }
            )
            .frame(minWidth: 500, idealWidth: 600, minHeight: 400, idealHeight: 500)
        }
        .sheet(item: $leaveSpaceItem) { item in
            LeaveSpaceSheet(spaceName: item.name, spaceId: item.id, children: item.children)
        }
        .onChange(of: matrixService.spaces.map(\.id)) {
            if let selectedSpaceId, !matrixService.spaces.contains(where: { $0.id == selectedSpaceId }) {
                self.selectedSpaceId = nil
            }
        }
        .onChange(of: matrixService.pendingDeepLink) { _, deepLink in
            guard let deepLink else { return }
            handleDeepLink(deepLink)
        }
        .onAppear {
            if let deepLink = matrixService.pendingDeepLink {
                handleDeepLink(deepLink)
            }
        }
    }

    // MARK: - Toolbar

    private var currentRoom: RoomSummary? {
        if selectedRoomId != nil, let room = matrixService.rooms.first(
            where: { $0.id == selectedRoomId
            }) {
            room
        } else {
            nil
        }
    }

    @ToolbarContentBuilder
    private var windowToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            roomDirectoryButton
        }

        if let previewingInvite {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") {
                    self.previewingInvite = nil
                }
                .help("Back to Room List")
            }
            ToolbarItem(placement: .secondaryAction) {
                inviteToolbarCapsule(for: previewingInvite)
            }
        } else if appActions.showRoomDirectory, let previewingDirectoryRoom {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") {
                    self.previewingDirectoryRoom = nil
                }
                .help("Back to Directory")
            }
            ToolbarItem(placement: .secondaryAction) {
                previewToolbarCapsule(for: previewingDirectoryRoom)
            }
        } else if selectedRoomId != nil && !appActions.showRoomDirectory {
            ToolbarItem(placement: .secondaryAction) {
                toolbarTitleCapsule
            }
        }
        
        if !appActions.showRoomDirectory && previewingInvite == nil {
            ToolbarItem(placement: .primaryAction) {
                showInspectorButton
            }
        }

    }

    private var toolbarTitleCapsule: some View {
        HStack(spacing: 0) {
            if let currentRoom {
                AvatarView(name: currentRoom.name,
                           mxcURL: currentRoom.avatarURL,
                           size: 28)
                .padding(.leading, 4)
                Text(currentRoom.name)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
        }
    }

    private func inviteToolbarCapsule(for invite: RoomSummary) -> some View {
        HStack(spacing: 0) {
            AvatarView(name: invite.name,
                       mxcURL: invite.avatarURL,
                       size: 28)
            .padding(.leading, 4)
            Text(invite.name)
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        }
    }

    private func previewToolbarCapsule(for room: DirectoryRoom) -> some View {
        HStack(spacing: 0) {
            AvatarView(name: room.name ?? room.roomId,
                       mxcURL: room.avatarURL,
                       size: 28)
            .padding(.leading, 4)
            Text(room.name ?? room.roomId)
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var roomDirectoryButton: some View {
        if appActions.showRoomDirectory {
            Button {
                appActions.showRoomDirectory = false
                previewingDirectoryRoom = nil
            } label: {
                Label("Close Directory", systemImage: "xmark")
            }
            .help("Close Directory")
        } else {
            Menu {
                Button("Create Room…") {
                    appActions.showCreateRoom = true
                }
                Button("Join Room…") {
                    appActions.showJoinRoom = true
                }
                Divider()
                Button("Room Directory") {
                    appActions.showRoomDirectory = true
                    previewingInvite = nil
                }
            } label: {
                Label("Room Directory", systemImage: "plus.bubble")
            }
            .help("Room Directory")
        }
    }

    @ViewBuilder
    private var showInspectorButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                showingInspector.toggle()
            }
        } label: {
            Label("Toggle Inspector", systemImage: "sidebar.trailing")
        }
        .help(showingInspector ? "Hide Inspector" : "Show Inspector")
        .disabled(selectedRoomId == nil && selectedSpaceId == nil)
    }

    // MARK: - Deep Link Handling

    /// Handles an incoming ``MatrixURI`` deep link by navigating to the referenced entity.
    private func handleDeepLink(_ uri: MatrixURI) {
        matrixService.pendingDeepLink = nil

        switch uri {
        case .room(let alias, _), .roomId(let alias, _):
            handleRoomTap(alias)
        case .user(let userId):
            let profile = UserProfile(userId: userId)
            showUserProfile(profile)
        case .event(let roomId, _, _):
            handleRoomTap(roomId)
        }
    }

    // MARK: - Room Link Handling

    /// Handles a tap on a `matrix.to` room link.
    ///
    /// If the user is already a member of the room, the sidebar selection
    /// navigates to it directly. Otherwise a room preview sheet is shown.
    private func handleRoomTap(_ identifier: String) {
        // Check if the user is already a member by room ID or canonical alias.
        if let joined = matrixService.rooms.first(where: {
            $0.id == identifier || $0.canonicalAlias == identifier
        }) {
            selectedRoomId = joined.id
            return
        }

        // Not a member -- show the room preview.
        let room: DirectoryRoom
        if identifier.hasPrefix("#") {
            room = DirectoryRoom(roomId: identifier, alias: identifier)
        } else {
            room = DirectoryRoom(roomId: identifier)
        }
        previewingLinkedRoom = room
    }

    /// Joins a room opened from a `matrix.to` link and navigates to it.
    private func joinLinkedRoom(_ room: DirectoryRoom) {
        guard !isJoiningLinkedRoom else { return }
        isJoiningLinkedRoom = true

        Task {
            do {
                let idOrAlias = room.alias ?? room.roomId
                try await matrixService.joinRoom(idOrAlias: idOrAlias)

                // Wait briefly for the room list to sync.
                try? await Task.sleep(for: .milliseconds(500))
                if let joined = matrixService.rooms.first(where: {
                    $0.id == room.roomId
                }) {
                    selectedRoomId = joined.id
                }
                previewingLinkedRoom = nil
            } catch {
                errorReporter.report(.roomJoinFailed(error.localizedDescription))
            }
            isJoiningLinkedRoom = false
        }
    }

    // MARK: - Invite Actions

    /// Accepts an invitation from the inline preview and navigates to the room.
    private func acceptInviteFromPreview(_ invite: RoomSummary) {
        Task {
            do {
                try await matrixService.acceptInvite(roomId: invite.id)
                try? await Task.sleep(for: .milliseconds(500))
                previewingInvite = nil
                selectedRoomId = invite.id
            } catch {
                errorReporter.report(.roomJoinFailed(error.localizedDescription))
            }
        }
    }

    /// Declines an invitation from the inline preview.
    private func declineInviteFromPreview(_ invite: RoomSummary) {
        Task {
            do {
                try await matrixService.declineInvite(roomId: invite.id)
            } catch {
                errorReporter.report(.roomLeaveFailed(error.localizedDescription))
            }
        }
    }

    // MARK: - Directory Room Join

    /// Joins a room selected from the directory grid and navigates to it.
    private func joinDirectoryRoom(_ room: DirectoryRoom) {
        Task {
            do {
                let idOrAlias = room.alias ?? room.roomId
                try await matrixService.joinRoom(idOrAlias: idOrAlias)

                try? await Task.sleep(for: .milliseconds(500))
                if let joined = matrixService.rooms.first(where: {
                    $0.id == room.roomId || $0.canonicalAlias == room.alias
                }) {
                    selectedRoomId = joined.id
                }
                previewingDirectoryRoom = nil
            } catch {
                errorReporter.report(.roomJoinFailed(error.localizedDescription))
            }
        }
    }

    // MARK: - Inspector Panel

    private func inspectorPanel(roomId: String) -> some View {
        TimelineInspectorView(
            roomId: roomId,
            context: .room,
            selectedProfile: $inspectorSelectedProfile,
            onMessageUser: { userId in
                Task {
                    do {
                        let dmRoomId = try await matrixService.createDirectMessage(userId: userId)
                        selectedRoomId = dmRoomId
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showingInspector = false
                        }
                    } catch {
                        errorReporter.report(.dmCreationFailed(error.localizedDescription))
                    }
                }
            },
            onScrollToMessage: scrollToMessage
        )
    }

    private func spaceInspectorPanel(spaceId: String) -> some View {
        TimelineInspectorView(
            roomId: spaceId,
            context: .space,
            initialTab: $inspectorInitialTab,
            onMessageUser: { userId in
                Task {
                    do {
                        let dmRoomId = try await matrixService.createDirectMessage(userId: userId)
                        selectedRoomId = dmRoomId
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showingInspector = false
                        }
                    } catch {
                        errorReporter.report(.dmCreationFailed(error.localizedDescription))
                    }
                }
            }
        )
    }
}

#Preview {
    MainView()
        .environment(\.matrixService, PreviewMatrixService())
        .environment(AppActions())
        .frame(width: 900, height: 600)
}
