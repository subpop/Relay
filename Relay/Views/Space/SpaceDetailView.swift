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

/// A breadcrumb entry in the space hierarchy navigation path.
struct SpaceBreadcrumb: Equatable {
    let spaceId: String
    let name: String?
}

/// The detail view shown when a space is selected in the sidebar rail.
///
/// ``SpaceDetailView`` displays the space's metadata and a grouped list of
/// child rooms and sub-spaces. Tapping a sub-space navigates deeper into the
/// hierarchy with a breadcrumb bar for navigation back up.
struct SpaceDetailView: View {
    @Environment(RelayClient.self) private var client
    @Environment(\.errorReporter) private var errorReporter
    let spaceId: String
    let spaceSummary: RoomRowData
    @Binding var selectedRoomId: String?

    /// Called when the user taps the Settings button. The parent view should
    /// open the inspector to the Settings tab.
    var onOpenSettings: (() -> Void)?

    @State private var path: [SpaceBreadcrumb] = []
    @State private var viewModel: SpaceHierarchyViewModel?
    @State private var hasLoaded = false
    @State private var leaveSpaceItem: LeaveSpaceItem?
    @State private var showAddRoomSheet = false
    @State private var childToRemove: SpaceChild?
    @State private var showCreateSubSpaceSheet = false

    /// The space ID currently being displayed (last in path, or root).
    private var currentSpaceId: String {
        path.last?.spaceId ?? spaceId
    }

    var body: some View {
        Form {
            Section {
                spaceHeader
            }

            if path.count > 0 {
                Section {
                    breadcrumbBar
                }
            }

            if !hasLoaded {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading rooms\u{2026}")
                        Spacer()
                    }
                    .padding(.vertical)
                }
            } else if let viewModel, viewModel.directChildren.isEmpty {
                Section {
                    if let loadError = viewModel.loadError {
                        ContentUnavailableView {
                            Label("Couldn't Load Space", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(loadError)
                        } actions: {
                            Button("Retry") {
                                Task { await viewModel.load() }
                            }
                            .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        ContentUnavailableView {
                            Label("No Rooms", systemImage: "square.stack.3d.up.slash")
                        } description: {
                            Text("This space doesn\u{2019}t have any rooms yet.")
                        } actions: {
                            if viewModel.canManageChildren {
                                Button("Add Room\u{2026}", systemImage: "plus") {
                                    showAddRoomSheet = true
                                }
                                .buttonStyle(.bordered)
                                .tint(.accentColor)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            } else if let viewModel {
                Section {
                    ForEach(viewModel.directChildren) { child in
                        SpaceChildRow(
                            child: child,
                            onJoin: !child.isJoined ? { joinChild(child, viewModel: viewModel) } : nil,
                            onTap: { handleChildTap(child) }
                        )
                        .contextMenu {
                            if viewModel.canManageChildren {
                                Button("Remove from Space", systemImage: "minus.circle", role: .destructive) {
                                    childToRemove = child
                                }
                            }
                        }
                        .contentShape(.rect)
                    }

                    // While the visible level is incomplete, the footer both
                    // signals loading and drives pagination. Once every
                    // direct child has a row, remaining (deeper, server-
                    // capped) pages continue silently in the background.
                    if !viewModel.isAtEnd, !viewModel.isCurrentLevelComplete {
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                            Spacer()
                        }
                        .onAppear {
                            Task { await viewModel.loadMore() }
                        }
                    }
                } header: {
                    HStack {
                        Text("Rooms")

                        Spacer()

                        if viewModel.canManageChildren {
                            Menu {
                                Button("Add Existing Room\u{2026}", systemImage: "plus.square.on.square") {
                                    showAddRoomSheet = true
                                }
                                Button("Create Sub-Space\u{2026}", systemImage: "square.stack.3d.up") {
                                    showCreateSubSpaceSheet = true
                                }
                            } label: {
                                Label("Add\u{2026}", systemImage: "plus")
                            }
                            .textCase(nil)
                            .font(.subheadline)
                        }
                    }
                }
            }

        }
        .formStyle(.grouped)
        .task(id: currentSpaceId) {
            hasLoaded = false
            let vm = SpaceHierarchyViewModel(spaceId: currentSpaceId, client: client)
            vm.errorReporter = errorReporter
            viewModel = vm
            await vm.load()
            hasLoaded = true
        }
        .onChange(of: spaceId) {
            // Reset path when a different top-level space is selected in the rail
            path = []
        }
        .sheet(item: $leaveSpaceItem) { item in
            LeaveSpaceSheet(spaceName: item.name, spaceId: item.id, children: item.children)
        }
        .sheet(isPresented: $showAddRoomSheet) {
            AddRoomToSpaceSheet(
                spaceId: currentSpaceId,
                spaceName: viewModel?.spaceName ?? currentDisplayName,
                existingChildIds: Set(viewModel?.directChildren.map(\.roomId.value) ?? [])
            )
        }
        .sheet(isPresented: $showCreateSubSpaceSheet) {
            CreateEntitySheet(
                kind: .subSpace(
                    parentId: currentSpaceId,
                    parentName: viewModel?.spaceName ?? currentDisplayName
                )
            )
        }
        .confirmationDialog(
            "Remove \(childToRemove?.name ?? "") from this space?",
            isPresented: Binding(
                get: { childToRemove != nil },
                set: { if !$0 { childToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let child = childToRemove {
                    removeChild(child)
                    childToRemove = nil
                }
            }
        } message: {
            Text("The room will be removed from the space hierarchy. Members can still access it directly.")
        }
    }

    // MARK: - Header

    private var spaceHeader: some View {
        VStack(spacing: 8) {
            AvatarView(
                name: viewModel?.spaceName ?? spaceSummary.name,
                mxcURL: viewModel?.spaceAvatarURL ?? spaceSummary.avatarURL,
                size: 64
            )

            Text(viewModel?.spaceName ?? currentDisplayName)
                .font(.title)
                .bold()

            if let topic = viewModel?.spaceTopic ?? spaceSummary.topic, !topic.isEmpty {
                Text(topic)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }

            HStack(spacing: 16) {
                if let memberCount = viewModel?.spaceMemberCount, memberCount > 0 {
                    Label("\(memberCount)", systemImage: "person.2")
                }
                if let childCount = viewModel?.directChildren.count, childCount > 0 {
                    Label("\(childCount) rooms", systemImage: "number")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let viewModel {
                HStack(spacing: 8) {
                    if let onOpenSettings {
                        Button("Settings", systemImage: "gearshape") {
                            onOpenSettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    
                    if viewModel.isJoined {
                        Button("Leave Space", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            leaveCurrentSpace()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Button("Join Space", systemImage: "plus.circle") {
                            joinCurrentSpace()
                        }
                        .buttonStyle(.bordered)
                        .tint(.accentColor)
                        .controlSize(.small)
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// The display name for the current level.
    private var currentDisplayName: String {
        path.last?.name ?? spaceSummary.name
    }

    // MARK: - Breadcrumb

    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            Button(spaceSummary.name) {
                navigateToLevel(0)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)

            ForEach(path.indices, id: \.self) { index in
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if index == path.count - 1 {
                    Text(path[index].name ?? path[index].spaceId)
                        .foregroundStyle(.primary)
                } else {
                    Button(path[index].name ?? path[index].spaceId) {
                        navigateToLevel(index + 1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }

            Spacer()
        }
        .font(.subheadline)
    }

    // MARK: - Actions

    private func joinCurrentSpace() {
        guard let viewModel else { return }
        Task {
            do {
                try await viewModel.joinRoom(roomId: currentSpaceId)
            } catch {
                errorReporter.report(.roomJoinFailed(error.localizedDescription))
            }
        }
    }

    private func leaveCurrentSpace() {
        Task {
            do {
                let children = try await client.leaveSpace(spaceId: spaceId)
                leaveSpaceItem = LeaveSpaceItem(
                    id: spaceId,
                    name: spaceSummary.name,
                    children: children
                )
            } catch {
                errorReporter.report(.roomLeaveFailed(error.localizedDescription))
            }
        }
    }

    private func removeChild(_ child: SpaceChild) {
        Task {
            do {
                try await client.removeChildFromSpace(childId: child.roomId.value, spaceId: currentSpaceId)
            } catch {
                errorReporter.report(.roomLeaveFailed(error.localizedDescription))
            }
        }
    }

    private func handleChildTap(_ child: SpaceChild) {
        if child.roomType == .space {
            // Always allow browsing into sub-spaces, joined or not
            path.append(SpaceBreadcrumb(spaceId: child.roomId.value, name: child.name))
        } else if child.isJoined {
            selectedRoomId = child.roomId.value
        }
    }

    private func navigateToLevel(_ level: Int) {
        if level == 0 {
            path = []
        } else {
            path = Array(path.prefix(level))
        }
    }

    private func joinChild(_ child: SpaceChild, viewModel: SpaceHierarchyViewModel) {
        Task {
            do {
                try await viewModel.joinRoom(roomId: child.roomId.value)
                try? await Task.sleep(for: .milliseconds(500))
                if child.roomType == .space {
                    // Browse into the newly joined sub-space
                    path.append(SpaceBreadcrumb(spaceId: child.roomId.value, name: child.name))
                } else {
                    selectedRoomId = child.roomId.value
                }
            } catch {
                errorReporter.report(.roomJoinFailed(error.localizedDescription))
            }
        }
    }
}

// MARK: - Previews

#Preview {
    SpaceDetailView(
        spaceId: "!space-work:matrix.org",
        spaceSummary: RoomRowData(
            roomId: "!space-work:matrix.org",
            name: "Work",
            topic: "Work-related rooms and discussions",
            isSpace: true
        ),
        selectedRoomId: .constant(nil)
    )
    .environment(RelayClient())
    .frame(width: 600, height: 600)
}
#Preview("No Rooms") {
    return SpaceDetailView(
        spaceId: "!space-empty:matrix.org",
        spaceSummary: RoomRowData(
            roomId: "!space-empty:matrix.org",
            name: "Empty Space",
            topic: "A space with no rooms",
            isSpace: true
        ),
        selectedRoomId: .constant(nil)
    )
    .environment(RelayClient())
    .frame(width: 600, height: 600)
}

