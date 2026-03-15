import RelayCore
import SwiftUI

struct MainView: View {
    @Environment(\.matrixService) private var matrixService
    @State private var selectedRoomId: String?
    @State private var searchText = ""
    @State private var isComposing = false
    @State private var showingInspector = false

    var body: some View {
        NavigationSplitView {
            RoomListView(selectedRoomId: $selectedRoomId, searchText: $searchText)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
                .onChange(of: selectedRoomId) {
                    if selectedRoomId != nil {
                        isComposing = false
                    }
                }
        } detail: {
            if isComposing {
                ComposeRoomView(selectedRoomId: $selectedRoomId, isComposing: $isComposing)
            } else if let selectedRoomId,
                      let summary = matrixService.rooms.first(where: { $0.id == selectedRoomId }),
                      let viewModel = matrixService.makeRoomDetailViewModel(roomId: selectedRoomId) {
                HStack(spacing: 0) {
                    RoomDetailView(roomId: selectedRoomId, roomName: summary.name, roomAvatarURL: summary.avatarURL, viewModel: viewModel)
                        .id(selectedRoomId)
                        .frame(maxWidth: .infinity)

                    if showingInspector {
                        Divider()

                        RoomInfoView(roomId: selectedRoomId)
                            .id(selectedRoomId)
                            .frame(width: 260)
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
                            showingInspector.toggle()
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
}

#Preview {
    MainView()
        .environment(\.matrixService, PreviewMatrixService())
        .frame(width: 900, height: 600)
}
