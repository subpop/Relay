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

/// A confirmation sheet shown before leaving a space.
///
/// Displays the space name, a list of child rooms with checkboxes (all selected by
/// default), ownership warnings, and a destructive "Leave" button.
struct LeaveSpaceSheet: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.errorReporter) private var errorReporter
    @Environment(\.dismiss) private var dismiss

    let spaceName: String
    let spaceId: String
    let children: [LeaveSpaceChild]

    @State private var selectedRoomIds: Set<String>
    @State private var isLeaving = false

    init(spaceName: String, spaceId: String, children: [LeaveSpaceChild]) {
        self.spaceName = spaceName
        self.spaceId = spaceId
        self.children = children
        self._selectedRoomIds = State(initialValue: Set(children.map(\.roomId)))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            childList
            Divider()
            footer
        }
        .frame(
            width: 400,
            height: min(CGFloat(children.count) * 52 + 200, 500)
        )
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Text("Leave \"\(spaceName)\"?")
                .font(.headline)
            Text("Select which rooms to leave along with this space.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    // MARK: - Child List

    private var childList: some View {
        List(children) { child in
            LeaveSpaceChildRow(
                child: child,
                isSelected: selectedRoomIds.contains(child.roomId),
                onToggle: { isOn in
                    if isOn {
                        selectedRoomIds.insert(child.roomId)
                    } else {
                        selectedRoomIds.remove(child.roomId)
                    }
                }
            )
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Leave Space", role: .destructive) {
                performLeave()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isLeaving)
        }
        .padding()
    }

    // MARK: - Actions

    private func performLeave() {
        isLeaving = true
        Task {
            do {
                try await matrixService.confirmLeaveSpace(
                    spaceId: spaceId,
                    roomIds: Array(selectedRoomIds)
                )
                dismiss()
            } catch {
                errorReporter.report(.roomLeaveFailed(error.localizedDescription))
                isLeaving = false
            }
        }
    }
}

// MARK: - Child Row

/// A single row in the leave-space child list with a checkbox toggle.
private struct LeaveSpaceChildRow: View {
    let child: LeaveSpaceChild
    let isSelected: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(
            get: { isSelected },
            set: { onToggle($0) }
        )) {
            HStack(spacing: 8) {
                AvatarView(name: child.name, mxcURL: child.avatarURL, size: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(child.name)
                        .lineLimit(1)

                    if child.isLastOwner {
                        Text("You are the last admin")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}

// MARK: - Previews

#Preview {
    LeaveSpaceSheet(
        spaceName: "Work",
        spaceId: "!space-work:matrix.org",
        children: [
            LeaveSpaceChild(roomId: "!general:matrix.org", name: "General", memberCount: 42),
            LeaveSpaceChild(roomId: "!design:matrix.org", name: "Design", memberCount: 15),
            LeaveSpaceChild(roomId: "!admin:matrix.org", name: "Admin", isLastOwner: true, memberCount: 3)
        ]
    )
    .environment(\.matrixService, PreviewMatrixService())
}
