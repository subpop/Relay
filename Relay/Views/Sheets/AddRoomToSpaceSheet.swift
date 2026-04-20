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

/// A sheet that presents the user's joined rooms for adding to a space.
///
/// The user can search and select a room, then confirm to add it as a child
/// of the current space via `m.space.child` state events.
struct AddRoomToSpaceSheet: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.errorReporter) private var errorReporter
    @Environment(\.dismiss) private var dismiss

    let spaceId: String
    let spaceName: String

    /// Room IDs already in this space, excluded from the picker.
    let existingChildIds: Set<String>

    @State private var searchText = ""
    @State private var isAdding = false

    /// The rooms available for adding — joined rooms not already in the space.
    private var availableRooms: [RoomSummary] {
        matrixService.rooms.filter { room in
            room.membership == .joined
                && !room.isSpace
                && !existingChildIds.contains(room.id)
        }
    }

    /// Filtered rooms based on search text.
    private var filteredRooms: [RoomSummary] {
        guard !searchText.isEmpty else { return availableRooms }
        return availableRooms.filter { room in
            room.name.localizedStandardContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if availableRooms.isEmpty {
                ContentUnavailableView(
                    "No Rooms Available",
                    systemImage: "tray",
                    description: Text("All your rooms are already in this space.")
                )
                .frame(maxHeight: .infinity)
            } else {
                roomList
            }
        }
        .frame(width: 400, height: 480)
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Add Room to \(spaceName)")
                    .font(.headline)

                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            TextField("Search rooms\u{2026}", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
        }
        .padding()
    }

    private var roomList: some View {
        List(filteredRooms) { room in
            RoomPickerRow(
                room: room,
                isAdding: isAdding,
                onAdd: { addRoom(room) }
            )
        }
        .listStyle(.plain)
    }

    private func addRoom(_ room: RoomSummary) {
        guard !isAdding else { return }
        isAdding = true
        Task {
            do {
                try await matrixService.addChildToSpace(childId: room.id, spaceId: spaceId)
                dismiss()
            } catch {
                errorReporter.report(.roomJoinFailed(error.localizedDescription))
                isAdding = false
            }
        }
    }
}

// MARK: - Room Picker Row

/// A single row in the room picker list with an Add button.
private struct RoomPickerRow: View {
    let room: RoomSummary
    let isAdding: Bool
    var onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: room.name, mxcURL: room.avatarURL, size: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(room.name)
                    .lineLimit(1)

                if let topic = room.topic, !topic.isEmpty {
                    Text(topic)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button("Add", systemImage: "plus.circle", action: onAdd)
                .buttonStyle(.bordered)
                .tint(.accentColor)
                .controlSize(.small)
                .disabled(isAdding)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Previews

#Preview {
    AddRoomToSpaceSheet(
        spaceId: "!space-work:matrix.org",
        spaceName: "Work",
        existingChildIds: ["!design:matrix.org"]
    )
    .environment(\.matrixService, PreviewMatrixService())
}
