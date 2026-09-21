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

/// Inline search results displayed in the sidebar, replacing the room list.
///
/// Shows two sections: matching rooms (client-side filtered) and matching
/// messages (server-side searched). Each section previews a few results
/// with a "Show More" button to expand.
struct SearchResultsList: View {
    let rooms: [RoomRowData]
    @Bindable var searchModel: SearchViewModel
    @Binding var selectedRoomId: String?
    let onMessageSelected: (_ roomId: String, _ eventId: String) -> Void

    private let previewLimit = 3

    @State private var showAllRooms = false
    @State private var showAllMessages = false

    var body: some View {
        List(selection: $selectedRoomId) {
            roomsSection
            messagesSection
        }
    }

    // MARK: - Rooms Section

    @ViewBuilder
    private var roomsSection: some View {
        if !rooms.isEmpty {
            Section {
                let visible = showAllRooms ? rooms : Array(rooms.prefix(previewLimit))
                ForEach(visible) { room in
                    RoomListRow(room: room)
                        .tag(room.id)
                }
                if rooms.count > previewLimit {
                    Button {
                        withAnimation { showAllRooms.toggle() }
                    } label: {
                        Text(showAllRooms
                             ? "Show Less"
                             : "Show \(rooms.count - previewLimit) More")
                            .font(.callout)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Label("Rooms", systemImage: "bubble.left.and.bubble.right")
            }
        }
    }

    // MARK: - Messages Section

    @ViewBuilder
    private var messagesSection: some View {
        Section {
            if searchModel.isSearchingMessages {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching\u{2026}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            if !searchModel.messageResults.isEmpty {
                let visible = showAllMessages
                    ? searchModel.messageResults
                    : Array(searchModel.messageResults.prefix(previewLimit))
                ForEach(visible) { result in
                    MessageSearchRow(result: result) {
                        onMessageSelected(result.roomId.value, result.eventId.value)
                    }
                }
                if searchModel.messageResults.count > previewLimit {
                    Button {
                        withAnimation { showAllMessages.toggle() }
                    } label: {
                        Text(showAllMessages
                             ? "Show Less"
                             : "Show \(searchModel.messageResults.count - previewLimit) More")
                            .font(.callout)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                }
            } else if !searchModel.isSearchingMessages {
                Text("No messages found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label("Messages", systemImage: "text.magnifyingglass")
        } footer: {
            if !searchModel.messageResults.isEmpty || searchModel.isSearchingMessages {
                Text("Encrypted rooms are not included.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Previews

private func previewSearchModel(
    text: String, results: [MessageSearchResult], searching: Bool = false
) -> SearchViewModel {
    let model = SearchViewModel()
    model.searchText = text
    model.messageResults = results
    model.isSearchingMessages = searching
    return model
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
        highlights: ["concurrency", "Swift"]
    ),
    MessageSearchResult(
        eventId: EventId(unchecked: "$evt2"),
        roomId: RoomId(unchecked: "!room:matrix.org"),
        roomName: "Swift Developers",
        sender: UserId(unchecked: "@bob:matrix.org"),
        body: "The borrow checker can be tricky at first.",
        timestamp: Date(timeIntervalSinceNow: -86400),
        highlights: ["borrow checker"]
    ),
]

#Preview("With Results") {
    @Previewable @State var selected: String?

    SearchResultsList(
        rooms: Array(PreviewFixtures.rooms.prefix(5)),
        searchModel: previewSearchModel(text: "test", results: previewResults),
        selectedRoomId: $selected,
        onMessageSelected: { _, _ in }
    )
    .environment(RelayClient())
    .frame(width: 300, height: 500)
}

#Preview("Searching") {
    @Previewable @State var selected: String?

    SearchResultsList(
        rooms: Array(PreviewFixtures.rooms.prefix(2)),
        searchModel: previewSearchModel(
            text: "test", results: [], searching: true),
        selectedRoomId: $selected,
        onMessageSelected: { _, _ in }
    )
    .environment(RelayClient())
    .frame(width: 300, height: 500)
}

#Preview("No Results") {
    @Previewable @State var selected: String?

    SearchResultsList(
        rooms: [],
        searchModel: previewSearchModel(text: "zzzzz", results: []),
        selectedRoomId: $selected,
        onMessageSelected: { _, _ in }
    )
    .environment(RelayClient())
    .frame(width: 300, height: 500)
}
