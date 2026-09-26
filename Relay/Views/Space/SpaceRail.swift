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

/// A vertical icon rail on the leading edge of the sidebar for switching between spaces.
///
/// Each top-level space is represented by a rounded-rectangle avatar. When a space is
/// selected, any joined sub-spaces expand out below it with smaller icons, pushing
/// other spaces down. Clicking Home or a different space collapses the previous group.
struct SpaceRail: View {
    /// The fixed width of the space rail column.
    static let width: CGFloat = 52

    /// All joined spaces plus the rooms they contain (for unread badges).
    var spaces: [RoomRowData] = []
    /// All joined rooms (for space unread badges).
    var rooms: [RoomRowData] = []
    @Binding var selectedSpaceId: String?
    var onSpaceTapped: (() -> Void)?
    var onCreateSpace: (() -> Void)?
    var onLeaveSpace: ((RoomRowData) -> Void)?

    /// Top-level spaces (those not nested inside another joined space).
    private var topLevelSpaces: [RoomRowData] {
        spaces.filter { $0.parentSpaceIds.isEmpty }
    }

    /// All joined sub-spaces that belong to the given top-level space, at any depth.
    ///
    /// This flattens the hierarchy so that a chain like Work → Engineering → Backend
    /// shows Engineering and Backend as peers under Work in the rail.
    private func subSpaces(of parentId: String) -> [RoomRowData] {
        spaces.filter {
            !$0.parentSpaceIds.isEmpty && $0.parentSpaceIds.contains(parentId)
        }
    }

    /// Whether a top-level space should show its sub-spaces (the space itself or any
    /// of its sub-spaces at any depth is currently selected).
    private func isExpanded(_ spaceId: String) -> Bool {
        guard let selectedSpaceId else { return false }
        if selectedSpaceId == spaceId { return true }
        // Check if the selected space is a sub-space of this top-level space
        return subSpaces(of: spaceId).contains(where: { $0.id == selectedSpaceId })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                homeButton

                if !spaces.isEmpty {
                    SpaceRailDivider()
                }

                ForEach(topLevelSpaces) { space in
                    spaceButton(space)

                    // Expanded sub-spaces
                    if isExpanded(space.id) {
                        let children = subSpaces(of: space.id)
                        if !children.isEmpty {
                            ForEach(children) { child in
                                subSpaceButton(child)
                                    .transition(.asymmetric(
                                        insertion: .scale(scale: 0.5).combined(with: .opacity),
                                        removal: .scale(scale: 0.5).combined(with: .opacity)
                                    ))
                            }
                        }
                    }
                }

                SpaceRailDivider()

                Button {
                    onCreateSpace?()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .background(.fill.tertiary, in: .rect(cornerRadius: 10))
                        .contentShape(.rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Create Space")
            }
            .padding(.vertical, 8)
            .animation(.easeInOut(duration: 0.25), value: selectedSpaceId)
        }
        .scrollIndicators(.hidden)
        .frame(width: Self.width)
        .accessibilityLabel("Spaces")
    }

    // MARK: - Buttons

    private var homeButton: some View {
        SpaceRailButton(
            isSelected: selectedSpaceId == nil,
            hasUnread: false
        ) {
            onSpaceTapped?()
            selectedSpaceId = nil
        } label: {
            Image(systemName: "house.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(selectedSpaceId == nil ? .white : .secondary)
                .frame(width: 36, height: 36)
                .background(
                    selectedSpaceId == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary),
                    in: .rect(cornerRadius: 10)
                )
                .animation(.easeInOut(duration: 0.15), value: selectedSpaceId == nil)
        }
    }

    private func spaceButton(_ space: RoomRowData) -> some View {
        SpaceRailButton(
            isSelected: selectedSpaceId == space.id,
            hasUnread: spaceHasUnread(space)
        ) {
            onSpaceTapped?()
            selectedSpaceId = space.id
        } label: {
            AvatarView(name: space.name, mxcURL: space.avatarURL, size: 36, shape: AnyShape(.rect(cornerRadius: 36 * 0.22)))
                .badge(at: .topTrailing) {
                    spaceUnreadBadge(for: space)
                }
        }
        .contextMenu {
            Button("Leave Space", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                onLeaveSpace?(space)
            }
        }
    }

    private func subSpaceButton(_ space: RoomRowData) -> some View {
        SpaceRailButton(
            isSelected: selectedSpaceId == space.id,
            hasUnread: spaceHasUnread(space)
        ) {
            onSpaceTapped?()
            selectedSpaceId = space.id
        } label: {
            AvatarView(name: space.name, mxcURL: space.avatarURL, size: 26, shape: AnyShape(.rect(cornerRadius: 26 * 0.22)))
                .badge(at: .topTrailing) {
                    spaceUnreadBadge(for: space)
                }
        }
        .contextMenu {
            Button("Leave Space", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                onLeaveSpace?(space)
            }
        }
    }

    // MARK: - Helpers

    private func spaceHasUnread(_ space: RoomRowData) -> Bool {
        rooms.contains { room in
            room.parentSpaceIds.contains(space.id)
                && room.notificationCount > 0
                && !room.isMuted
        }
    }

    /// A colored dot badge for the space icon, or nothing when there are no unreads.
    ///
    /// The 1pt border keeps the small dot legible against the icon behind it.
    @ViewBuilder
    private func spaceUnreadBadge(for space: RoomRowData) -> some View {
        if let color = spaceUnreadColor(space) {
            AvatarBadge.dot(color: color)
                .overlay {
                    Circle().strokeBorder(.background, lineWidth: 1)
                }
        }
    }

    /// The badge color for unread activity in a space, or `nil` when there are no unreads.
    ///
    /// Returns red when any child room has unread mentions, keyword
    /// highlights, or is a DM with unread messages. Returns blue for plain
    /// unread messages in group rooms.
    private func spaceUnreadColor(_ space: RoomRowData) -> Color? {
        var hasUnread = false
        var hasHighPriority = false

        for room in rooms where room.parentSpaceIds.contains(space.id) && !room.isMuted {
            if room.needsAttention {
                hasHighPriority = true
                break
            }
            if room.notificationCount > 0 {
                hasUnread = true
            }
        }

        if hasHighPriority { return Color(.systemRed) }
        if hasUnread { return Color(.systemBlue) }
        return nil
    }
}

/// A single button in the space rail with selection indicator and unread badge.
struct SpaceRailButton<Label: View>: View {
    let isSelected: Bool
    var hasUnread: Bool = false
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            label
                .scaleEffect(isSelected ? 1.08 : 1.0)
                .padding(4)
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.5)) : AnyShapeStyle(.clear))
                }
                .animation(.easeInOut(duration: 0.15), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A short horizontal line separating the Home button from space icons.
struct SpaceRailDivider: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(.quaternary)
            .frame(width: 24, height: 2)
    }
}

// MARK: - Previews

#Preview("With Spaces") {
    @Previewable @State var selectedSpace: String?
    SpaceRail(
        spaces: PreviewFixtures.rooms.filter(\.isSpace),
        rooms: PreviewFixtures.rooms,
        selectedSpaceId: $selectedSpace
    )
    .frame(height: 400)
    .background(.background)
}

#Preview("No Spaces") {
    @Previewable @State var selectedSpace: String?
    SpaceRail(selectedSpaceId: $selectedSpace)
        .frame(height: 300)
        .background(.background)
}
