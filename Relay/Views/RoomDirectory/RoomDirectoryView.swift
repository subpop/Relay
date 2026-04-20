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

/// A browsable room directory rendered as a grouped list in the detail pane.
///
/// ``RoomDirectoryView`` loads popular rooms from the homeserver on appear and
/// provides a search field for finding rooms by name or alias. Rooms are displayed
/// as rows with avatars (circles for rooms, rounded rectangles for spaces).
/// Clicking a row sets `previewingRoom` so that ``MainView`` can render the
/// preview with the standard toolbar identity.
struct RoomDirectoryView: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.errorReporter) private var errorReporter

    /// The room currently being previewed. Owned by ``MainView`` so it can
    /// render the toolbar capsule and preview content at the top level.
    @Binding var previewingRoom: DirectoryRoom?

    /// Called after successfully joining a room, with the joined room's ID.
    var onRoomJoined: ((String) -> Void)?

    @State private var viewModel: (any RoomDirectoryViewModelProtocol)?
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var isJoining = false
    @State private var joiningRoomId: String?

    var body: some View {
        directoryContent
            .navigationTitle("Room Directory")
            .searchable(text: $query, prompt: "Search rooms by name or alias")
            .onSubmit(of: .search) { performSearch() }
            .onChange(of: query) { _, newValue in
                debounceSearch(newValue)
            }
            .onAppear {
                if viewModel == nil {
                    viewModel = matrixService.makeRoomDirectoryViewModel()
                }
                searchTask = Task {
                    await viewModel?.search(query: nil)
                }
            }
    }

    // MARK: - Directory Content

    @ViewBuilder
    private var directoryContent: some View {
        if let viewModel {
            if viewModel.rooms.isEmpty && viewModel.isSearching {
                ProgressView("Searching directory...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.rooms.isEmpty && !viewModel.isSearching {
                ContentUnavailableView(
                    "No Rooms Found",
                    systemImage: "magnifyingglass",
                    description: Text(query.isEmpty
                                      ? "No public rooms are available on this server."
                                      : "No rooms match \"\(query)\". Try a different search.")
                )
            } else {
                roomList(viewModel)
            }
        } else {
            ContentUnavailableView(
                "Directory Unavailable",
                systemImage: "building.2",
                description: Text("Sign in to browse the room directory.")
            )
        }
    }

    // MARK: - Room List

    private func roomList(_ viewModel: any RoomDirectoryViewModelProtocol) -> some View {
        Form {
            Section {
                ForEach(viewModel.rooms) { room in
                    DirectoryRoomRow(
                        room: room,
                        isJoining: joiningRoomId == room.roomId,
                        onJoin: { joinRoom(idOrAlias: room.alias ?? room.roomId) },
                        onNavigate: { previewingRoom = room }
                    )
                }

                // Pagination sentinel
                if !viewModel.isAtEnd {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                        Spacer()
                    }
                    .onAppear {
                        Task { await viewModel.loadMore() }
                    }
                }
            } header: {
                Text(query.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "Popular Rooms"
                     : "Search Results")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Search Logic

    private func debounceSearch(_ text: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            performSearch()
        }
    }

    private func performSearch() {
        searchTask?.cancel()
        searchTask = Task {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            await viewModel?.search(query: trimmed.isEmpty ? nil : trimmed)
        }
    }

    // MARK: - Join

    func joinRoom(idOrAlias: String) {
        guard !isJoining else { return }
        isJoining = true
        joiningRoomId = idOrAlias

        Task {
            do {
                try await matrixService.joinRoom(idOrAlias: idOrAlias)

                // Wait briefly for room list to sync, then find the room.
                try? await Task.sleep(for: .milliseconds(500))
                let rooms = matrixService.rooms
                if let joined = rooms.first(where: {
                    $0.id == idOrAlias || ($0.name.localizedCaseInsensitiveContains(query) && !query.isEmpty)
                }) {
                    onRoomJoined?(joined.id)
                }
            } catch {
                errorReporter.report(.roomJoinFailed(error.localizedDescription))
            }
            isJoining = false
            joiningRoomId = nil
        }
    }
}

// MARK: - Directory Room Row

/// A single row in the directory list, styled to match ``SpaceChildRow``.
///
/// Spaces use a rounded-rectangle avatar (``SpaceRailIcon``), while regular
/// rooms use a circular ``AvatarView``.
private struct DirectoryRoomRow: View {
    let room: DirectoryRoom
    var isJoining: Bool = false
    let onJoin: () -> Void
    let onNavigate: () -> Void

    var body: some View {
        Button(action: onNavigate) {
            HStack(spacing: 12) {
                avatar

                VStack(alignment: .leading, spacing: 2) {
                    Text(room.name ?? room.alias ?? room.roomId)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    subtitle
                }

                Spacer()

                trailingContent
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var avatar: some View {
        if room.isSpace {
            SpaceRailIcon(
                name: room.name ?? room.roomId,
                mxcURL: room.avatarURL
            )
        } else {
            AvatarView(
                name: room.name ?? room.roomId,
                mxcURL: room.avatarURL,
                size: 36
            )
        }
    }

    private var subtitle: some View {
        Group {
            if let topic = room.topic, !topic.isEmpty {
                Text(topic)
            } else if let alias = room.alias {
                Text(alias)
            } else if room.memberCount > 0 {
                Text("\(room.memberCount) members")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private var trailingContent: some View {
        if isJoining {
            ProgressView()
                .controlSize(.small)
        } else {
            Button("Join", systemImage: "plus", action: onJoin)
                .buttonStyle(.bordered)
                .tint(.accentColor)
                .controlSize(.small)
        }
    }
}

// MARK: - Previews

#Preview("Room Directory") {
    NavigationSplitView {
        List {
            Text("Design Team")
            Text("Alice")
        }
        .navigationSplitViewColumnWidth(260)
    } detail: {
        RoomDirectoryView(previewingRoom: .constant(nil))
    }
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 900, height: 600)
}
