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
/// ``BrowseRoomsView`` loads popular rooms from the logged-in homeserver
/// and any enabled extra directories (managed in Settings) on appear,
/// grouped by server, and provides a search field for finding rooms by
/// name or alias. Joining a room dismisses the sheet and selects it in
/// the sidebar.
struct BrowseRoomsView: View {
    @Environment(RelayClient.self) private var client
    @Environment(\.errorReporter) private var errorReporter
    @Environment(\.dismiss) private var dismiss

    /// Bound to the sidebar's selected room ID. Set on successful join.
    @Binding var selectedRoomId: String?

    @State private var viewModel = BrowseRoomsViewModel()
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var isJoining = false
    @State private var joiningRoomId: String?
    /// The selected directory server. Defaults to the homeserver on appear.
    @State private var scope: String?
    @State private var homeServer: String?
    @State private var remoteServers: [String] = []

    private var visiblePages: [BrowseRoomsViewModel.ServerPage] {
        guard let scope else { return [] }
        return viewModel.pages.filter { $0.serverName == scope }
    }

    var body: some View {
        NavigationStack {
            directoryContent
                .navigationTitle("Browse Rooms")
                .searchable(text: $query, placement: .toolbar, prompt: "Search rooms by name or alias")
                .onSubmit(of: .search) { performSearch() }
                .onChange(of: query) { _, newValue in
                    debounceSearch(newValue)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        serverScopePicker
                    }
                }
        }
        .frame(width: 600, height: 490)
        .task {
            viewModel.client = client
            homeServer = client.homeServerName()
            remoteServers = RoomDirectoryStore.load()
                .filter(\.isEnabled)
                .map(\.serverName)
            if scope == nil {
                scope = homeServer
            }
            performSearch()
        }
        .onChange(of: scope) { _, _ in
            performSearch()
        }
    }

    // MARK: - Server Scope

    private var serverScopePicker: some View {
        Picker("Server", selection: $scope) {
            ForEach(allServerNames, id: \.self) { server in
                Text(server).tag(server as String?)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help("Choose which directory to browse")
    }

    private var allServerNames: [String] {
        var names: [String] = []
        if let homeServer { names.append(homeServer) }
        names += remoteServers.filter { $0 != homeServer }
        return names
    }

    // MARK: - Directory Content

    @ViewBuilder
    private var directoryContent: some View {
        if viewModel.isEmpty {
            ContentUnavailableView(
                "No Rooms Found",
                systemImage: "magnifyingglass",
                description: Text(query.isEmpty
                    ? "No public rooms are available on \(scope ?? "this server")."
                    : "No rooms match \"\(query)\". Try a different search.")
            )
        } else {
            roomList
        }
    }

    // MARK: - Room List

    private var roomList: some View {
        List {
            ForEach(listItems) { item in
                switch item {
                case .room(let room):
                    BrowseRoomsRow(
                        room: room,
                        isJoining: joiningRoomId == room.roomId.value,
                        onJoin: { joinRoom(room) }
                    )
                case .loadMore(let server, let count):
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                        Spacer()
                    }
                    .id("more-\(server)-\(count)")
                    .onAppear {
                        Task { await viewModel.loadMore(serverName: server) }
                    }
                case .pageError(let server, let message):
                    HStack {
                        Text("Couldn't load \(server): \(message)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Retry") {
                            Task { await viewModel.retry(serverName: server) }
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
        .listStyle(.inset)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .overlay {
            if viewModel.isSearching, visiblePages.allSatisfy(\.rooms.isEmpty) {
                ProgressView("Searching directories…")
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
        }
    }

    /// Every visible page flattened into one list: each server's rooms in
    /// order, each followed by its own loader or error row, so per-server
    /// paging continues invisibly underneath the merged list.
    private var listItems: [BrowseListItem] {
        var items: [BrowseListItem] = []
        for page in visiblePages {
            if let errorMessage = page.errorMessage, page.rooms.isEmpty {
                items.append(.pageError(server: page.serverName, message: errorMessage))
            } else {
                items += page.rooms.map(BrowseListItem.room)
                if let errorMessage = page.errorMessage {
                    items.append(.pageError(server: page.serverName, message: errorMessage))
                } else if !page.isAtEnd {
                    items.append(.loadMore(server: page.serverName, count: page.rooms.count))
                }
            }
        }
        return items
    }

    /// One row of the flattened browse list.
    private enum BrowseListItem: Identifiable {
        case room(PublicRoomEntry)
        case loadMore(server: String, count: Int)
        case pageError(server: String, message: String)

        var id: String {
            switch self {
            case .room(let room):
                room.roomId.value
            case .loadMore(let server, let count):
                "more-\(server)-\(count)"
            case .pageError(let server, _):
                "error-\(server)"
            }
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
            let scoped = scopedServers()
            await viewModel.search(
                query: trimmed.isEmpty ? nil : trimmed,
                homeServer: scoped.home, remotes: scoped.remotes)
        }
    }

    /// Only the selected directory is queried: the homeserver without a
    /// `server` filter, or exactly one remote.
    private func scopedServers() -> (home: String?, remotes: [String]) {
        guard let scope else { return (homeServer, []) }
        if scope == homeServer {
            return (scope, [])
        }
        return (nil, [scope])
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

// MARK: - Browse Rooms Row

/// A single row in the directory list showing the room avatar, name,
/// topic with member count, and a join button.
private struct BrowseRoomsRow: View {
    let room: PublicRoomEntry
    var isJoining: Bool = false
    let onJoin: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            AvatarView(
                name: room.name ?? room.roomId.value,
                mxcURL: room.avatarUrl,
                size: 40
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(room.name ?? room.canonicalAlias ?? room.roomId.value)
                    .fontWeight(.medium)
                    .lineLimit(1)

                subtitle
            }

            Spacer()

            joinButton
        }
        .padding(.vertical, 10)
    }

    private var subtitle: some View {
        Group {
            if let topic = room.topic, !topic.isEmpty {
                Text(topic) + memberSuffix
            } else if let alias = room.canonicalAlias {
                Text(alias) + memberSuffix
            } else {
                memberSuffix
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// The member count tucked onto the subtitle line (`Topic · 35,305 members`).
    private var memberSuffix: Text {
        if room.numJoinedMembers > 0 {
            Text(" · \(room.numJoinedMembers, format: .number) members")
        } else {
            Text("")
        }
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

#Preview("Browse Rooms") {
    @Previewable @State var selected: String?

    BrowseRoomsView(selectedRoomId: $selected)
        .environment(PreviewFixtures.previewClient())
}

#Preview("Browse Rooms Row") {
    List {
        BrowseRoomsRow(
            room: PublicRoomEntry(
                roomId: RoomId(unchecked: "!matrix:matrix.org"),
                name: "Matrix Community",
                topic: "All things Matrix. There's a lot of rooms in this space.",
                canonicalAlias: "#community:matrix.org",
                numJoinedMembers: 35305),
            onJoin: {})
        BrowseRoomsRow(
            room: PublicRoomEntry(
                roomId: RoomId(unchecked: "!kde:kde.org"),
                canonicalAlias: "#user:kde.org",
                numJoinedMembers: 7906),
            onJoin: {})
        BrowseRoomsRow(
            room: PublicRoomEntry(
                roomId: RoomId(unchecked: "!quiet:example.org"),
                name: "Quiet Corner"),
            isJoining: true,
            onJoin: {})
    }
    .frame(width: 560, height: 260)
    .environment(PreviewFixtures.previewClient())
}
