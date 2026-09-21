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

/// A browsable room directory presented as a sheet.
///
/// ``RoomDirectoryView`` loads popular rooms from the homeserver on appear and
/// provides a search field for finding rooms by name or alias. Joining a room
/// dismisses the sheet and selects it in the sidebar.
struct RoomDirectoryView: View {
    @Environment(RelayClient.self) private var client
    @Environment(\.errorReporter) private var errorReporter
    @Environment(\.dismiss) private var dismiss

    /// Bound to the sidebar's selected room ID. Set on successful join.
    @Binding var selectedRoomId: String?

    @State private var viewModel = RoomDirectoryViewModel()
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var isJoining = false
    @State private var joiningRoomId: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            directoryContent
        }
        .frame(width: 540, height: 500)
        .task {
            viewModel.client = client
            viewModel.errorReporter = errorReporter
            await viewModel.search(query: nil)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Spacer()

            Text("Room Directory")
                .fontWeight(.semibold)

            Spacer()

            // Invisible spacer button to balance the header layout.
            Button("Cancel") {}
                .hidden()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Directory Content

    @ViewBuilder
    private var directoryContent: some View {
        if viewModel.rooms.isEmpty && viewModel.isSearching {
            ProgressView("Searching directory…")
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
            roomList
        }
    }

    // MARK: - Room List

    private var roomList: some View {
        Form {
            Section {
                ForEach(viewModel.rooms, id: \.roomId) { room in
                    DirectoryRoomRow(
                        room: room,
                        isJoining: joiningRoomId == room.roomId.value,
                        onJoin: { joinRoom(room) }
                    )
                }

                if !viewModel.rooms.isEmpty, !viewModel.isAtEnd, !viewModel.isSearching {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                        Spacer()
                    }
                    .id(viewModel.rooms.count)
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
        .searchable(text: $query, prompt: "Search rooms by name or alias")
        .onSubmit(of: .search) { performSearch() }
        .onChange(of: query) { _, newValue in
            debounceSearch(newValue)
        }
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
            await viewModel.search(query: trimmed.isEmpty ? nil : trimmed)
        }
    }

    // MARK: - Join

    private func joinRoom(_ room: PublicRoomEntry) {
        guard !isJoining else { return }
        isJoining = true
        joiningRoomId = room.roomId.value

        Task {
            do {
                let idOrAlias = room.canonicalAlias ?? room.roomId.value
                try await client.joinRoom(idOrAlias: idOrAlias)

                try? await Task.sleep(for: .milliseconds(500))
                if let joined = client.rooms.first(where: {
                    $0.roomId.value == room.roomId.value
                        || $0.canonicalAlias == room.canonicalAlias
                }) {
                    selectedRoomId = joined.roomId.value
                }
                dismiss()
            } catch {
                errorReporter.report(.roomJoinFailed(error.localizedDescription))
            }
            isJoining = false
            joiningRoomId = nil
        }
    }
}

// MARK: - Directory Room Row

/// A single row in the directory list showing the room avatar, name, topic,
/// member count, and a join button.
private struct DirectoryRoomRow: View {
    let room: PublicRoomEntry
    var isJoining: Bool = false
    let onJoin: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(
                name: room.name ?? room.roomId.value,
                mxcURL: room.avatarUrl,
                size: 36
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(room.name ?? room.canonicalAlias ?? room.roomId.value)
                    .fontWeight(.medium)
                    .lineLimit(1)

                subtitle
            }

            Spacer()

            if room.numJoinedMembers > 0 {
                Label("\(room.numJoinedMembers)", systemImage: "person.2")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            joinButton
        }
        .padding(.vertical, 4)
    }

    private var subtitle: some View {
        Group {
            if let topic = room.topic, !topic.isEmpty {
                Text(topic)
            } else if let alias = room.canonicalAlias {
                Text(alias)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private var joinButton: some View {
        if isJoining {
            ProgressView()
                .controlSize(.small)
        } else {
            Button("Join", action: onJoin)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

// MARK: - Previews

#Preview("Room Directory") {
    @Previewable @State var selected: String?

    RoomDirectoryView(selectedRoomId: $selected)
        .environment(RelayClient())
}
