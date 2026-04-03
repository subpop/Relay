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

/// A browsable room directory that replaces the detail pane.
///
/// ``RoomDirectoryView`` loads popular rooms from the homeserver on appear and
/// provides a search field for finding rooms by name or alias. Each room row
/// offers a Join button and, for rooms with world-readable history, a Preview
/// button that opens a read-only timeline.
struct RoomDirectoryView: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.errorReporter) private var errorReporter
    @Binding var selectedRoomId: String?
    @Binding var isBrowsing: Bool

    @State private var viewModel: (any RoomDirectoryViewModelProtocol)?
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var isJoining = false
    @State private var joiningRoomId: String?
    @State private var previewingRoom: DirectoryRoom?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider()
            content
        }
        .onAppear {
            isSearchFocused = true
            if viewModel == nil {
                viewModel = matrixService.makeRoomDirectoryViewModel()
            }
            // Load popular rooms on first appear.
            searchTask = Task {
                await viewModel?.search(query: nil)
            }
        }
    }

    // MARK: - Search Header

    private var searchHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search rooms...", text: $query)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onSubmit { performSearch() }
                .onChange(of: query) { _, newValue in
                    debounceSearch(newValue)
                }

            if viewModel?.isSearching == true {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                isBrowsing = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close Directory")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let previewingRoom {
            RoomPreviewView(
                room: previewingRoom,
                onJoin: { joinRoom(idOrAlias: previewingRoom.alias ?? previewingRoom.roomId) },
                onClose: { self.previewingRoom = nil }
            )
        } else if let viewModel {
            directoryList(viewModel)
        } else {
            ContentUnavailableView(
                "Directory Unavailable",
                systemImage: "building.2",
                description: Text("Sign in to browse the room directory.")
            )
        }
    }

    private func directoryList(_ viewModel: any RoomDirectoryViewModelProtocol) -> some View {
        Group {
            if viewModel.rooms.isEmpty && !viewModel.isSearching {
                ContentUnavailableView(
                    "No Rooms Found",
                    systemImage: "magnifyingglass",
                    description: Text(query.isEmpty
                                      ? "No public rooms are available on this server."
                                      : "No rooms match \"\(query)\". Try a different search.")
                )
            } else if viewModel.rooms.isEmpty && viewModel.isSearching {
                ProgressView("Searching directory...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                roomList(viewModel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func roomList(_ viewModel: any RoomDirectoryViewModelProtocol) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    sectionHeader("Popular Rooms")
                } else {
                    sectionHeader("Search Results")
                }

                ForEach(viewModel.rooms) { room in
                    DirectoryRoomRow(
                        room: room,
                        isJoining: joiningRoomId == room.roomId,
                        onJoin: { joinRoom(idOrAlias: room.alias ?? room.roomId) },
                        onPreview: room.isWorldReadable ? { previewingRoom = room } : nil
                    )
                }

                // Pagination sentinel
                if !viewModel.isAtEnd {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                            .padding()
                        Spacer()
                    }
                    .onAppear {
                        Task { await viewModel.loadMore() }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
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

    private func joinRoom(idOrAlias: String) {
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
                    selectedRoomId = joined.id
                }
                isBrowsing = false
            } catch {
                errorReporter.report(.roomJoinFailed(error.localizedDescription))
            }
            isJoining = false
            joiningRoomId = nil
        }
    }
}

// MARK: - Directory Room Row

private struct DirectoryRoomRow: View {
    let room: DirectoryRoom
    var isJoining: Bool = false
    let onJoin: () -> Void
    var onPreview: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(name: room.name ?? room.roomId, mxcURL: room.avatarURL, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(room.name ?? room.alias ?? room.roomId)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if let topic = room.topic, !topic.isEmpty {
                    Text(topic)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    if let alias = room.alias {
                        Text(alias)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Label("\(room.memberCount)", systemImage: "person.2")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if let onPreview {
                Button("Preview") {
                    onPreview()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if isJoining {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Join") {
                    onJoin()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Previews

#Preview("Room Directory") {
    RoomDirectoryView(selectedRoomId: .constant(nil), isBrowsing: .constant(true))
        .environment(\.matrixService, PreviewMatrixService())
        .frame(width: 600, height: 500)
}
