import RelayCore
import SwiftUI

struct MainView: View {
    @Environment(\.matrixService) private var matrixService
    @State private var selectedRoomId: String?
    @State private var searchText = ""
    @State private var isComposing = false

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
                RoomDetailView(roomId: selectedRoomId, roomName: summary.name, roomAvatarURL: summary.avatarURL, viewModel: viewModel)
                    .id(selectedRoomId)
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
        }
    }
}

#Preview {
    MainView()
        .environment(\.matrixService, PreviewMatrixService())
        .frame(width: 800, height: 500)
}
