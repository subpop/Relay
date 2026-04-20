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

/// A vertical icon rail on the leading edge of the sidebar for switching between spaces.
///
/// Each top-level space is represented by a rounded-rectangle avatar. When a space is
/// selected, any joined sub-spaces expand out below it with smaller icons, pushing
/// other spaces down. Clicking Home or a different space collapses the previous group.
struct SpaceRail: View {
    @Environment(\.matrixService) private var matrixService
    @Binding var selectedSpaceId: String?
    var onSpaceTapped: (() -> Void)?
    var onCreateSpace: (() -> Void)?
    var onLeaveSpace: ((RoomSummary) -> Void)?

    /// Top-level spaces (those not nested inside another joined space).
    private var topLevelSpaces: [RoomSummary] {
        matrixService.spaces.filter { $0.parentSpaceIds.isEmpty }
    }

    /// All joined sub-spaces that belong to the given top-level space, at any depth.
    ///
    /// This flattens the hierarchy so that a chain like Work → Engineering → Backend
    /// shows Engineering and Backend as peers under Work in the rail.
    private func subSpaces(of parentId: String) -> [RoomSummary] {
        matrixService.spaces.filter {
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

                if !matrixService.spaces.isEmpty {
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
        .frame(width: 52)
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

    private func spaceButton(_ space: RoomSummary) -> some View {
        SpaceRailButton(
            isSelected: selectedSpaceId == space.id,
            hasUnread: spaceHasUnread(space)
        ) {
            onSpaceTapped?()
            selectedSpaceId = space.id
        } label: {
            SpaceRailIcon(name: space.name, mxcURL: space.avatarURL, size: 36)
        }
        .contextMenu {
            Button("Leave Space", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                onLeaveSpace?(space)
            }
        }
    }

    private func subSpaceButton(_ space: RoomSummary) -> some View {
        SpaceRailButton(
            isSelected: selectedSpaceId == space.id,
            hasUnread: spaceHasUnread(space)
        ) {
            onSpaceTapped?()
            selectedSpaceId = space.id
        } label: {
            SpaceRailIcon(name: space.name, mxcURL: space.avatarURL, size: 26)
        }
        .contextMenu {
            Button("Leave Space", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                onLeaveSpace?(space)
            }
        }
    }

    // MARK: - Helpers

    private func spaceHasUnread(_ space: RoomSummary) -> Bool {
        matrixService.rooms.contains { room in
            room.parentSpaceIds.contains(space.id)
                && room.unreadMessages > 0
                && !room.isMuted
        }
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
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.tint, lineWidth: isSelected ? 2 : 0)
                        .animation(.easeInOut(duration: 0.15), value: isSelected)
                }
                .scaleEffect(isSelected ? 1.0 : 0.92)
                .animation(.easeInOut(duration: 0.15), value: isSelected)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(.primary)
                .frame(width: 3, height: isSelected ? 20 : (hasUnread ? 8 : 0))
                .offset(x: -4)
                .animation(.easeInOut(duration: 0.15), value: isSelected)
                .animation(.easeInOut(duration: 0.15), value: hasUnread)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A rounded-rectangle avatar for a space in the rail.
///
/// Unlike ``AvatarView`` which clips to a circle, this view uses a rounded
/// rectangle to visually distinguish spaces from user/room avatars.
struct SpaceRailIcon: View {
    @Environment(\.matrixService) private var matrixService
    let name: String
    let mxcURL: String?
    var size: CGFloat = 36

    @State private var image: NSImage?

    private var cornerRadius: CGFloat { size * 0.22 }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(StableNameColor.color(for: name))
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .task(id: mxcURL) {
            guard let mxcURL else {
                image = nil
                return
            }
            image = await matrixService.avatarThumbnail(mxcURL: mxcURL, size: size)
        }
    }

    private var initials: String {
        let words = name.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
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
    SpaceRail(selectedSpaceId: $selectedSpace)
        .environment(\.matrixService, PreviewMatrixService())
        .frame(height: 400)
        .background(.background)
}

#Preview("No Spaces") {
    @Previewable @State var selectedSpace: String?
    SpaceRail(selectedSpaceId: $selectedSpace)
        .frame(height: 300)
        .background(.background)
}
