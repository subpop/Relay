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

/// Search results shown in the detail pane in place of the selected timeline.
struct SearchResultsList: View {
    @Bindable var searchModel: SearchViewModel
    let roomName: String?
    let onMessageSelected: (_ roomId: String, _ eventId: String) -> Void
    let onSearchMore: () -> Void

    var body: some View {
        List {
            LocalSearchResultsSection(
                searchModel: searchModel,
                roomName: roomName,
                onMessageSelected: onMessageSelected)
            if !searchModel.visibleServerResults.isEmpty
                || searchModel.isSearchingServer
                || searchModel.hasCompletedServerSearch
                || searchModel.serverSearchError != nil
                || searchModel.canSearchMoreOnServer
            {
                ServerSearchResultsSection(
                    searchModel: searchModel,
                    roomName: roomName,
                    onMessageSelected: onMessageSelected,
                    onSearchMore: onSearchMore)
            }
        }
    }
}

private struct LocalSearchResultsSection: View {
    @Bindable var searchModel: SearchViewModel
    let roomName: String?
    let onMessageSelected: (_ roomId: String, _ eventId: String) -> Void

    private var header: String {
        let scopeLabel = searchModel.scope == .allRooms
            ? "All Rooms"
            : (roomName ?? "This Room")
        return "On This Mac — \(scopeLabel)"
    }

    var body: some View {
        Section {
            if searchModel.isSearchingLocal && searchModel.localResults.isEmpty {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching on This Mac…")
                        .foregroundStyle(.secondary)
                }
            } else if let error = searchModel.localSearchError {
                Text("Local search failed: \(error)")
                    .foregroundStyle(.secondary)
            } else if searchModel.localResults.isEmpty {
                Text("No matching messages found on this Mac.")
                    .foregroundStyle(.secondary)
            }

            ForEach(searchModel.localResults) { result in
                MessageSearchRow(result: result) {
                    onMessageSelected(result.roomId.value, result.eventId.value)
                }
            }
        } header: {
            Label(header, systemImage: "text.magnifyingglass")
        }
    }
}

private struct ServerSearchResultsSection: View {
    @Environment(RelayClient.self) private var client
    @Bindable var searchModel: SearchViewModel
    let roomName: String?
    let onMessageSelected: (_ roomId: String, _ eventId: String) -> Void
    let onSearchMore: () -> Void

    private var header: String {
        let scopeLabel = searchModel.scope == .allRooms
            ? "All Rooms"
            : (roomName ?? "This Room")
        return "On \(client.homeServerName() ?? "Server") — \(scopeLabel)"
    }

    var body: some View {
        Section {
            ForEach(searchModel.visibleServerResults) { result in
                MessageSearchRow(result: result) {
                    onMessageSelected(result.roomId.value, result.eventId.value)
                }
            }

            if searchModel.isSearchingServer {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching the server…")
                        .foregroundStyle(.secondary)
                }
            }

            if let error = searchModel.serverSearchError {
                Text("Server search failed: \(error)")
                    .foregroundStyle(.secondary)
            } else if searchModel.hasCompletedServerSearch
                && searchModel.serverResults.isEmpty
            {
                Text("No matching messages found on the server.")
                    .foregroundStyle(.secondary)
            }

            if searchModel.canSearchMoreOnServer {
                Button(action: onSearchMore) {
                    Label(searchModel.serverSearchButtonTitle, systemImage: "magnifyingglass")
                }
            }
        } header: {
            Label(header, systemImage: "globe")
        }
    }
}

private let previewResults: [MessageSearchResult] = [
    MessageSearchResult(
        eventId: EventId(unchecked: "$evt1"),
        roomId: RoomId(unchecked: "!room:matrix.org"),
        roomName: "Swift Developers",
        sender: UserId(unchecked: "@alice:matrix.org"),
        senderDisplayName: "Alice",
        body: "Has anyone tried the new concurrency features in Swift 6?",
        timestamp: Date(timeIntervalSinceNow: -3600),
        highlights: ["concurrency", "Swift"]),
    MessageSearchResult(
        eventId: EventId(unchecked: "$evt2"),
        roomId: RoomId(unchecked: "!room:matrix.org"),
        roomName: "Swift Developers",
        sender: UserId(unchecked: "@bob:matrix.org"),
        body: "The borrow checker can be tricky at first.",
        timestamp: Date(timeIntervalSinceNow: -86400),
        highlights: ["borrow checker"]),
]

private func previewSearchModel(
    scope: SearchViewModel.Scope = .room,
    includesServerResults: Bool = false
) -> SearchViewModel {
    let model = SearchViewModel()
    model.searchText = "swift"
    model.scope = scope
    model.localResults = previewResults
    if includesServerResults {
        model.serverResults = previewResults
        model.hasCompletedServerSearch = true
    }
    return model
}

#Preview("Room Results") {
    @Previewable @State var model = previewSearchModel()
    SearchResultsList(
        searchModel: model,
        roomName: "Swift Developers",
        onMessageSelected: { _, _ in },
        onSearchMore: {})
    .environment(PreviewFixtures.previewClient())
    .frame(width: 520, height: 500)
}

#Preview("All Rooms Results") {
    @Previewable @State var model = previewSearchModel(
        scope: .allRooms, includesServerResults: true)
    SearchResultsList(
        searchModel: model,
        roomName: nil,
        onMessageSelected: { _, _ in },
        onSearchMore: {})
    .environment(PreviewFixtures.previewClient())
    .frame(width: 520, height: 500)
}
