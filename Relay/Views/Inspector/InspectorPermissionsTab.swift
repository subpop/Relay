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

/// The Permissions tab of the inspector, showing grouped power level controls
/// that let admins configure which roles can perform which actions.
///
/// Each permission is presented as a role-based picker with options for
/// "Everyone" (0), "Moderator" (50), and "Admin" (100). Non-standard values
/// are shown as an additional "Custom (N)" option.
///
/// This tab is only shown when the current user has permission to change
/// the room's power levels.
struct InspectorPermissionsTab: View {
    let viewModel: TimelineInspectorViewModel

    @State private var settings: RoomPowerLevelSettings?
    @State private var isSaving = false
    @State private var hasPopulated = false

    var body: some View {
        Group {
            if let settings {
                permissionsContent(settings)
            } else if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("No Permission Settings", systemImage: "slider.horizontal.3")
                } description: {
                    Text("Power level settings are unavailable for this room.")
                } actions: {
                    Button("Retry") {
                        Task { await viewModel.retryLoading() }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .disabled(isSaving)
        .onChange(of: viewModel.isLoading) {
            populateFromDetails()
        }
        .onAppear {
            populateFromDetails()
        }
    }

    // MARK: - Content

    private func permissionsContent(_ current: RoomPowerLevelSettings) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                roomDetailsGroup(current)
                membershipGroup(current)
                messagesGroup(current)
                advancedGroup(current)
            }
            .padding(.vertical)
        }
    }

    // MARK: - Room Details Group

    private func roomDetailsGroup(_ current: RoomPowerLevelSettings) -> some View {
        GroupBox {
            VStack(spacing: 0) {
                powerLevelRow(
                    label: "Change name",
                    value: current.roomName,
                    onChange: { save(current, roomName: $0) }
                )
                Divider().padding(.vertical, 4)
                powerLevelRow(
                    label: "Change topic",
                    value: current.roomTopic,
                    onChange: { save(current, roomTopic: $0) }
                )
                Divider().padding(.vertical, 4)
                powerLevelRow(
                    label: "Change avatar",
                    value: current.roomAvatar,
                    onChange: { save(current, roomAvatar: $0) }
                )
            }
            .padding(.vertical, 2)
        } label: {
            Label("Room Details", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    // MARK: - Membership Group

    private func membershipGroup(_ current: RoomPowerLevelSettings) -> some View {
        GroupBox {
            VStack(spacing: 0) {
                powerLevelRow(
                    label: "Invite users",
                    value: current.invite,
                    onChange: { save(current, invite: $0) }
                )
                Divider().padding(.vertical, 4)
                powerLevelRow(
                    label: "Remove users",
                    value: current.kick,
                    onChange: { save(current, kick: $0) }
                )
                Divider().padding(.vertical, 4)
                powerLevelRow(
                    label: "Ban users",
                    value: current.ban,
                    onChange: { save(current, ban: $0) }
                )
            }
            .padding(.vertical, 2)
        } label: {
            Label("Membership", systemImage: "person.2")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    // MARK: - Messages Group

    private func messagesGroup(_ current: RoomPowerLevelSettings) -> some View {
        GroupBox {
            VStack(spacing: 0) {
                powerLevelRow(
                    label: "Send messages",
                    value: current.eventsDefault,
                    onChange: { save(current, eventsDefault: $0) }
                )
                Divider().padding(.vertical, 4)
                powerLevelRow(
                    label: "Delete messages",
                    info: "The power level required to delete another user's message.",
                    value: current.redact,
                    onChange: { save(current, redact: $0) }
                )
            }
            .padding(.vertical, 2)
        } label: {
            Label("Messages", systemImage: "text.bubble")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    // MARK: - Advanced Group

    private func advancedGroup(_ current: RoomPowerLevelSettings) -> some View {
        GroupBox {
            VStack(spacing: 0) {
                powerLevelRow(
                    label: "New members",
                    info: "The power level automatically assigned to users when they join this room.",
                    value: current.usersDefault,
                    onChange: { save(current, usersDefault: $0) }
                )
                Divider().padding(.vertical, 4)
                powerLevelRow(
                    label: "Change settings",
                    info: "The default power level required to send state events (e.g. room settings) that don't have a specific override above.",
                    value: current.stateDefault,
                    onChange: { save(current, stateDefault: $0) }
                )
            }
            .padding(.vertical, 2)
        } label: {
            Label("Advanced", systemImage: "slider.horizontal.3")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    // MARK: - Power Level Row

    private func powerLevelRow(
        label: String,
        info: String? = nil,
        value: Int,
        onChange: @escaping (Int) -> Void
    ) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let info {
                InfoPopoverButton(text: info)
            }

            Picker(label, selection: Binding(
                get: { value },
                set: { onChange($0) }
            )) {
                Text("Everyone").tag(Int(0))
                Text("Moderator").tag(Int(50))
                Text("Admin").tag(Int(100))
                // Show the current value as a custom option if it's non-standard.
                if value != 0 && value != 50 && value != 100 {
                    Text("Custom (\(value))").tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    // MARK: - Populate

    private func populateFromDetails() {
        guard viewModel.powerLevelSettings != nil, !hasPopulated else { return }
        settings = viewModel.powerLevelSettings
        hasPopulated = true
    }

    // MARK: - Save

    /// Builds a new settings value with one field overridden and saves it.
    private func save(
        _ current: RoomPowerLevelSettings,
        ban: Int? = nil,
        kick: Int? = nil,
        invite: Int? = nil,
        redact: Int? = nil,
        eventsDefault: Int? = nil,
        stateDefault: Int? = nil,
        usersDefault: Int? = nil,
        roomName: Int? = nil,
        roomTopic: Int? = nil,
        roomAvatar: Int? = nil
    ) {
        let updated = RoomPowerLevelSettings(
            ban: ban ?? current.ban,
            kick: kick ?? current.kick,
            invite: invite ?? current.invite,
            redact: redact ?? current.redact,
            eventsDefault: eventsDefault ?? current.eventsDefault,
            stateDefault: stateDefault ?? current.stateDefault,
            usersDefault: usersDefault ?? current.usersDefault,
            roomName: roomName ?? current.roomName,
            roomTopic: roomTopic ?? current.roomTopic,
            roomAvatar: roomAvatar ?? current.roomAvatar
        )
        settings = updated
        isSaving = true
        Task {
            defer { isSaving = false }
            try? await viewModel.updatePowerLevelSettings(updated)
        }
    }
}

// MARK: - Info Popover Button

/// A small info icon that shows a popover with explanatory text when clicked.
private struct InfoPopoverButton: View {
    let text: String

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(width: 200)
                .padding(10)
        }
    }
}

#Preview("Admin") {
    InspectorPermissionsTab(viewModel: .preview(asAdmin: true))
        .frame(width: 280, height: 700)
}
