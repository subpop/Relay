import RelayCore
import SwiftUI

struct MainView: View {
    @Environment(\.matrixService) private var matrixService
    @State private var selectedRoomId: String?
    @State private var searchText = ""
    @State private var isComposing = false
    @State private var showingInspector = false
    @State private var inspectorProfile: UserProfile?

    private func showUserProfile(_ profile: UserProfile) {
        withAnimation(.easeInOut(duration: 0.25)) {
            inspectorProfile = profile
            showingInspector = true
        }
    }

    var body: some View {
        NavigationSplitView {
            RoomListView(selectedRoomId: $selectedRoomId, searchText: $searchText)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
                .onChange(of: selectedRoomId) {
                    if selectedRoomId != nil {
                        isComposing = false
                        inspectorProfile = nil
                    }
                }
        } detail: {
            if isComposing {
                ComposeRoomView(selectedRoomId: $selectedRoomId, isComposing: $isComposing)
            } else if let selectedRoomId,
                      let summary = matrixService.rooms.first(where: { $0.id == selectedRoomId }),
                      let viewModel = matrixService.makeRoomDetailViewModel(roomId: selectedRoomId) {
                HStack(spacing: 0) {
                    RoomDetailView(
                        roomId: selectedRoomId,
                        roomName: summary.name,
                        roomAvatarURL: summary.avatarURL,
                        viewModel: viewModel,
                        onUserTap: { profile in showUserProfile(profile) }
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
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    selectedRoomId = nil
                    isComposing = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .padding(1)
                .help("New Conversation")
            }
            ToolbarItem(placement: .primaryAction) {
                if let selectedRoomId,
                   let summary = matrixService.rooms.first(where: { $0.id == selectedRoomId }) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            if showingInspector {
                                showingInspector = false
                                inspectorProfile = nil
                            } else {
                                showingInspector = true
                            }
                        }
                    } label: {
                        if showingInspector {
                            Image(systemName: "xmark")
                                .font(.title2)
                                .foregroundStyle(.primary)
                                .frame(width: 36, height: 36)
                                .contentShape(Circle())
                        } else {
                            AvatarView(name: summary.name, mxcURL: summary.avatarURL, size: 36)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(showingInspector ? "Hide Room Info" : "Show Room Info")
                }
            }
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

                UserDetailView(profile: profile)
            }
        } else {
            RoomInfoView(roomId: roomId, onMemberTap: { profile in showUserProfile(profile) })
        }
    }
}

#Preview {
    MainView()
        .environment(\.matrixService, PreviewMatrixService())
        .frame(width: 900, height: 600)
}
