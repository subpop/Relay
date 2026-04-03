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
struct MainView: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.errorReporter) private var errorReporter
    @State private var selectedRoomId: String?
    @State private var searchText = ""
    @State private var showingCreateRoom = false
    @State private var isBrowsingDirectory = false
    @State private var showingInspector = false
    @State private var inspectorProfile: UserProfile?
    @State private var showingPinnedMessages = false
    @State private var focusedMessageId: String?
    @State private var incomingVerificationItem: VerificationItem?
    @State private var previewingLinkedRoom: DirectoryRoom?
    @State private var isJoiningLinkedRoom = false

    private func scrollToMessage(_ eventId: String) {
        showingPinnedMessages = false
        focusedMessageId = eventId
    }

    private func showUserProfile(_ profile: UserProfile) {
        withAnimation(.easeInOut(duration: 0.25)) {
            inspectorProfile = profile
            showingInspector = true
        }
    }

    var body: some View {
        NavigationSplitView {
            RoomListView(selectedRoomId: $selectedRoomId, searchText: $searchText)
                .navigationSplitViewColumnWidth(min: 116, ideal: 260, max: 360)
                .onChange(of: selectedRoomId) {
                    if selectedRoomId != nil {
                        isBrowsingDirectory = false
                        inspectorProfile = nil
                        showingPinnedMessages = false
                    }
                }
        } detail: {
            if isBrowsingDirectory {
                RoomDirectoryView(selectedRoomId: $selectedRoomId, isBrowsing: $isBrowsingDirectory)
            } else if let selectedRoomId,
                      let summary = matrixService.rooms.first(where: { $0.id == selectedRoomId }),
                      let viewModel = matrixService.makeRoomDetailViewModel(roomId: selectedRoomId) {
                HStack(spacing: 0) {
                    RoomDetailView(
                        roomId: selectedRoomId,
                        roomName: summary.name,
                        roomAvatarURL: summary.avatarURL,
                        viewModel: viewModel,
                        focusedMessageId: $focusedMessageId,
                        onUserTap: { profile in showUserProfile(profile) },
                        onRoomTap: { identifier in handleRoomTap(identifier) }
                    )
                    .id(selectedRoomId)
                    .frame(maxWidth: .infinity)

                    if showingInspector {
                        Divider()

                        inspectorPanel(roomId: selectedRoomId)
                            .id(selectedRoomId)
                            .frame(width: 260)
                            .transition(.move(edge: .trailing))
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Conversation Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Pick a room from the sidebar to start chatting.")
                )
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .ignoresSafeArea()
                .frame(height: 52)
                .allowsHitTesting(false)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    showingCreateRoom = true
                } label: {
                    Image(systemName: "plus.bubble")
                }
                .padding(1)
                .help("Create Room")
            }
            ToolbarItem(placement: .navigation) {
                Button {
                    selectedRoomId = nil
                    isBrowsingDirectory = true
                } label: {
                    Image(systemName: "building.2")
                }
                .padding(1)
                .help("Room Directory")
            }
            ToolbarItem(placement: .primaryAction) {
                if let selectedRoomId,
                   let summary = matrixService.rooms.first(where: { $0.id == selectedRoomId }) {
                    GlassEffectContainer {
                        if !showingInspector {
                            Button {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    showingInspector = true
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    if summary.hasPinnedMessages {
                                        Button {
                                            showingPinnedMessages.toggle()
                                        } label: {
                                            Image(systemName: "pin.fill")
                                                .foregroundStyle(.secondary)
                                                .frame(width: 28, height: 28)
                                                .contentShape(Circle())
                                        }
                                        .buttonStyle(.plain)
                                        .help("Pinned Messages")
                                        .popover(isPresented: $showingPinnedMessages,
                                                 arrowEdge: .bottom) {
                                            PinnedMessagesView(
                                                roomId: selectedRoomId,
                                                onSelectMessage: scrollToMessage
                                            )
                                        }
                                    }


                                    VStack(alignment: .trailing, spacing: 1) {
                                        Text(summary.name)
                                            .fontWeight(.semibold)
                                            .lineLimit(1)

                                        if let topic = summary.topic, !topic.isEmpty {
                                            Text(topic)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }

                                    AvatarView(name: summary.name, mxcURL: summary.avatarURL, size: 36)
                                }
                                .padding(.leading, 10)
                                .padding(.trailing, 2)
                                .padding(.vertical, 4)
                                .frame(maxWidth: 200)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(in: .capsule)
                            .help("Show Room Info")
                        }

                        if showingInspector {
                            Button {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    showingInspector = false
                                    inspectorProfile = nil
                                }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.title2)
                                    .foregroundStyle(.primary)
                                    .frame(width: 36, height: 36)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .glassEffect(in: .circle)
                            .help("Hide Room Info")
                        }
                    }
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .onChange(of: matrixService.shouldPresentVerificationSheet) { _, shouldPresent in
            guard shouldPresent else { return }
            matrixService.shouldPresentVerificationSheet = false
            Task {
                if let vm = try? await matrixService.makeSessionVerificationViewModel() {
                    matrixService.pendingVerificationRequest = nil
                    incomingVerificationItem = VerificationItem(viewModel: vm)
                }
            }
        }
        .sheet(item: $incomingVerificationItem) { item in
            VerificationSheet(viewModel: item.viewModel)
        }
        .sheet(isPresented: $showingCreateRoom) {
            CreateRoomSheet(selectedRoomId: $selectedRoomId)
        }
        .sheet(item: $previewingLinkedRoom) { room in
            RoomPreviewView(
                room: room,
                onJoin: { joinLinkedRoom(room) },
                onClose: { previewingLinkedRoom = nil }
            )
            .frame(minWidth: 500, idealWidth: 600, minHeight: 400, idealHeight: 500)
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

    // MARK: - Inspector Panel

    @ViewBuilder
    private func inspectorPanel(roomId: String) -> some View {
        if let profile = inspectorProfile {
            VStack(spacing: 0) {
                HStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            inspectorProfile = nil
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Room Info")
                        }
                        .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                UserDetailView(profile: profile) {
                    Task {
                        do {
                            let roomId = try await matrixService.createDirectMessage(userId: profile.userId)
                            selectedRoomId = roomId
                            withAnimation(.easeInOut(duration: 0.25)) {
                                inspectorProfile = nil
                                showingInspector = false
                            }
                        } catch {
                            errorReporter.report(.dmCreationFailed(error.localizedDescription))
                        }
                    }
                }
            }
        } else {
            RoomInfoView(
                roomId: roomId,
                onMemberTap: { profile in showUserProfile(profile) },
                onPinnedMessageTap: scrollToMessage
            )
        }
    }
}

#Preview {
    MainView()
        .environment(\.matrixService, PreviewMatrixService())
        .frame(width: 900, height: 600)
}
