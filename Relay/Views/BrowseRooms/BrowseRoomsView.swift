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
    /// The selected server scope, or nil for all servers.
    @State private var scope: String?
    @State private var homeServer: String?
    @State private var remoteServers: [String] = []
    /// Servers whose list group is collapsed.
    @State private var collapsedServers: Set<String> = []

    private var visiblePages: [BrowseRoomsViewModel.ServerPage] {
        guard let scope else { return viewModel.pages }
        return viewModel.pages.filter { $0.serverName == scope }
    }

    var body: some View {
        VStack {
            HStack(alignment: .top) {
                Text("Browse Rooms")
                    .font(.headline)
                Spacer()
                serverScopeBar
            }
            .padding([.leading, .trailing, .top], 16)

            Spacer()
            directoryContent
            Spacer()
        }
        .searchable(text: $query, prompt: "Search rooms by name or alias")
        .onSubmit(of: .search) { performSearch() }
        .onChange(of: query) { _, newValue in
            debounceSearch(newValue)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 640, height: 560)
        .task {
            viewModel.client = client
            homeServer = client.homeServerName()
            remoteServers = RoomDirectoryStore.load()
                .filter(\.isEnabled)
                .map(\.serverName)
            await viewModel.search(query: nil, homeServer: homeServer, remotes: remoteServers)
        }
    }

    // MARK: - Server Scope

    private var serverScopeBar: some View {
        Picker("", selection: $scope) {
            Text("All Servers").tag(nil as String?)
            ForEach(allServerNames, id: \.self) { server in
                Text(server).tag(server as String?)
            }
        }
        .pickerStyle(.menu)
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
                    ? "No public rooms are available on the selected directories."
                    : "No rooms match \"\(query)\". Try a different search.")
            )
        } else {
            roomList
        }
    }

    // MARK: - Room List

    private var roomList: some View {
        List {
            ForEach(visiblePages, id: \.serverName) { page in
                Section(isExpanded: isExpandedBinding(for: page.serverName)) {
                    if let errorMessage = page.errorMessage, page.rooms.isEmpty {
                        ContentUnavailableView(
                            "Couldn't load \(page.serverName)",
                            systemImage: "exclamationmark.triangle",
                            description: Text(errorMessage)
                        )
                        Button("Retry") {
                            Task { await viewModel.retry(serverName: page.serverName) }
                        }
                        .buttonStyle(.link)
                    } else {
                        ForEach(page.rooms, id: \.roomId) { room in
                            BrowseRoomsRow(
                                room: room,
                                isJoining: joiningRoomId == room.roomId.value,
                                onJoin: { joinRoom(room) }
                            )
                        }

                        if let errorMessage = page.errorMessage, !page.rooms.isEmpty {
                            HStack {
                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Retry") {
                                    Task { await viewModel.retry(serverName: page.serverName) }
                                }
                                .buttonStyle(.link)
                            }
                        } else if !page.isAtEnd {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .controlSize(.small)
                                Spacer()
                            }
                            .id("\(page.serverName)-\(page.rooms.count)")
                            .onAppear {
                                Task { await viewModel.loadMore(serverName: page.serverName) }
                            }
                        }
                    }
                } header: {
                    Text(page.serverName)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if viewModel.isSearching, visiblePages.allSatisfy(\.rooms.isEmpty) {
                ProgressView("Searching directories…")
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
        }
    }

    /// Collapsed-state binding for a server group. A single-server scope
    /// is always expanded; with all servers each group collapses independently.
    private func isExpandedBinding(for server: String) -> Binding<Bool> {
        guard scope == nil else { return .constant(true) }
        return Binding(
            get: { !collapsedServers.contains(server) },
            set: { isExpanded in
                if isExpanded {
                    collapsedServers.remove(server)
                } else {
                    collapsedServers.insert(server)
                }
            })
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
            await viewModel.search(
                query: trimmed.isEmpty ? nil : trimmed,
                homeServer: homeServer, remotes: remoteServers)
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

// MARK: - Browse Rooms Row

/// A single row in the directory list showing the room avatar, name, topic,
/// member count, and a join button.
private struct BrowseRoomsRow: View {
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

#Preview("Browse Rooms") {
    @Previewable @State var selected: String?

    BrowseRoomsView(selectedRoomId: $selected)
        .environment(PreviewFixtures.previewClient())
}
