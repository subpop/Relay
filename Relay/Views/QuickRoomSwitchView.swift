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

import SwiftUI

/// A quick-switch overlay for rapidly navigating between rooms.
///
/// Triggered by ⌘K, this view presents a floating panel with a search field
/// and a filtered list of joined rooms. The user can type to filter, use arrow
/// keys to navigate, and press Return to switch to the selected room.
struct QuickRoomSwitchView: View {
    var rooms: [RoomRowData] = []
    @Binding var selectedRoomId: String?
    @Binding var isPresented: Bool

    @State private var filterText = ""
    @State private var highlightedIndex = 0
    @FocusState private var isTextFieldFocused: Bool

    private var filteredRooms: [RoomRowData] {
        let rooms = rooms.filter { !$0.isSpace }
        if filterText.isEmpty {
            return rooms
        }
        return rooms.filter { $0.name.localizedStandardContains(filterText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterField
            Divider()
            roomList
        }
        .frame(width: 500)
        .frame(maxHeight: 400)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        .onAppear {
            highlightedIndex = 0
            isTextFieldFocused = true
        }
        .onChange(of: filterText) {
            highlightedIndex = 0
        }
    }

    // MARK: - Filter Field

    private var filterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Quick Switch\u{2026}", text: $filterText)
                .textFieldStyle(.plain)
                .font(.title2)
                .focused($isTextFieldFocused)
                .onSubmit { confirmSelection() }
                .onKeyPress(.upArrow) { moveHighlight(by: -1); return .handled }
                .onKeyPress(.downArrow) { moveHighlight(by: 1); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
        }
        .padding()
    }

    // MARK: - Room List

    private var roomList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredRooms.enumerated(), id: \.element.id) { index, room in
                        QuickSwitchRow(room: room, isHighlighted: index == highlightedIndex)
                            .id(room.id)
                            .contentShape(.rect)
                            .onTapGesture { selectRoom(room) }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .onChange(of: highlightedIndex) { _, newIndex in
                guard newIndex >= 0, newIndex < filteredRooms.count else { return }
                withAnimation {
                    proxy.scrollTo(filteredRooms[newIndex].id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Actions

    private func moveHighlight(by offset: Int) {
        let count = filteredRooms.count
        guard count > 0 else { return }
        highlightedIndex = max(0, min(count - 1, highlightedIndex + offset))
    }

    private func confirmSelection() {
        guard !filteredRooms.isEmpty,
              highlightedIndex >= 0,
              highlightedIndex < filteredRooms.count else { return }
        selectRoom(filteredRooms[highlightedIndex])
    }

    private func selectRoom(_ room: RoomRowData) {
        selectedRoomId = room.id
        dismiss()
    }

    private func dismiss() {
        isPresented = false
    }
}

// MARK: - Quick Switch Row

/// A single row in the quick-switch overlay, showing the room avatar, name,
/// and an optional canonical alias as the subtitle.
private struct QuickSwitchRow: View {
    let room: RoomRowData
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: room.name, mxcURL: room.avatarURL, size: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(room.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if let alias = room.canonicalAlias {
                    Text(alias)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isHighlighted {
                Image(systemName: "return")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(isHighlighted ? Color.accentColor : .clear, in: .rect(cornerRadius: 8))
        .foregroundStyle(isHighlighted ? .white : .primary)
        .padding(.horizontal, 4)
    }
}

// MARK: - Previews

#Preview("Quick Room Switch") {
    QuickRoomSwitchView(
        rooms: PreviewFixtures.rooms,
        selectedRoomId: .constant(nil),
        isPresented: .constant(true)
    )
    .frame(width: 600, height: 500)
}
