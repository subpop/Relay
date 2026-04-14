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

/// A browsable room directory rendered as a grid of cards in the detail pane.
///
/// ``RoomDirectoryView`` loads popular rooms from the homeserver on appear and
/// provides a search field for finding rooms by name or alias. Rooms are displayed
/// as cards in an adaptive grid. Clicking a card sets `previewingRoom` so that
/// ``MainView`` can render the preview with the standard toolbar identity.
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

    private let gridColumns = [GridItem(.adaptive(minimum: 220, maximum: 300))]

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
                roomGrid(viewModel)
            }
        } else {
            ContentUnavailableView(
                "Directory Unavailable",
                systemImage: "building.2",
                description: Text("Sign in to browse the room directory.")
            )
        }
    }

    // MARK: - Room Grid

    private func roomGrid(_ viewModel: any RoomDirectoryViewModelProtocol) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(query.trimmingCharacters(in: .whitespaces).isEmpty
                              ? "Popular Rooms"
                              : "Search Results")

                LazyVGrid(columns: gridColumns) {
                    ForEach(viewModel.rooms) { room in
                        DirectoryRoomCard(
                            room: room,
                            isJoining: joiningRoomId == room.roomId,
                            onJoin: { joinRoom(idOrAlias: room.alias ?? room.roomId) },
                            onNavigate: { previewingRoom = room }
                        )
                    }
                }
                .padding(.horizontal)

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
            .padding(.vertical)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3)
            .bold()
            .padding(.horizontal)
            .padding(.bottom)
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

// MARK: - Directory Room Card

/// A card displaying a room from the directory with its avatar, metadata,
/// and action buttons arranged in a compact grid-friendly layout.
private struct DirectoryRoomCard: View {
    let room: DirectoryRoom
    var isJoining: Bool = false
    let onJoin: () -> Void
    let onNavigate: () -> Void

    var body: some View {
        Button(action: onNavigate) {
            VStack(spacing: 0) {
                // Avatar + name
                VStack(spacing: 8) {
                    AvatarView(
                        name: room.name ?? room.roomId,
                        mxcURL: room.avatarURL,
                        size: 48
                    )

                    Text(room.name ?? room.alias ?? room.roomId)
                        .font(.headline)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .padding(.top)
                .padding(.horizontal)

                // Alias + member count
                VStack(spacing: 4) {
                    if let alias = room.alias {
                        Text(alias)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Label("\(room.memberCount) members", systemImage: "person.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)

                // Topic
                if let topic = room.topic, !topic.isEmpty {
                    Text(topic)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                        .padding(.horizontal)
                }

                Spacer(minLength: 12)

                // Action buttons
                HStack {
                    if room.isWorldReadable {
                        Button("Preview", systemImage: "eye") {
                            onNavigate()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Spacer()

                    if isJoining {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Join", systemImage: "plus") {
                            onJoin()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: 180)
        .background(.fill.quaternary, in: .rect(cornerRadius: 12))
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
